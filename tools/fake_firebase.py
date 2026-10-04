#!/usr/bin/env python3
"""In-memory stand-in for the Firebase Realtime Database REST API (the subset LuluPet uses).

    python3 tools/fake_firebase.py [--port 8765] [--reject]

Then set the app's database URL to http://127.0.0.1:8765.

Supported:
  GET    <path>.json                      subtree or null
  GET    <path>.json?orderBy="ts"&startAt=N   children with ts >= N
         + Accept: text/event-stream      SSE: initial `put` of the matching children, then one
                                          `put` per new child, `keep-alive` every 15 s
  PUT    <path>.json                      store body, echo it
  POST   <path>.json                      append child with a time-ordered push id -> {"name": id}
  DELETE <path>.json                      remove subtree
  --reject                                every request gets 401 {"error": "Permission denied"}
  --stream-delay-ms N                     hold each live stream `put` for N ms (simulates a slow network, e.g.
                                          so two near-simultaneous sends both leave before either arrives)
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

KEEPALIVE_SECONDS = 15

tree = {}
changes = []          # (seq, parent path parts, child key, value) for every POST/PUT, used by streams
cond = threading.Condition()
push_counter = 0
log_lock = threading.Lock()


def log(msg):
    with log_lock:
        print(time.strftime("%H:%M:%S"), msg, flush=True)


def split_path(raw):
    path = unquote(raw)
    if path.endswith(".json"):
        path = path[: -len(".json")]
    return [p for p in path.split("/") if p]


def get_node(parts):
    node = tree
    for p in parts:
        if not isinstance(node, dict) or p not in node:
            return None
        node = node[p]
    return node


def set_node(parts, value):
    if not parts:
        global tree
        tree = value if isinstance(value, dict) else {}
        return
    node = tree
    for p in parts[:-1]:
        if not isinstance(node.get(p), dict):
            node[p] = {}
        node = node[p]
    if value is None:
        node.pop(parts[-1], None)
    else:
        node[parts[-1]] = value


def next_push_id():
    global push_counter
    push_counter += 1
    # Millisecond clock + counter keeps ids sortable in creation order.
    return "-%013d%06d" % (int(time.time() * 1000), push_counter)


def parse_query(query):
    q = {k: v[-1] for k, v in parse_qs(query).items()}
    order_by = q.get("orderBy")
    if order_by is not None:
        order_by = json.loads(order_by)
    start_at = json.loads(q["startAt"]) if "startAt" in q else None
    return order_by, start_at


def matches(value, order_by, start_at):
    if order_by is None or start_at is None:
        return True
    if not isinstance(value, dict):
        return False
    v = value.get(order_by)
    try:
        return v is not None and v >= start_at
    except TypeError:
        return False


def filtered(node, order_by, start_at):
    if order_by is None:
        return node
    if not isinstance(node, dict):
        return None
    out = {k: v for k, v in node.items() if matches(v, order_by, start_at)}
    return out or None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    reject = False
    stream_delay = 0.0

    def log_message(self, fmt, *args):
        pass  # we log request lines ourselves

    def send_json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        return json.loads(raw) if raw else None

    def start(self):
        log("%s %s" % (self.command, self.path))
        if self.reject:
            self.send_json(401, {"error": "Permission denied"})
            return None
        url = urlsplit(self.path)
        return split_path(url.path), url.query

    def do_GET(self):
        r = self.start()
        if r is None:
            return
        parts, query = r
        try:
            order_by, start_at = parse_query(query)
        except (ValueError, KeyError):
            self.send_json(400, {"error": "bad query"})
            return
        if "text/event-stream" in (self.headers.get("Accept") or ""):
            self.stream(parts, order_by, start_at)
            return
        with cond:
            node = filtered(get_node(parts), order_by, start_at)
        self.send_json(200, node)

    def do_PUT(self):
        r = self.start()
        if r is None:
            return
        parts, _ = r
        body = self.read_body()
        with cond:
            set_node(parts, body)
            if parts:
                changes.append((len(changes), parts[:-1], parts[-1], body))
            cond.notify_all()
        self.send_json(200, body)

    def do_POST(self):
        r = self.start()
        if r is None:
            return
        parts, _ = r
        body = self.read_body()
        with cond:
            key = next_push_id()
            set_node(parts + [key], body)
            changes.append((len(changes), parts, key, body))
            cond.notify_all()
        self.send_json(200, {"name": key})

    def do_DELETE(self):
        r = self.start()
        if r is None:
            return
        parts, _ = r
        with cond:
            set_node(parts, None)
        self.send_json(200, None)

    def sse(self, event, data):
        self.wfile.write(("event: %s\ndata: %s\n\n" % (event, json.dumps(data, ensure_ascii=False))).encode())
        self.wfile.flush()

    def stream(self, parts, order_by, start_at):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        peer = "%s:%d" % self.client_address
        try:
            with cond:
                cursor = len(changes)
                snapshot = filtered(get_node(parts), order_by, start_at)
            self.sse("put", {"path": "/", "data": snapshot})
            deadline = time.monotonic() + KEEPALIVE_SECONDS
            while True:
                with cond:
                    while len(changes) == cursor and time.monotonic() < deadline:
                        cond.wait(deadline - time.monotonic())
                    new = changes[cursor:]
                    cursor = len(changes)
                for _, parent, key, value in new:
                    if parent == parts and value is not None and matches(value, order_by, start_at):
                        if self.stream_delay:
                            time.sleep(self.stream_delay)
                        self.sse("put", {"path": "/" + key, "data": value})
                        deadline = time.monotonic() + KEEPALIVE_SECONDS
                if time.monotonic() >= deadline:
                    self.sse("keep-alive", None)
                    deadline = time.monotonic() + KEEPALIVE_SECONDS
        except (BrokenPipeError, ConnectionResetError):
            log("stream closed %s" % peer)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--reject", action="store_true", help="answer every request with 401")
    ap.add_argument("--stream-delay-ms", type=int, default=0, help="delay each live stream event by N ms")
    args = ap.parse_args()
    Handler.reject = args.reject
    Handler.stream_delay = args.stream_delay_ms / 1000
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    log("fake firebase on http://%s:%d%s" % (args.host, args.port, " (rejecting)" if args.reject else ""))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
