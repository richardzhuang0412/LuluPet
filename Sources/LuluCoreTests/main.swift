// Minimal test runner (no XCTest / swift-testing without Xcode).
// Run: swift run LuluCoreTests
import Foundation
import LuluCore
import LuluSync

var failures = 0
var passes = 0
func check(_ cond: @autoclosure () throws -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
    do {
        if try cond() { passes += 1; return }
        print("FAIL \(name) (\(file):\(line))")
    } catch {
        print("FAIL \(name) threw \(error) (\(file):\(line))")
    }
    failures += 1
}

// MARK: Role
check(Role.lulu.partner == .lumei && Role.lumei.partner == .lulu, "role partner")
check(Role.lulu.displayName == "噜噜" && Role.lumei.displayName == "噜妹", "role display name")

// MARK: Message
let m = Message.text("想你", from: .lulu, ts: 1)
check(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(m)) == m, "message roundtrip")
check(Message.text(String(repeating: "a", count: 600), from: .lulu, ts: 1).text!.count == 500, "text truncated to 500")
check(Message.sticker("hug", from: .lumei, ts: 2).stickerId == "hug", "sticker message")
check(Message.poke(from: .lulu, ts: 3).kind == .poke, "poke message")
do {
    let payload = try JSONSerialization.jsonObject(with: Message.poke(from: .lulu, ts: 3).firebasePayload()) as! [String: Any]
    check(payload["id"] == nil && payload["from"] as? String == "lulu" && payload["ts"] as? Int == 3, "firebase payload omits id")
}

// MARK: PairCode
let code = PairCode.generate()
check(code.count == 24 && PairCode.isValid(code), "pair code generate/valid")
check(!PairCode.isValid("short"), "pair code too short")
check(!PairCode.isValid(String(repeating: "0", count: 24)), "pair code bad alphabet")
check(PairCode.normalize(" abcd efgh ") == "ABCDEFGH", "pair code normalize")

// MARK: Presence
check(Presence.isOnline(lastSeen: 1_000, now: 70_000), "presence online")
check(!Presence.isOnline(lastSeen: 1_000, now: 80_000), "presence offline after 75 s")
check(!Presence.isOnline(lastSeen: 0, now: 5_000), "presence lastSeen 0 = signed off")
check(!Presence.isOnline(lastSeen: nil, now: 5), "presence nil offline")

// MARK: SSE parser
var p = SSEParser()
check(p.feed(line: "event: put") == nil, "sse no emit on event line")
let e = p.feed(line: #"data: {"path":"/-Na","data":{"from":"lumei","kind":"text","text":"hi","ts":5}}"#)
check(e?.event == "put", "sse event name")
let single = e.map(FirebaseDecode.messages(from:)) ?? []
check(single.count == 1 && single[0].id == "-Na" && single[0].text == "hi", "decode single message")
check(p.feed(line: "") == nil && p.feed(line: ": comment") == nil, "sse ignores blank/comment")
let snap = SSEEvent(event: "put", data: #"{"path":"/","data":{"-B":{"from":"lulu","kind":"poke","ts":9},"-A":{"from":"lumei","kind":"sticker","stickerId":"hug","ts":3}}}"#)
check(FirebaseDecode.messages(from: snap).map(\.id) == ["-A", "-B"], "decode snapshot sorted by ts")
check(FirebaseDecode.messages(from: SSEEvent(event: "put", data: #"{"path":"/","data":null}"#)).isEmpty, "decode null")
check(FirebaseDecode.messages(from: SSEEvent(event: "keep-alive", data: "null")).isEmpty, "decode keep-alive")
let patch = SSEEvent(event: "patch", data: #"{"path":"/","data":{"-C":{"from":"lulu","kind":"text","text":"yo","ts":11}}}"#)
check(FirebaseDecode.messages(from: patch).first?.id == "-C", "decode patch")
check(FirebaseDecode.messages(from: SSEEvent(event: "put", data: #"{"path":"/-D/text","data":"x"}"#)).isEmpty, "ignore nested field put")
check(FirebaseDecode.isAuthRevoked(SSEEvent(event: "auth_revoked", data: "null")) && FirebaseDecode.isAuthRevoked(SSEEvent(event: "cancel", data: "null")), "cancel/auth_revoked")

// MARK: SpriteCatalog
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lulutest-\(UUID().uuidString)")
func makeClip(_ path: String, frames: Int) throws {
    let dir = tmp.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for i in 0..<frames { try Data([0]).write(to: dir.appendingPathComponent(String(format: "%03d.png", i))) }
    let meta = #"{"frames":\#(frames),"delays":\#(Array(repeating: 0.1, count: frames)),"width":100,"height":200}"#
    try meta.data(using: .utf8)!.write(to: dir.appendingPathComponent("meta.json"))
}
do {
    try makeClip("lumei/lace/idle", frames: 3)
    try makeClip("lumei/lace/happy", frames: 2)
    try makeClip("lumei/bow/idle", frames: 1)
    let cat = SpriteCatalog(root: tmp)
    check(cat.outfits(for: .lumei) == ["bow", "lace"], "catalog outfits sorted")
    check(cat.outfits(for: .lulu).isEmpty, "catalog missing character")
    check(cat.outfits(for: .lumei).contains(cat.randomOutfit(for: .lumei) ?? "-"), "catalog random outfit")
    let idle = cat.clip(.lumei, outfit: "lace", action: .idle)
    check(idle?.frames.count == 3 && idle?.delays.count == 3 && idle?.size == CGSize(width: 100, height: 200), "catalog clip")
    check(cat.clip(.lumei, outfit: "lace", action: .react)?.frames.count == 3, "catalog react falls back to idle")
    check(cat.clip(.lumei, outfit: "lace", action: .happy)?.frames.count == 2, "catalog happy")
    check(cat.clip(.lulu, outfit: "classic", action: .idle) == nil, "catalog nil for missing")
    check(cat.exactClip(.lumei, outfit: "lace", action: .run) == nil && cat.exactClip(.lumei, outfit: "lace", action: .happy)?.frames.count == 2,
          "catalog exactClip: optional run/wave don't fall back")
    check(cat.preferredOutfit(for: .lumei) == "bow", "catalog preferred = first sorted without order.json")
    check(cat.preferredOutfit(for: .lulu) == nil, "catalog preferred nil for missing")
    // order.json sets preference order; unknown names are skipped, unlisted outfits follow sorted.
    try makeClip("lumei/zebra/idle", frames: 1)
    try #"["lace","ghost","bow","lace"]"#.data(using: .utf8)!.write(to: tmp.appendingPathComponent("lumei/order.json"))
    check(cat.outfits(for: .lumei) == ["lace", "bow", "zebra"], "catalog outfits follow order.json")
    check(cat.preferredOutfit(for: .lumei) == "lace", "catalog preferred from order.json")
    try Data("not json".utf8).write(to: tmp.appendingPathComponent("lumei/order.json"))
    check(cat.outfits(for: .lumei) == ["bow", "lace", "zebra"], "catalog bad order.json falls back to sorted")
} catch { check(false, "catalog setup \(error)") }

// MARK: StickerCatalog
do {
    let sdir = tmp.appendingPathComponent("Stickers")
    try FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
    try #"[{"id":"hug","label":"抱抱","file":"hug.gif"}]"#.data(using: .utf8)!.write(to: sdir.appendingPathComponent("stickers.json"))
    let sc = StickerCatalog(root: sdir)
    check(sc.stickers.map(\.label) == ["抱抱"], "stickers load")
    check(sc.url(for: "hug")?.lastPathComponent == "hug.gif" && sc.url(for: "nope") == nil, "sticker url")
} catch { check(false, "sticker setup \(error)") }

// MARK: Config
let store = ConfigStore(profile: "test-\(UUID().uuidString)")
check(store.load() == nil, "config empty")
let cfg = AppConfig(role: .lumei, pairCode: code, databaseURL: "https://x-default-rtdb.firebaseio.com/")
store.save(cfg)
check(store.load() == cfg, "config roundtrip")
check(cfg.isComplete && !AppConfig(role: .lulu, pairCode: "x", databaseURL: "").isComplete, "config complete")
check(cfg.normalizedDatabaseURL == "https://x-default-rtdb.firebaseio.com", "config url normalized")
check(AppConfig(role: .lulu, pairCode: code, databaseURL: "http://127.0.0.1:8765").isComplete
      && AppConfig(role: .lulu, pairCode: code, databaseURL: "http://localhost:8765").isComplete
      && !AppConfig(role: .lulu, pairCode: code, databaseURL: "http://x-default-rtdb.firebaseio.com").isComplete
      && !AppConfig(role: .lulu, pairCode: code, databaseURL: "http://localhost.evil.com").isComplete,
      "config allows plain http only for localhost")
store.lastReadTs = 42
check(store.lastReadTs == 42, "lastReadTs persists")
store.wipe()

// MARK: FirebaseClient URL building
do {
    let u1 = try FirebaseClient.url(databaseURL: " https://x.firebaseio.com// ", pairCode: "ABC", path: "presence/lulu")
    check(u1.absoluteString == "https://x.firebaseio.com/pairs/ABC/presence/lulu.json", "fb url trims slashes")
    let u2 = try FirebaseClient.messageStreamURL(databaseURL: "https://x.firebaseio.com", pairCode: "ABC", since: 41)
    check(u2.absoluteString == "https://x.firebaseio.com/pairs/ABC/messages.json?orderBy=%22ts%22&startAt=42", "fb stream url query")
    check(URLComponents(url: u2, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "orderBy" }?.value == "\"ts\"", "fb orderBy decodes to quoted key")
} catch { check(false, "fb url \(error)") }
check((try? FirebaseClient.url(databaseURL: "not a url", pairCode: "ABC", path: "messages")) == nil, "fb bad url rejected")

// MARK: FirebaseClient over stubbed URLSession
final class StubProtocol: URLProtocol {
    struct Reply { var status: Int; var body: String; var contentType = "application/json" }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]      // key: "METHOD path"
    nonisolated(unsafe) static var requests: [(method: String, url: URL, body: Data?, accept: String?)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            body = d
        }
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        Self.lock.lock()
        Self.requests.append((method, url, body, request.value(forHTTPHeaderField: "Accept")))
        let accept = request.value(forHTTPHeaderField: "Accept")
        // "<METHOD> <path> sse" answers only streaming requests; plain "<METHOD> <path>" answers both.
        let sseReply = accept == "text/event-stream" ? Self.replies["\(method) \(url.path) sse"] : nil
        let reply = sseReply ?? Self.replies["\(method) \(url.path)"] ?? Reply(status: 404, body: "null")
        Self.lock.unlock()
        let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let stubConfig = URLSessionConfiguration.ephemeral
stubConfig.protocolClasses = [StubProtocol.self]
let stubSession = URLSession(configuration: stubConfig)
let fb = FirebaseClient(databaseURL: "https://stub.firebaseio.com/", pairCode: "PAIR", session: stubSession)
let sseBody = "event: put\ndata: {\"path\":\"/\",\"data\":{\"-A\":{\"from\":\"lumei\",\"kind\":\"text\",\"text\":\"hi\",\"ts\":5},\"-M\":{\"from\":\"lulu\",\"kind\":\"poke\",\"ts\":6}}}\n\nevent: keep-alive\ndata: null\n\nevent: put\ndata: {\"path\":\"/-B\",\"data\":{\"from\":\"lumei\",\"kind\":\"poke\",\"ts\":7}}\n\n"

func collect(_ stream: AsyncThrowingStream<SSEEvent, Error>) async -> (events: [SSEEvent], error: Error?) {
    var events: [SSEEvent] = []
    do { for try await ev in stream { events.append(ev) } } catch { return (events, error) }
    return (events, nil)
}

StubProtocol.replies = ["GET /pairs/PAIR/messages.json": .init(status: 200, body: sseBody, contentType: "text/event-stream")]
do {
    let (events, error) = await collect(fb.messageStream(since: 4))
    check(error == nil, "stream ends cleanly: \(String(describing: error))")
    check(events.map(\.event) == ["put", "keep-alive", "put"], "stream yields events")
    check(events.flatMap(FirebaseDecode.messages(from:)).map(\.id) == ["-A", "-M", "-B"], "stream events decode")
    let req = StubProtocol.requests.last
    check(req?.accept == "text/event-stream" && req?.url.query == "orderBy=%22ts%22&startAt=5", "stream request headers/query")
}
StubProtocol.replies = ["GET /pairs/PAIR/messages.json": .init(status: 401, body: #"{"error":"Permission denied"}"#)]
do {
    let (events, error) = await collect(fb.messageStream(since: 0))
    check(events.isEmpty && (error as? FirebaseError) == .http(401), "stream 401 throws http(401)")
}
StubProtocol.replies = ["GET /pairs/PAIR/messages.json": .init(status: 200, body: "event: cancel\ndata: null\n\n", contentType: "text/event-stream")]
do {
    let (_, error) = await collect(fb.messageStream(since: 0))
    check((error as? FirebaseError) == .cancelled, "stream cancel throws cancelled")
}
StubProtocol.replies = [
    "POST /pairs/PAIR/messages.json": .init(status: 200, body: #"{"name":"-X"}"#),
    "PUT /pairs/PAIR/presence/lulu.json": .init(status: 200, body: #"{"lastSeen":1}"#),
    "GET /pairs/PAIR/presence/lumei/lastSeen.json": .init(status: 200, body: "1234"),
    "GET /pairs/PAIR/presence/lulu/lastSeen.json": .init(status: 200, body: "null"),
]
do {
    StubProtocol.requests = []
    try await fb.post(.text("想你", from: .lulu, ts: 9))
    let post = StubProtocol.requests.last
    let postBody = post?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(post?.method == "POST" && postBody?["text"] as? String == "想你" && postBody?["ts"] as? Int == 9, "post sends payload")
    try await fb.heartbeat(.lulu)
    let hb = StubProtocol.requests.last
    let hbBody = hb?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(hb?.method == "PUT" && (hbBody?["lastSeen"] as? NSNumber).map { abs($0.int64Value - nowMs()) < 5_000 } == true, "heartbeat puts lastSeen")
    let seenLumei = try await fb.lastSeen(.lumei)
    check(seenLumei == 1234, "lastSeen number")
    let seenLulu = try await fb.lastSeen(.lulu)
    check(seenLulu == nil, "lastSeen null → nil")
} catch { check(false, "fb requests \(error)") }
StubProtocol.replies = [:]
do {
    try await fb.post(.poke(from: .lulu, ts: 1))
    check(false, "post 404 should throw")
} catch { check((error as? FirebaseError) == .http(404), "post 404 throws http(404)") }

// MARK: Visits (v0.2)
do {
    let v = Message.visit(from: .lumei, ts: 1759000000010)
    let payload = try JSONSerialization.jsonObject(with: v.firebasePayload()) as! NSDictionary
    check(payload == ["from": "lumei", "kind": "visit", "ts": 1759000000010, "v": 1] as NSDictionary, "visit payload \(payload)")
    let back = FirebaseDecode.messages(fromSnapshot: Data(#"{"-V":{"from":"lumei","kind":"visit","ts":1759000000010,"v":1}}"#.utf8))
    check(back.count == 1 && back[0].kind == .visit && back[0].id == "-V" && back[0].extra.isEmpty, "visit decodes as first-class kind")
    check(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(v)) == v, "visit history roundtrip")
    check(Message.Kind(rawValue: "visit") == .visit && Message.Kind.visit.rawValue == "visit", "visit raw value")
} catch { check(false, "visit \(error)") }
check(FirebaseDecode.isBacklog(SSEEvent(event: "put", data: #"{"path":"/","data":{}}"#)), "sse root put is backlog")
check(!FirebaseDecode.isBacklog(SSEEvent(event: "put", data: #"{"path":"/-X","data":{"from":"lulu","kind":"poke","ts":1}}"#)), "sse child put is live")
check(Visits.coupleMove(for: .visit) == .hug, "couple: visit → hug")
check(Visits.coupleMove(for: .text, text: "好想你呀") == .hug && Visits.coupleMove(for: .sticker, label: "抱抱") == .hug, "couple: 想你/抱抱 → hug")
check(Visits.coupleMove(for: .sticker, label: "亲亲") == .kiss && Visits.coupleMove(for: .text, text: "亲亲你") == .kiss, "couple: 亲亲 → kiss")
check(Visits.coupleMove(for: .poke) == .nuzzle && Visits.coupleMove(for: .text, text: "吃饭了吗") == .nuzzle
      && Visits.coupleMove(for: .unknown("voice")) == .nuzzle, "couple: others → nuzzle")
check(Visits.resolveCouple(.kiss, available: ["kiss", "hug"]) == .kiss, "couple: preferred available")
check(Visits.resolveCouple(.nuzzle, available: ["hug"]) == .hug, "couple: missing → hug")
check(Visits.resolveCouple(.kiss, available: []) == nil && Visits.resolveCouple(.hug, available: ["kiss"]) == nil, "couple: none → fallback")
check(Visits.dwell(for: .poke) == 4 && Visits.dwell(for: .visit) == 6 && Visits.dwell(for: .text) == Visits.bubbleDwell, "visit dwell per kind")
do {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    // Host (sprite 100 wide) near the right edge with room on its right → enters and stands right.
    let a = VisitGeometry.arrival(host: CGRect(x: 1000, y: 8, width: 100, height: 170), visitorWindowWidth: 150, visitorSpriteWidth: 110, screen: screen)
    check(a.entrySide == .right && a.standSide == .right && a.entryX == 1440 && a.standX + 20 == 1116, "arrival: nearer edge, stands on that side \(a)")
    // Host in the bottom-right corner: no room on the right → runs past and stands on the left.
    let b = VisitGeometry.arrival(host: CGRect(x: 1300, y: 8, width: 110, height: 170), visitorWindowWidth: 150, visitorSpriteWidth: 110, screen: screen)
    check(b.entrySide == .right && b.standSide == .left && b.standX + 20 + 110 == 1300 - 16, "arrival: no room → other side \(b)")
    let c = VisitGeometry.arrival(host: CGRect(x: 40, y: 8, width: 100, height: 170), visitorWindowWidth: 150, visitorSpriteWidth: 110, screen: screen)
    check(c.entrySide == .left && c.entryX == -150 && c.standSide == .right, "arrival: left edge \(c)")
    let g = VisitGeometry.go(window: CGRect(x: 1250, y: 8, width: 150, height: 214), spriteWidth: 110, screen: screen)
    check(g.side == .right && g.edgeX == 1440 - 150 + 20 && g.offscreenX == 1440, "go: right edge \(g)")
    let h = VisitGeometry.go(window: CGRect(x: 100, y: 8, width: 150, height: 214), spriteWidth: 110, screen: screen)
    check(h.side == .left && h.edgeX == -20 && h.offscreenX == -150, "go: left edge \(h)")
    check(abs(VisitGeometry.runDuration(440) - 2) < 1e-9, "run duration at 220 pt/s")
}
do {
    let croot = tmp.appendingPathComponent("Couples")
    try makeClip("Couples/hug", frames: 2)
    try #"{"frames":2,"delays":[0.1,0.1],"width":100,"height":200,"facing":"lulu-right"}"#.data(using: .utf8)!
        .write(to: croot.appendingPathComponent("hug/meta.json"))
    try makeClip("Couples/kiss", frames: 1)
    let cc = CoupleCatalog(root: croot)
    check(cc.names == ["hug", "kiss"], "couple catalog names")
    check(cc.clip(named: "hug")?.luluOnLeft == false && cc.clip(named: "kiss")?.luluOnLeft == true, "couple facing (default lulu-left)")
    check(cc.clip(named: "hug")?.mirrored(luluIsLeft: true) == true && cc.clip(named: "kiss")?.mirrored(luluIsLeft: true) == false, "couple mirroring")
    check(cc.clip(named: "nuzzle") == nil && CoupleCatalog(root: tmp.appendingPathComponent("nope")).names.isEmpty, "couple missing")
} catch { check(false, "couple catalog \(error)") }

// MARK: v0.3 clip lists (fidgets / stay)
check(ClipIndex.parse(Data(#"[{"name":"wiggle","dir":"fidget_0"},"fidget_1",{"dir":"fidget_2"},{"name":"x"},{"dir":"../idle"},7]"#.utf8))
      == [.init(name: "wiggle", dir: "fidget_0"), .init(name: "fidget_1", dir: "fidget_1"), .init(name: "fidget_2", dir: "fidget_2")],
      "clip index: objects, bare dirs, defaults; bad entries skipped")
check(ClipIndex.parse(Data("nope".utf8)).isEmpty && ClipIndex.parse(Data("{}".utf8)).isEmpty, "clip index: bad json = empty")
do {
    try makeClip("lulu/classic/idle", frames: 2)
    try makeClip("lulu/classic/fidget_0", frames: 4)
    try makeClip("lulu/classic/fidget_1", frames: 5)
    try makeClip("lulu/classic/stay_0", frames: 6)
    try makeClip("lulu/classic/sleep", frames: 3)
    let cat = SpriteCatalog(root: tmp)
    check(cat.namedClips(.lulu, outfit: "classic", list: .fidgets).isEmpty, "fidgets: no index = none")
    try #"[{"name":"a","dir":"fidget_0"},{"name":"gone","dir":"fidget_9"},{"name":"b","dir":"fidget_1"}]"#.data(using: .utf8)!
        .write(to: tmp.appendingPathComponent("lulu/classic/fidgets.json"))
    try #"[{"name":"sit","dir":"stay_0"}]"#.data(using: .utf8)!.write(to: tmp.appendingPathComponent("lulu/classic/stay.json"))
    let f = cat.namedClips(.lulu, outfit: "classic", list: .fidgets)
    check(f.map(\.name) == ["a", "b"] && f.map(\.clip.frames.count) == [4, 5], "fidgets: index order, missing clip skipped")
    let st = cat.namedClips(.lulu, outfit: "classic", list: .stay)
    check(st.map(\.name) == ["sit"] && st.first?.clip.frames.count == 6, "stay clips")
    check(cat.exactClip(.lulu, outfit: "classic", action: .sleep)?.frames.count == 3
          && cat.exactClip(.lumei, outfit: "lace", action: .sleep) == nil, "sleep is an optional action")
} catch { check(false, "clip list setup \(error)") }

// MARK: content-addressed clip store (Clips/<id>/ shared by several uses)
do {
    let res = tmp.appendingPathComponent("store-res")
    func write(_ path: String, _ json: String) throws {
        let url = res.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }
    try write("Clips/abc123/meta.json", #"{"frames":3,"width":120,"height":250,"ext":"webp"}"#)
    try write("Sprites/lumei/lace/idle/meta.json", #"{"clip":"abc123","frames":3,"delays":[0.1,0.2,0.3],"width":120,"height":250}"#)
    try write("Sprites/lumei/bow/idle/meta.json", #"{"clip":"abc123","frames":3,"delays":[0.5,0.5],"width":120,"height":250}"#)
    try write("Sprites/lumei/bow/fidget_0/meta.json", #"{"clip":"abc123","frames":3,"delays":[0.2,0.2,0.2],"width":120,"height":250}"#)
    try write("Sprites/lumei/bow/fidgets.json", #"[{"name":"spin","dir":"fidget_0"},{"name":"bad","dir":"fidget_1"}]"#)
    try write("Sprites/lumei/bow/fidget_1/meta.json", #"{"clip":"../abc123","delays":[0.1]}"#)
    try write("Sprites/lumei/bow/react/meta.json", #"{"clip":"missing","delays":[0.1]}"#)
    try write("Couples/hug/meta.json", #"{"clip":"abc123","frames":3,"delays":[0.1,0.1,0.1],"width":120,"height":250,"facing":"lulu-right"}"#)
    let cat = SpriteCatalog(root: res.appendingPathComponent("Sprites"))
    let lace = cat.clip(.lumei, outfit: "lace", action: .idle), bow = cat.clip(.lumei, outfit: "bow", action: .idle)
    let frame0 = res.appendingPathComponent("Clips/abc123/000.webp")
    check(lace?.frames.count == 3 && lace?.frames.first?.standardizedFileURL == frame0.standardizedFileURL
          && lace?.frames.last?.lastPathComponent == "002.webp" && lace?.size == CGSize(width: 120, height: 250),
          "clip store: frames resolved in Clips/<id>/ with the stored extension")
    check(lace?.frames == bow?.frames && lace?.delays == [0.1, 0.2, 0.3] && bow?.delays == [0.5, 0.5, 0.1],
          "clip store: outfits share frames, delays are per use (missing ones default)")
    check(cat.namedClips(.lumei, outfit: "bow", list: .fidgets).map(\.name) == ["spin"], "clip store: unsafe clip id skipped")
    check(cat.exactClip(.lumei, outfit: "bow", action: .react) == nil && cat.clip(.lumei, outfit: "bow", action: .react)?.frames == bow?.frames,
          "clip store: missing stored clip = no clip (react falls back to idle)")
    check(cat.outfits(for: .lumei) == ["bow", "lace"], "clip store: outfits still found by idle/meta.json")
    let hug = CoupleCatalog(root: res.appendingPathComponent("Couples")).clip(named: "hug")
    check(hug?.clip.frames == lace?.frames && hug?.luluOnLeft == false, "clip store: couples read the same store")
    // v0.9: clip-bound sound + heightFactor in a couple's meta; sound in a clip index entry.
    check(hug?.sound == nil && hug?.heightFactor == 1, "couple meta: no sound / heightFactor = defaults")
    try write("Couples/sleep/meta.json", #"{"clip":"abc123","frames":3,"delays":[0.1],"width":120,"height":250,"facing":"lulu-right","sound":"sleep_snore","heightFactor":0.7}"#)
    try write("Couples/crazy/meta.json", #"{"clip":"abc123","frames":3,"delays":[0.1],"width":120,"height":250,"sound":"","heightFactor":9}"#)
    let cc = CoupleCatalog(root: res.appendingPathComponent("Couples"))
    check(cc.clip(named: "sleep")?.sound == "sleep_snore" && cc.clip(named: "sleep")?.heightFactor == 0.7, "couple meta: sound + heightFactor read")
    check(cc.clip(named: "crazy")?.sound == nil && cc.clip(named: "crazy")?.heightFactor == 1.5, "couple meta: empty sound = none, heightFactor clamped")
    try write("Sprites/lulu/classic/clips.json", #"[{"name":"comein","dir":"clip_0","sound":"lulu_comein"},{"name":"plain","dir":"clip_1"}]"#)
    try write("Sprites/lulu/classic/clip_0/meta.json", #"{"clip":"abc123","delays":[0.1]}"#)
    try write("Sprites/lulu/classic/clip_1/meta.json", #"{"clip":"abc123","delays":[0.1]}"#)
    let extras = cat.namedClips(.lulu, outfit: "classic", list: .clips)
    check(extras.map(\.name) == ["comein", "plain"] && extras.map(\.sound) == ["lulu_comein", nil], "clip index: optional bound sound")
    check(ClipIndex.parse(#"[{"name":"a","dir":"clip_0"}, "stay_0"]"#.data(using: .utf8)!).allSatisfy { $0.sound == nil }, "clip index: old entries have no sound")
    let ct = ReactionTable(entries: ReactionTable.parse(#"{"click": {"visitor": {"lulu": ["fart"]}}}"#.data(using: .utf8)!))
    check(ct.clickClips(for: .lulu) == ["fart"] && ct.clickClips(for: .lumei).isEmpty && ReactionTable.clickChance > 0 && ReactionTable.clickChance < 1, "click clips pool")
} catch { check(false, "clip store setup \(error)") }

// MARK: v0.3 reactions
do {
    let table = ReactionTable(entries: ReactionTable.parse(Data(#"""
    {"kiss": {"couple": "smooch", "visitor": "twirl"},
     "flower": {"visitor": "happy"},
     "sticker": {"couple": "cuddle"},
     "poke": {"couple": "kiss"},
     "bad": 3, "empty": {"couple": ""}}
    """#.utf8)))
    check(Set(table.entries.keys) == ["kiss", "flower", "sticker", "poke"], "reactions: bad / empty entries ignored")
    check(table.reaction(kind: .sticker, stickerId: "kiss") == Reaction(couple: "smooch", visitor: "twirl"), "reactions: sticker id first")
    check(table.reaction(kind: .sticker, stickerId: "flower") == Reaction(couple: "cuddle", visitor: "happy"), "reactions: merged with kind entry")
    check(table.reaction(kind: .sticker, stickerId: "other") == Reaction(couple: "cuddle"), "reactions: kind entry")
    check(table.reaction(kind: .poke, stickerId: nil)?.couple == "kiss" && table.reaction(kind: .text, stickerId: nil) == nil, "reactions: by kind / none")
    check(ReactionTable(url: tmp.appendingPathComponent("missing.json")).entries.isEmpty, "reactions: missing file")
    let per = ReactionTable(entries: ReactionTable.parse(Data(#"""
    {"hug": {"couple": "none", "visitor": {"lumei": "shy", "lulu": null}},
     "sticker": {"visitor": "happy"}}
    """#.utf8)))
    let hug = per.reaction(kind: .sticker, stickerId: "hug")
    check(hug?.visitorClip(for: .lumei) == "shy" && hug?.visitorClip(for: .lulu) == "happy", "reactions: per-character visitor, falls back to kind's")
    check(per.reaction(kind: .sticker, stickerId: nil)?.visitorClip(for: .lulu) == "happy", "reactions: '*' visitor")
    check(Visits.coupleName(reaction: hug?.couple, preferred: .hug, available: ["hug", "none"]) == nil, "couple name: none = no couple clip")
    // Resolution order: reaction couple (if built) → built-in preferred → hug → none.
    check(Visits.coupleName(reaction: "smooch", preferred: .kiss, available: ["smooch", "kiss", "hug"]) == "smooch", "couple name: reaction first")
    check(Visits.coupleName(reaction: "smooch", preferred: .kiss, available: ["kiss", "hug"]) == "kiss", "couple name: missing reaction clip → preferred")
    check(Visits.coupleName(reaction: nil, preferred: .nuzzle, available: ["hug"]) == "hug", "couple name: → hug")
    check(Visits.coupleName(reaction: "smooch", preferred: .kiss, available: []) == nil, "couple name: none")
}

// MARK: v0.3.1 random meeting pools
do {
    // Old single-string format still reads the same.
    let old = ReactionTable(entries: ReactionTable.parse(Data(#"{"hug": {"couple": "hug", "visitor": "happy"}}"#.utf8)))
    check(old.entries["hug"] == Reaction(couple: "hug", visitor: "happy") && old.entries["hug"]?.couples == ["hug"], "pools: old string format")
    // Lists (couple, visitor, per-character visitor), bad items and duplicates dropped, "*" default.
    let t = ReactionTable(entries: ReactionTable.parse(Data(#"""
    {"*": {"couple": ["hug", "kiss", "nuzzle"]},
     "missyou": {"couple": ["hug", "nuzzle", 3, "", "hug"], "visitor": ["wave", "happy"]},
     "cry": {"visitor": {"lulu": ["think", "shy"], "lumei": "pout"}},
     "morning": {"couple": "none"},
     "poke": {"couple": []},
     "empty": {"couple": [], "visitor": []}}
    """#.utf8)))
    check(t.entries["missyou"]?.couples == ["hug", "nuzzle"] && t.entries["missyou"]?.visitorClips(for: .lulu) == ["wave", "happy"], "pools: lists parsed")
    check(t.entries["cry"]?.visitorClips(for: .lulu) == ["think", "shy"] && t.entries["cry"]?.visitorClips(for: .lumei) == ["pout"], "pools: per-character lists")
    check(t.entries["empty"] == nil && t.entries["poke"] == nil, "pools: empty lists ignored")
    check(t.reaction(kind: .sticker, stickerId: "cry")?.couples == ["hug", "kiss", "nuzzle"], "pools: no couple → '*' default")
    check(t.reaction(kind: .poke, stickerId: nil)?.couples == ["hug", "kiss", "nuzzle"]
          && t.reaction(kind: .text, stickerId: nil)?.couples == ["hug", "kiss", "nuzzle"], "pools: poke / text use the default")
    check(t.reaction(kind: .sticker, stickerId: "morning")?.couples == ["none"], "pools: specific 'none' wins over default")
    check(ReactionTable(entries: [:]).reaction(kind: .text, stickerId: nil) == nil, "pools: no table, no reaction")

    // Seeded picks: deterministic, only built clips, never the same one twice in a row.
    let pool = ["hug", "kiss", "nuzzle", "dance", "missing"]
    let available: Set<String> = ["hug", "kiss", "nuzzle", "dance"]
    func run(seed: UInt64, _ n: Int) -> [String?] {
        var rng = SeededRandom(seed: seed)
        var last: String?
        return (0..<n).map { _ in
            let p = Visits.coupleName(pool: pool, preferred: .hug, available: available, last: last, using: &rng)
            last = p
            return p
        }
    }
    let a = run(seed: 7, 60)
    check(a == run(seed: 7, 60), "pick: same seed, same picks")
    check(a != run(seed: 8, 60), "pick: other seed, other picks")
    check(zip(a, a.dropFirst()).allSatisfy { $0 != $1 }, "pick: no immediate repeat")
    check(a.allSatisfy { $0 != nil && available.contains($0!) }, "pick: only built clips")
    check(Set(a.compactMap { $0 }) == available, "pick: every pool member shows up")
    var rng = SeededRandom(seed: 1)
    check(Visits.coupleName(pool: ["hug"], preferred: .kiss, available: ["hug", "kiss"], last: "hug", using: &rng) == "hug", "pick: single-item pool may repeat")
    check(Visits.coupleName(pool: ["missing"], preferred: .kiss, available: ["hug", "kiss"], last: nil, using: &rng) == "kiss", "pick: unbuilt pool → built-in rule")
    check(Visits.coupleName(pool: [], preferred: .nuzzle, available: ["hug"], last: nil, using: &rng) == "hug", "pick: empty pool → built-in rule")
    check(Visits.coupleName(pool: ["none"], preferred: .hug, available: ["hug"], last: nil, using: &rng) == nil, "pick: none = no couple clip")
    check((0..<20).allSatisfy { _ in Visits.coupleName(pool: ["none", "hug"], preferred: .hug, available: ["hug"], last: "none", using: &rng) == "hug" }, "pick: 'none' counts for no-repeat")
    check(PoolPick.pick([], last: nil, using: &rng) == nil && PoolPick.pick(["a", "b"], last: "a", using: &rng) == "b", "pool pick basics")
    check(Visits.keywordCouples(text: "亲亲你") == ["kiss", "kiss_2", "kiss_sit"] && Visits.keywordCouples(text: "好想你") != nil
          && Visits.keywordCouples(text: "吃饭了吗") == nil, "keyword couple pools")
    check(Set(Visits.keywordCouples(text: "想你")!).isSuperset(of: ["comfort", "hug_bed"]) && Set(Visits.keywordCouples(text: "抱抱")!).isSuperset(of: ["comfort", "hug_bed"]),
          "v0.9 keyword pools: 想你 / 抱抱 include comfort + hug_bed")
    // The shipped reactions file parses and the hug-ish stickers really are pools.
    let shipped = ReactionTable(url: URL(fileURLWithPath: "assets/reactions.json"))
    if !shipped.entries.isEmpty {
        for id in ["missyou", "run", "night", "cry", "sleeptogether", "hug"] {
            check((shipped.entries[id]?.couples.count ?? 0) >= 2, "shipped reactions: \(id) has a couple pool")
        }
        check((shipped.entries["*"]?.couples.count ?? 0) >= 5, "shipped reactions: default pool")
        // v0.9 pools (human-reviewed clips)
        func has(_ id: String, _ names: [String]) -> Bool { Set(shipped.entries[id]?.couples ?? []).isSuperset(of: names) }
        check(shipped.entries["angry"]?.couples == ["angry"], "shipped reactions: angry pool (flawed coldwar / shout dropped)")
        check(has("cry", ["comfort"]) && has("hug", ["hug_bed", "comfort"]) && has("missyou", ["comfort", "cuddle_bed"]), "shipped reactions: cry / hug / missyou pools")
        check(has("nuzzle", ["cuddle_bed", "sniff", "lean"]) && has("goodgirl", ["cuddle_bed", "sniff", "lean"]), "shipped reactions: nuzzle / goodgirl pools")
        check(has("night", ["cuddle_bed", "lean"]) && has("sleeptogether", ["cuddle_bed", "lean"]), "shipped reactions: night / sleeptogether pools")
        check(has("*", ["sniff", "lean", "hug_bed"]), "shipped reactions: default pool has the new clips")
        // every couple a pool names exists in couples.json
        if let cdata = try? Data(contentsOf: URL(fileURLWithPath: "assets/couples.json")),
           let cobj = (try? JSONSerialization.jsonObject(with: cdata)) as? [String: Any] {
            let known = Set(cobj.keys).union(["none"])
            let used = shipped.entries.values.flatMap(\.couples)
            check(used.allSatisfy(known.contains), "shipped reactions: every pooled couple is in couples.json (\(Set(used).subtracting(known)))")
            for (name, v) in cobj {
                if let snd = (v as? [String: Any])?["sound"] as? String {
                    let sm = SoundManifest(url: URL(fileURLWithPath: "assets/sounds.json"))
                    check(!sm.files(for: snd).isEmpty, "shipped couples: \(name) sound \(snd) exists in sounds.json")
                }
            }
            func sound(_ n: String) -> String? { ((cobj[n] as? [String: Any])?["sound"]) as? String }
            check(sound("hug_sit") == "hug_missyou" && sound("hug") == nil && sound("hug_slow") == nil && sound("hug_soft") == nil, "shipped couples: only hug_sit says 我想你了")
            check(sound("angry") == "angry_hmph" && sound("dance") == "dance_lalala" && sound("comfort") == "comfort_missyou", "shipped couples: pair sounds")
        }
    }
}

// MARK: v0.3 idle (doze / fidgets)
do {
    var clock = DozeClock(threshold: 60, now: 1000)
    check(clock.check(now: 1030, blocked: false) == .wait(30), "doze: waits for the rest of the threshold")
    check(clock.check(now: 1060, blocked: true) == .wait(IdleRules.retry) && !clock.dozing, "doze: busy postpones")
    check(!DozeClock(threshold: 60, now: 0).isDue(now: 59) && clock.isDue(now: 1061), "doze: due after threshold")
    check(clock.check(now: 1061, blocked: false) == .doze && clock.dozing, "doze: dozes when due and idle")
    check(clock.check(now: 1100, blocked: false) == .none, "doze: already dozing")
    check(clock.activity(now: 1200) == true && !clock.dozing, "doze: activity wakes")
    check(clock.activity(now: 1210) == false && clock.check(now: 1240, blocked: false) == .wait(30), "doze: activity restarts the countdown")
    check(IdleRules.dozeAfter == 15 * 60 && IdleRules.fidgetInterval == 45...120, "idle defaults")
    check(IdleRules.fidgetDelay(fixed: nil, unit: 0) == 45 && IdleRules.fidgetDelay(fixed: nil, unit: 1) == 120
          && IdleRules.fidgetDelay(fixed: 5, unit: 0.3) == 5, "fidget delay range / fixed")
    check(IdleRules.pickFidget(count: 0, last: nil) { _ in 0 } == nil, "fidget: none")
    check(IdleRules.pickFidget(count: 1, last: 0) { _ in 0 } == 0, "fidget: single repeats")
    check(IdleRules.pickFidget(count: 3, last: 0) { _ in 0 } == 1 && IdleRules.pickFidget(count: 3, last: 2) { n in n - 1 } == 1,
          "fidget: never the last one")
    var seen = Set<Int>(), last: Int? = nil, repeats = 0
    for _ in 0..<200 {
        let i = IdleRules.pickFidget(count: 4, last: last) { Int.random(in: 0..<$0) }!
        if i == last { repeats += 1 }
        seen.insert(i); last = i
    }
    check(repeats == 0 && seen == [0, 1, 2, 3], "fidget: random picks cover all, no repeats")
}

// MARK: PairChannel over stubbed URLSession
let chHistoryDir = tmp.appendingPathComponent("channel-history")
let chHistory = HistoryStore(directory: chHistoryDir)
StubProtocol.replies = [
    "GET /pairs/PAIR/messages.json sse": .init(status: 200, body: sseBody, contentType: "text/event-stream"),
    // Plain GET = backfill: an old message only the server has, plus one the stream also delivers.
    "GET /pairs/PAIR/messages.json": .init(status: 200, body: #"{"-Z":{"from":"lumei","kind":"text","text":"old","ts":1},"-A":{"from":"lumei","kind":"text","text":"hi","ts":5}}"#),
    "PUT /pairs/PAIR/presence/lulu.json": .init(status: 200, body: "{}"),
    "GET /pairs/PAIR/presence/lumei/lastSeen.json": .init(status: 200, body: "\(nowMs())"),
    // v0.8 reads the whole presence object (an old client's shape: no dnd).
    "GET /pairs/PAIR/presence/lumei.json": .init(status: 200, body: "{\"lastSeen\":\(nowMs())}"),
    "POST /pairs/PAIR/messages.json": .init(status: 200, body: #"{"name":"-Y"}"#),
]
StubProtocol.requests = []
let chStore = ConfigStore(profile: "test-\(UUID().uuidString)")
let channel = PairChannel(config: AppConfig(role: .lulu, pairCode: "PAIR", databaseURL: "https://stub.firebaseio.com"), store: chStore, client: fb, history: chHistory)
nonisolated(unsafe) var got: [Message] = []
nonisolated(unsafe) var gotLive: [Bool] = []
nonisolated(unsafe) var states: [PairChannel.ConnectionState] = []
nonisolated(unsafe) var online: [Bool] = []
await MainActor.run {
    channel.onMessage = { got.append($0); gotLive.append($1) }
    channel.onConnection = { states.append($0) }
    channel.onPartnerOnline = { online.append($0) }
    channel.start()
    channel.send(.text("a", from: .lulu, ts: 100))
    channel.send(.text("b", from: .lulu, ts: 101))
    let c = channel.send(.text("c", from: .lulu, ts: 101))
    check(c.ts == 102, "channel makes send timestamps strictly increasing")
}
try? await Task.sleep(nanoseconds: 1_500_000_000)   // stub stream ends at once → offline, reconnects after 1 s
await MainActor.run {
    check(got.map(\.id) == ["-A", "-B"], "channel delivers partner messages once, drops own echo: \(got.map(\.id))")
    check(gotLive == [false, true], "channel flags backlog vs live messages: \(gotLive)")
    check(states.first == .connecting && states.contains(.connected) && states.contains(.offline), "channel states \(states)")
    check(online == [true], "channel partner online reported once")
    check(channel.outbox.isEmpty, "channel outbox flushed")
    let posted = StubProtocol.requests.filter { $0.method == "POST" }.compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String }
    check(posted == ["a", "b", "c"], "channel sends in order")
    check(StubProtocol.requests.filter { $0.method == "GET" && $0.url.path.hasSuffix("messages.json") }.count >= 2, "channel reconnects")
    channel.markRead(got[1])   // -B (ts 7) read while -A (ts 5) is still shown
    check(chStore.lastReadTs == 4, "markRead stops before an unread message: \(chStore.lastReadTs)")
    channel.markRead(got[0])
    check(chStore.lastReadTs == 7, "markRead advances once earlier messages are read")
    channel.markRead(Message.poke(from: .lumei, ts: 3))
    check(chStore.lastReadTs == 7, "markRead keeps max ts")
    channel.stop()
    let h = chHistory.all()
    // -Z/-A from backfill, -A/-M/-B from the stream (own echo -M included), -Y = first sent message
    // (the stub answers every POST with "-Y", so "b" and "c" dedupe against it).
    check(h.map(\.id) == ["-Z", "-A", "-M", "-B", "-Y"], "channel history records both directions + backfill once each: \(h.map(\.id))")
    check(h.last?.text == "a" && h.last?.localId != nil, "channel history stores sent message under push id with local id")
    check(StubProtocol.requests.filter { $0.method == "GET" && $0.accept != "text/event-stream" && $0.url.path.hasSuffix("messages.json") }.count == 1, "channel backfills once per launch")
    check(PairChannel.misconfigurationReason(FirebaseError.http(401)) == "数据库规则拒绝访问 (HTTP 401)" && PairChannel.misconfigurationReason(FirebaseError.http(503)) == nil, "misconfiguration reasons")
}
chStore.wipe()

// MARK: Upgrade compatibility — today's exact wire payloads (fixture)
let todayFixture = #"""
{"-O1text":{"from":"lulu","kind":"text","text":"想你","ts":1759000000001},
 "-O2stk":{"from":"lumei","kind":"sticker","stickerId":"hug","ts":1759000000002},
 "-O3poke":{"from":"lulu","kind":"poke","ts":1759000000003}}
"""#
do {
    let ms = FirebaseDecode.messages(fromSnapshot: Data(todayFixture.utf8))
    check(ms.map(\.id) == ["-O1text", "-O2stk", "-O3poke"] && ms.map(\.kind) == [.text, .sticker, .poke], "today's payloads decode")
    check(ms[0].text == "想你" && ms[1].stickerId == "hug" && ms.allSatisfy { $0.v == nil && $0.schemaVersion == 1 && $0.extra.isEmpty }, "today's payloads fields; absent v means 1")
    // Re-encoding an old message (no v) gives back exactly the stored object.
    let obj = try JSONSerialization.jsonObject(with: ms[1].firebasePayload()) as! NSDictionary
    check(obj == ["from": "lumei", "kind": "sticker", "stickerId": "hug", "ts": 1759000000002] as NSDictionary, "old payload re-encodes identically")
    // Newly sent messages carry v = 1 and otherwise the same field names as before.
    let sent = try JSONSerialization.jsonObject(with: Message.text("嗨", from: .lulu, ts: 7).firebasePayload()) as! [String: Any]
    check(Set(sent.keys) == ["from", "kind", "text", "ts", "v"] && sent["v"] as? Int == 1, "send writes v=1: \(sent.keys.sorted())")
    check(FirebaseDecode.messages(fromSnapshot: Data("null".utf8)).isEmpty, "snapshot null")
} catch { check(false, "fixture \(error)") }

// MARK: Upgrade compatibility — a future kind with extra fields
let futureJSON = #"{"from":"lumei","kind":"voice","ts":1759000000009,"v":2,"audioUrl":"https://x/y.m4a","durationSec":3.5,"meta":{"codec":"aac","tags":["a",1,true,null]}}"#
do {
    let ev = SSEEvent(event: "put", data: #"{"path":"/-Fut","data":"# + futureJSON + "}")
    let fut = FirebaseDecode.messages(from: ev)
    check(fut.count == 1 && fut[0].id == "-Fut" && fut[0].kind == .unknown("voice") && fut[0].kind.rawValue == "voice", "future kind kept, not dropped")
    check(fut.first?.schemaVersion == 2 && fut.first?.extra["audioUrl"] == .string("https://x/y.m4a"), "future fields preserved")
    let original = try JSONSerialization.jsonObject(with: Data(futureJSON.utf8)) as! NSDictionary
    let again = try JSONSerialization.jsonObject(with: fut[0].firebasePayload()) as! NSDictionary
    check(original == again, "future message round-trips to identical JSON")
    // Local (history) encoding round-trips too, keeping id and extras.
    let local = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(fut[0]))
    check(local == fut[0], "future message local round-trip")
    check(Message.Kind(rawValue: "text") == .text && Message.unknownKindPlaceholder.contains("升级"), "kind raw values / placeholder")
} catch { check(false, "future \(error)") }

// MARK: HistoryStore
do {
    let hdir = tmp.appendingPathComponent("history-\(UUID().uuidString)")
    let hs = HistoryStore(directory: hdir)
    check(hs.count == 0 && hs.all().isEmpty, "history empty when missing")
    check(hs.append(Message(id: "-b", from: .lumei, kind: .text, text: "second", ts: 20)), "history append")
    check(hs.append(Message(id: "-a", from: .lulu, kind: .poke, ts: 10)), "history append 2")
    check(!hs.append(Message(id: "-a", from: .lulu, kind: .poke, ts: 10)), "history dedupes by id")
    check(hs.append(Message(id: "-c", from: .lulu, kind: .text, text: "mine", ts: 30, localId: "L1")), "history append sent")
    check(!hs.append(Message(id: "L1", from: .lulu, kind: .text, text: "mine", ts: 30)), "history dedupes by local id")
    check(hs.all().map(\.id) == ["-a", "-b", "-c"] && hs.count == 3, "history sorted by ts")
    let futureMsg = FirebaseDecode.messages(from: SSEEvent(event: "put", data: #"{"path":"/-f","data":"# + futureJSON + "}"))[0]
    hs.append(futureMsg)

    // Reload from disk (a relaunch / upgrade) and a second store on the same dir.
    let reloaded = HistoryStore(directory: hdir)
    check(reloaded.all() == hs.all() && reloaded.count == 4, "history reload from disk")
    check(reloaded.all().last == futureMsg, "history keeps future kind + extras across reload")
    let other = HistoryStore(directory: hdir)
    _ = other.count
    check(reloaded.append(Message(id: "-d", from: .lumei, kind: .text, text: "x", ts: 40)), "history append via second store")
    check(other.contains(id: "-d") && hs.contains(id: "-d"), "stores on the same dir see each other's appends")
    check(!other.append(Message(id: "-d", from: .lumei, kind: .text, text: "x", ts: 40)), "second store dedupes against first")

    // Crash mid-write: torn last line is ignored, and the next append seals it off.
    let fh = try FileHandle(forWritingTo: hs.fileURL)
    try fh.seekToEnd()
    try fh.write(contentsOf: Data(#"{"from":"lulu","id":"-torn","kind":"te"#.utf8))
    try fh.close()
    let afterCrash = HistoryStore(directory: hdir)
    check(afterCrash.count == 5 && !afterCrash.contains(id: "-torn"), "history tolerates truncated last line")
    check(afterCrash.append(Message(id: "-e", from: .lulu, kind: .poke, ts: 50)), "append after torn line")
    let fresh = HistoryStore(directory: hdir)
    check(fresh.count == 6 && fresh.contains(id: "-e"), "append after torn line readable: \(fresh.all().map(\.id))")
    let lines = try String(contentsOf: hs.fileURL, encoding: .utf8).split(separator: "\n")
    check(lines.count == 7, "file is append-only (6 records + 1 torn line): \(lines.count)")

    // Batch merge (backfill) dedupes against what is stored and within itself.
    let added = fresh.merge([Message(id: "-a", from: .lulu, kind: .poke, ts: 10), Message(id: "-g", from: .lumei, kind: .poke, ts: 5), Message(id: "-g", from: .lumei, kind: .poke, ts: 5)])
    check(added == 1 && fresh.all().first?.id == "-g", "history merge dedupes")
    check(HistoryStore.defaultDirectory(profile: nil).path.hasSuffix("Library/Application Support/LuluPet/default")
          && HistoryStore.defaultDirectory(profile: "A").lastPathComponent == "A", "history default directory")
} catch { check(false, "history \(error)") }

// MARK: Backfill via FirebaseClient (stubbed plain GET)
do {
    StubProtocol.replies = ["GET /pairs/PAIR/messages.json": .init(status: 200, body: todayFixture)]
    StubProtocol.requests = []
    let fetched = try await fb.allMessages()
    check(fetched.map(\.id) == ["-O1text", "-O2stk", "-O3poke"], "allMessages decodes snapshot")
    check(StubProtocol.requests.last?.accept == nil && StubProtocol.requests.last?.url.query == nil, "allMessages is a plain GET")
    let bdir = tmp.appendingPathComponent("backfill-\(UUID().uuidString)")
    let bs = HistoryStore(directory: bdir)
    bs.append(fetched[1])                                           // already stored locally
    bs.append(Message(id: "-local", from: .lulu, kind: .poke, ts: 1))
    check(bs.merge(fetched) == 2 && bs.count == 4, "backfill merge adds only missing")
    let refetched = try await fb.allMessages()
    check(bs.merge(refetched) == 0, "second backfill adds nothing")
    StubProtocol.replies = ["POST /pairs/PAIR/messages.json": .init(status: 200, body: #"{"name":"-P1"}"#)]
    let pushId = try await fb.post(.poke(from: .lulu, ts: 2))
    check(pushId == "-P1", "post returns push id")
} catch { check(false, "backfill \(error)") }

// MARK: Schema migrations
do {
    let ms = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(ms.schemaVersion == 1 && ms.runMigrations().isEmpty, "schema defaults to 1, no shipped migrations")
    nonisolated(unsafe) var order: [Int] = []
    let steps = [
        ConfigStore.Migration(version: 3) { _ in order.append(3) },
        ConfigStore.Migration(version: 2) { s in order.append(2); s.lastReadTs = 99 },
    ]
    check(ms.runMigrations(steps) == [2, 3] && order == [2, 3] && ms.schemaVersion == 3 && ms.lastReadTs == 99, "migrations run in order")
    check(ms.runMigrations(steps).isEmpty && order == [2, 3], "migrations run once")
    ms.wipe()
}

// MARK: v0.4 shortcuts
do {
    check(Shortcut.defaultToggle.display == "⌃⌥L" && Shortcut.defaultCompose.display == "⌃⌥M", "default shortcut display")
    check(Shortcut(keyCode: 37, modifiers: [.command, .shift, .control, .option], key: "L").display == "⌃⌥⇧⌘L", "modifier order ⌃⌥⇧⌘")
    check(Shortcut(keyCode: 37, modifiers: [.shift], key: "L").problem(conflictingWith: nil) != nil, "shift-only rejected")
    check(Shortcut(keyCode: 37, modifiers: [], key: "L").problem(conflictingWith: nil) != nil, "no modifier rejected")
    check(Shortcut(keyCode: 37, modifiers: [.command], key: "L").problem(conflictingWith: nil) == nil, "⌘ alone ok")
    check(Shortcut.defaultToggle.problem(conflictingWith: .defaultCompose) == nil, "defaults don't conflict")
    check(Shortcut(keyCode: 46, modifiers: [.control, .option], key: "M").problem(conflictingWith: .defaultCompose) != nil, "duplicate rejected")
    check(Shortcut.keyName(keyCode: 49, characters: " ") == "Space" && Shortcut.keyName(keyCode: 96, characters: nil) == "F5"
          && Shortcut.keyName(keyCode: 37, characters: "l") == "L", "key names")
    check(Shortcut.defaultToggle.menuKeyEquivalent == "l" && Shortcut(keyCode: 49, modifiers: [.control], key: "Space").menuKeyEquivalent == nil, "menu key equivalent")
    let rt = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(Shortcut.defaultCompose))
    check(rt == .defaultCompose, "shortcut JSON round trip")

    let ps = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(ps.toggleShortcut == .defaultToggle && ps.composeShortcut == .defaultCompose && ps.autoHideInFullscreen, "v0.4 prefs default")
    let custom = Shortcut(keyCode: 3, modifiers: [.command, .option], key: "F")
    ps.toggleShortcut = custom
    ps.autoHideInFullscreen = false
    check(ps.toggleShortcut == custom && !ps.autoHideInFullscreen && ps.composeShortcut == .defaultCompose, "v0.4 prefs persist")
    check(ps.defaults.data(forKey: "hotkeyToggle") != nil && ps.defaults.object(forKey: "autoHideFullscreen") != nil
          && ps.defaults.object(forKey: "config") == nil, "v0.4 keys are new keys only")
    ps.wipe()
} catch { check(false, "shortcuts \(error)") }

// MARK: v0.4 hide state
do {
    var h = HideState()
    check(!h.isHidden, "hide: shown by default")
    h.hide(.fiveMinutes, now: 100)
    check(h.isHidden && h.remaining(now: 160) == 240, "hide 5 min")
    check(!h.expire(now: 399) && h.isHidden, "hide not yet expired")
    check(h.expire(now: 400) && !h.isHidden, "hide expires after 5 min")
    h.hide(.untilReopened, now: 0)
    check(!h.expire(now: 1e9) && h.isHidden && h.remaining(now: 5) == nil, "hide until reopened never expires")
    h.fullscreen = true
    h.showManually()
    check(h.isHidden, "fullscreen keeps it hidden after manual show")
    h.fullscreen = false
    check(!h.isHidden, "shown after leaving fullscreen")
    check(HideOption.allCases.map(\.title) == ["5 分钟", "30 分钟", "1 小时", "直到我再打开"]
          && HideOption.oneHour.duration == 3600 && HideOption.untilReopened.duration == nil, "hide options")
}

// MARK: v0.4 away summary
do {
    let label: (String) -> String? = { ["hug": "抱抱", "kiss": "亲亲"][$0] }
    check(AwaySummary.build([], stickerLabel: label) == nil, "away summary empty → nil")
    check(AwaySummary.build([.poke(from: .lulu, ts: 1)], me: .lulu, stickerLabel: label) == nil, "away summary ignores my own messages")
    let msgs: [Message] = [
        .text("在吗", from: .lumei, ts: 1), .poke(from: .lumei, ts: 2), .sticker("hug", from: .lumei, ts: 3),
        .visit(from: .lumei, ts: 4), .poke(from: .lumei, ts: 5), .text("想你啦", from: .lumei, ts: 6),
        Message(from: .lumei, kind: .unknown("voice"), ts: 7), .sticker("kiss", from: .lumei, ts: 8), .sticker("hug", from: .lumei, ts: 9),
    ]
    let s = AwaySummary.build(msgs, me: .lulu, stickerLabel: label)!
    check(s.total == 9 && s.pokes == 2 && s.texts == 2 && s.visits == 1 && s.unknown == 1, "away summary counts")
    check(s.stickers.map(\.id) == ["hug", "kiss"] && s.stickers[0].count == 2, "away summary stickers grouped in first-seen order")
    check(s.lines == ["❤️ 爱心 ×2", "🤗 抱抱 ×2", "😘 亲亲", "💬 2 条消息", "🏃 来找过你 1 次", "✨ 1 条新版本消息"], "away summary lines: \(s.lines)")
    check(s.latestText == "想你啦", "away summary latest text")
    check(AwaySummary.build([.poke(from: .lumei, ts: 1)], stickerLabel: label)!.lines == ["❤️ 爱心"], "single poke has no ×1")
    let many = ["a", "b", "c", "d", "d", "e"].enumerated().map { Message.sticker($1, from: .lumei, ts: Int64($0)) }
    let ms = AwaySummary.build(many, stickerLabel: { _ in nil })!
    check(ms.lines.count == 4 && ms.lines.last == "🧸 还有 3 个表情" && ms.lines[0] == "🧸 表情", "away summary collapses extra stickers: \(ms.lines)")
}

// MARK: v0.4 history timeline
do {
    let sorted = (0..<10).map { Message(id: String(format: "-%02d", $0), from: $0 % 2 == 0 ? .lulu : .lumei, kind: .text, text: "\($0)", ts: Int64($0 / 2)) }
    let p1 = HistoryTimeline.page(sorted, limit: 4)
    check(p1.messages.map(\.id) == ["-06", "-07", "-08", "-09"] && p1.hasMore, "history page: newest first page")
    let p2 = HistoryTimeline.page(sorted, limit: 4, before: p1.messages.first)
    check(p2.messages.map(\.id) == ["-02", "-03", "-04", "-05"] && p2.hasMore, "history page: older page (ts ties by id)")
    let p3 = HistoryTimeline.page(sorted, limit: 4, before: p2.messages.first)
    check(p3.messages.map(\.id) == ["-00", "-01"] && !p3.hasMore, "history page: last page")
    check(HistoryTimeline.page([], limit: 4).messages.isEmpty && !HistoryTimeline.page([], limit: 4).hasMore, "history page: empty")
    check(HistoryTimeline.page(sorted, limit: 200).messages.count == 10 && !HistoryTimeline.page(sorted, limit: 200).hasMore, "history page: all fits")

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10))!
    func at(_ d: Int, _ h: Int, y: Int = 2026, mo: Int = 9) -> Int64 {
        Int64(cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!.timeIntervalSince1970 * 1000)
    }
    check(HistoryTimeline.dayLabel(Date(timeIntervalSince1970: Double(at(28, 1)) / 1000), now: now, calendar: cal) == "今天", "day label today")
    check(HistoryTimeline.dayLabel(Date(timeIntervalSince1970: Double(at(27, 23)) / 1000), now: now, calendar: cal) == "昨天", "day label yesterday")
    check(HistoryTimeline.dayLabel(Date(timeIntervalSince1970: Double(at(26, 9)) / 1000), now: now, calendar: cal) == "9月26日", "day label date")
    check(HistoryTimeline.dayLabel(Date(timeIntervalSince1970: Double(at(3, 9, y: 2025, mo: 12)) / 1000), now: now, calendar: cal) == "2025年12月3日", "day label other year")
    check(HistoryTimeline.timeLabel(at(26, 9) + 5 * 60_000, calendar: cal) == "09:05", "time label")
    let dayMsgs = [at(26, 9), at(26, 20), at(27, 8), at(28, 9), at(28, 9) + 1].enumerated().map {
        Message(id: "-d\($0)", from: .lulu, kind: .poke, ts: $1)
    }
    let rows = HistoryTimeline.rows(dayMsgs, now: now, calendar: cal)
    let shape = rows.map { r -> String in if case .day(let l, _) = r { return "[\(l)]" }; if case .message(let m) = r { return m.id }; return "?" }
    check(shape == ["[9月26日]", "-d0", "-d1", "[昨天]", "-d2", "[今天]", "-d3", "-d4"], "history rows with day separators: \(shape)")
    check(Set(rows.map(\.id)).count == rows.count, "history row ids unique")

    // HistoryStore.page reads from disk, and picks up appends made after the first read.
    let pdir = tmp.appendingPathComponent("page-\(UUID().uuidString)")
    let ph = HistoryStore(directory: pdir)
    ph.merge(sorted)
    let page = ph.page(limit: 3)
    check(page.messages.map(\.id) == ["-07", "-08", "-09"] && page.hasMore, "HistoryStore.page newest")
    ph.append(Message(id: "-10", from: .lumei, kind: .poke, ts: 99))
    check(HistoryStore(directory: pdir).page(limit: 2).messages.map(\.id) == ["-09", "-10"], "HistoryStore.page sees new appends")
    check(ph.page(limit: 2).messages.map(\.id) == ["-09", "-10"], "HistoryStore.page cache invalidated on append")
    check(ph.page(limit: 50, before: ph.page(limit: 2).messages.first).messages.count == 9, "HistoryStore.page older")
}

// MARK: v0.5 sounds
do {
    // Manifest: a string or a list per event; junk dropped; missing files left out.
    let json = #"{"poke": "p.m4a", "hug": ["h1.m4a", "h2.m4a", "h1.m4a", ""], "bgm": ["b.m4a"], "bad": 3, "empty": [], "kiss": ["gone.m4a"]}"#
    let man = SoundManifest(entries: SoundManifest.parse(json.data(using: .utf8)!))
    check(man.files(for: "poke") == ["p.m4a"], "sound manifest: string value")
    check(man.files(for: "hug") == ["h1.m4a", "h2.m4a"], "sound manifest: array, duplicates / empty dropped")
    check(man.entries["bad"] == nil && man.entries["empty"] == nil, "sound manifest: junk keys omitted")
    check(man.files(for: "click").isEmpty, "sound manifest: absent event = no files")
    check(SoundManifest.parse("not json".data(using: .utf8)!).isEmpty && SoundManifest.parse("[]".data(using: .utf8)!).isEmpty, "sound manifest: bad file = empty")
    check(SoundManifest(url: tmp.appendingPathComponent("nope/sounds.json")).entries.isEmpty, "sound manifest: missing file = empty")
    let r = man.resolved { $0 != "gone.m4a" && $0 != "h2.m4a" }
    check(r.manifest.files(for: "kiss").isEmpty && r.manifest.entries["kiss"] == nil, "sound manifest: all files missing → event skipped")
    check(r.manifest.files(for: "hug") == ["h1.m4a"], "sound manifest: missing file dropped from pool")
    check(r.missing == ["hug: h2.m4a", "kiss: gone.m4a"], "sound manifest: missing listed \(r.missing)")
    check(SoundEvent.allCases.count == 16 && SoundEvent(rawValue: "awaySummary") == .awaySummary && SoundEvent(rawValue: "notHome") == .notHome, "sound events")

    // Selection: random, no immediate repeat, per event.
    var picker = SoundPicker()
    var rng = SeededRandom(seed: 7)
    var prev: String?
    var seen = Set<String>()
    var repeated = false
    for _ in 0..<60 {
        let f = picker.pick("hug", from: ["a", "b", "c"], using: &rng)!
        if f == prev { repeated = true }
        prev = f
        seen.insert(f)
    }
    check(!repeated && seen == ["a", "b", "c"], "sound pick: no immediate repeat, all used")
    check((0..<5).allSatisfy { _ in picker.pick("poke", from: ["only"], using: &rng) == "only" }, "sound pick: single file repeats")
    check(picker.pick("click", from: [], using: &rng) == nil, "sound pick: empty pool")
    // Memory is per event: picking "kiss" doesn't change what "hug" avoids.
    var p2 = SoundPicker()
    _ = p2.pick("hug", from: ["a"], using: &rng)
    _ = p2.pick("kiss", from: ["b"], using: &rng)
    check((0..<20).allSatisfy { _ in var q = p2; return q.pick("hug", from: ["a", "b"], using: &rng) == "b" }, "sound pick: per-event memory")

    // Throttle: same event not within 0.3 s; other events independent.
    var g = SoundGate(enabled: true)
    check(g.decide("poke", now: 10) == .play, "gate: first play")
    check(g.decide("poke", now: 10.2) == .throttled, "gate: throttled within 0.3 s")
    check(g.decide("hug", now: 10.2) == .play, "gate: other event not throttled")
    check(g.decide("poke", now: 10.31) == .play, "gate: plays again after 0.3 s")
    check(g.decide("poke", now: 10.5) == .throttled, "gate: throttle measured from the last start")

    // Mute and hidden.
    g.enabled = false
    check(g.decide("click", now: 20) == .muted && !g.allowsBGM, "gate: muted")
    g.enabled = true
    g.hidden = true
    check(g.decide("click", now: 21) == .hidden && g.decide("awaySummary", now: 21) == .hidden && !g.allowsBGM, "gate: nothing while hidden")
    g.hidden = false
    check(g.decide("click", now: 22) == .play && g.allowsBGM, "gate: plays when shown again")
    // Shown again: only the away card's sound while the batch is replayed.
    g.beginAwayOnly(now: 30, duration: 10)
    check(g.decide("arrive", now: 30.1) == .awayOnly && g.decide("bubble", now: 30.2) == .awayOnly, "gate: away replay is quiet")
    check(g.decide("awaySummary", now: 30.5) == .play, "gate: away card sound plays")
    check(g.decide("hug", now: 41) == .play && g.awayOnlyUntil == nil, "gate: away-only expires")
    g.beginAwayOnly(now: 50, duration: 10)
    g.endAwayOnly()
    check(g.decide("bubble", now: 50.5) == .play, "gate: away-only ended early")
    check(SoundGate().enabled == SoundDefaults.enabled, "gate default = SoundDefaults.enabled")

    // Couple / sticker mapping.
    check(SoundEvent.forCouple("hug_sit") == .hug && SoundEvent.forCouple("kiss") == .kiss && SoundEvent.forCouple("nuzzle") == .nuzzle, "couple sound")
    check(SoundEvent.forCouple("angry") == .angry && SoundEvent.forCouple("dance_q") == .happy && SoundEvent.forCouple(nil) == .happy, "couple sound fallback")
    check(SoundEvent.forSticker("cry") == .cry && SoundEvent.forSticker("celebrate") == .happy && SoundEvent.forSticker("hug") == nil && SoundEvent.forSticker(nil) == nil, "sticker sound")
    check(SoundEvent.forCouple("sleep") == .doze && SoundEvent.forCouple("cuddle_bed") == .nuzzle && SoundEvent.forCouple("lean") == .nuzzle
          && SoundEvent.forCouple("sniff") == .nuzzle && SoundEvent.forCouple("comfort") == .hug && SoundEvent.forCouple("hug_bed") == .hug
          && SoundEvent.forCouple("coldwar") == .angry && SoundEvent.forCouple("shout") == .angry && SoundEvent.forCouple("bite") == .poke
          && SoundEvent.forCouple("makeup") == .happy, "v0.9 couple category sounds")
    // Clip-bound sound replaces the category sound; reaction sounds still win; sticker sound is after the clip's.
    check(SoundEvent.meetingKeys(reaction: [], clipSound: "hug_missyou", fallback: [], couple: "hug_sit") == ["hug_missyou", "hug"], "meeting keys: clip sound before category")
    check(SoundEvent.meetingKeys(reaction: ["x"], clipSound: "hug_missyou", fallback: ["cry"], couple: "comfort") == ["x", "hug_missyou", "cry", "hug"], "meeting keys: reaction, clip, sticker, category")
    check(SoundEvent.meetingKeys(reaction: [], clipSound: nil, fallback: [], couple: nil) == ["happy"], "meeting keys: no clip → happy")
    do {
        // first key with files wins: a clip sound whose files are missing falls through to the category sound
        let m = SoundManifest(entries: ["hug": ["h.m4a"], "hug_missyou": ["s06.m4a"]])
        let keys = SoundEvent.meetingKeys(reaction: [], clipSound: "hug_missyou", fallback: [], couple: "hug_sit")
        check(keys.first { !m.files(for: $0, visitor: .lumei).isEmpty } == "hug_missyou", "meeting keys: clip sound plays")
        let gone = m.resolved { $0 != "s06.m4a" }.manifest
        check(keys.first { !gone.files(for: $0, visitor: .lumei).isEmpty } == "hug", "meeting keys: missing clip sound → category")
    }
    // Character-specific voice lines (v0.9): {"file", "visitor"} entries.
    do {
        let j = #"{"arrive": ["a.m4a", {"file": "s01.m4a", "visitor": "lulu"}, {"file": "s02.m4a", "visitor": "lulu"}, {"file": "z.m4a", "visitor": "robot"}, {"visitor": "lulu"}, 5],"# +
                #" "goVisit": {"file": "s01.m4a", "visitor": "lulu"}, "plain": "p.m4a", "hug": ["h.m4a", {"file": "h.m4a", "visitor": "lumei"}]}"#
        let man = SoundManifest(url: { let u = tmp.appendingPathComponent("sf-\(UUID().uuidString).json"); try? j.data(using: .utf8)!.write(to: u); return u }())
        check(man.files(for: "arrive") == ["a.m4a", "s01.m4a", "s02.m4a", "z.m4a"], "voice filter: all files kept in entries (junk dropped)")
        check(man.files(for: "arrive", visitor: .lulu) == ["a.m4a", "s01.m4a", "s02.m4a", "z.m4a"], "voice filter: lulu gets the lulu lines")
        check(man.files(for: "arrive", visitor: .lumei) == ["a.m4a", "z.m4a"], "voice filter: lumei only gets neutral files (bad visitor value = neutral)")
        check(man.files(for: "arrive", visitor: nil) == ["a.m4a", "z.m4a"], "voice filter: unknown character = neutral only")
        check(man.files(for: "goVisit", visitor: .lumei).isEmpty && man.files(for: "goVisit", visitor: .lulu) == ["s01.m4a"], "voice filter: single object value; none for the other character")
        check(man.files(for: "plain", visitor: .lumei) == ["p.m4a"], "voice filter: plain string = neutral")
        check(man.files(for: "hug", visitor: .lumei) == ["h.m4a"], "voice filter: first mention of a file decides")
        // Old manifests (plain names only) parse exactly as before.
        let old = SoundManifest.parseFull(#"{"poke": "p.m4a", "hug": ["h1.m4a", "h2.m4a"]}"#.data(using: .utf8)!)
        check(old.only.isEmpty && old.entries == ["poke": ["p.m4a"], "hug": ["h1.m4a", "h2.m4a"]]
              && SoundManifest.parse(#"{"poke": "p.m4a"}"#.data(using: .utf8)!) == ["poke": ["p.m4a"]], "voice filter: old manifest unchanged")
        // Filters survive resolving; a filtered file whose file is missing is dropped with its filter.
        let r2 = man.resolved { $0 != "s02.m4a" }
        check(r2.manifest.files(for: "arrive", visitor: .lulu) == ["a.m4a", "s01.m4a", "z.m4a"] && r2.manifest.files(for: "arrive", visitor: .lumei) == ["a.m4a", "z.m4a"]
              && r2.missing.contains("arrive: s02.m4a"), "voice filter: kept through resolved()")
        // The shipped manifest: S01 / S02 are lulu-only, on arrive, and goVisit / goBack too.
        let shippedSounds = SoundManifest(url: URL(fileURLWithPath: "assets/sounds.json"))
        if !shippedSounds.entries.isEmpty {
            let arriveLumei = shippedSounds.files(for: "arrive", visitor: .lumei)
            let arriveLulu = shippedSounds.files(for: "arrive", visitor: .lulu)
            check(arriveLulu.contains("v4/S01.m4a") && arriveLulu.contains("v4/S02.m4a") && !arriveLumei.contains("v4/S01.m4a") && !arriveLumei.contains("v4/S02.m4a") && !arriveLumei.isEmpty,
                  "shipped sounds: arrive S01 / S02 only for a lulu visitor")
            check(shippedSounds.files(for: "goVisit", visitor: .lulu) == ["v4/S01.m4a"] && shippedSounds.files(for: "goVisit", visitor: .lumei).isEmpty
                  && shippedSounds.files(for: "goBack", visitor: .lulu).isEmpty && shippedSounds.files(for: "goBack", visitor: .lumei).isEmpty,
                  "shipped sounds: goVisit S01 only when our own pet is lulu; no goBack line (老公你回来啦 is 噜妹 greeting a visiting 噜噜, not my pet coming home)")
            check(shippedSounds.files(for: "poke").contains("v4/S03.m4a") && shippedSounds.files(for: "hug").contains("v4/S06.m4a") && shippedSounds.files(for: "cry").contains("v4/S08.m4a")
                  && shippedSounds.files(for: "angry").contains("v4/S10.m4a") && shippedSounds.files(for: "doze").contains("v4/S38.m4a") && shippedSounds.files(for: "doze").contains("v4/S39.m4a"),
                  "shipped sounds: category additions")
            check(shippedSounds.files(for: "dance_lalala") == ["v4/S05.m4a"] && shippedSounds.files(for: "angry_hmph") == ["v4/S10.m4a"]
                  && shippedSounds.files(for: "hug_missyou") == ["v4/S06.m4a"] && shippedSounds.files(for: "comfort_missyou") == ["v4/S06.m4a"], "shipped sounds: pair sounds")
            let all = shippedSounds.entries.values.flatMap { $0 }
            check(all.allSatisfy { FileManager.default.fileExists(atPath: "assets/sounds/" + $0) }, "shipped sounds: every file exists")
        }
    }
    check(SoundDefaults.presetIndex(for: 0.25) == 0 && SoundDefaults.presetIndex(for: 0.55) == 1 && SoundDefaults.presetIndex(for: 1) == 2, "volume preset index")

    // reactions.json "sound" (additive; layered sticker → kind → *).
    let rt = ReactionTable(entries: ReactionTable.parse(#"{"*": {"couple": "hug", "sound": "happy"}, "cry": {"sound": ["cry", "sob"]}, "angry": {"couple": "angry"}}"#.data(using: .utf8)!))
    check(rt.reaction(kind: .sticker, stickerId: "cry")?.sounds == ["cry", "sob"], "reaction sound pool")
    check(rt.reaction(kind: .sticker, stickerId: "cry")?.couples == ["hug"], "reaction sound-only entry keeps default couple")
    check(rt.reaction(kind: .sticker, stickerId: "angry")?.sounds == ["happy"], "reaction sound falls back to *")
    check(ReactionTable(entries: ReactionTable.parse(#"{"x": {"couple": "hug"}}"#.data(using: .utf8)!)).reaction(kind: .text, stickerId: nil) == nil
          && Reaction(couple: "hug").sounds.isEmpty, "reaction without sound")

    // Settings keys: defaults, round trip, clamping.
    let ss = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(ss.soundEnabled == SoundDefaults.enabled && ss.soundVolume == 0.25 && !ss.bgmEnabled, "sound prefs defaults (on, 小, no bgm)")
    ss.soundEnabled = false
    ss.soundVolume = 0.8
    ss.bgmEnabled = true
    check(!ss.soundEnabled && abs(ss.soundVolume - 0.8) < 0.0001 && ss.bgmEnabled, "sound prefs round trip")
    ss.soundVolume = 3
    check(ss.soundVolume == 1, "sound volume clamped")
    ss.wipe()
}

// MARK: v0.5 message field `outfit` (optional, additive)
do {
    let sent = Message(from: .lulu, kind: .text, text: "嗨", ts: 8, outfit: "bear")
    let wire = try JSONSerialization.jsonObject(with: sent.firebasePayload()) as! [String: Any]
    check(Set(wire.keys) == ["from", "kind", "text", "ts", "v", "outfit"] && wire["outfit"] as? String == "bear", "outfit sent on the wire")
    let back = Message.decode(firebaseKey: "-Out", value: wire)
    check(back?.outfit == "bear" && back?.extra.isEmpty == true, "outfit decodes into its field, not extra")
    let local = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(sent))
    check(local == sent && local.outfit == "bear", "outfit local (history) round-trip")
    let old = Message.decode(firebaseKey: "-Old", value: ["from": "lumei", "kind": "poke", "ts": 9] as [String: Any])
    check(old != nil && old?.outfit == nil, "missing outfit = nil (older sender)")
    let odd = Message.decode(firebaseKey: "-Odd", value: ["from": "lumei", "kind": "poke", "ts": 9, "outfit": 42] as [String: Any])
    check(odd != nil && odd?.outfit == nil, "non-string outfit tolerated")
    // Receiver: the sender's outfit if we have it, else the partner's preferred outfit.
    let have = ["lace", "maid", "angel"]
    check(OutfitRules.visitorOutfit(requested: "maid", available: have, fallback: "lace") == "maid", "visitor wears the sender's outfit")
    check(OutfitRules.visitorOutfit(requested: "bow", available: have, fallback: "lace") == "lace", "unknown sender outfit falls back to preferred")
    check(OutfitRules.visitorOutfit(requested: nil, available: have, fallback: "lace") == "lace", "no sender outfit: preferred")
} catch { check(false, "outfit field \(error)") }

// MARK: v0.6 送信串门: message field `trip` + PetLocation
do {
    let sent = Message(from: .lulu, kind: .poke, ts: 5, trip: Message.tripDeliver)
    let wire = try JSONSerialization.jsonObject(with: sent.firebasePayload()) as! [String: Any]
    check(wire["trip"] as? String == "deliver", "trip sent on the wire")
    let back = Message.decode(firebaseKey: "-T", value: wire)
    check(back?.trip == "deliver" && back?.extra.isEmpty == true && back?.isDeliveryTrip == true, "trip decodes into its field")
    check(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(sent)) == sent, "trip history round-trip")
    let old = Message.decode(firebaseKey: "-O", value: ["from": "lumei", "kind": "text", "text": "x", "ts": 9] as [String: Any])
    check(old?.trip == nil && old?.isDeliveryTrip == true, "missing trip (older sender) = deliver")
    check(Message(from: .lumei, kind: .text, ts: 1, trip: "local").isDeliveryTrip == false
          && Message(from: .lumei, kind: .text, ts: 1, trip: "teleport").isDeliveryTrip == true, "local / unknown trip values")
    let plain = try JSONSerialization.jsonObject(with: Message.poke(from: .lulu, ts: 3).firebasePayload()) as! [String: Any]
    check(plain["trip"] == nil, "no trip field unless set")
} catch { check(false, "trip field \(error)") }
check(Visits.deliveryAway(for: .poke) == 10 && Visits.deliveryAway(for: .text) == 12 && Visits.deliveryAway(for: .sticker) == 12
      && Visits.deliveryAway(for: .visit) == 10, "delivery away times")
check(Visits.resolveCollision(partnerTs: 100, myTs: 100, partner: .lulu) == .partner
      && Visits.resolveCollision(partnerTs: 100, myTs: 100, partner: .lumei) == .me, "collision: same ms, 噜噜 goes first")
check(Visits.resolveCollision(partnerTs: 99, myTs: 100, partner: .lumei) == .partner
      && Visits.resolveCollision(partnerTs: 101, myTs: 100, partner: .lulu) == .me, "collision: earlier ts goes first")
do {
    // Plain delivery: home → leaving → away → returning → home.
    var p = PetLocation()
    check(p.planSend(kind: .sticker, now: 0, visitorHere: false, reachable: true) == .deliver(away: 12) && p.place == .leaving, "send: deliver")
    p.sent(ts: 1000)
    check(p.tripTs == 1000, "send: trip ts recorded")
    p.reachedAway(now: 2)
    check(p.place == .away && p.awayRemaining(now: 2) == 12, "away for 12 s")
    // Rule 3: rapid sends while away extend to max(remaining, new).
    check(p.planSend(kind: .poke, now: 5, visitorHere: false, reachable: true) == .extendAway(away: 10) && p.awayRemaining(now: 5) == 10,
          "send while away: extend to max(9 left, 10)")
    check(p.planSend(kind: .poke, now: 5.5, visitorHere: false, reachable: true) == .extendAway(away: 10) && p.awayRemaining(now: 5.5) == 10, "again")
    check(p.planSend(kind: .text, now: 6, visitorHere: false, reachable: false) == .extendAway(away: 12) && p.awayRemaining(now: 6) == 12,
          "send while away: longer text extends (presence ignored)")
    p.sent(ts: 2000)
    check(p.tripTs == 1000, "later sends don't change the trip's ts")
    // Partner message while away: queued for the card (their later trip loses; local never collides).
    check(p.incoming(Message(from: .lumei, kind: .text, ts: 1500)) == .collision, "incoming delivery (old client, no trip) while away → collision")
    check(p.incoming(Message(from: .lumei, kind: .text, ts: 500, trip: "local")) == .queueForCard, "incoming local while away → card, no collision")
    check(p.incoming(Message(from: .lumei, kind: .text, ts: 500, trip: "deliver")) == .collision, "explicit deliver → collision")
    var dancing = p
    dancing.beginCollision(.me)
    check(dancing.incoming(Message(from: .lumei, kind: .text, ts: 1)) == .queueForCard
          && dancing.planSend(kind: .poke, now: 5, visitorHere: false, reachable: true) == .sendOnly, "during a dance: incoming → card, sends only send")
    dancing.setReturn(at: 50)
    check(dancing.awayRemaining(now: 20) == 30, "dance sets the return time while away")
    dancing.endCollision()
    check(dancing.collision == nil && dancing.incoming(Message(from: .lumei, kind: .text, ts: 1)) == .collision, "dance ended")
    p.startReturn()
    check(p.place == .returning && p.incoming(Message(from: .lumei, kind: .text, ts: 1, trip: "local")) == .queueForCard
          && p.incoming(Message(from: .lumei, kind: .text, ts: 1)) == .holdUntilHome, "returning: local → card, delivery → visitor at home")
    p.arrivedHome()
    check(p.place == .home && p.tripTs == nil && p.incoming(Message(from: .lumei, kind: .poke, ts: 1)) == .showVisitor,
          "after coming home: no collision, normal visitor")
}
do {
    // Leaving (not yet off screen): extensions raise awayFor, then count from the moment it's off screen.
    var p = PetLocation()
    _ = p.planSend(kind: .poke, now: 0, visitorHere: false, reachable: true)
    check(p.planSend(kind: .sticker, now: 0.5, visitorHere: false, reachable: true) == .extendAway(away: 12), "send while leaving: extend")
    p.reachedAway(now: 2)
    check(p.awayRemaining(now: 2) == 12, "leaving extension applies once away")
    // Winner's dance while still leaving: the fixed return time applies once off screen.
    var w = PetLocation()
    _ = w.planSend(kind: .poke, now: 0, visitorHere: false, reachable: true)
    w.sent(ts: 10)
    w.beginCollision(.me)
    w.setReturn(at: 13)
    w.reachedAway(now: 1.5)
    check(w.awayRemaining(now: 1.5) == 11.5, "winner: back 12 s after the collision, not awayFor after leaving")
    // Loser's dance: home, then off again together with the visitor.
    var l = PetLocation()
    _ = l.planSend(kind: .text, now: 0, visitorHere: false, reachable: true)
    l.sent(ts: 20)
    l.beginCollision(.partner)
    l.startReturn()
    l.arrivedHome()
    check(l.collision == .partner && l.place == .home, "loser: home again, dance still on")
    l.leaveAgain(away: Visits.collisionLoserAway)
    l.reachedAway(now: 10)
    check(l.place == .away && l.awayRemaining(now: 10) == 12, "loser: away 12 s at the winner's")
}
do {
    // Rule 4 / rule 2 / cooldown.
    var p = PetLocation()
    check(p.planSend(kind: .text, now: 0, visitorHere: true, reachable: true) == .localMeeting && p.place == .home, "visitor here: local meeting, stays home")
    check(p.planSend(kind: .visit, now: 1, visitorHere: true, reachable: true) == .localMeeting, "去找TA with visitor here: local meeting")
    check(p.planSend(kind: .visit, now: 5, visitorHere: false, reachable: true) == .coolingDown(remaining: 6), "去找TA cooldown")
    check(p.planSend(kind: .poke, now: 5, visitorHere: false, reachable: false) == .bounce(send: false) && p.bouncing, "offline poke: bounce, not sent")
    check(p.planSend(kind: .sticker, now: 5.2, visitorHere: false, reachable: false) == .bounce(send: true) && p.place == .leaving,
          "offline sticker during the bounce: sent, no new run")
    check(p.incoming(Message(from: .lumei, kind: .poke, ts: 1)) == .holdUntilHome, "incoming during a bounce: meet at home")
    p.reachedAway(now: 6)
    check(p.place == .leaving, "a bounce never goes away")
    p.startReturn()
    p.arrivedHome()
    check(p.planSend(kind: .text, now: 7, visitorHere: false, reachable: false) == .bounce(send: true), "offline text: bounce, sent")
    p.arrivedHome()
    check(p.planSend(kind: .poke, now: 8, visitorHere: false, reachable: true) == .deliver(away: 10), "pokes never cool down")
    p.arrivedHome()
    check(p.planSend(kind: .poke, now: 8.1, visitorHere: false, reachable: true) == .deliver(away: 10), "…even twice")
    p.arrivedHome()
    check(p.planSend(kind: .visit, now: 11.5, visitorHere: false, reachable: true) == .deliver(away: 10), "去找TA after the cooldown")
    p.startReturn()
    check(p.planSend(kind: .poke, now: 12, visitorHere: false, reachable: true) == .deliver(away: 10) && p.place == .leaving,
          "send while returning: turn around and deliver")
}
do {
    // Both sides at once: 噜噜 (A) and 噜妹 (B) each start a delivery; each receives the other's while out,
    // and each builds its plan from the same two messages.
    func simulate(aTs: Int64, bTs: Int64) -> (Visits.CollisionPlan?, Visits.CollisionPlan?) {
        var a = PetLocation(), b = PetLocation()
        let ma = Message(id: "A", from: .lulu, kind: .sticker, stickerId: "hug", ts: aTs, trip: "deliver")
        let mb = Message(id: "B", from: .lumei, kind: .poke, ts: bTs, trip: "deliver")
        _ = a.planSend(kind: .sticker, now: 0, visitorHere: false, reachable: true); a.sent(ts: aTs)
        _ = b.planSend(kind: .poke, now: 0, visitorHere: false, reachable: true); b.sent(ts: bTs)
        let pa = a.incoming(mb) == .collision ? Visits.collisionPlan(mine: ma, theirs: mb, me: .lulu) : nil
        let pb = b.incoming(ma) == .collision ? Visits.collisionPlan(mine: mb, theirs: ma, me: .lumei) : nil
        return (pa, pb)
    }
    let ma = Message(id: "A", from: .lulu, kind: .sticker, stickerId: "hug", ts: 500, trip: "deliver")
    let loserSteps: (Message) -> [Visits.CollisionStep] = { theirs in
        [.turnBack, .hostVisitor(theirs), .dwell(4), .leaveTogether, .stayAway(12), .comeHome, .showPinned(theirs)]
    }
    let same = simulate(aTs: 500, bTs: 500)
    check(same.0?.winner == .me && same.1?.winner == .partner, "same ms: 噜噜 goes first on both sides")
    check(same.0?.steps == [.stayAwayFor(12), .comeHomeWithVisitor(Message(id: "B", from: .lumei, kind: .poke, ts: 500, trip: "deliver"))],
          "winner plan: stay away, come home with the loser's pet (meeting #2)")
    check(same.1?.steps == loserSteps(ma), "loser plan: turn back, meeting #1, dwell 4 s, leave together, away 12 s, home, pinned")
    let bFirst = simulate(aTs: 501, bTs: 500)
    check(bFirst.0?.winner == .partner && bFirst.1?.winner == .me, "噜妹 earlier: 噜妹 wins on both sides")
    check(bFirst.0?.steps.first == .turnBack && bFirst.1?.steps.first == .stayAwayFor(12), "噜妹 earlier: 噜噜 turns back")
    let aFirst = simulate(aTs: 500, bTs: 900)
    check(aFirst.0?.winner == .me && aFirst.1?.winner == .partner, "噜噜 earlier: 噜噜 wins")
    // Exactly one side loses in every case: never two absent hosts, never two visitors.
    for (x, y) in [(1, 1), (1, 2), (2, 1), (7, 3)] as [(Int64, Int64)] {
        let r = simulate(aTs: x, bTs: y)
        check(r.0 != nil && r.1 != nil && (r.0!.winner == .me) != (r.1!.winner == .me), "exactly one winner (\(x), \(y))")
    }
    // Plans don't depend on which message is called "mine": 噜妹's view of the tie.
    check(Visits.collisionPlan(mine: Message(from: .lumei, kind: .text, ts: 7), theirs: Message(from: .lulu, kind: .text, ts: 7), me: .lumei).winner == .partner
          && Visits.collisionPlan(mine: Message(from: .lulu, kind: .text, ts: 7), theirs: Message(from: .lumei, kind: .text, ts: 7), me: .lulu).winner == .me,
          "tie from both roles' points of view")
}

// MARK: v0.5 seasonal outfits
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))! }
    let sf = OutfitSeason.springFestival, xmas = OutfitSeason.christmas
    // 2026 春节 = Feb 17: Feb 2 … Mar 4 inclusive.
    check(sf.contains(day(2026, 2, 17), calendar: cal) && sf.contains(day(2026, 2, 2, hour: 0), calendar: cal) && sf.contains(day(2026, 3, 4, hour: 23), calendar: cal),
          "spring festival window 2026 (inside)")
    check(!sf.contains(day(2026, 2, 1, hour: 23), calendar: cal) && !sf.contains(day(2026, 3, 5, hour: 0), calendar: cal), "spring festival window 2026 (edges)")
    // 2028 春节 = Jan 26: Jan 11 … Feb 10.
    check(sf.contains(day(2028, 1, 11), calendar: cal) && !sf.contains(day(2028, 1, 10), calendar: cal) && sf.contains(day(2028, 2, 10), calendar: cal)
          && !sf.contains(day(2028, 2, 11), calendar: cal), "spring festival window 2028")
    check(sf.contains(day(2035, 2, 8), calendar: cal) && !sf.contains(day(2036, 1, 28), calendar: cal) && !sf.contains(day(2026, 9, 28), calendar: cal),
          "spring festival: table years only, not in autumn")
    check(OutfitSeason.chineseNewYear.count == 10 && (2026...2035).allSatisfy { OutfitSeason.chineseNewYear[$0] != nil }, "CNY table 2026-2035")
    check(xmas.contains(day(2026, 12, 1, hour: 0), calendar: cal) && xmas.contains(day(2026, 12, 31, hour: 23), calendar: cal)
          && !xmas.contains(day(2026, 11, 30, hour: 23), calendar: cal) && !xmas.contains(day(2027, 1, 1, hour: 0), calendar: cal), "christmas = December")

    let lulu = ["classic", "bear", "xingshi", "xmastree", "dog"]
    let seasons = ["xingshi": "springFestival", "xmastree": "christmas", "dog": "someday"]
    let autumn = day(2026, 9, 28), cny = day(2027, 2, 6), dec = day(2026, 12, 24)
    check(OutfitRules.eligible(lulu, seasons: seasons, on: autumn, calendar: cal) == ["classic", "bear"], "out of season (and unknown season) not eligible")
    check(OutfitRules.eligible(lulu, seasons: seasons, on: cny, calendar: cal) == ["classic", "bear", "xingshi"], "xingshi eligible at 春节")
    check(OutfitRules.eligible(lulu, seasons: seasons, on: dec, calendar: cal) == ["classic", "bear", "xmastree"], "xmastree eligible in December")
    check(OutfitRules.launchOutfit(lulu, seasons: seasons, on: autumn, calendar: cal) == "classic", "launch: preferred out of season")
    check(OutfitRules.launchOutfit(lulu, seasons: seasons, on: cny, calendar: cal) == "xingshi", "launch: in-season outfit first")
    check(OutfitRules.launchOutfit(lulu, seasons: seasons, on: dec, calendar: cal) == "xmastree", "launch: xmastree in December")
    check(OutfitRules.launchOutfit(["xingshi", "bear"], seasons: seasons, on: autumn, calendar: cal) == "bear", "launch skips an out-of-season first outfit")
    // Pins: kept even out of season; a pin to a removed outfit falls back to the preferred one.
    check(OutfitRules.resolvePin("xingshi", outfits: lulu, seasons: seasons, on: autumn, calendar: cal) == "xingshi", "pinned seasonal outfit kept out of season")
    check(OutfitRules.resolvePin("bow", outfits: ["lace", "maid"], seasons: [:], on: autumn, calendar: cal) == "lace", "pin to removed bow falls back to lace")
    check(OutfitRules.resolvePin(nil, outfits: lulu, seasons: seasons, on: autumn, calendar: cal) == nil, "no pin")
    // Rotation: never the current outfit, never out of season; in-season outfits weigh more.
    var rng = SeededRandom(seed: 7)
    var counts: [String: Int] = [:]
    for _ in 0..<3000 {
        let o = OutfitRules.next(after: "classic", outfits: lulu, seasons: seasons, on: cny, calendar: cal, using: &rng)
        counts[o ?? "nil", default: 0] += 1
    }
    check(Set(counts.keys) == ["bear", "xingshi"], "rotation: eligible others only (\(counts))")
    check((counts["xingshi"] ?? 0) > 3 * (counts["bear"] ?? 0) - 300, "rotation: in-season outfit weighted \(OutfitRules.seasonalWeight)x (\(counts))")
    var autumnPicks = Set<String>()
    for _ in 0..<200 { autumnPicks.insert(OutfitRules.next(after: "bear", outfits: lulu, seasons: seasons, on: autumn, calendar: cal, using: &rng) ?? "nil") }
    check(autumnPicks == ["classic"], "rotation out of season: \(autumnPicks)")
    check(OutfitRules.next(after: "lace", outfits: ["lace"], seasons: [:], on: autumn, calendar: cal, using: &rng) == nil, "rotation: nothing else to wear")
    // A pinned out-of-season outfit being worn: rotation (if unpinned) moves to an eligible one.
    check(OutfitRules.next(after: "xingshi", outfits: lulu, seasons: seasons, on: autumn, calendar: cal, using: &rng).map { ["classic", "bear"].contains($0) } == true,
          "rotation from an out-of-season outfit")
    // outfits.json parsing (tolerant).
    let idx = Data(#"{"xingshi":{"season":"springFestival","label":"醒狮新年"},"bear":{"label":"小熊"},"bad":3,"odd":{"season":5}}"#.utf8)
    check(OutfitIndex.seasons(idx) == ["xingshi": "springFestival"] && OutfitIndex.labels(idx) == ["xingshi": "醒狮新年", "bear": "小熊"], "outfits.json parse")
    check(OutfitIndex.seasons(Data("nope".utf8)).isEmpty && OutfitIndex.seasons(nil).isEmpty, "outfits.json bad / missing")
}

// MARK: v0.5 shipped outfits (Resources/Sprites, from assets/sprites.json)
do {
    let res = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Sprites")
    let cat = SpriteCatalog(root: res)
    let lumei = cat.outfits(for: .lumei), lulu = cat.outfits(for: .lulu)
    check(lumei.first == "lace" && lulu.first == "classic", "shipped preferred outfits: lace / classic")
    check(lumei.count == 9 && lulu.count == 11 && !lumei.contains("bow"), "shipped outfits: 9 噜妹 (no bow) + 11 噜噜 (\(lumei.count) + \(lulu.count))")
    check(cat.seasons(for: .lulu) == ["xingshi": "springFestival", "xmastree": "christmas"] && cat.seasons(for: .lumei).isEmpty, "shipped seasons")
    check(Set(cat.seasons(for: .lulu).values).allSatisfy { OutfitSeason(rawValue: $0) != nil }, "shipped seasons are known")
    let fm = FileManager.default
    var missing: [String] = []
    for (ch, list) in [(Role.lumei, lumei), (Role.lulu, lulu)] {
        for o in list {
            let clips = Action.allCases.compactMap { cat.clip(ch, outfit: o, action: $0) }
                + ClipList.allCases.flatMap { cat.namedClips(ch, outfit: o, list: $0).map(\.clip) }
            for c in clips { for f in c.frames where !fm.fileExists(atPath: f.path) { missing.append("\(ch.rawValue)/\(o): \(f.lastPathComponent)") } }
        }
    }
    check(missing.isEmpty, "every shipped clip's frames exist (\(missing.prefix(3)))")
    // Partial set: missing actions use the outfit's OWN idle; empty fidgets / stay.
    let own = cat.clip(.lumei, outfit: "pinkhood", action: .idle)?.frames
    check(own != nil && cat.clip(.lumei, outfit: "pinkhood", action: .sleep)?.frames == own && cat.clip(.lumei, outfit: "pinkhood", action: .wave)?.frames == own,
          "partial set falls back to its own idle")
    check(cat.namedClips(.lumei, outfit: "pinkhood", list: .fidgets).isEmpty && cat.namedClips(.lumei, outfit: "pinkhood", list: .stay).isEmpty
          && cat.namedClips(.lumei, outfit: "pinkbow", list: .fidgets).isEmpty, "partial sets: empty fidgets / stay")
    // Reaction clips (the default costume's) only go to lace / classic, or to outfits made of those GIFs.
    check(!cat.namedClips(.lumei, outfit: "lace", list: .clips).isEmpty && cat.namedClips(.lulu, outfit: "bear", list: .clips).isEmpty
          && cat.namedClips(.lumei, outfit: "pinkhood", list: .clips).isEmpty, "reaction clips stay with their costume")
    check(!cat.namedClips(.lumei, outfit: "lace", list: .fidgets).map(\.name).contains("lumei_idle_03"), "lace fidgets without the maid clip")
}

// MARK: v0.7 quit shortcut (three actions)
do {
    check(Shortcut.defaultQuit.display == "⌃⌥Q" && Shortcut.defaultQuit.keyCode == 12 && Shortcut.defaultQuit.menuKeyEquivalent == "q",
          "default quit shortcut ⌃⌥Q")
    check(ShortcutAction.allCases.map(\.rawValue) == [1, 2, 3] && ShortcutAction.allCases.map(\.name) == ["toggle", "compose", "quit"],
          "shortcut actions keep their hotkey ids")
    check(ShortcutAction.allCases.map(\.defaultShortcut) == [.defaultToggle, .defaultCompose, .defaultQuit], "action defaults")
    var set = ShortcutSet()
    check(ShortcutAction.allCases.allSatisfy { set.problem(set[$0], for: $0) == nil }, "defaults of all three don't conflict")
    // Anything already used by one of the OTHER two actions is rejected, whichever action records it.
    check(set.problem(.defaultQuit, for: .toggle) != nil && set.problem(.defaultQuit, for: .compose) != nil, "quit's keys rejected for toggle / compose")
    check(set.problem(.defaultToggle, for: .quit) != nil && set.problem(.defaultCompose, for: .quit) != nil, "toggle / compose keys rejected for quit")
    let ctrlOptX = Shortcut(keyCode: 7, modifiers: [.control, .option], key: "X")
    check(set.problem(ctrlOptX, for: .quit) == nil, "a free combination is fine")
    check(set.problem(Shortcut(keyCode: 12, modifiers: [.shift], key: "Q"), for: .quit) != nil, "quit also needs ⌃ / ⌥ / ⌘")
    // Same key, different modifiers: no conflict; display name doesn't matter.
    check(set.problem(Shortcut(keyCode: 12, modifiers: [.control, .option, .command], key: "Q"), for: .toggle) == nil, "modifiers distinguish")
    check(set.problem(Shortcut(keyCode: 12, modifiers: [.control, .option], key: "q?"), for: .compose) != nil, "same keys, other label: conflict")
    set[.quit] = ctrlOptX
    check(set.quit == ctrlOptX && set.problem(.defaultQuit, for: .toggle) == nil && set.problem(ctrlOptX, for: .compose) != nil,
          "after moving quit, its old keys are free and the new ones taken")
    check(Shortcut.defaultQuit.problem(conflictingWith: [Shortcut.defaultToggle, .defaultCompose]) == nil
          && Shortcut.defaultQuit.problem(conflictingWith: nil) == nil, "array / optional overloads")

    let ps = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(ps.quitShortcut == .defaultQuit && ps.defaults.object(forKey: "hotkeyQuit") == nil, "hotkeyQuit absent = ⌃⌥Q")
    ps.quitShortcut = ctrlOptX
    check(ps.quitShortcut == ctrlOptX && ps.toggleShortcut == .defaultToggle && ps.composeShortcut == .defaultCompose, "hotkeyQuit persists")
    ps.defaults.set(Data("junk".utf8), forKey: "hotkeyQuit")
    check(ps.quitShortcut == .defaultQuit, "bad hotkeyQuit data = default")
    ps.wipe()
}

// MARK: v0.7 pet size
do {
    check(PetScale.min == 0.6 && PetScale.max >= 1.4 && PetScale.standard == 1.0, "scale limits")
    check(PetScale.clamp(0.2) == PetScale.min && PetScale.clamp(9) == PetScale.max && PetScale.clamp(1.2) == 1.2
          && PetScale.clamp(.nan) == 1.0 && PetScale.clamp(.infinity) == 1.0, "scale clamp")
    check(PetScale.normalized(1.2999999) == 1.3 && PetScale.normalized(0.1) == PetScale.min && PetScale.normalized(3) == PetScale.max,
          "scale normalized (rounded, clamped)")
    // Rubber band: identity inside, never more than the overshoot past a limit, still increasing.
    check(PetScale.rubberBand(1.1) == 1.1 && PetScale.rubberBand(PetScale.max) == PetScale.max, "rubber band inside")
    let far = PetScale.rubberBand(PetScale.max + 5), near = PetScale.rubberBand(PetScale.max + 0.02)
    check(far > PetScale.max && far < PetScale.max + 0.04 && near < far && near > PetScale.max, "rubber band above max")
    let low = PetScale.rubberBand(0.1)
    check(low < PetScale.min && low > PetScale.min - 0.04, "rubber band below min")
    // Presets 小 / 标准 / 大; checkmark only when exact.
    check(PetScale.presets.map(\.title) == ["小", "标准", "大"] && PetScale.presets.map(\.scale) == [0.75, 1.0, 1.3], "size presets")
    check(PetScale.presetIndex(for: 0.75) == 0 && PetScale.presetIndex(for: 1.0) == 1 && PetScale.presetIndex(for: 1.3) == 2
          && PetScale.presetIndex(for: 1.2999999) == 2 && PetScale.presetIndex(for: 1.12) == nil, "preset checkmark only when exact")
    check(PetScale.presets.allSatisfy { PetScale.clamp($0.scale) == $0.scale }, "presets inside the limits")
    // Drag: right / up grows, left / down shrinks, along the sprite's diagonal.
    let sprite = CGSize(width: 120, height: 170)
    check(PetScale.dragged(start: 1, delta: .zero, sprite: sprite) == 1, "no movement, no change")
    let d2 = Double(120 * 120 + 170 * 170)
    check(abs(PetScale.dragged(start: 1, delta: CGVector(dx: 120, dy: 170), sprite: sprite) - 2) < 1e-9, "dragging one diagonal doubles")
    check(abs(PetScale.dragged(start: 1.5, delta: CGVector(dx: 100, dy: 0), sprite: sprite) - 1.5 * (1 + 12000 / d2)) < 1e-9, "right grows (relative)")
    check(PetScale.dragged(start: 1, delta: CGVector(dx: 0, dy: 50), sprite: sprite) > 1
          && PetScale.dragged(start: 1, delta: CGVector(dx: -40, dy: -40), sprite: sprite) < 1, "up grows, down-left shrinks")
    check(PetScale.dragged(start: 1, delta: CGVector(dx: 50, dy: 50), sprite: .zero) == 1, "degenerate sprite")
    // Anchor: the sprite's bottom-left stays put.
    let old = CGRect(x: 1000, y: 8, width: 150, height: 214)   // sprite 110 wide, centred → left edge 1020
    let o = PetScale.anchoredOrigin(oldFrame: old, oldSpriteWidth: 110, newSpriteWidth: 165, newWindowWidth: 225)
    check(o.y == 8 && abs((o.x + 225 / 2 - 165 / 2) - 1020) < 1e-9, "sprite bottom-left anchored")
    let same = PetScale.anchoredOrigin(oldFrame: old, oldSpriteWidth: 110, newSpriteWidth: 110, newWindowWidth: 150)
    check(same == old.origin, "same size, same origin")
    let screenRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    check(PetScale.keepOnScreen(CGPoint(x: 1400, y: 8), size: CGSize(width: 200, height: 300), screen: screenRect) == CGPoint(x: 1240, y: 8)
          && PetScale.keepOnScreen(CGPoint(x: -30, y: 8), size: CGSize(width: 200, height: 300), screen: screenRect) == CGPoint(x: 0, y: 8)
          && PetScale.keepOnScreen(CGPoint(x: 500, y: 8), size: CGSize(width: 200, height: 300), screen: screenRect) == CGPoint(x: 500, y: 8),
          "keep on screen")
    // Visit geometry at another size: the standing gap scales with the pets.
    let host = CGRect(x: 1000, y: 8, width: 100 * 1.4, height: 170 * 1.4)
    let a = VisitGeometry.arrival(host: host, visitorWindowWidth: 150 * 1.4, visitorSpriteWidth: 110 * 1.4, screen: screenRect,
                                  gap: Visits.standGap * 1.4)
    let inset = (150 * 1.4 - 110 * 1.4) / 2
    check(a.standSide == .right && abs((a.standX + inset) - (host.maxX + Visits.standGap * 1.4)) < 1e-9, "scaled standing gap")

    // Persistence: absent = 1.0; stored clamped + rounded; out-of-range stored values read clamped.
    let ps = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(ps.petScale == 1.0 && ps.defaults.object(forKey: "petScale") == nil, "petScale absent = 1.0")
    ps.petScale = 1.2999999
    check(ps.petScale == 1.3 && (ps.defaults.object(forKey: "petScale") as? NSNumber)?.doubleValue == 1.3, "petScale persists (Double)")
    ps.petScale = 7
    check(ps.petScale == PetScale.max, "petScale saved clamped")
    ps.defaults.set(0.01, forKey: "petScale")
    check(ps.petScale == PetScale.min, "out-of-range petScale read clamped")
    ps.defaults.set("big", forKey: "petScale")
    check(ps.petScale == 1.0, "non-number petScale = 1.0")
    check(ps.defaults.object(forKey: "config") == nil && ps.defaults.object(forKey: "petOrigin") == nil, "petScale touches no other key")
    ps.wipe()
}

// MARK: v0.7.4 收到 ❤️ + visitor time limit
do {
    check(Visits.visitorMaxStay == 45, "visitor max stay is 45 s")
    // Clock: starts once, restarts on a new live message, stops on leave.
    var clock = VisitorStayClock(limit: 45)
    check(!clock.isRunning && !clock.expired(now: 1_000), "clock idle never expires")
    clock.start(now: 100)
    clock.start(now: 130)   // staying again (e.g. after a merge clip) does not move the start
    check(clock.deadline == 145, "clock starts once")
    check(!clock.expired(now: 144.5) && clock.expired(now: 145), "clock expires at start + limit")
    clock.restart(now: 140)   // a new live message during the visit (meetAgain)
    check(clock.deadline == 185 && !clock.expired(now: 150) && clock.remaining(now: 150) == 35, "new live message resets the clock")
    clock.stop()
    check(!clock.isRunning && !clock.expired(now: 10_000), "stopped clock never expires")

    // Decision: min dwell, waiting bubbles, time limit.
    var c = VisitorStayClock(limit: 45); c.start(now: 0)
    check(Visits.stayDecision(now: 1, stayUntil: 2, bubblesWaiting: false, clock: c) == .wait, "dwell not over: wait")
    check(Visits.stayDecision(now: 3, stayUntil: 2, bubblesWaiting: false, clock: c) == .leave, "all acknowledged + dwell over: leave")
    check(Visits.stayDecision(now: 30, stayUntil: 2, bubblesWaiting: true, clock: c) == .wait, "bubbles waiting, time left: wait")
    check(Visits.stayDecision(now: 45, stayUntil: 2, bubblesWaiting: true, clock: c) == .leaveLeavingBubbles, "time up with bubbles: leave, bubbles stay")
    check(Visits.stayDecision(now: 45, stayUntil: 50, bubblesWaiting: false, clock: c) == .leave, "time up wins over the dwell")
    c.restart(now: 40)
    check(Visits.stayDecision(now: 60, stayUntil: 2, bubblesWaiting: true, clock: c) == .wait, "reset clock: still waiting at 60 s")
    check(Visits.stayDecision(now: 85, stayUntil: 2, bubblesWaiting: true, clock: c) == .leaveLeavingBubbles, "reset clock: time up 45 s after the new message")

    // Queue: read only on acknowledge; time up keeps every item (in order, unread).
    struct B: Equatable { var header: String; var ts: Int64 }
    var q = AckQueue<B>()
    var read: [Int64] = []
    check(q.enqueue(B(header: "噜噜说：", ts: 1)) && !q.enqueue(B(header: "噜噜说：", ts: 2)), "first item becomes current")
    q.enqueue(B(header: "噜噜说：", ts: 3))
    check(q.count == 3 && q.all.map(\.ts) == [1, 2, 3], "queue keeps order")
    if let done = q.acknowledge() { read.append(done.ts) }
    check(read == [1] && q.current?.ts == 2 && q.count == 2, "acknowledge returns the current item and shows the next")
    q.leaveAll { $0.header = Visits.pinnedHeader }
    check(read == [1], "time up marks nothing read")
    check(q.count == 2 && q.all.map(\.ts) == [2, 3], "time up drops nothing")
    check(q.all.allSatisfy { $0.header == Visits.pinnedHeader }, "left bubbles become \"TA 留下的话\"")
    while let done = q.acknowledge() { read.append(done.ts) }
    check(read == [1, 2, 3] && q.isEmpty, "left bubbles acknowledged later, each read once")
    check(q.acknowledge() == nil, "acknowledge on an empty queue is a no-op")
    var e = AckQueue<B>()
    e.leaveAll { $0.header = "x" }
    check(e.isEmpty, "time up with nothing waiting")
}


// MARK: v0.8 勿扰模式 + 省电
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    // 2026-09-28 14:05:00 +08:00
    let t0 = cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 14, minute: 5))!.timeIntervalSince1970
    check(DNDDuration.thirtyMinutes.until(now: t0) == t0 + 1800 && DNDDuration.oneHour.until(now: t0) == t0 + 3600, "dnd 30 min / 1 h")
    check(DNDDuration.untilOff.until(now: t0) == 0, "dnd until off = 0")
    let midnight = cal.date(from: DateComponents(year: 2026, month: 9, day: 29))!.timeIntervalSince1970
    check(DNDDuration.today.until(now: t0, calendar: cal) == midnight, "dnd today ends at the next local midnight")
    let late = cal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 23, minute: 59, second: 30))!.timeIntervalSince1970
    check(DNDDuration.today.until(now: late, calendar: cal) == midnight, "dnd today at 23:59:30 still ends at midnight")

    var st = DNDState()
    check(!st.isOn(now: t0) && st.mood == .unsaid && st.status(now: t0) == nil, "dnd off by default, mood 不说原因")
    st.mood = .angry
    st.turnOn(.oneHour, now: t0, calendar: cal)
    check(st.isOn(now: t0 + 3599) && !st.isOn(now: t0 + 3600), "dnd on until its end")
    check(st.status(now: t0) == DNDStatus(mood: "angry", untilMs: Int64((t0 + 3600) * 1000)), "dnd presence status")
    check(st.offTitle(calendar: cal) == "关闭勿扰（15:05 结束）", "dnd off item title: \(st.offTitle(calendar: cal))")
    check(st.statusLine(calendar: cal) == "🔕 我勿扰中（😤 生气中 · 15:05 结束）", "dnd status line")
    st.turnOn(.thirtyMinutes, now: t0 + 600, calendar: cal)
    check(st.since == t0 && st.until == t0 + 2400, "re-setting the time keeps the start")
    check(st.expire(now: t0 + 2399) == nil && st.isOn(now: t0 + 2399), "not expired before the end")
    let span = st.expire(now: t0 + 9999)
    check(span == DNDSpan(startMs: Int64(t0 * 1000), endMs: Int64((t0 + 2400) * 1000), mood: "angry"), "expired span ends at the end time (Mac slept through it)")
    check(!st.isOn(now: t0 + 9999) && st.until == nil && st.mood == .angry, "expired: off, mood kept")
    check(span?.label(calendar: cal) == "😤 勿扰中 14:05–14:45", "span label: \(span?.label(calendar: cal) ?? "-")")
    st.turnOn(.untilOff, now: t0, calendar: cal)
    check(st.isOn(now: t0 + 1e7) && st.expire(now: t0 + 1e7) == nil, "until off never expires")
    check(st.offTitle(calendar: cal) == "关闭勿扰（手动关闭）", "until off menu title")
    check(st.status(now: t0)?.untilMs == 0, "until off → presence until 0")
    let s2 = st.turnOff(now: t0 + 60)
    check(s2?.endMs == Int64((t0 + 60) * 1000) && st.turnOff(now: t0 + 70) == nil, "turn off by hand once")
    st.mood = .unsaid
    st.turnOn(.today, now: t0, calendar: cal)
    check(st.offTitle(calendar: cal) == "关闭勿扰（24:00 结束）", "today ends at 24:00: \(st.offTitle(calendar: cal))")
    check(DNDSpan(startMs: 0, endMs: 60_000, mood: "unsaid").label(calendar: cal).hasPrefix("🔕 勿扰中 ") && DNDSpan(startMs: 0, endMs: 0, mood: "future").label(calendar: cal).hasPrefix("🔕"), "no reason → 🔕")
    check(DNDMood.unsaid.sign == "🔕 勿扰中" && DNDMood.busy.sign == "💼 忙碌中" && DNDMood.resting.sign == "😴 休息中" && DNDMood.angry.sign == "😤 生气中", "mood signs")

    // Persistence (new keys) and restart.
    let dstore = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(dstore.dnd == DNDState() && dstore.dndLog.isEmpty, "no dnd keys = off")
    var on = DNDState(mood: .busy)
    on.turnOn(.oneHour, now: t0)
    dstore.dnd = on
    check(dstore.dnd == on && (dstore.defaults.object(forKey: "dndUntil") as? NSNumber)?.doubleValue == t0 + 3600 && dstore.defaults.string(forKey: "dndMood") == "busy", "dnd persists (dndUntil / dndMood / dndSince)")
    var back = dstore.dnd
    _ = back.turnOff(now: t0 + 10)
    dstore.dnd = back
    check(dstore.defaults.object(forKey: "dndUntil") == nil && dstore.dnd.mood == .busy && !dstore.dnd.isOn(now: t0), "off removes dndUntil, keeps the mood")
    dstore.defaults.set("sulking", forKey: "dndMood")
    check(dstore.dnd.mood == .unsaid, "unknown mood reads as 不说原因")
    dstore.dndLog = [DNDSpan(startMs: 1, endMs: 2, mood: "angry")]
    check(dstore.dndLog == [DNDSpan(startMs: 1, endMs: 2, mood: "angry")], "dndLog roundtrip")
    let logJSON = (try? JSONSerialization.jsonObject(with: dstore.defaults.data(forKey: "dndLog")!)) as? [[String: Any]]
    check(logJSON?.first?["start"] as? Int == 1 && logJSON?.first?["end"] as? Int == 2, "dndLog wire keys start / end / mood")
    check(DNDSpan.appending(DNDSpan(startMs: 9, endMs: 9, mood: ""), to: Array(repeating: DNDSpan(startMs: 0, endMs: 0, mood: ""), count: DNDSpan.maxLog)).count == DNDSpan.maxLog, "dndLog capped")
    dstore.wipe()

    // Presence encode / decode, with and without dnd.
    let p1 = PresenceInfo.payload(lastSeen: 5, dnd: nil)
    check(p1.count == 1 && p1["lastSeen"] as? Int64 == 5, "presence payload without dnd = old shape")
    let p2 = PresenceInfo.payload(lastSeen: 5, dnd: DNDStatus(mood: "angry", untilMs: 99))
    let p2data = try! JSONSerialization.data(withJSONObject: p2)
    check(PresenceInfo.decode(p2data) == PresenceInfo(lastSeen: 5, dnd: DNDStatus(mood: "angry", untilMs: 99)), "presence roundtrip with dnd")
    check(PresenceInfo.decode(Data(#"{"lastSeen":1234}"#.utf8)) == PresenceInfo(lastSeen: 1234), "old presence (lastSeen only)")
    check(PresenceInfo.decode(Data("null".utf8)) == nil, "never written presence")
    check(PresenceInfo.decode(Data("1234".utf8)) == PresenceInfo(lastSeen: 1234), "bare number tolerated")
    check(PresenceInfo.decode(Data(#"{"lastSeen":0,"dnd":{"until":0}}"#.utf8))?.dnd == DNDStatus(mood: "", untilMs: 0), "dnd without mood")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"dnd":"x","extra":1}"#.utf8)) == PresenceInfo(lastSeen: 7), "malformed dnd ignored")
    check(DNDStatus(mood: "future", untilMs: 0).reason == nil && DND.partnerStatusLine(DNDStatus(mood: "future", untilMs: 0)) == "TA 勿扰中", "unknown mood → no reason")
    check(DND.partnerStatusLine(DNDStatus(mood: "angry", untilMs: 0)) == "TA 勿扰中（😤 生气中）", "partner status line")
    check(DND.bounceLine(DNDStatus(mood: "angry", untilMs: 0)) == "TA 开了勿扰（😤 生气中），先放在 TA 那儿啦", "bounce line with mood")
    check(DND.bounceLine(DNDStatus(mood: "unsaid", untilMs: 0)) == "TA 开了勿扰，先放在 TA 那儿啦" && DND.bounceLine(nil) == "TA 开了勿扰，先放在 TA 那儿啦", "bounce line without mood")

    // Partner-send decision.
    let now: Int64 = 1_000_000
    let angry = DNDStatus(mood: "angry", untilMs: 0)
    check(Presence.reach(connected: true, info: PresenceInfo(lastSeen: now - 1000), nowMs: now) == .online, "reach online")
    check(Presence.reach(connected: true, info: PresenceInfo(lastSeen: now - 1000, dnd: angry), nowMs: now) == .dnd(angry), "reach dnd")
    check(Presence.reach(connected: true, info: PresenceInfo(lastSeen: 0, dnd: angry), nowMs: now) == .dnd(angry), "dnd wins over offline (still on when TA is back)")
    check(Presence.reach(connected: true, info: PresenceInfo(lastSeen: now - 1000, dnd: DNDStatus(mood: "busy", untilMs: now - 1)), nowMs: now) == .online, "expired dnd ignored")
    check(Presence.reach(connected: true, info: PresenceInfo(lastSeen: now - 100_000), nowMs: now) == .offline, "reach offline")
    check(Presence.reach(connected: true, info: nil, nowMs: now) == .notPaired && Presence.reach(connected: true, info: PresenceInfo(lastSeen: nil), nowMs: now) == .notPaired, "reach not paired")
    check(Presence.reach(connected: false, info: PresenceInfo(lastSeen: now, dnd: angry), nowMs: now) == .offline, "not connected → offline")
    check(PartnerReach.online.isReachable && !PartnerReach.dnd(angry).isReachable, "only online is reachable")

    // A partner in 勿扰: the pet bounces and EVERYTHING is sent (pokes / visits too).
    for kind in [Message.Kind.poke, .visit, .text, .sticker] {
        var loc = PetLocation()
        check(loc.planSend(kind: kind, now: 100, visitorHere: false, reachable: false, partnerDND: true) == .bounce(send: true), "dnd bounce sends \(kind.rawValue)")
        check(loc.planSend(kind: .poke, now: 101, visitorHere: false, reachable: false, partnerDND: true) == .bounce(send: true), "second send during a dnd bounce still sent")
    }
    var offl = PetLocation()
    check(offl.planSend(kind: .poke, now: 100, visitorHere: false, reachable: false) == .bounce(send: false), "offline poke still not sent")

    // 诚意清单 counts.
    let from = Role.lumei
    let batch: [Message] = [.poke(from: from), .poke(from: from), .poke(from: from), .visit(from: from), .visit(from: from),
                            .text("a", from: from), .text("b", from: from), .text("c", from: from), .text("d", from: from),
                            .sticker("hug", from: from), .poke(from: .lulu)]
    let sum = AwaySummary.build(batch, me: .lulu, stickerLabel: { $0 == "hug" ? "抱抱" : nil })!
    check(sum.sincerityLines == ["❤️ 爱心 ×3", "🏃 来找你 ×2", "💬 4 条消息", "🤗 抱抱 ×1"], "诚意清单 lines: \(sum.sincerityLines)")
    check(sum.total == 10 && DND.cardTitle(count: sum.total) == "你勿扰的时候，TA 来找过你 10 次～", "诚意清单 title")
    check(AwaySummary.build([.poke(from: from)], me: .lulu, stickerLabel: { _ in nil })!.sincerityLines == ["❤️ 爱心 ×1"], "single heart spelled ×1")

    // History divider rows.
    let base = Int64(t0 * 1000)
    let msgs = [Message(id: "a", from: .lumei, kind: .text, text: "x", ts: base - 60_000),
                Message(id: "b", from: .lumei, kind: .poke, ts: base + 60_000),
                Message(id: "c", from: .lulu, kind: .text, text: "y", ts: base + 3_000_000)]
    let dspan = DNDSpan(startMs: base, endMs: base + 2_400_000, mood: "angry")
    let rows = HistoryTimeline.rows(msgs, dndSpans: [dspan], complete: true, now: Date(timeIntervalSince1970: t0), calendar: cal)
    check(rows.map(\.id) == ["day-2026-9-28", "a", "dnd-\(base)", "b", "c"], "dnd divider placed where it began: \(rows.map(\.id))")
    if case .dnd(let label, _) = rows[2] { check(label == "😤 勿扰中 14:05–14:45", "divider label") } else { check(false, "divider row") }
    let older = HistoryTimeline.rows(Array(msgs.dropFirst()), dndSpans: [DNDSpan(startMs: base - 999_999, endMs: base - 900_000, mood: "busy")], complete: false, calendar: cal)
    check(!older.contains { if case .dnd = $0 { return true }; return false }, "a span older than the loaded page waits for its page")
    check(HistoryTimeline.rows(msgs, dndSpans: [], complete: true, now: Date(timeIntervalSince1970: t0), calendar: cal) == HistoryTimeline.rows(msgs, now: Date(timeIntervalSince1970: t0), calendar: cal), "no spans = v0.4 rows")
    let tail = HistoryTimeline.rows(msgs, dndSpans: [DNDSpan(startMs: base + 9_000_000, endMs: base + 9_100_000, mood: "angry")], complete: true, now: Date(timeIntervalSince1970: t0), calendar: cal)
    check(tail.last?.id == "dnd-\(base + 9_000_000)", "span after the last message goes last")

    // 省电: rest pose and quiet clock; battery timings.
    check(IdleRules.quietAfter == 120, "quiet mode after 2 minutes")
    check(RestPose.pick(dozing: false, quiet: false, dnd: false) == .idle && RestPose.idle.allowsFidgets, "idle animates, fidgets")
    check(RestPose.pick(dozing: false, quiet: true, dnd: false) == .quiet && !RestPose.quiet.allowsFidgets, "quiet: still, no fidgets")
    check(RestPose.pick(dozing: false, quiet: false, dnd: true) == .quiet, "dnd is always quiet")
    check(RestPose.pick(dozing: true, quiet: true, dnd: true) == .doze && !RestPose.doze.allowsFidgets, "doze wins")
    var qc = DozeClock(threshold: IdleRules.quietAfter, now: 0)
    check(qc.check(now: 60, blocked: false) == .wait(60), "quiet not yet")
    check(qc.check(now: 120, blocked: true) == .wait(IdleRules.retry), "quiet waits while a visit / bubble is on")
    check(qc.check(now: 125, blocked: false) == .doze && qc.activity(now: 130), "quiet after 2 min; activity wakes")
    check(PowerProfile.current(onBattery: true) == PowerProfile(heartbeat: 30, presencePoll: 30, hoverInterval: 0.25, fullscreenPoll: 8), "battery timings")
    check(PowerProfile.current(onBattery: false) == PowerProfile(heartbeat: 20, presencePoll: 15, hoverInterval: 0.1, fullscreenPoll: 3), "AC timings")
    check(Presence.thresholdMs > Int64(PowerProfile.battery.heartbeat * 1000) * 2, "presence threshold outlasts two battery heartbeats")
    check(abs(PowerProfile.tolerance(for: 0.1) - 0.01) < 1e-9 && PowerProfile.tolerance(for: 30) == 1, "timer tolerance 10 %, ≤ 1 s")
}

// MARK: v0.8 shipped quiet frames (Resources/Sprites)
do {
    let cat = SpriteCatalog(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Sprites"))
    for ch in [Role.lulu, .lumei] {
        for o in cat.outfits(for: ch) {
            let q = cat.exactClip(ch, outfit: o, action: .quiet)
            check(q?.frames.count == 1 && q.map { FileManager.default.fileExists(atPath: $0.frames[0].path) } == true, "quiet frame for \(ch.rawValue)/\(o)")
        }
    }
}

// MARK: v0.8 FirebaseClient presence with dnd (stubbed)
StubProtocol.replies = [
    "PUT /pairs/PAIR/presence/lulu.json": .init(status: 200, body: "{}"),
    "GET /pairs/PAIR/presence/lumei.json": .init(status: 200, body: #"{"lastSeen":42,"dnd":{"mood":"busy","until":0}}"#),
]
do {
    StubProtocol.requests = []
    try await fb.heartbeat(.lulu, dnd: DNDStatus(mood: "angry", untilMs: 77))
    let body = StubProtocol.requests.last?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let d = body?["dnd"] as? [String: Any]
    check(body?["lastSeen"] != nil && d?["mood"] as? String == "angry" && d?["until"] as? Int == 77, "heartbeat publishes dnd")
    try await fb.heartbeat(.lulu)
    let plain = StubProtocol.requests.last?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(plain?.keys.sorted() == ["lastSeen"], "heartbeat without dnd = v0.7 body")
    try await fb.markOffline(.lulu, dnd: DNDStatus(mood: "angry", untilMs: 0))
    let off = StubProtocol.requests.last?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check((off?["lastSeen"] as? Int) == 0 && off?["dnd"] != nil, "sign-off keeps dnd")
    let info = try await fb.presence(.lumei)
    check(info == PresenceInfo(lastSeen: 42, dnd: DNDStatus(mood: "busy", untilMs: 0)), "presence reads the whole object")
} catch { check(false, "presence dnd requests \(error)") }


// MARK: v0.8 outfit memory (换回上一个 / 选择造型)
do {
    var h = OutfitHistory()
    let all = ["classic", "bear", "panda", "bee", "xingshi"]
    check(!h.canGoBack(valid: all, current: "classic") && h.pop(valid: all, current: "classic") == nil, "empty history: nothing to go back to")
    h.push("classic"); h.push("bear")
    check(h.stack == ["bear", "classic"], "most recent first")
    h.push("classic")
    check(h.stack == ["classic", "bear"], "no outfit listed twice")
    for i in 0..<15 { h.push("o\(i)") }
    check(h.stack.count == OutfitHistory.maxCount && h.stack.first == "o14", "capped at 10, newest kept")
    var w = OutfitHistory(["gone", "panda", "bear", "classic"])
    check(w.pop(valid: all, current: "bee") == "panda" && w.stack == ["bear", "classic"], "unknown / removed outfits skipped")
    check(w.pop(valid: all, current: "bear") == "classic", "the current outfit is skipped")
    check(w.pop(valid: all, current: "classic") == nil && w.stack.isEmpty, "walked back to the end")
    // Walking back through several changes.
    var walk = OutfitHistory()
    var cur = "classic"
    for next in ["bear", "panda", "bee"] { walk.push(cur); cur = next }
    var seen: [String] = []
    while let o = walk.pop(valid: all, current: cur) { seen.append(o); cur = o }
    check(seen == ["panda", "bear", "classic"], "repeated 换回上一个 walks back: \(seen)")
    check(OutfitHistory(Array(repeating: "x", count: 30)).stack.count == 10, "loaded stack capped")

    let hs = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(hs.outfitHistory(for: .lulu).stack.isEmpty, "no outfitHistory key = empty")
    hs.setOutfitHistory(OutfitHistory(["bear", "classic"]), for: .lulu)
    hs.setOutfitHistory(OutfitHistory(["lace"]), for: .lumei)
    check(hs.outfitHistory(for: .lulu).stack == ["bear", "classic"] && hs.outfitHistory(for: .lumei).stack == ["lace"], "outfitHistory per character")
    check((hs.defaults.dictionary(forKey: "outfitHistory") as? [String: [String]])?["lulu"] == ["bear", "classic"], "outfitHistory wire shape {role: [outfit]}")
    hs.wipe()

    let seasons = ["xingshi": "springFestival"]
    let labels = ["classic": "经典", "bear": "小熊", "xingshi": "醒狮新年"]
    var ocal = Calendar(identifier: .gregorian)
    ocal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let sept = ocal.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!
    let rows = OutfitChoice.list(outfits: ["classic", "bear", "xingshi", "nolabel"], labels: labels, seasons: seasons, current: "bear", pinned: nil, on: sept, calendar: ocal)
    check(rows.map(\.title) == ["经典", "小熊", "醒狮新年（节日限定）", "nolabel"], "choice titles: \(rows.map(\.title))")
    check(rows.map(\.current) == [false, true, false, false], "current outfit checked")
    check(rows.map(\.enabled) == [true, true, false, true], "out-of-season outfit disabled")
    let pinnedRows = OutfitChoice.list(outfits: ["xingshi"], labels: labels, seasons: seasons, current: "xingshi", pinned: "xingshi", on: sept, calendar: ocal)
    check(pinnedRows.first?.enabled == true, "pinned seasonal outfit stays enabled")
}

// v0.8.1 event-driven hover watch geometry
do {
    let win = CGRect(x: 100, y: 100, width: 150, height: 214)
    check(HoverWatch.needsCheck(pointer: CGPoint(x: 120, y: 120), window: win, handleShown: false, pointerOver: false), "hover: move inside window checks")
    check(HoverWatch.needsCheck(pointer: CGPoint(x: 100 - 20, y: 150), window: win, handleShown: false, pointerOver: false), "hover: move just outside (margin) checks")
    check(!HoverWatch.needsCheck(pointer: CGPoint(x: 900, y: 900), window: win, handleShown: false, pointerOver: false), "hover: far move skipped")
    check(HoverWatch.needsCheck(pointer: CGPoint(x: 900, y: 900), window: win, handleShown: true, pointerOver: false), "hover: far move checks while handle shown (to hide it)")
    check(HoverWatch.needsCheck(pointer: CGPoint(x: 900, y: 900), window: win, handleShown: false, pointerOver: true), "hover: far move checks after being over (exit)")
    let sprite = CGRect(x: 120, y: 100, width: 100, height: 170)
    let handle = CGRect(x: 110, y: 256, width: 22, height: 22)
    let over = HoverWatch.state(pointer: CGPoint(x: 170, y: 180), sprite: sprite, handle: handle)
    check(over.over && over.show, "hover: over sprite = over + show")
    let onHandle = HoverWatch.state(pointer: CGPoint(x: 112, y: 276), sprite: sprite, handle: handle)
    check(!onHandle.over && onHandle.show, "hover: on handle (outside sprite) = show, not over")
    let slack = HoverWatch.state(pointer: CGPoint(x: 106, y: 280), sprite: sprite, handle: handle)
    check(slack.show, "hover: handle slack")
    let away = HoverWatch.state(pointer: CGPoint(x: 300, y: 100), sprite: sprite, handle: handle)
    check(!away.over && !away.show, "hover: away = hidden")
    check(HoverWatch.fallbackPoll >= 1, "hover: fallback poll at most 1 Hz")
}

// MARK: v0.8.1 energy: coalesced presence schedule, stream watchdog, fullscreen fallback
do {
    check(Presence.pollInterval == 15 && Presence.heartbeatInterval == 20 && Presence.thresholdMs == 75_000, "v0.8.1 AC presence timings")
    check(PowerProfile.battery.heartbeat == 30 && PowerProfile.battery.presencePoll == 30, "battery presence timings")
    check(Presence.tolerance(for: 15) == 1.5 && Presence.tolerance(for: 90) == 3 && Presence.tolerance(for: -1) == 0, "presence tolerance 10 %, ≤ 3 s")
    check(Int64((PowerProfile.battery.heartbeat + Presence.tolerance(for: 30)) * 2 * 1000) < Presence.thresholdMs, "two late battery heartbeats stay online")

    // Simulates the loop: returns (wake times, heartbeat times, poll times) up to `until`.
    func run(_ hb: TimeInterval, _ poll: TimeInterval, until: TimeInterval, late: TimeInterval = 0) -> ([TimeInterval], [TimeInterval], [TimeInterval]) {
        var s = PresenceSchedule(start: 0)
        var now: TimeInterval = 0, wakes: [TimeInterval] = [], beats: [TimeInterval] = [], polls: [TimeInterval] = []
        while now < until {
            let due = s.fire(now: now, heartbeat: hb, poll: poll)
            wakes.append(now)
            if due.heartbeat { beats.append(now) }
            if due.poll { polls.append(now) }
            let d = s.delay(now: now)
            check(d > 0, "schedule never busy-loops (\(hb)/\(poll) at \(now))")
            if d <= 0 { break }
            now += d + late
        }
        return (wakes, beats, polls)
    }
    let ac = run(20, 15, until: 120)
    check(ac.0 == [0, 15, 30, 45, 60, 75, 90, 105], "AC: one wake-up every 15 s: \(ac.0)")
    check(ac.1 == ac.0 && ac.2 == ac.0, "AC: heartbeat and poll share every wake-up")
    let bat = run(30, 30, until: 120)
    check(bat.0 == [0, 30, 60, 90] && bat.1 == bat.0 && bat.2 == bat.0, "battery: one shared wake-up every 30 s")
    let lateAC = run(20, 15, until: 300, late: 1.5)
    check(zip(lateAC.1, lateAC.1.dropFirst()).allSatisfy { $1 - $0 <= 20 + 1.5 }, "late wake-ups never stretch the heartbeat past interval + tolerance")
    let apart = run(60, 10, until: 61)
    check(apart.1 == [0, 60] && apart.2.count == 7, "far-apart intervals: heartbeat not pulled early: \(apart.1)")
    let fast = run(2, 2, until: 10)
    check(fast.0 == [0, 2, 4, 6, 8] && fast.1 == fast.0, "--presence-fast 2 s / 2 s")
    // Battery → AC: the shorter interval applies at the next wake-up, not after the old one.
    var sw = PresenceSchedule(start: 0)
    _ = sw.fire(now: 0, heartbeat: 30, poll: 30)
    check(sw.delay(now: 1) == 29, "battery schedule")
    let d1 = sw.fire(now: 1, heartbeat: 20, poll: 15)
    check(d1 == .init(heartbeat: false, poll: false) && sw.nextPoll == 16 && sw.nextHeartbeat == 21, "switch to AC shortens the wait: \(sw)")

    // Stream idle watchdog: sleeps until the 90 s deadline, never less than 1 s.
    check(StreamWatchdog.sleep(idle: 0, timeout: 90) == 90, "fresh stream: sleep 90 s")
    check(StreamWatchdog.sleep(idle: 30, timeout: 90) == 60, "keep-alive 30 s ago: sleep 60 s")
    check(StreamWatchdog.sleep(idle: 89.8, timeout: 90) == 1, "sleep at least 1 s")
    check(StreamWatchdog.sleep(idle: 90, timeout: 90) == nil && StreamWatchdog.sleep(idle: 200, timeout: 90) == nil, "silent 90 s → reconnect")

    // Fullscreen: no poll normally, slow poll while fullscreen.
    check(FullscreenFallback.pollInterval(isFullscreen: false) == 10, "10 s safety poll when not fullscreen")
    check(FullscreenFallback.pollInterval(isFullscreen: true) == 15, "15 s fallback poll while fullscreen")
    check(FullscreenFallback.settleDelays.allSatisfy { $0 > 0 && $0 <= 8 } && FullscreenFallback.settleDelays.max() == 8, "settle re-checks up to 8 s")
}

// MARK: Housekeeping (v0.8.1: one timer for every deadline)
do {
    let up: TimeInterval = 1_000, wall: TimeInterval = 1_790_000_000
    check(Housekeeping.plan(HousekeepingDeadlines(), uptime: up, wall: wall) == nil, "housekeeping: nothing armed = no timer")

    // Earliest deadline wins across both clocks; the tolerance never lets it run past another task's window.
    let mixed = HousekeepingDeadlines(quiet: up + 120, fidget: up + 60, dndEnd: wall + 30)
    let p1 = Housekeeping.plan(mixed, uptime: up, wall: wall)
    check(p1?.delay == 30 && p1?.tolerance == 1 && p1?.tasks == [.dndEnd], "housekeeping: earliest (勿扰 end) first: \(String(describing: p1))")

    // Deadlines inside the window coalesce into one wake-up.
    let close = HousekeepingDeadlines(quiet: up + 120, fidget: up + 115)
    let p2 = Housekeeping.plan(close, uptime: up, wall: wall)
    check(p2?.delay == 115 && abs((p2?.tolerance ?? 0) - 11.5) < 1e-9 && p2?.tasks == [.quiet, .fidget], "housekeeping: quiet + fidget coalesce: \(String(describing: p2))")
    check(Housekeeping.due(close, uptime: up + 115, wall: wall + 115) == [.fidget], "housekeeping: only the due one runs")
    check(Housekeeping.due(close, uptime: up + 121, wall: wall + 121) == [.quiet, .fidget], "housekeeping: run order")
    check(Housekeeping.due(HousekeepingDeadlines(doze: up, hideEnd: wall - 5), uptime: up, wall: wall) == [.hideEnd, .doze], "housekeeping: wall-clock ends run first")
    check(Housekeeping.plan(HousekeepingDeadlines(rotation: up - 10), uptime: up, wall: wall)?.delay == 0, "housekeeping: overdue fires at once")

    // Tolerance: ≥ 1 s, 10 %, capped at a minute; wall-clock ends 1 s.
    check(Housekeeping.tolerance(for: .fidget, delay: 5) == 1 && Housekeeping.tolerance(for: .quiet, delay: 120) == 12
          && Housekeeping.tolerance(for: .rotation, delay: 1800) == 60 && Housekeeping.tolerance(for: .dndEnd, delay: 3600) == 1,
          "housekeeping: tolerances")

    // Re-arm after an interaction: quiet / doze restart a full threshold from the interaction.
    var qc = DozeClock(threshold: IdleRules.quietAfter, now: up)
    var d = HousekeepingDeadlines(quiet: up + IdleRules.quietAfter, doze: up + IdleRules.dozeAfter)
    let later = up + 100
    qc.activity(now: later)
    d.quiet = later + qc.threshold
    d.doze = later + IdleRules.dozeAfter
    let p3 = Housekeeping.plan(d, uptime: later, wall: wall + 100)
    check(p3?.delay == IdleRules.quietAfter && p3?.tasks == [.quiet], "housekeeping: interaction pushes quiet a full 120 s out")
    check(qc.check(now: later + 119, blocked: false) == .wait(1) && qc.check(now: later + 120, blocked: false) == .doze, "housekeeping: quiet clock agrees")

    // 勿扰「今天之内」ends at local midnight, even when the Mac slept through it (uptime barely moved).
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let evening = cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 23, minute: 30))!.timeIntervalSince1970
    var dnd = DNDState()
    dnd.turnOn(.today, now: evening, calendar: cal)
    let midnight = cal.date(from: DateComponents(year: 2026, month: 9, day: 30))!.timeIntervalSince1970
    let dd = HousekeepingDeadlines(fidget: nil, dndEnd: dnd.until)
    check(dnd.until == midnight && Housekeeping.plan(dd, uptime: up, wall: evening)?.delay == 30 * 60, "housekeeping: 勿扰 today → timer to midnight")
    check(Housekeeping.due(dd, uptime: up + 60, wall: midnight + 7 * 3600).contains(.dndEnd) && !dnd.isOn(now: midnight), "housekeeping: 勿扰 over after sleeping past midnight")

    // A 5-minute hide whose time passed while the Mac slept: due on wake (re-arm), and it expires.
    var hs = HideState()
    hs.hide(.fiveMinutes, now: wall)
    let hd = HousekeepingDeadlines(hideEnd: hs.until)
    check(Housekeeping.plan(hd, uptime: up, wall: wall)?.delay == 300, "housekeeping: hide end in 5 min")
    check(Housekeeping.due(hd, uptime: up + 2, wall: wall + 600) == [.hideEnd] && hs.expire(now: wall + 600) && !hs.isHidden, "housekeeping: hide ends after sleep")

    // Fidgets are only scheduled while animating and visible; a fresh wait when they come back.
    check(Housekeeping.fidgetsArmed(pose: .idle, hidden: false, paused: false), "fidgets armed when idle")
    check(!Housekeeping.fidgetsArmed(pose: .quiet, hidden: false, paused: false) && !Housekeeping.fidgetsArmed(pose: .doze, hidden: false, paused: false)
          && !Housekeeping.fidgetsArmed(pose: .idle, hidden: true, paused: false) && !Housekeeping.fidgetsArmed(pose: .idle, hidden: false, paused: true),
          "no fidget timer in quiet / doze / hidden / paused")
    check(Housekeeping.fidgetDeadline(current: 50, armed: true, now: 10, delay: 99) == 50, "fidget deadline kept")
    check(Housekeeping.fidgetDeadline(current: nil, armed: true, now: 10, delay: 60) == 70, "fidget deadline drawn")
    check(Housekeeping.fidgetDeadline(current: 50, armed: false, now: 10, delay: 60) == nil, "fidget deadline dropped")

    // Busy: 5 s like v0.8, then backing off to 30 s.
    check((1...6).map { Housekeeping.blockedRetry(attempt: $0) } == [5, 5, 10, 20, 30, 30], "blocked retry backoff")
}

// MARK: v0.10 personal tools
do {
    let cfg = PomodoroConfig()
    check(cfg.focus == 1500 && cfg.shortBreak == 300 && cfg.longBreak == 900 && cfg.roundsPerLong == 4, "pomodoro defaults")
    var p = PomodoroState.idle
    check(p.phase == .idle && p.remaining(now: 0) == nil && !p.isPaused && p.focusStatus == nil, "pomodoro idle")
    p.start(now: 1000, config: cfg)
    check(p.phase == .focus && p.remaining(now: 1000) == 1500 && p.remaining(now: 1100) == 1400 && p.remaining(now: 9999) == 0, "pomodoro start: 1500 s remaining")
    check(p.advance(now: 2000, config: cfg) == nil, "pomodoro not due → nil")
    check(p.focusStatus == FocusStatus(phase: "focus", until: 2_500_000), "pomodoro focus status in ms")
    var now = 1000.0
    var events: [PomodoroEvent] = []
    for round in 1...4 {
        if round > 1 { p.start(now: now, config: cfg) }
        now = p.until!
        events.append(p.advance(now: now, config: cfg)!)
        check(p.focusStatus == nil, "no focus status during a break (round \(round))")
        now = p.until!
        check(p.advance(now: now, config: cfg) == .breakDone && p.phase == .idle && p.until == nil, "break ends → idle (round \(round))")
    }
    check(events == [.focusDone(next: .shortBreak), .focusDone(next: .shortBreak), .focusDone(next: .shortBreak), .focusDone(next: .longBreak)], "4th focus → long break: \(events)")
    check(p.completedFocus == 0, "long break over → round count restarts")
    var q = PomodoroState.idle
    q.start(now: 0, config: cfg); _ = q.advance(now: 1500, config: cfg)
    check(q.phase == .shortBreak && q.until == 1800 && q.completedFocus == 1, "short break lasts 300 s from the end")
    q.skipBreak()
    check(q.phase == .idle && q.until == nil && q.completedFocus == 1, "skipBreak → idle, keeps rounds")
    q.start(now: 0, config: cfg); q.skipBreak()
    check(q.phase == .focus, "skipBreak ignored during focus")
    var r = PomodoroState.idle
    r.start(now: 0, config: cfg)
    r.pause(now: 600)
    check(r.isPaused && r.until == nil && r.pausedRemaining == 900 && r.remaining(now: 5000) == 900 && r.focusStatus == nil, "pause keeps remaining, no focus status")
    check(r.advance(now: 99999, config: cfg) == nil, "paused never advances")
    r.pause(now: 700)
    check(r.pausedRemaining == 900, "second pause is a no-op")
    r.resume(now: 5000)
    check(!r.isPaused && r.until == 5900 && r.remaining(now: 5000) == 900 && r.pausedRemaining == nil, "resume continues with the saved time")
    r.stop()
    check(r == .idle && r.completedFocus == 0, "stop → idle, rounds cleared")
    var s = PomodoroState.idle
    s.start(now: 0, config: cfg)
    check(s.advance(now: 100_000, config: cfg) == .focusDone(next: .shortBreak) && s.until == 100_300 && s.phase == .shortBreak, "sleep: one step, next phase from now")
    check(s.advance(now: 100_000, config: cfg) == nil, "…and no second step in the same call")
    var j = PomodoroState.idle
    j.start(now: 123.5, config: cfg); j.pause(now: 200); j.completedFocus = 2
    check(try JSONDecoder().decode(PomodoroState.self, from: JSONEncoder().encode(j)) == j, "pomodoro state JSON roundtrip")
    check(try JSONDecoder().decode(PomodoroState.self, from: Data("{}".utf8)) == .idle, "pomodoro state: empty JSON = idle")
    check(try JSONDecoder().decode(PomodoroConfig.self, from: Data(#"{"focus":60}"#.utf8)).focus == 60, "pomodoro config: missing keys default")
}

do {
    let f = FocusStatus(phase: "focus", until: 10 * 60_000)
    check(f.minutesLeft(nowMs: 0) == 10 && f.minutesLeft(nowMs: 1) == 10 && f.minutesLeft(nowMs: 540_001) == 1 && f.minutesLeft(nowMs: 539_000) == 2, "focus minutes round up")
    check(f.minutesLeft(nowMs: 600_000) == 1 && f.minutesLeft(nowMs: 700_000) == 1, "focus minutes at least 1")
    check(f.isActive(nowMs: 599_999) && !f.isActive(nowMs: 600_000), "focus isActive")
    check(try JSONDecoder().decode(FocusStatus.self, from: JSONEncoder().encode(f)) == f, "focus JSON roundtrip")
}

do {
    var r = ActiveTimeReminder(interval: 3600)
    check(!r.tick(now: 1000, idleSeconds: 0, blocked: false) && r.activeSeconds == 0, "first tick only records the time")
    check(!r.tick(now: 1060, idleSeconds: 3, blocked: false) && r.activeSeconds == 60, "active time accumulates")
    check(!r.tick(now: 1120, idleSeconds: 299, blocked: false) && r.activeSeconds == 120, "idle < 300 still counts as active")
    check(!r.tick(now: 1180, idleSeconds: 300, blocked: false) && r.activeSeconds == 0, "away ≥ 300 s resets")
    var c = ActiveTimeReminder(interval: 3600)
    _ = c.tick(now: 0, idleSeconds: 0, blocked: false)
    _ = c.tick(now: 36_000, idleSeconds: 0, blocked: false)
    check(c.activeSeconds == 7200, "dt capped (long sleep not counted as work): \(c.activeSeconds)")
    var short = ActiveTimeReminder(interval: 60)
    _ = short.tick(now: 0, idleSeconds: 0, blocked: false)
    _ = short.tick(now: 10_000, idleSeconds: 0, blocked: false)
    check(short.activeSeconds == 120, "dt cap floor is 120 s: \(short.activeSeconds)")
    var d = ActiveTimeReminder(interval: 300)
    _ = d.tick(now: 0, idleSeconds: 0, blocked: false)
    check(!d.tick(now: 100, idleSeconds: 0, blocked: false) && !d.tick(now: 200, idleSeconds: 0, blocked: false), "not due yet")
    check(d.tick(now: 300, idleSeconds: 0, blocked: false) && d.showing, "due → true, showing")
    check(!d.tick(now: 360, idleSeconds: 0, blocked: false) && !d.tick(now: 420, idleSeconds: 0, blocked: false), "showing → no repeat")
    d.done(now: 430)
    check(!d.showing && d.activeSeconds == 0 && d.snoozeUntil == nil, "done resets")
    check(!d.tick(now: 490, idleSeconds: 0, blocked: false) && d.activeSeconds == 60, "counts again after done")
    var b = ActiveTimeReminder(interval: 120)
    _ = b.tick(now: 0, idleSeconds: 0, blocked: true)
    check(!b.tick(now: 100, idleSeconds: 0, blocked: true) && !b.tick(now: 200, idleSeconds: 0, blocked: true) && !b.showing, "blocked → not shown")
    check(b.activeSeconds >= 120, "blocked keeps the pending state")
    check(b.tick(now: 260, idleSeconds: 0, blocked: false) && b.showing, "unblocked → fires")
    var z = ActiveTimeReminder(interval: 120)
    _ = z.tick(now: 0, idleSeconds: 0, blocked: false)
    check(z.tick(now: 120, idleSeconds: 0, blocked: false), "due")
    z.snooze(now: 130)
    check(!z.showing && z.snoozeUntil == 730 && z.activeSeconds == 120, "snooze: 600 s, active time stays")
    check(!z.tick(now: 190, idleSeconds: 0, blocked: false) && !z.tick(now: 700, idleSeconds: 0, blocked: false), "snoozed → quiet")
    check(z.tick(now: 730, idleSeconds: 0, blocked: false) && z.showing, "snooze over → fires again")
    check(!z.tick(now: 790, idleSeconds: 0, blocked: false), "…once")
    z.done(now: 800)
    check(z.snoozeUntil == nil, "done clears snooze")
    var aw = ActiveTimeReminder(interval: 120)
    _ = aw.tick(now: 0, idleSeconds: 0, blocked: false); _ = aw.tick(now: 120, idleSeconds: 0, blocked: false)
    aw.snooze(now: 121)
    _ = aw.tick(now: 200, idleSeconds: 400, blocked: false)
    check(aw.activeSeconds == 0 && aw.snoozeUntil == nil, "away also clears snooze")
    check(ActiveTimeReminder(interval: 3600).secondsUntilNextCheck() == 3600, "next check: full interval when fresh")
    var n = ActiveTimeReminder(interval: 3600); n.activeSeconds = 3590
    check(n.secondsUntilNextCheck() == 60, "next check: at least 60 s")
    n.activeSeconds = 1800
    check(n.secondsUntilNextCheck() == 1800, "next check: remaining time")
    n.activeSeconds = 4000
    check(n.secondsUntilNextCheck() == 60, "next check: overdue → 60 s")
    check(ActiveTimeReminder(interval: 30).secondsUntilNextCheck() == 60, "next check floor beats a tiny interval")
    check(try JSONDecoder().decode(ActiveTimeReminder.self, from: JSONEncoder().encode(z)) == z, "reminder JSON roundtrip")
    check(ActiveTimeReminder.awayThreshold == 300 && ActiveTimeReminder.snoozeDelay == 600, "reminder constants")
}

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let day1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 23, minute: 30))!
    let day1b = cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 8))!
    let day2 = cal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 0, minute: 5))!
    var w = WaterLog()
    check(w.cups(on: day1, calendar: cal) == 0, "empty water log")
    w.add(now: day1b, calendar: cal); w.add(now: day1, calendar: cal)
    check(w.day == "2026-10-04" && w.cups == 2 && w.cups(on: day1, calendar: cal) == 2, "water adds up within a day")
    check(w.cups(on: day2, calendar: cal) == 0, "next day reads 0")
    w.add(now: day2, calendar: cal)
    check(w.day == "2026-10-05" && w.cups == 1, "adding on a new day restarts at 1")
    check(try JSONDecoder().decode(WaterLog.self, from: JSONEncoder().encode(w)) == w, "water log JSON roundtrip")
}

do {
    let s = ToolsSettings()
    check(!s.waterEnabled && !s.standEnabled && s.waterInterval == 3600 && s.standInterval == 2700 && s.pomodoro == PomodoroConfig(), "tools settings defaults (reminders off)")
    check(try JSONDecoder().decode(ToolsSettings.self, from: Data("{}".utf8)) == s, "tools settings: empty JSON = defaults")
    check(try JSONDecoder().decode(ToolsSettings.self, from: Data(#"{"waterEnabled":true,"future":1}"#.utf8)).waterEnabled, "tools settings: unknown keys ignored")
    let suite = "lulupet.test-tools-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = PersonalToolsStore(defaults: defaults)
    check(store.settings == ToolsSettings() && store.pomodoro == .idle && store.waterLog == WaterLog() && store.reminder(.water) == nil && store.reminder(.stand) == nil, "store: empty defaults")
    var ns = ToolsSettings(); ns.waterEnabled = true; ns.pomodoro.focus = 60; ns.standInterval = 1200
    store.settings = ns
    var ps = PomodoroState.idle; ps.start(now: 5, config: ns.pomodoro)
    store.pomodoro = ps
    store.waterLog = WaterLog(day: "2026-10-04", cups: 3)
    var rem = ActiveTimeReminder(interval: 600); rem.activeSeconds = 42; rem.showing = true
    store.setReminder(rem, for: .water)
    let again = PersonalToolsStore(defaults: UserDefaults(suiteName: suite)!)
    check(again.settings == ns && again.pomodoro == ps && again.waterLog.cups == 3 && again.reminder(.water) == rem && again.reminder(.stand) == nil, "store roundtrips through a second instance")
    check(defaults.data(forKey: "toolsSettings") != nil && defaults.data(forKey: "pomodoroState") != nil && defaults.data(forKey: "waterLog") != nil && defaults.data(forKey: "reminder.water") != nil, "store key names")
    store.setReminder(nil, for: .water)
    check(store.reminder(.water) == nil, "setReminder(nil) clears")
    defaults.set(Data("garbage".utf8), forKey: "toolsSettings")
    check(store.settings == ToolsSettings(), "store: garbage = defaults")
    defaults.removePersistentDomain(forName: suite)
    let cs = ConfigStore(profile: "test-\(UUID().uuidString)")
    PersonalToolsStore(defaults: cs.defaults).waterLog = WaterLog(day: "x", cups: 1)
    check(cs.defaults.data(forKey: "waterLog") != nil && cs.defaults.data(forKey: "config") == nil, "store writes into the profile's defaults, leaves config alone")
}

do {
    let f = FocusStatus(phase: "focus", until: 99_000)
    let dn = DNDStatus(mood: "busy", untilMs: 0)
    let pay = PresenceInfo.payload(lastSeen: 5, dnd: nil, focus: f)
    check(Set(pay.keys) == ["lastSeen", "focus"], "presence payload carries focus")
    check(Set(PresenceInfo.payload(lastSeen: 5, dnd: nil).keys) == ["lastSeen"], "presence payload without focus = old shape")
    for info in [PresenceInfo(lastSeen: 5, dnd: nil, focus: f), PresenceInfo(lastSeen: 5, dnd: dn, focus: f), PresenceInfo(lastSeen: 5, dnd: dn), PresenceInfo(lastSeen: 5)] {
        let data = try JSONSerialization.data(withJSONObject: PresenceInfo.payload(lastSeen: 5, dnd: info.dnd, focus: info.focus))
        check(PresenceInfo.decode(data) == info, "presence roundtrip focus=\(info.focus != nil) dnd=\(info.dnd != nil)")
    }
    check(PresenceInfo.decode(Data(#"{"lastSeen":1234}"#.utf8)) == PresenceInfo(lastSeen: 1234), "old presence (lastSeen only) still decodes")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"dnd":{"mood":"busy","until":0}}"#.utf8)) == PresenceInfo(lastSeen: 7, dnd: dn), "old presence (dnd only) still decodes")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"focus":"x"}"#.utf8)) == PresenceInfo(lastSeen: 7), "malformed focus ignored")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"focus":{"until":5}}"#.utf8))?.focus == FocusStatus(phase: "focus", until: 5), "focus without phase")
    let now = nowMs()
    check(Presence.reach(connected: true, info: PresenceInfo(lastSeen: now - 1000, focus: f), nowMs: now) == .online, "focus doesn't change reach")
}

do {
    let m = Message.remind(.water, from: .lulu, ts: 5)
    check(m.kind == .remind && m.kind.rawValue == "remind" && m.remind == .water && m.ackOf == nil && m.from == .lulu, "remind factory")
    check(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(m)) == m, "remind roundtrip (local)")
    let pay = try JSONSerialization.jsonObject(with: m.firebasePayload()) as! [String: Any]
    check(pay["kind"] as? String == "remind" && pay["remind"] as? String == "water" && pay["ackOf"] == nil && pay["id"] == nil, "remind firebase payload")
    let ack = Message.remind(.stand, from: .lumei, ackOf: "-Abc", ts: 6)
    let ackPay = try JSONSerialization.jsonObject(with: ack.firebasePayload()) as! [String: Any]
    check(ack.ackOf == "-Abc" && ackPay["ackOf"] as? String == "-Abc" && ackPay["remind"] as? String == "stand", "remind receipt ackOf")
    let dec = Message.decode(firebaseKey: "-K", value: ackPay)
    check(dec?.kind == .remind && dec?.remind == .stand && dec?.ackOf == "-Abc" && dec?.extra.isEmpty == true, "remind decodes from firebase, nothing leaks into extra")
    let future = Message.decode(firebaseKey: "-F", value: ["from": "lulu", "kind": "remind", "remind": "sleep", "ts": 9])
    check(future?.kind == .remind && future?.remind == nil, "unknown remind value → nil")
    let futurePay = try JSONSerialization.jsonObject(with: future!.firebasePayload()) as! [String: Any]
    check(futurePay["remind"] as? String == "sleep", "unknown remind value survives a re-encode")
    check(Message.decode(firebaseKey: "-T", value: ["from": "lulu", "kind": "text", "text": "hi", "ts": 1]) == Message(id: "-T", from: .lulu, kind: .text, text: "hi", ts: 1, v: nil), "plain text payload unchanged by v0.10 fields")
    check(Visits.deliveryAway(for: .remind) > 0, "remind has a delivery stay")
}

do {
    check(HousekeepingTask.pomodoro.isWallClock && !HousekeepingTask.water.isWallClock && !HousekeepingTask.stand.isWallClock, "pomodoro wall clock, water / stand monotonic")
    var d = HousekeepingDeadlines()
    check(d[.pomodoro] == nil && d[.water] == nil && d[.stand] == nil, "new deadlines default to nil")
    d.pomodoro = 1000; d.water = 50; d.stand = 70
    check(d[.pomodoro] == 1000 && d.delay(.pomodoro, uptime: 0, wall: 990) == 10, "pomodoro delay uses wall clock")
    check(d.delay(.water, uptime: 30, wall: 99999) == 20 && d.delay(.stand, uptime: 30, wall: 99999) == 40, "water / stand delays use uptime")
    check(Housekeeping.due(d, uptime: 60, wall: 990) == [.water], "only the due one runs")
    check(Housekeeping.due(d, uptime: 80, wall: 1000) == [.pomodoro, .water, .stand], "run order: pomodoro, water, stand")
    check(Housekeeping.plan(d, uptime: 0, wall: 995)?.tasks.first == .pomodoro, "plan picks the wall-clock pomodoro when earliest")
    check(HousekeepingDeadlines(quiet: 1, doze: 2, rotation: 3, fidget: 4, dndEnd: 5, hideEnd: 6).pomodoro == nil, "old initializer call still compiles")
}

// MARK: v0.10 PairChannel.setFocus → heartbeat carries focus
StubProtocol.replies = [
    "PUT /pairs/PAIR/presence/lulu.json": .init(status: 200, body: "{}"),
    "GET /pairs/PAIR/presence/lumei.json": .init(status: 200, body: "{\"lastSeen\":\(nowMs()),\"focus\":{\"phase\":\"focus\",\"until\":\(nowMs() + 600_000)}}"),
    "GET /pairs/PAIR/messages.json": .init(status: 200, body: "event: keep-alive\ndata: null\n\n", contentType: "text/event-stream"),
]
StubProtocol.requests = []
do {
    let fch = PairChannel(config: AppConfig(role: .lulu, pairCode: "PAIR", databaseURL: "https://stub.firebaseio.com"),
                          store: ConfigStore(profile: "test-\(UUID().uuidString)"), client: fb)
    nonisolated(unsafe) var seen: [FocusStatus?] = []
    await MainActor.run {
        fch.onPartnerFocus = { seen.append($0) }
        fch.start()
    }
    try? await Task.sleep(nanoseconds: 400_000_000)
    func heartbeatBodies() -> [[String: Any]] {
        StubProtocol.requests.filter { $0.method == "PUT" }.compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
    check(!heartbeatBodies().isEmpty && heartbeatBodies().allSatisfy { $0["focus"] == nil }, "heartbeat has no focus before setFocus")
    let until = nowMs() + 300_000
    let before = heartbeatBodies().count
    await MainActor.run { fch.setFocus(FocusStatus(phase: "focus", until: until)) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let after = heartbeatBodies()
    let fo = after.last?["focus"] as? [String: Any]
    check(after.count == before + 1 && fo?["phase"] as? String == "focus" && (fo?["until"] as? NSNumber)?.int64Value == until, "setFocus sends a heartbeat at once, with focus")
    await MainActor.run { fch.setFocus(FocusStatus(phase: "focus", until: until)) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    check(heartbeatBodies().count == after.count, "setFocus with the same value sends nothing")
    await MainActor.run { fch.setFocus(nil) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(heartbeatBodies().last?["focus"] == nil && heartbeatBodies().count == after.count + 1, "setFocus(nil) clears it")
    await MainActor.run { fch.setFocus(FocusStatus(phase: "focus", until: nowMs() - 1)) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(heartbeatBodies().last?["focus"] == nil, "an expired focus is never published")
    await MainActor.run {
        check(fch.partnerPresence?.focus?.phase == "focus" && fch.partnerFocus != nil, "partner presence carries focus")
        check(seen.count == 1 && seen[0]?.phase == "focus", "onPartnerFocus fired once")
        fch.stop()
    }
}
StubProtocol.replies = [:]

// MARK: v0.11 PairChannel identity: heartbeat carries it, partner identity + seat clash are exposed
do {
    let other = nowMs()
    StubProtocol.replies = [
        "PUT /pairs/PAIR/presence/lulu.json": .init(status: 200, body: "{}"),
        "GET /pairs/PAIR/presence/lumei.json": .init(status: 200, body: "{\"lastSeen\":\(other),\"character\":\"lulu\",\"mode\":\"friend\",\"device\":\"P-1\"}"),
        "GET /pairs/PAIR/presence/lulu.json": .init(status: 200, body: "{\"lastSeen\":\(other),\"device\":\"SOMEONE-ELSE\"}"),
        "GET /pairs/PAIR/messages.json": .init(status: 200, body: "event: keep-alive\ndata: null\n\n", contentType: "text/event-stream"),
    ]
    StubProtocol.requests = []
    let ich = PairChannel(config: AppConfig(role: .lulu, pairCode: "PAIR", databaseURL: "https://stub.firebaseio.com"),
                          store: ConfigStore(profile: "test-\(UUID().uuidString)"), client: fb)
    nonisolated(unsafe) var ids: [PartnerIdentity] = []
    nonisolated(unsafe) var clashes: [Bool] = []
    nonisolated(unsafe) var presences = 0
    await MainActor.run {
        check(ich.partnerIdentity == PartnerIdentity(character: .lumei, mode: .couple) && !ich.seatClash && ich.identity == nil, "v0.11 channel: defaults before any read")
        ich.onPartnerIdentity = { ids.append($0) }
        ich.onSeatClash = { clashes.append($0) }
        ich.onPartnerPresence = { _ in presences += 1 }
        ich.start()
    }
    try? await Task.sleep(nanoseconds: 400_000_000)
    func puts() -> [[String: Any]] {
        StubProtocol.requests.filter { $0.method == "PUT" }.compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
    func getsOfMySeat() -> Int { StubProtocol.requests.filter { $0.method == "GET" && $0.url.path.hasSuffix("/presence/lulu.json") }.count }
    check(!puts().isEmpty && puts().allSatisfy { $0["character"] == nil && $0["mode"] == nil && $0["device"] == nil }, "v0.11 channel: heartbeat has no identity before setIdentity (as before)")
    check(getsOfMySeat() == 0 && !ich.seatClash, "v0.11 channel: my seat is not polled before setIdentity")
    check(ids.count == 1 && ids[0] == PartnerIdentity(character: .lulu, mode: .friend) && presences >= 1, "v0.11 channel: partner presence → identity (character lulu, friend)")
    let before = puts().count
    await MainActor.run { ich.setIdentity(character: .lumei, mode: .friend, device: "ME") }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let last = puts().last
    check(puts().count == before + 1 && last?["character"] as? String == "lumei" && last?["mode"] as? String == "friend" && last?["device"] as? String == "ME" && last?["lastSeen"] != nil, "v0.11 channel: setIdentity heartbeats at once with identity")
    await MainActor.run { ich.setIdentity(character: .lumei, mode: .friend, device: "ME") }
    try? await Task.sleep(nanoseconds: 150_000_000)
    check(puts().count == before + 1, "v0.11 channel: same identity → no extra heartbeat")
    // v0.12 place
    check(puts().allSatisfy { $0["place"] == nil }, "v0.12 channel: heartbeat has no place before setPlace (as before)")
    let wplace = WeatherPlace(name: "洛杉矶", admin: nil, country: "美国", latitude: 34.0522, longitude: -118.2437, timezone: "America/Los_Angeles")
    await MainActor.run { ich.setPlace(wplace) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let pl = puts().last?["place"] as? [String: Any]
    check(puts().count == before + 2 && pl?["name"] as? String == "洛杉矶" && pl?["latitude"] as? Double == 34.05 && puts().last?["character"] as? String == "lumei", "v0.12 channel: setPlace heartbeats at once with place (rounded), identity kept")
    await MainActor.run { ich.setPlace(wplace) }
    try? await Task.sleep(nanoseconds: 150_000_000)
    check(puts().count == before + 2, "v0.12 channel: same place → no extra heartbeat")
    await MainActor.run { ich.setPlace(nil) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(puts().count == before + 3 && puts().last?["place"] == nil, "v0.12 channel: clearing the place heartbeats without it")
    await MainActor.run {
        check(ich.partnerPresence?.device == "P-1" && ich.partnerPresence?.mode == .friend, "v0.11 channel: partnerPresence exposes the whole PresenceInfo")
        ich.stop()
    }
    // seat clash is read on the next poll once identity is set: restart the loop
    // checks every 0.3 s here (default ~3 min); the clash needs two consecutive positive reads
    StubProtocol.requests = []
    await MainActor.run {
        ich.heartbeatInterval = 0.1; ich.presencePollInterval = 0.1; ich.seatCheckInterval = 0.3
        ich.start()
    }
    try? await Task.sleep(nanoseconds: 150_000_000)
    check(!ich.seatClash && clashes.isEmpty && getsOfMySeat() == 1, "v0.11 channel: one positive read is not yet a clash (read once at start)")
    try? await Task.sleep(nanoseconds: 1_100_000_000)
    await MainActor.run {
        check(ich.seatClash && clashes == [true] && ich.mySeatPresence?.device == "SOMEONE-ELSE", "v0.11 channel: two consecutive positive reads → seatClash")
        // my seat is read BEFORE the heartbeat PUT of the same iteration, and only every seatCheckInterval
        let first = StubProtocol.requests.first { $0.url.path.hasSuffix("/presence/lulu.json") }
        check(first?.method == "GET", "v0.11 channel: my seat is read before the first heartbeat PUT")
        check(getsOfMySeat() <= 5, "v0.11 channel: my seat is read once per seatCheckInterval, not on every poll (\(getsOfMySeat()) reads)")
        ich.stop()
    }
}
StubProtocol.replies = [:]
do {
    // the newest partner message's character is the fallback when presence has none
    let msg = "event: put\ndata: {\"path\":\"/-Z\",\"data\":{\"from\":\"lumei\",\"kind\":\"text\",\"text\":\"hi\",\"ts\":99,\"character\":\"lulu\"}}\n\n"
    StubProtocol.replies = [
        "PUT /pairs/PAIR/presence/lulu.json": .init(status: 200, body: "{}"),
        "GET /pairs/PAIR/presence/lumei.json": .init(status: 200, body: "{\"lastSeen\":\(nowMs())}"),
        "GET /pairs/PAIR/messages.json": .init(status: 200, body: msg, contentType: "text/event-stream"),
    ]
    let mch = PairChannel(config: AppConfig(role: .lulu, pairCode: "PAIR", databaseURL: "https://stub.firebaseio.com"),
                          store: ConfigStore(profile: "test-\(UUID().uuidString)"), client: fb)
    await MainActor.run { mch.start() }
    try? await Task.sleep(nanoseconds: 500_000_000)
    await MainActor.run {
        check(mch.partnerIdentity == PartnerIdentity(character: .lulu, mode: .couple), "v0.11 channel: partner message character is the fallback")
        mch.stop()
    }
}
StubProtocol.replies = [:]

// v0.10 partner: focus hold + remind water / stand
do {
    var focusing = PomodoroState.idle
    focusing.start(now: 1000, config: PomodoroConfig())
    check(Visits.isHoldingForFocus(state: focusing, now: 1100), "own focus running → holding visits")
    check(!Visits.isHoldingForFocus(state: focusing, now: 1000 + 1500), "own focus ended exactly → not holding")
    check(!Visits.isHoldingForFocus(state: .idle, now: 1100), "idle → not holding")
    var paused = focusing
    paused.pause(now: 1100)
    check(!Visits.isHoldingForFocus(state: paused, now: 1200), "paused focus → not holding")
    var brk = focusing
    _ = brk.advance(now: 3000, config: PomodoroConfig())
    check(brk.phase == .shortBreak && !Visits.isHoldingForFocus(state: brk, now: 3001), "break → not holding")

    let f = FocusStatus(phase: "focus", until: 10_000_000)
    check(Visits.partnerFocusHolds(f, partnerOnline: true, nowMs: 9_000_000), "partner online + focus → holds")
    check(!Visits.partnerFocusHolds(f, partnerOnline: false, nowMs: 9_000_000), "partner offline (stale focus) → no hold")
    check(!Visits.partnerFocusHolds(f, partnerOnline: true, nowMs: 10_000_000), "expired focus → no hold")
    check(!Visits.partnerFocusHolds(nil, partnerOnline: true, nowMs: 1), "no focus → no hold")
    check(Visits.partnerFocusLine(name: "噜妹", focus: f, nowMs: 10_000_000 - 12 * 60_000 + 5_000) == "噜妹正在专注 🍅 还剩 12 分钟", "partner focus line (rounded up)")
    check(Visits.partnerFocusLine(name: "噜噜", focus: f, nowMs: 10_000_000 - 100) == "噜噜正在专注 🍅 还剩 1 分钟", "partner focus line minimum 1 min")
    check(Visits.focusBounceLine == "TA 在专注，先放在 TA 那儿啦", "focus bounce line")

    let w = Visits.remindBubble(kind: .water, sender: "噜噜")
    check(w.line == "噜噜叫你喝水啦 💧" && w.comply == "喝了 ✓" && w.snooze == "等会儿", "water remind bubble")
    let st = Visits.remindBubble(kind: .stand, sender: "噜妹")
    check(st.line == "噜妹叫你起来动动 🧍" && st.comply == "好的 ✓" && st.snooze == "等会儿", "stand remind bubble")
    check(Visits.remindAckLine(.water) == "TA 喝啦 💧" && Visits.remindAckLine(.stand) == "TA 站起来啦", "ack lines")
    check(Visits.remindReactionKey(.water) == "remind_water" && Visits.remindReactionKey(.stand) == "remind_stand", "remind reaction keys")

    let call = Message.remind(.water, from: .lulu, ts: 5)
    let ack = Message.remind(.water, from: .lumei, ackOf: call.id, ts: 6)
    check(!Visits.isRemindAck(call) && Visits.isRemindAck(ack), "isRemindAck")
    check(Visits.remindHistoryLine(call, fromMe: true) == "💧 叫 TA 喝水" && Visits.remindHistoryLine(call, fromMe: false) == "💧 TA 叫你喝水", "history: water call")
    check(Visits.remindHistoryLine(ack, fromMe: false) == "💧 TA 喝啦" && Visits.remindHistoryLine(ack, fromMe: true) == "💧 你喝啦", "history: water ack")
    let sc = Message.remind(.stand, from: .lulu, ts: 7)
    check(Visits.remindHistoryLine(sc, fromMe: true) == "🧍 叫 TA 起来动动" && Visits.remindHistoryLine(Message.remind(.stand, from: .lumei, ackOf: sc.id, ts: 8), fromMe: false) == "🧍 TA 站起来啦", "history: stand")
    var unknownRemind = call
    unknownRemind.remindRaw = "dance"
    check(Visits.remindHistoryLine(unknownRemind, fromMe: false) == nil, "history: unknown remind value → nil (placeholder)")

    let label: (String) -> String? = { _ in nil }
    let away = AwaySummary.build([call, call, sc, ack, unknownRemind], stickerLabel: label)!
    check(away.waterCalls == 2 && away.standCalls == 1 && away.acks == 1 && away.unknown == 1 && away.total == 5, "away summary counts reminds")
    check(away.lines == ["💧 叫你喝水 ×2", "🧍 叫你起来动动", "✅ TA 回应了提醒", "✨ 1 条新版本消息"], "away summary remind lines")
    check(AwaySummary.build([sc], stickerLabel: label)!.sincerityLines == ["🧍 叫你起来动动"], "sincerity list has remind lines")
}

// MARK: v0.11 modes (docs/superpowers/specs/2026-10-05-modes-design.md)
do {
    // Today's exact config JSON (written by every version before v0.11): no mode / character.
    let todayConfig = #"{"role":"lumei","pairCode":"ABCDEFGHJKLMNPQRSTUVWXYZ","databaseURL":"https://x-default-rtdb.firebaseio.com"}"#
    let old = try JSONDecoder().decode(AppConfig.self, from: Data(todayConfig.utf8))
    check(old.mode == nil && old.character == nil && old.effectiveMode == .couple && old.myCharacter == .lumei, "v0.11: today's config loads as couple / seat character")
    check(old.isComplete == AppConfig(role: .lumei, pairCode: old.pairCode, databaseURL: old.databaseURL).isComplete && old.isComplete, "v0.11: today's config isComplete unchanged")
    let reenc = String(data: try JSONEncoder().encode(old), encoding: .utf8)!
    check(!reenc.contains("mode") && !reenc.contains("character"), "v0.11: nil mode / character are not written")
    let ms = ConfigStore(profile: "test-\(UUID().uuidString)")
    ms.defaults.set(Data(todayConfig.utf8), forKey: "config")
    check(ms.load() == old, "v0.11: store loads today's config")
    // new fields round-trip; unknown values never make the whole config unreadable
    let fr = AppConfig(role: .lulu, pairCode: old.pairCode, databaseURL: old.databaseURL, mode: .friend, character: .lumei)
    check(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(fr)) == fr && fr.effectiveMode == .friend && fr.myCharacter == .lumei, "v0.11: mode / character roundtrip")
    let future = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"role":"lulu","pairCode":"x","databaseURL":"","mode":"triangle","character":"bob"}"#.utf8))
    check(future.mode == nil && future.character == nil && future.effectiveMode == .couple, "v0.11: unknown mode / character decode as nil")
    // solo: only a role is needed; code / URL are kept
    let solo = AppConfig(role: .lulu, pairCode: "", databaseURL: "", mode: .solo)
    check(solo.isComplete && !AppConfig(role: .lulu, pairCode: "", databaseURL: "", mode: .couple).isComplete && !AppConfig(role: .lulu, pairCode: "", databaseURL: "", mode: .friend).isComplete, "v0.11: solo isComplete without code / URL")
    check(AppConfig(role: .lulu, pairCode: code, databaseURL: "https://x.firebaseio.com", mode: .solo).pairCode == code, "v0.11: solo keeps pair code")
    // enums
    check(PetCharacter.lulu.displayName == "噜噜" && PetCharacter.lumei.displayName == "噜妹" && PetCharacter.lulu.other == .lumei && PetCharacter.lumei.other == .lulu, "v0.11: PetCharacter names / other")
    check(PetCharacter(.lulu) == .lulu && PetCharacter(.lumei) == .lumei && PetCharacter.allCases.map(\.rawValue) == Role.allCases.map(\.rawValue), "v0.11: PetCharacter(seat)")
    check(PairMode.allCases == [.solo, .couple, .friend] && !PairMode.solo.isPaired && PairMode.couple.isPaired && PairMode.friend.isPaired, "v0.11: PairMode.isPaired")
    // deviceId persists
    let d1 = ms.deviceId
    check(!d1.isEmpty && ms.deviceId == d1, "v0.11: deviceId stable within a store")
    check(ms.defaults.string(forKey: "deviceId") == d1, "v0.11: deviceId persisted under `deviceId`")
    check({ let o = ConfigStore(profile: "test-other-\(UUID().uuidString)"); defer { o.wipe() }; return o.deviceId != d1 }(), "v0.11: deviceId differs per profile")
    ms.wipe()
}

do {
    // presence: old (no new fields) and new payloads
    let oldP = PresenceInfo.decode(Data(#"{"lastSeen":1000,"dnd":{"mood":"busy","until":0}}"#.utf8))!
    check(oldP.character == nil && oldP.mode == nil && oldP.device == nil && oldP.lastSeen == 1000 && oldP.dnd?.mood == "busy", "v0.11: old presence decodes with nil identity")
    let newP = PresenceInfo.decode(Data(#"{"lastSeen":2000,"character":"lumei","mode":"friend","device":"D-1"}"#.utf8))!
    check(newP.character == .lumei && newP.mode == .friend && newP.device == "D-1", "v0.11: new presence fields decode")
    let oddP = PresenceInfo.decode(Data(#"{"lastSeen":3,"character":"bob","mode":7,"device":5}"#.utf8))!
    check(oddP.character == nil && oddP.mode == nil && oddP.device == nil, "v0.11: unknown presence identity values → nil")
    let plain = PresenceInfo.payload(lastSeen: 5, dnd: nil)
    check(Set(plain.keys) == ["lastSeen"], "v0.11: payload without identity is byte-compatible")
    let full = PresenceInfo.payload(lastSeen: 5, dnd: nil, character: .lulu, mode: .solo, device: "X")
    check(full["character"] as? String == "lulu" && full["mode"] as? String == "solo" && full["device"] as? String == "X" && full["lastSeen"] as? Int64 == 5, "v0.11: payload carries identity")
    let rt = PresenceInfo.decode(try JSONSerialization.data(withJSONObject: full))!
    check(rt.character == .lulu && rt.mode == .solo && rt.device == "X", "v0.11: presence identity roundtrip")
    check(PresenceInfo(lastSeen: 1) == PresenceInfo(lastSeen: 1, dnd: nil, focus: nil), "v0.11: PresenceInfo old init still works")

    // messages
    let withC = Message(from: .lulu, kind: .text, text: "hi", ts: 9, character: .lumei)
    check(withC.character == .lumei, "v0.11: message init takes character")
    let wire = try JSONSerialization.jsonObject(with: withC.firebasePayload()) as! [String: Any]
    check(wire["character"] as? String == "lumei", "v0.11: message wire carries character")
    check(try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(withC)) == withC, "v0.11: message with character roundtrips")
    let noC = Message.decode(firebaseKey: "-K", value: ["from": "lulu", "kind": "text", "text": "x", "ts": 1])!
    check(noC.character == nil && noC.extra.isEmpty, "v0.11: message without character")
    let wireNoC = try JSONSerialization.jsonObject(with: Message.text("a", from: .lulu, ts: 1).firebasePayload()) as! [String: Any]
    check(wireNoC["character"] == nil, "v0.11: no character key when nil")
    let weird = Message.decode(firebaseKey: "-K", value: ["from": "lulu", "kind": "text", "ts": 1, "character": "bob"])!
    check(weird.character == nil && weird.extra["character"] == .string("bob"), "v0.11: unknown character → nil, raw kept in extra")
    let weirdWire = try JSONSerialization.jsonObject(with: weird.firebasePayload()) as! [String: Any]
    check(weirdWire["character"] as? String == "bob", "v0.11: unknown character re-encoded unchanged")

    // PartnerIdentity inference order
    var pi = PartnerIdentity.resolve(partnerSeat: .lumei, presence: PresenceInfo(lastSeen: 1, character: .lulu, mode: .friend), lastMessageCharacter: .lumei)
    check(pi.character == .lulu && pi.mode == .friend, "v0.11: partner identity: presence wins")
    pi = PartnerIdentity.resolve(partnerSeat: .lumei, presence: PresenceInfo(lastSeen: 1), lastMessageCharacter: .lulu)
    check(pi.character == .lulu && pi.mode == .couple, "v0.11: partner identity: then last message, mode defaults to couple")
    pi = PartnerIdentity.resolve(partnerSeat: .lumei, presence: nil, lastMessageCharacter: nil)
    check(pi == PartnerIdentity(character: .lumei, mode: .couple), "v0.11: partner identity: then seat default")
    pi = PartnerIdentity.resolve(partnerSeat: .lulu, presence: nil, lastMessageCharacter: nil)
    check(pi.character == .lulu, "v0.11: partner identity: seat lulu")

    // SeatClashMonitor
    do {
        var m = SeatClashMonitor(interval: 180)
        check(m.isDue(now: 0), "v0.11 monitor: due at start")
        check(m.record(read: true, now: 0) == nil && !m.clash, "v0.11 monitor: one positive read → not yet")
        check(m.isDue(now: 15), "v0.11 monitor: …its confirmation is due at the next poll")
        check(m.record(read: true, now: 15) == true && m.clash && !m.isDue(now: 16) && m.isDue(now: 195), "v0.11 monitor: 2 consecutive positives → clash; then every ~3 min")
        m = SeatClashMonitor(interval: 180)
        check(m.record(read: false, now: 0) == nil && !m.isDue(now: 100) && !m.isDue(now: 179) && m.isDue(now: 180), "v0.11 monitor: next check ~3 min later")
        check(m.record(read: true, now: 180) == nil && m.record(read: false, now: 195) == nil && !m.isDue(now: 200), "v0.11 monitor: a negative resets the streak (no clash)")
        check(m.record(read: true, now: 360) == nil && m.record(read: true, now: 375) == true && m.clash, "v0.11 monitor: 2 consecutive positives → clash")
        check(m.record(read: true, now: 555) == nil, "v0.11 monitor: still clashing, no repeat report")
        check(m.record(read: false, now: 735) == nil && m.clash && m.isDue(now: 750), "v0.11 monitor: one negative keeps the clash (confirmation due)")
        check(m.record(read: true, now: 750) == nil && m.clash && !m.isDue(now: 751), "v0.11 monitor: a positive in between resets the negative streak")
        check(m.record(read: false, now: 930) == nil && m.record(read: false, now: 945) == false && !m.clash, "v0.11 monitor: 2 consecutive negatives → resolved")
        check(m.record(read: false, now: 1125) == nil, "v0.11 monitor: no repeat report")
    }
    // SeatClash
    let now: Int64 = 1_000_000
    check(SeatClash.detect(mySeatPresence: PresenceInfo(lastSeen: now - 1000, device: "OTHER"), myDevice: "ME", nowMs: now), "v0.11: clash: online + other device")
    check(!SeatClash.detect(mySeatPresence: PresenceInfo(lastSeen: now - 1000, device: "ME"), myDevice: "ME", nowMs: now), "v0.11: no clash: my own device")
    check(!SeatClash.detect(mySeatPresence: PresenceInfo(lastSeen: now - 1000), myDevice: "ME", nowMs: now), "v0.11: no clash: old client (no device)")
    check(!SeatClash.detect(mySeatPresence: PresenceInfo(lastSeen: now - Presence.thresholdMs - 1, device: "OTHER"), myDevice: "ME", nowMs: now), "v0.11: no clash: other device is stale")
    check(!SeatClash.detect(mySeatPresence: PresenceInfo(lastSeen: 0, device: "OTHER"), myDevice: "ME", nowMs: now), "v0.11: no clash: signed off")
    check(!SeatClash.detect(mySeatPresence: nil, myDevice: "ME", nowMs: now), "v0.11: no clash: no presence")
}

do {
    // intimate tags in the built manifests
    let sdir = tmp.appendingPathComponent("Stickers11")
    try FileManager.default.createDirectory(at: sdir, withIntermediateDirectories: true)
    try #"[{"id":"kiss","label":"亲亲","file":"kiss.gif","intimate":true},{"id":"hi","label":"你好呀","file":"hi.gif"}]"#.data(using: .utf8)!.write(to: sdir.appendingPathComponent("stickers.json"))
    let sc = StickerCatalog(root: sdir)
    check(sc.stickers.map(\.intimate) == [true, false], "v0.11: sticker intimate parses (absent = false)")
    check(StickerCatalog(root: tmp.appendingPathComponent("Stickers")).stickers.allSatisfy { !$0.intimate }, "v0.11: old sticker json → not intimate")

    let croot = tmp.appendingPathComponent("Couples11")
    for (name, intimate) in [("kiss", true), ("dance", false), ("lone", false)] {
        try makeClip("Couples11/\(name)", frames: 1)
        let extra = intimate ? #","intimate":true"# : ""
        try #"{"frames":1,"delays":[0.1],"width":100,"height":200,"facing":"lulu-left"\#(extra)}"#.data(using: .utf8)!
            .write(to: croot.appendingPathComponent("\(name)/meta.json"))
    }
    let cat = CoupleCatalog(root: croot)
    check(cat.clip(named: "kiss")?.intimate == true && cat.clip(named: "dance")?.intimate == false, "v0.11: couple intimate parses (absent = false)")

    // ContentPolicy truth table
    let kiss = cat.clip(named: "kiss")!, dance = cat.clip(named: "dance")!
    let couple = ContentPolicy.couple
    check(couple.mode == .couple && couple.me == .lulu && couple.partner == .lumei && couple.allowsIntimate && couple.allowsCoupleClips, "v0.11: policy couple basics")
    check(couple.allowsCouple(kiss) && couple.allowsCouple(dance) && couple.allowsSticker(intimate: true) && couple.allowsSticker(intimate: false), "v0.11: couple allows everything")
    check(couple.allowsCouple(named: "kiss", catalog: cat) && !couple.allowsCouple(named: "nope", catalog: cat), "v0.11: allowsCouple(named:) — unknown name not allowed")
    check(couple.filterCouplePool(["kiss", "dance", "nope", "none"], catalog: cat) == ["kiss", "dance", "none"], "v0.11: couple pool keeps known + none")

    let friendDiff = ContentPolicy(myMode: .friend, partnerMode: .friend, me: .lulu, partner: .lumei)
    check(friendDiff.mode == .friend && !friendDiff.allowsIntimate && friendDiff.allowsCoupleClips, "v0.11: friend / different characters basics")
    check(!friendDiff.allowsCouple(kiss) && friendDiff.allowsCouple(dance) && !friendDiff.allowsSticker(intimate: true) && friendDiff.allowsSticker(intimate: false), "v0.11: friend blocks intimate only")
    check(friendDiff.filterCouplePool(["kiss", "dance", "none"], catalog: cat) == ["dance", "none"], "v0.11: friend pool filtered")

    let friendSame = ContentPolicy(myMode: .friend, partnerMode: .friend, me: .lulu, partner: .lulu)
    check(!friendSame.allowsCoupleClips && !friendSame.allowsCouple(dance) && !friendSame.allowsCouple(kiss) && friendSame.filterCouplePool(["kiss", "dance", "none"], catalog: cat) == ["none"], "v0.11: friend same character: no couple clips")

    let coupleSame = ContentPolicy(myMode: .couple, partnerMode: .couple, me: .lulu, partner: .lulu)
    check(coupleSame.allowsIntimate && !coupleSame.allowsCoupleClips, "v0.11: same character never gets two-person clips")

    let mixed = ContentPolicy(myMode: .couple, partnerMode: .friend, me: .lulu, partner: .lumei)
    check(mixed.mode == .friend && !mixed.allowsIntimate, "v0.11: either side friend → friend (stricter)")
    check(ContentPolicy(myMode: .friend, partnerMode: nil, me: .lulu, partner: .lumei).mode == .friend && ContentPolicy(myMode: .couple, partnerMode: nil, me: .lulu, partner: .lumei).mode == .couple, "v0.11: unknown partner mode follows mine")

    let solo = ContentPolicy(myMode: .solo, partnerMode: nil, me: .lumei, partner: nil)
    check(solo.mode == .solo && solo.partner == nil && !solo.allowsIntimate && !solo.allowsCoupleClips && !solo.allowsCouple(dance) && solo.filterCouplePool(["dance", "none"], catalog: cat) == ["none"], "v0.11: solo: nothing two-person")
    check(!ContentPolicy(myMode: .couple, partnerMode: .couple, me: .lulu, partner: nil).allowsCoupleClips, "v0.11: paired but partner unknown: no couple clips")

    // sounds
    let snd = SoundManifest.parseFull(Data(#"{"arrive":["a.m4a",{"file":"v4/S02.m4a","visitor":"lulu","intimate":true}],"hug_missyou":[{"file":"v4/S06.m4a","intimate":true}],"hug":["h.m4a",{"file":"v4/S06.m4a","intimate":true}]}"#.utf8))
    let sm = SoundManifest(entries: snd.entries, only: snd.only, intimate: snd.intimate)
    check(sm.files(for: "arrive", visitor: .lulu) == ["a.m4a", "v4/S02.m4a"] && sm.files(for: "arrive", visitor: .lulu, allowIntimate: false) == ["a.m4a"], "v0.11: intimate sound file skipped when not allowed")
    check(sm.files(for: "hug_missyou", visitor: nil, allowIntimate: false).isEmpty && sm.files(for: "hug_missyou", visitor: nil) == ["v4/S06.m4a"], "v0.11: all-intimate event is empty when not allowed")
    check(sm.files(for: "hug", visitor: nil, allowIntimate: false) == ["h.m4a"], "v0.11: category loses only its intimate file")
    check(sm.files(for: "arrive", visitor: .lumei, allowIntimate: false) == ["a.m4a"] && sm.files(for: "arrive", visitor: .lumei) == ["a.m4a"], "v0.11: visitor filter still applies")
    check(SoundManifest.parse(Data(#"{"x":[{"file":"f.m4a","intimate":true}]}"#.utf8))["x"] == ["f.m4a"], "v0.11: parse() unchanged shape")
    let kept = sm.resolved(exists: { $0 != "h.m4a" }).manifest
    check(kept.files(for: "hug", visitor: nil, allowIntimate: false).isEmpty && kept.files(for: "hug", visitor: nil) == ["v4/S06.m4a"], "v0.11: resolved keeps intimate flags")
    check(SoundManifest(entries: ["a": ["f"]]).files(for: "a", visitor: nil, allowIntimate: false) == ["f"], "v0.11: old manifest: nothing intimate")

    // v0.11 friends: clip choice under a policy (Visits.meetingCouple), fixtures kiss (intimate) / dance / lone
    var mrng = SystemRandomNumberGenerator()
    let coupleP = ContentPolicy.couple
    let friendP = friendDiff
    func pick(_ pool: [String], _ p: ContentPolicy, preferred: Visits.CoupleMove = .hug, last: String? = nil) -> String? {
        Visits.meetingCouple(pool: pool, preferred: preferred, catalog: cat, policy: p, last: last, using: &mrng)
    }
    check((0..<30).allSatisfy { _ in pick(["kiss"], coupleP) == "kiss" }, "v0.11 visits: couple keeps intimate clips")
    check((0..<30).allSatisfy { _ in pick(["kiss", "dance", "lone"], coupleP) != nil }, "v0.11 visits: couple: any pool clip")
    check((0..<30).allSatisfy { _ in pick(["kiss", "dance"], friendP) == "dance" }, "v0.11 visits: friend drops the intimate clip from the pool")
    check(pick(["kiss"], friendP) == nil, "v0.11 visits: friend + only intimate in pool → bothHappy (nil)")
    check(pick([], friendP, preferred: .kiss) == nil && pick([], friendP, preferred: .hug) == nil, "v0.11 visits: friend + built-in hug/kiss rule → nil (kiss/hug missing from allowed)")
    check(pick(["none", "kiss"], friendP) == nil && pick(["none"], coupleP) == nil, "v0.11 visits: 'none' stays a no-clip choice")
    check(pick(["dance", "nope"], friendP) == "dance", "v0.11 visits: unknown clip name is never picked under a filter")
    check((0..<10).allSatisfy { _ in pick(["kiss", "dance"], friendSame) == nil && pick(["kiss"], coupleSame) == nil }, "v0.11 visits: same character → never a couple clip")
    check(pick(["dance"], solo) == nil, "v0.11 visits: solo → no couple clip")
    check(pick(["dance"], mixed) == "dance" && pick(["kiss"], mixed) == nil, "v0.11 visits: one-sided friend filters intimate")
    check((0..<20).allSatisfy { _ in
        pick(["dance", "lone"], friendP, last: "dance") == "lone"
    }, "v0.11 visits: filtered pool still avoids repeating the last clip")
    // Couple default is the old chooser, bit for bit (same seed, same pick)
    check((0..<40).allSatisfy { seed in
        var ra = SeededRandom(seed: UInt64(seed)), rb = SeededRandom(seed: UInt64(seed))
        return Visits.meetingCouple(pool: ["kiss", "dance", "lone", "zzz"], preferred: .nuzzle, catalog: cat, policy: coupleP, last: "dance", using: &ra)
            == Visits.coupleName(pool: ["kiss", "dance", "lone", "zzz"], preferred: .nuzzle, available: cat.names, last: "dance", using: &rb)
    }, "v0.11 visits: couple default = the old chooser, same seed same pick")
    check(Visits.meetingCouple(pool: [], preferred: .kiss, catalog: cat, policy: coupleP, last: nil, using: &mrng) == "kiss", "v0.11 visits: couple built-in rule unchanged")
    // Mirroring: 噜噜 on the left in the source frames; each pet lands on its own side; same character → nil
    if let k = cat.clip(named: "kiss") {
        check(Visits.coupleMirrored(clip: k, host: .lulu, visitor: .lumei, hostIsLeft: true) == false, "v0.11 visits: lulu host on the left → as drawn")
        check(Visits.coupleMirrored(clip: k, host: .lulu, visitor: .lumei, hostIsLeft: false) == true, "v0.11 visits: lulu host on the right → mirrored")
        check(Visits.coupleMirrored(clip: k, host: .lumei, visitor: .lulu, hostIsLeft: true) == true, "v0.11 visits: lumei host on the left → mirrored")
        check(Visits.coupleMirrored(clip: k, host: .lumei, visitor: .lulu, hostIsLeft: false) == false, "v0.11 visits: lumei host on the right → as drawn")
        check(Visits.coupleMirrored(clip: k, host: .lulu, visitor: .lulu, hostIsLeft: true) == nil, "v0.11 visits: same character → no mirroring")
    } else { check(false, "v0.11 visits: kiss fixture") }

    // The shipped Resources carry the tags
    let res = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
    if FileManager.default.fileExists(atPath: res.appendingPathComponent("Couples").path) {
        let real = CoupleCatalog(root: res.appendingPathComponent("Couples"))
        let intimateSet: Set<String> = ["hug", "kiss", "kiss_2", "nuzzle", "hug_slow", "hug_soft", "kiss_sit", "hug_sit", "hug_stand", "hug_kneel", "cuddle_bed", "comfort", "hug_bed", "sniff", "lean"]
        let tagged = Set(real.names.filter { real.clip(named: $0)?.intimate == true })
        check(tagged == intimateSet.intersection(real.names) && tagged.count == intimateSet.count, "v0.11: shipped couples: intimate tags match the spec (\(tagged.sorted()))")
        check(["dance", "happy", "bench", "walk", "wink", "flowers", "angry"].allSatisfy { real.clip(named: $0)?.intimate == false }, "v0.11: shipped couples: non-intimate stay untagged")
        let realSounds = SoundManifest(url: res.appendingPathComponent("Sounds/sounds.json"))
        check(realSounds.files(for: "hug_missyou", visitor: nil, allowIntimate: false).isEmpty && realSounds.files(for: "comfort_missyou", visitor: nil, allowIntimate: false).isEmpty, "v0.11: shipped sounds: missyou events are intimate")
        check(!realSounds.files(for: "arrive", visitor: .lulu, allowIntimate: false).contains("v4/S02.m4a") && realSounds.files(for: "arrive", visitor: .lulu).contains("v4/S02.m4a"), "v0.11: shipped sounds: S02 intimate")
        check(!realSounds.files(for: "hug", visitor: nil, allowIntimate: false).contains("v4/S06.m4a") && realSounds.files(for: "hug", visitor: nil).contains("v4/S06.m4a"), "v0.11: shipped sounds: S06 intimate")
        // friend lulu+lumei with the shipped clips: no kiss / hug ever, built-in rule falls to bothHappy
        let reactions = ReactionTable(url: res.appendingPathComponent("reactions.json"))
        var rr = SystemRandomNumberGenerator()
        let intimateNames = intimateSet.intersection(real.names)
        var leaked = false, played = 0
        for key in ["hug", "kiss", "nuzzle", "happy"] {
            let pool = reactions.reaction(kind: .sticker, stickerId: key)?.couples ?? []
            for _ in 0..<20 {
                if let n = Visits.meetingCouple(pool: pool, preferred: .hug, catalog: real, policy: friendP, last: nil, using: &rr) {
                    played += 1
                    if intimateNames.contains(n) { leaked = true }
                }
            }
        }
        check(!leaked, "v0.11 visits: shipped pools under friend policy never yield an intimate clip (\(played) non-intimate picks)")
        let realStickers = StickerCatalog(root: res.appendingPathComponent("Stickers"))
        check(realStickers.stickers.filter(\.intimate).map(\.id).sorted() == ["hug", "holdhands", "kiss", "nuzzle", "sleeptogether", "wink"].sorted(), "v0.11: shipped stickers: intimate set")
    }
} catch { check(false, "v0.11 manifests \(error)") }

// MARK: v0.11.2 app version + upgrade nudge
do {
    check(AppVersion("0.11.2") == AppVersion(0, 11, 2), "v0.11.2: AppVersion parses 0.11.2")
    check(AppVersion("v1.2") == AppVersion(1, 2, 0), "v0.11.2: AppVersion tolerates v prefix / short form")
    for bad in ["", "abc", "1.2.3.4", "1..2", "-1.0.0", "1.x", " ", "0.11.2-beta"] { check(AppVersion(bad) == nil, "v0.11.2: AppVersion garbage '\(bad)' = nil") }
    check(AppVersion(nil) == nil, "v0.11.2: AppVersion nil")
    check(AppVersion("0.9.0")! < AppVersion("0.11.0")! && AppVersion("0.11.2")! < AppVersion("0.12.0")! && AppVersion("0.11.1")! < AppVersion("0.11.2")!, "v0.11.2: AppVersion ordering (numeric, not lexical)")
    check(AppVersion("0.11.2")!.description == "0.11.2", "v0.11.2: AppVersion description")
    check(UpgradeNudge.evaluate(mine: "0.11.1", partner: "0.12.0", lastNudged: nil) == .partnerNewer(version: "0.12.0", shouldBubble: true), "v0.11.2: nudge: partner newer, first time")
    check(UpgradeNudge.evaluate(mine: "0.11.1", partner: "0.12.0", lastNudged: "0.12.0") == .partnerNewer(version: "0.12.0", shouldBubble: false), "v0.11.2: nudge: already bubbled")
    check(UpgradeNudge.evaluate(mine: "0.11.1", partner: "0.12.1", lastNudged: "0.12.0") == .partnerNewer(version: "0.12.1", shouldBubble: true), "v0.11.2: nudge: newer still bubbles again")
    check(UpgradeNudge.evaluate(mine: "0.11.1", partner: "0.12.0", lastNudged: "garbage") == .partnerNewer(version: "0.12.0", shouldBubble: true), "v0.11.2: nudge: garbage last = none")
    check(UpgradeNudge.evaluate(mine: "0.12.0", partner: "0.11.1", lastNudged: nil) == .partnerOlder(version: "0.11.1"), "v0.11.2: nudge: partner older")
    check(UpgradeNudge.evaluate(mine: "0.12.0", partner: "0.12.0", lastNudged: nil) == .none, "v0.11.2: nudge: same")
    check(UpgradeNudge.evaluate(mine: "0.12.0", partner: nil, lastNudged: nil) == .none, "v0.11.2: nudge: partner unknown")
    check(UpgradeNudge.evaluate(mine: nil, partner: "0.12.0", lastNudged: nil) == .none, "v0.11.2: nudge: mine unknown")
    check(UpgradeNudge.evaluate(mine: "0.12.0", partner: "junk", lastNudged: nil) == .none, "v0.11.2: nudge: partner garbage")
    // presence field "app"
    let withApp = PresenceInfo.payload(lastSeen: 5, dnd: nil, app: "0.11.2")
    check(withApp["app"] as? String == "0.11.2", "v0.11.2: payload carries app")
    check(Set(PresenceInfo.payload(lastSeen: 5, dnd: nil).keys) == ["lastSeen"], "v0.11.2: payload without app = old shape")
    check(PresenceInfo.decode(try JSONSerialization.data(withJSONObject: withApp))?.app == "0.11.2", "v0.11.2: app roundtrips")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7}"#.utf8))?.app == nil, "v0.11.2: old presence has no app")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"app":5}"#.utf8))?.app == nil, "v0.11.2: non-string app ignored")
    let ncs = ConfigStore(profile: "test-nudge-\(UUID().uuidString)")
    check(ncs.upgradeNudgedFor == nil, "v0.11.2: upgradeNudgedFor default nil")
    ncs.upgradeNudgedFor = "0.12.0"
    check(ncs.upgradeNudgedFor == "0.12.0", "v0.11.2: upgradeNudgedFor persists")
}

// v0.11.3 shared 小工具 wording
do {
    check(ToolsCopy.menuTitle(.water, interval: 3600) == "喝水提醒 💧（每用电脑 60 分钟）", "tools copy: water menu title shows the live interval")
    check(ToolsCopy.menuTitle(.stand, interval: 2700) == "站立提醒 🧍（每用电脑 45 分钟）", "tools copy: stand menu title")
    let ex = ToolsCopy.explanation(.water, interval: 1800)
    check(ex.contains("累计满 30 分钟") && ex.contains("5 分钟以上") && ex.contains("勿扰"), "tools copy: explanation carries interval and rules")
    check(ToolsCopy.pomodoroDurations(PomodoroConfig()) == "25 分钟专注 / 5 分钟休息", "tools copy: pomodoro durations")
    var ps = PomodoroState.idle
    check(ToolsCopy.pomodoroState(ps, now: 0) == "没在专注", "tools copy: idle line")
    ps.start(now: 1000, config: PomodoroConfig())
    check(ToolsCopy.pomodoroState(ps, now: 1000) == "专注中 还剩 25 分钟", "tools copy: focus line")
    ps.pause(now: 1000)
    check(ToolsCopy.pomodoroState(ps, now: 1000).hasPrefix("已暂停"), "tools copy: paused line")
}

// MARK: v0.12 weather (docs/superpowers/specs/2026-10-06-weather-design.md)
do {
    // WMO mapping
    check(WeatherCondition(wmo: 0) == .clear && WeatherCondition(wmo: 1) == .clear, "weather: wmo 0/1 clear")
    check(WeatherCondition(wmo: 2) == .partlyCloudy && WeatherCondition(wmo: 3) == .cloudy, "weather: wmo 2 partly, 3 cloudy")
    check(WeatherCondition(wmo: 45) == .fog && WeatherCondition(wmo: 48) == .fog, "weather: wmo fog")
    check([51, 53, 55, 56, 57].allSatisfy { WeatherCondition(wmo: $0) == .drizzle }, "weather: wmo drizzle")
    check([61, 63, 65, 66, 67, 80, 81, 82].allSatisfy { WeatherCondition(wmo: $0) == .rain }, "weather: wmo rain + showers")
    check([71, 73, 75, 77, 85, 86].allSatisfy { WeatherCondition(wmo: $0) == .snow }, "weather: wmo snow")
    check([95, 96, 99].allSatisfy { WeatherCondition(wmo: $0) == .thunder }, "weather: wmo thunder")
    check(WeatherCondition(wmo: 1234) == .cloudy && WeatherCondition(wmo: -1) == .cloudy, "weather: unknown wmo = cloudy")
    check(WeatherCondition.clear.emoji(isDay: true) == "☀️" && WeatherCondition.clear.emoji(isDay: false) == "🌙", "weather: clear emoji day / night")
    check(WeatherCondition.rain.emoji(isDay: true) == "🌧" && WeatherCondition.thunder.emoji(isDay: false) == "⛈", "weather: rain / thunder emoji")
    check(WeatherCondition.allCases.map(\.label) == ["晴", "多云", "阴", "雾", "毛毛雨", "雨", "雪", "雷雨"], "weather: Chinese labels")

    // place: two decimals, subtitle, codable
    let la = WeatherPlace(name: "洛杉矶", admin: "加利福尼亚", country: "美国", latitude: 34.052235, longitude: -118.243683, timezone: "America/Los_Angeles")
    check(la.latitude == 34.05 && la.longitude == -118.24, "weather: place rounds to two decimals")
    check(la.subtitle == "加利福尼亚 · 美国", "weather: place subtitle")
    check(WeatherPlace(name: "上海", admin: "上海", country: "中国", latitude: 31.2, longitude: 121.4, timezone: "Asia/Shanghai").subtitle == "中国", "weather: subtitle drops admin equal to name")
    check(WeatherPlace(name: "X", admin: nil, country: nil, latitude: 0, longitude: 0, timezone: "UTC").subtitle == "", "weather: empty subtitle")
    let laData = try JSONEncoder().encode(la)
    check(try JSONDecoder().decode(WeatherPlace.self, from: laData) == la, "weather: place codable roundtrip")
    let raw = try JSONDecoder().decode(WeatherPlace.self, from: Data(#"{"name":"A","latitude":1.23456,"longitude":-9.87654,"timezone":"UTC"}"#.utf8))
    check(raw.latitude == 1.23 && raw.longitude == -9.88 && raw.admin == nil && raw.country == nil, "weather: decoding also rounds; admin / country optional")

    // forecast JSON
    let forecast = #"{"latitude":34.05,"longitude":-118.24,"timezone":"America/Los_Angeles","current":{"time":"2026-10-06T15:00","interval":900,"temperature_2m":23.6,"weather_code":2,"wind_speed_10m":11.5,"is_day":1},"daily":{"time":["2026-10-06"],"temperature_2m_max":[27.1],"temperature_2m_min":[15.9]}}"#
    let snap = try WeatherParse.snapshot(Data(forecast.utf8), now: 1000)
    check(snap == WeatherSnapshot(condition: .partlyCloudy, temperature: 23.6, high: 27.1, low: 15.9, windSpeed: 11.5, isDay: true, fetchedAt: 1000), "weather: parse forecast")
    let night = try WeatherParse.snapshot(Data(#"{"current":{"temperature_2m":-3,"weather_code":73,"is_day":0}}"#.utf8), now: 5)
    check(night.condition == .snow && night.temperature == -3 && night.high == nil && night.low == nil && night.windSpeed == nil && !night.isDay, "weather: parse minimal forecast (no daily, no wind)")
    check((try? WeatherParse.snapshot(Data(#"{"current":{"weather_code":1}}"#.utf8), now: 0)) == nil, "weather: forecast without temperature throws")
    check((try? WeatherParse.snapshot(Data("nope".utf8), now: 0)) == nil, "weather: bad forecast json throws")
    check((try? WeatherParse.snapshot(Data(#"{"error":true,"reason":"x"}"#.utf8), now: 0)) == nil, "weather: error body throws")

    // city search JSON
    let search = #"{"results":[{"id":5368361,"name":"洛杉矶","latitude":34.05223,"longitude":-118.24368,"country":"美国","admin1":"加利福尼亚","timezone":"America/Los_Angeles"},{"name":"洛杉矶","latitude":34.0522,"longitude":-118.2437,"country":"美国","admin1":"加利福尼亚","timezone":"America/Los_Angeles"},{"name":"No tz","latitude":1,"longitude":2},{"name":"洛杉矶","latitude":14.5,"longitude":-90.1,"country_code":"GT","timezone":"America/Guatemala"}],"generationtime_ms":0.5}"#
    let found = WeatherParse.places(Data(search.utf8))
    check(found.count == 2 && found[0] == la && found[1].timezone == "America/Guatemala" && found[1].country == nil, "weather: parse search (rounded, duplicates and no-timezone dropped)")
    check(WeatherParse.places(Data(#"{"generationtime_ms":0.2}"#.utf8)).isEmpty && WeatherParse.places(Data("x".utf8)).isEmpty, "weather: search without results / bad json = empty")

    // look thresholds + priority
    func s(_ c: WeatherCondition, _ t: Double, wind: Double? = nil) -> WeatherSnapshot {
        WeatherSnapshot(condition: c, temperature: t, high: nil, low: nil, windSpeed: wind, isDay: true, fetchedAt: 0)
    }
    check(WeatherLook.of(s(.clear, 20)) == nil, "look: mild clear = none")
    check(WeatherLook.of(s(.rain, 20)) == .rain && WeatherLook.of(s(.drizzle, 20)) == .rain && WeatherLook.of(s(.thunder, 20)) == .rain, "look: rain / drizzle / thunder = rain")
    check(WeatherLook.of(s(.snow, 0)) == .snow, "look: snow")
    check(WeatherLook.of(s(.clear, 30)) == .hot && WeatherLook.of(s(.clear, 29.9)) == nil, "look: hot at 30")
    check(WeatherLook.of(s(.cloudy, 5)) == .cold && WeatherLook.of(s(.clear, 5.1)) == nil, "look: cold at 5")
    check(WeatherLook.of(s(.clear, 20, wind: 30)) == .windy && WeatherLook.of(s(.clear, 20, wind: 29.9)) == nil, "look: windy at 30 km/h")
    check(WeatherLook.of(s(.rain, 35, wind: 50)) == .rain && WeatherLook.of(s(.snow, 35)) == .snow, "look: rain / snow beat hot")
    check(WeatherLook.of(s(.clear, 31, wind: 50)) == .hot && WeatherLook.of(s(.clear, 0, wind: 50)) == .cold, "look: hot / cold beat windy")
    check(WeatherLook.allCases.map(\.rawValue) == ["rain", "snow", "hot", "cold", "windy", "cloudy"], "look: raw values")
    check(WeatherLook.of(s(.cloudy, 20)) == .cloudy && WeatherLook.of(s(.fog, 12)) == .cloudy, "look: cloudy / fog = cloudy")
    check(WeatherLook.of(s(.partlyCloudy, 20)) == nil && WeatherLook.of(s(.clear, 20)) == nil && WeatherLook.of(s(.drizzle, 20)) == .rain, "look: partly cloudy / clear = none")
    check(WeatherLook.of(s(.cloudy, 31)) == .hot && WeatherLook.of(s(.fog, 2)) == .cold && WeatherLook.of(s(.cloudy, 20, wind: 40)) == .windy, "look: cloudy is the lowest priority")
    check(WeatherLook.snow.clipLooks == [.snow, .cold] && WeatherLook.rain.clipLooks == [.rain] && WeatherLook.cloudy.clipLooks == [.cloudy], "look: snow falls back to cold clips")

    // refresh rules
    check(WeatherRefresh.interval == 1800 && WeatherRefresh.staleAfter == 10800, "refresh: constants")
    check(WeatherRefresh.isDue(last: nil, now: 100), "refresh: never fetched = due")
    check(!WeatherRefresh.isDue(last: 1000, now: 1000 + 1799) && WeatherRefresh.isDue(last: 1000, now: 1000 + 1800), "refresh: due after 30 minutes")
    check(WeatherRefresh.isDue(last: 1000, now: 1000 + 20_000), "refresh: after sleep, overdue = due")
    check(WeatherRefresh.isDue(last: 5000, now: 1000), "refresh: clock moved back = due")
    check(WeatherRefresh.nextDeadline(last: nil, now: 100) == 100, "refresh: deadline now when never fetched")
    check(WeatherRefresh.nextDeadline(last: 1000, now: 1100) == 2800, "refresh: deadline = last + 30 min")
    check(WeatherRefresh.nextDeadline(last: 1000, now: 9000) == 9000, "refresh: overdue deadline = now")
    check(WeatherRefresh.nextDeadline(last: 5000, now: 1000) == 1000, "refresh: clock moved back, deadline = now")
    check(WeatherRefresh.ageLabel(fetchedAt: 0, now: 44 * 60) == nil, "age: under 45 min = nil")
    check(WeatherRefresh.ageLabel(fetchedAt: 0, now: 45 * 60) == "45 分钟前" && WeatherRefresh.ageLabel(fetchedAt: 0, now: 59 * 60) == "59 分钟前", "age: minutes")
    check(WeatherRefresh.ageLabel(fetchedAt: 0, now: 3600) == "1 小时前" && WeatherRefresh.ageLabel(fetchedAt: 0, now: 2.5 * 3600) == "2 小时前", "age: hours")
    check(WeatherRefresh.ageLabel(fetchedAt: 100, now: 50) == nil, "age: future fetch time = nil")
    check(!WeatherRefresh.isStale(fetchedAt: 0, now: 10800) && WeatherRefresh.isStale(fetchedAt: 0, now: 10801), "stale: over 3 hours")
    // failed refresh keeps old data: the store only changes on success
    let failDefaults = UserDefaults(suiteName: "lulupet.test-weather-\(UUID().uuidString)")!
    let failStore = WeatherStore(defaults: failDefaults)
    failStore.setCached(snap, for: la)
    check(failStore.cached(for: la) == snap && WeatherRefresh.ageLabel(fetchedAt: snap.fetchedAt, now: snap.fetchedAt + 3000) == "50 分钟前", "refresh: failure leaves the cached snapshot, shown with its age")

    // local time across time zones: 2026-10-06 22:20 UTC (PDT = UTC-7, CST = UTC+8)
    let utc = Date(timeIntervalSince1970: 1_791_325_200)   // 2026-10-06 22:20:00 UTC
    check(WeatherText.localTime(timezone: "America/Los_Angeles", now: utc) == "下午 3:20", "local time: Los Angeles 下午 3:20")
    check(WeatherText.localTime(timezone: "Asia/Shanghai", now: utc) == "上午 6:20", "local time: Shanghai 上午 6:20 (next day)")
    check(WeatherText.localTime(timezone: "UTC", now: utc) == "晚上 10:20", "local time: UTC 晚上 10:20")
    check(LocalTime.format(timezone: "Asia/Tokyo", now: utc) == "上午 7:20", "local time: Tokyo via LocalTime.format")
    check(WeatherText.localTime(timezone: "UTC", now: Date(timeIntervalSince1970: 1_791_244_800)) == "凌晨 12:00", "local time: midnight = 凌晨 12:00")
    check(WeatherText.localTime(timezone: "UTC", now: Date(timeIntervalSince1970: 1_791_244_800 + 12 * 3600 + 5 * 60)) == "下午 12:05", "local time: 12:05 = 下午 12:05")
    check(WeatherText.localTime(timezone: "Not/AZone", now: utc).isEmpty == false, "local time: bad timezone doesn't crash")

    // panel line
    let la1 = WeatherSnapshot(condition: .clear, temperature: 24.2, high: 27, low: 16, windSpeed: 5, isDay: true, fetchedAt: utc.timeIntervalSince1970 - 60)
    check(WeatherText.line(name: "噜妹", place: la, snapshot: la1, now: utc) == "噜妹那边：洛杉矶 ☀️ 24° · 下午 3:20", "line: fresh data")
    let old = WeatherSnapshot(condition: .rain, temperature: 18.6, high: nil, low: nil, windSpeed: nil, isDay: true, fetchedAt: utc.timeIntervalSince1970 - 50 * 60)
    check(WeatherText.line(name: "噜噜", place: la, snapshot: old, now: utc) == "噜噜那边：洛杉矶 🌧 19° · 下午 3:20 · 50 分钟前", "line: older data carries its age")
    let stale = WeatherSnapshot(condition: .rain, temperature: 18.6, high: nil, low: nil, windSpeed: nil, isDay: true, fetchedAt: utc.timeIntervalSince1970 - 4 * 3600)
    check(WeatherText.line(name: "噜噜", place: la, snapshot: stale, now: utc) == "噜噜那边：洛杉矶 暂时拿不到天气 · 下午 3:20", "line: over 3 hours = 暂时拿不到天气")
    check(WeatherText.line(name: "噜噜", place: la, snapshot: nil, now: utc) == "噜噜那边：洛杉矶 暂时拿不到天气 · 下午 3:20", "line: no data = 暂时拿不到天气")
    check(WeatherText.line(name: "噜噜", place: la, snapshot: WeatherSnapshot(condition: .snow, temperature: -2.4, high: nil, low: nil, windSpeed: nil, isDay: false, fetchedAt: utc.timeIntervalSince1970), now: utc).contains("-2°"), "line: negative temperature")

    // store
    let wd = UserDefaults(suiteName: "lulupet.test-weather-\(UUID().uuidString)")!
    let ws = WeatherStore(defaults: wd)
    check(ws.myPlace == nil && !ws.widgetEnabled && ws.widgetOrigin == nil && ws.cached(for: la) == nil, "store: defaults")
    ws.myPlace = la
    ws.widgetEnabled = true
    ws.widgetOrigin = CGPoint(x: 120.5, y: 300)
    ws.setCached(snap, for: la)
    let ws2 = WeatherStore(defaults: wd)
    check(ws2.myPlace == la && ws2.widgetEnabled && ws2.widgetOrigin == CGPoint(x: 120.5, y: 300) && ws2.cached(for: la) == snap, "store: persists across instances")
    ws2.widgetEnabled = false
    check(!WeatherStore(defaults: wd).widgetEnabled && WeatherStore(defaults: wd).widgetOrigin == CGPoint(x: 120.5, y: 300), "store: disabling keeps the position")
    let sh = WeatherPlace(name: "上海", admin: nil, country: "中国", latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai")
    check(ws2.cached(for: sh) == nil, "store: cache is per place")
    ws2.setCached(old, for: sh)
    check(ws2.cached(for: sh) == old && ws2.cached(for: la) == snap, "store: two places cached side by side")
    ws2.myPlace = nil
    check(WeatherStore(defaults: wd).myPlace == nil, "store: clearing the city")
    wd.set(Data("garbage".utf8), forKey: "weatherCache")
    wd.set(Data("garbage".utf8), forKey: "myPlace")
    wd.set(Data("garbage".utf8), forKey: "weatherWidget")
    let bad = WeatherStore(defaults: wd)
    check(bad.cached(for: la) == nil && bad.myPlace == nil && !bad.widgetEnabled && bad.widgetOrigin == nil, "store: bad data = defaults")
    bad.setCached(snap, for: la)
    check(bad.cached(for: la) == snap, "store: recovers after bad cache data")

    // presence.place
    let pay = PresenceInfo.payload(lastSeen: 5, dnd: nil, place: la)
    let placeJSON = pay["place"] as? [String: Any]
    check(placeJSON?["name"] as? String == "洛杉矶" && placeJSON?["latitude"] as? Double == 34.05 && placeJSON?["timezone"] as? String == "America/Los_Angeles", "presence: payload carries place")
    check(Set(PresenceInfo.payload(lastSeen: 5, dnd: nil).keys) == ["lastSeen"], "presence: no place = old payload shape")
    let rt = PresenceInfo.decode(try JSONSerialization.data(withJSONObject: pay))
    check(rt?.place == la && rt?.lastSeen == 5, "presence: place roundtrip")
    check(PresenceInfo.decode(Data(#"{"lastSeen":1234}"#.utf8)) == PresenceInfo(lastSeen: 1234), "presence: old presence still decodes, place nil")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"place":"x"}"#.utf8)) == PresenceInfo(lastSeen: 7), "presence: malformed place ignored")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"place":{"name":"A"}}"#.utf8))?.place == nil, "presence: incomplete place ignored")
    check(PresenceInfo.decode(Data(#"{"lastSeen":7,"place":{"name":"A","latitude":1.23456,"longitude":2,"timezone":"UTC"}}"#.utf8))?.place?.latitude == 1.23, "presence: published place is rounded on read")
    check(PresenceInfo(lastSeen: 1, place: la) != PresenceInfo(lastSeen: 1), "presence: place takes part in equality")

    // housekeeping
    check(HousekeepingTask.weather.isWallClock, "housekeeping: weather is wall clock")
    var hk = HousekeepingDeadlines()
    check(hk[.weather] == nil, "housekeeping: weather not armed by default")
    hk.weather = 2000
    check(hk[.weather] == 2000 && hk.delay(.weather, uptime: 5, wall: 1500) == 500, "housekeeping: weather deadline on wall clock")
    check(Housekeeping.due(hk, uptime: 5, wall: 2000) == [.weather] && Housekeeping.due(hk, uptime: 5, wall: 1999).isEmpty, "housekeeping: weather due at its deadline")
    check(Housekeeping.plan(hk, uptime: 5, wall: 1500)?.tasks == [.weather], "housekeeping: plan includes weather")

    // fake data + shared state
    check(FakeWeather.places.count >= 2 && FakeWeather.places[0].name == "洛杉矶" && FakeWeather.places[1].name == "上海", "fake weather: places")
    let f1 = FakeWeather.snapshot(for: FakeWeather.places[0], now: 50), f2 = FakeWeather.snapshot(for: FakeWeather.places[1], now: 50)
    check(f1.condition == .clear && f1.temperature == 24 && f1.isDay && f1.fetchedAt == 50, "fake weather: 洛杉矶 ☀️ 24°")
    check(f2.condition == .rain && f2.temperature == 19 && f2.fetchedAt == 50, "fake weather: 上海 🌧 19°")
    check(FakeWeather.snapshot(for: FakeWeather.places[0], now: 50) == f1, "fake weather: deterministic")
    check(FakeWeather.snapshot(for: WeatherPlace(name: "东京", admin: nil, country: nil, latitude: 35.68, longitude: 139.69, timezone: "Asia/Tokyo"), now: 1).fetchedAt == 1, "fake weather: any place works")
    var wstate = WeatherState()
    check(wstate.mine == nil && wstate.partner == nil && wstate.partnerPlace == nil, "weather state: empty")
    wstate.mine = f1
    check(wstate != WeatherState(), "weather state: equatable")
}

// weather manifest in sprites (SpriteCatalog.weatherClips)
do {
    let wroot = tmp.appendingPathComponent("weather-sprites-\(UUID().uuidString)")
    let chars = wroot.appendingPathComponent("lulu")
    try FileManager.default.createDirectory(at: chars, withIntermediateDirectories: true)
    let wcat = SpriteCatalog(root: wroot)
    check(wcat.weatherClips(for: .lulu, look: .rain).isEmpty, "weather manifest: no file = none")
    try Data(#"{"rain":[{"name":"lulu_umbrella","dir":"rain_0"},{"name":"lulu_puddle","dir":"rain_1"},{"name":"bad","dir":"../x"}],"hot":[],"snow":"x","windy":[{"dir":"windy_0"}],"future":[{"dir":"a"}]}"#.utf8)
        .write(to: chars.appendingPathComponent("weather.json"))
    check(wcat.weatherClips(for: .lulu, look: .rain) == ["lulu_umbrella", "lulu_puddle"], "weather manifest: names in order, unsafe dirs skipped")
    check(wcat.weatherClips(for: .lulu, look: .hot).isEmpty && wcat.weatherClips(for: .lulu, look: .snow).isEmpty && wcat.weatherClips(for: .lulu, look: .cold).isEmpty, "weather manifest: empty / bad / missing looks = none")
    check(wcat.weatherClips(for: .lulu, look: .windy) == ["windy_0"], "weather manifest: bare dir doubles as name")
    check(wcat.weatherClips(for: .lumei, look: .rain).isEmpty, "weather manifest: per character")
    try Data(#"{"cold":[{"name":"c0","dir":"cold_0"},{"name":"c1","dir":"cold_1"}],"rain":[{"name":"r","dir":"rain_0"}]}"#.utf8)
        .write(to: chars.appendingPathComponent("weather.json"))
    check(wcat.weatherClips(for: .lulu, look: .snow) == ["c0", "c1"] && wcat.weatherClips(for: .lulu, look: .cold) == ["c0", "c1"], "weather manifest: snow falls back to cold clips")
    check(wcat.weatherClips(for: .lulu, look: .rain) == ["r"] && wcat.weatherClips(for: .lulu, look: .cloudy).isEmpty, "weather manifest: rain does not fall back, cloudy has none")
    try Data(#"{"snow":[{"name":"s","dir":"snow_0"}],"cold":[{"name":"c0","dir":"cold_0"}]}"#.utf8).write(to: chars.appendingPathComponent("weather.json"))
    check(wcat.weatherClips(for: .lulu, look: .snow) == ["s"] && wcat.weatherClips(for: .lulu, look: .cold) == ["c0"], "weather manifest: own snow clips win over the fallback")
    try Data("garbage".utf8).write(to: chars.appendingPathComponent("weather.json"))
    check(wcat.weatherClips(for: .lulu, look: .rain).isEmpty, "weather manifest: bad json = none")
    check(wcat.weatherNamedClips(for: .lulu, look: .rain).isEmpty, "weather manifest: named clips need frames too")
    check(WeatherManifest.parse(Data(#"{"rain":[{"name":"a","dir":"rain_0","sound":"s"}]}"#.utf8))[.rain] == [ClipIndex.Entry(name: "a", dir: "rain_0", sound: "s")], "weather manifest: parse keeps sound")
}

// v0.12 tool clip pools
do {
    var rng = SeededRandom(seed: 3)
    for kind in ToolClips.Kind.allCases { for who in Role.allCases { _ = ToolClips.pool(kind, for: who) } }
    check(ToolClips.pool(.water, for: .lulu).count == 5 && ToolClips.pool(.water, for: .lumei).count == 3, "tool clips: water pools")
    check(ToolClips.pool(.stand, for: .lulu).count == 5 && ToolClips.pool(.focus, for: .lumei).isEmpty, "tool clips: stand pool, no lumei focus clip")
    check((0..<30).allSatisfy { _ in ToolClips.pick(.water, for: .lulu, last: "sohu_107", has: { _ in true }, using: &rng) != "sohu_107" }, "tool clips: no immediate repeat")
    check(ToolClips.pick(.stand, for: .lumei, last: "lumei_stretch_01", has: { _ in true }, using: &rng) == "lumei_stretch_01", "tool clips: single clip may repeat")
    check(ToolClips.pick(.water, for: .lulu, last: nil, has: { $0 == "tool_W07" }, using: &rng) == "tool_W07"
          && ToolClips.pick(.water, for: .lulu, last: nil, has: { _ in false }, using: &rng) == nil, "tool clips: only what the outfit has")
    // the built Resources/reactions.json (names compiled from assets/) has exactly the extra clips the pools name
    let shipped = ReactionTable(url: URL(fileURLWithPath: "Resources/reactions.json"))
    if !shipped.entries.isEmpty {
        for who in Role.allCases {
            check(Set(shipped.entries["remind_water"]?.visitor[who.rawValue] ?? []) == Set(ToolClips.pool(.water, for: who)), "tool clips: remind_water visitors = water pool (\(who))")
            check(Set(shipped.entries["remind_stand"]?.visitor[who.rawValue] ?? []) == Set(ToolClips.pool(.stand, for: who)), "tool clips: remind_stand visitors = stand pool (\(who))")
        }
        check(shipped.entries["focus"]?.visitor["lulu"] == ToolClips.pool(.focus, for: .lulu), "tool clips: focus clip is built")
    }
}

// WeatherClient (LuluSync) with a stubbed session
do {
    let client = WeatherClient(session: stubSession)
    StubProtocol.requests = []
    StubProtocol.replies = [
        "GET /v1/search": .init(status: 200, body: #"{"results":[{"name":"上海","latitude":31.22222,"longitude":121.45806,"country":"中国","admin1":"上海","timezone":"Asia/Shanghai"}]}"#),
        "GET /v1/forecast": .init(status: 200, body: #"{"current":{"temperature_2m":19.4,"weather_code":61,"wind_speed_10m":8,"is_day":0},"daily":{"temperature_2m_max":[22],"temperature_2m_min":[17]}}"#),
    ]
    let places = try await client.search("  上海 ")
    check(places.count == 1 && places[0].latitude == 31.22 && places[0].timezone == "Asia/Shanghai", "client: search parses places")
    let sreq = StubProtocol.requests.last
    let sq = sreq.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false) }?.queryItems ?? []
    func q(_ n: String) -> String? { sq.first { $0.name == n }?.value }
    check(sreq?.url.host == "geocoding-api.open-meteo.com" && q("name") == "上海" && q("language") == "zh" && q("count") == "8" && q("format") == "json", "client: search query (trimmed name, language=zh)")
    let blank = try await client.search("   ")
    check(blank.isEmpty && StubProtocol.requests.count == 1, "client: blank query makes no request")
    let cur = try await client.current(for: places[0])
    check(cur.condition == .rain && cur.temperature == 19.4 && cur.high == 22 && cur.low == 17 && !cur.isDay && cur.fetchedAt > 1_700_000_000, "client: current parses and stamps fetchedAt")
    let freq = StubProtocol.requests.last
    let fq = freq.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false) }?.queryItems ?? []
    check(freq?.url.host == "api.open-meteo.com" && fq.first { $0.name == "latitude" }?.value == "31.22" && fq.first { $0.name == "longitude" }?.value == "121.46" && fq.first { $0.name == "timezone" }?.value == "auto" && fq.first { $0.name == "forecast_days" }?.value == "1", "client: forecast query")
    check((fq.first { $0.name == "current" }?.value ?? "").contains("weather_code") && (fq.first { $0.name == "daily" }?.value ?? "").contains("temperature_2m_max"), "client: asks for current + daily")
    StubProtocol.replies["GET /v1/forecast"] = .init(status: 500, body: "{}")
    do { _ = try await client.current(for: places[0]); check(false, "client: http error throws") } catch { check((error as? WeatherClientError) == .http(500), "client: http 500 → WeatherClientError.http") }
    StubProtocol.replies["GET /v1/forecast"] = .init(status: 200, body: "not json")
    do { _ = try await client.current(for: places[0]); check(false, "client: bad body throws") } catch { check(true, "client: bad body throws") }
    check(URLSession.ephemeralTimeout10.configuration.timeoutIntervalForRequest == 10, "client: default session is ephemeral with a 10 s timeout")
}

// v0.12 widget: refresh need / deadline / fidget mixing
do {
    check(WeatherPlan.needsRefresh(hasPlace: true, partnerHasPlace: true, composeOpen: false, hasClips: false), "plan: city + TA's city refreshes (想 TA)")
    check(WeatherPlan.needsRefresh(hasPlace: true, partnerHasPlace: false, composeOpen: true, hasClips: false), "plan: city + compose open refreshes")
    check(WeatherPlan.needsRefresh(hasPlace: true, partnerHasPlace: false, composeOpen: false, hasClips: true), "plan: city + weather clips refreshes")
    check(!WeatherPlan.needsRefresh(hasPlace: true, partnerHasPlace: false, composeOpen: false, hasClips: false), "plan: nothing shows weather = no refresh")
    check(!WeatherPlan.needsRefresh(hasPlace: false, partnerHasPlace: true, composeOpen: true, hasClips: true), "plan: no city = no refresh")
    check(WeatherPlan.deadline(needed: false, last: 0, now: 100) == nil, "plan: not needed = no deadline")
    check(WeatherPlan.deadline(needed: true, last: 1000, now: 1100) == 2800, "plan: next deadline 30 min after the last refresh")
    check(WeatherPlan.deadline(needed: true, last: nil, now: 1100) == 1100, "plan: never fetched = due now")
    check(WeatherPlan.deadline(needed: true, last: 1000, now: 9000) == 9000, "plan: overdue (sleep) = due now")
    check(WeatherPlan.lastRefresh(fetchedAt: [500, 300], lastAttempt: nil) == 300, "plan: oldest cached result")
    check(WeatherPlan.lastRefresh(fetchedAt: [500, nil], lastAttempt: nil) == nil, "plan: a place never fetched = due")
    check(WeatherPlan.lastRefresh(fetchedAt: [500, nil], lastAttempt: 900) == 900, "plan: a failed attempt still counts (no hammering)")
    check(WeatherPlan.lastRefresh(fetchedAt: [], lastAttempt: nil) == nil, "plan: nothing to fetch")
    // fidget mixing: roll returns the value of the scripted sequence
    func scripted(_ values: [Int]) -> (Int) -> Int { var i = 0; return { n in defer { i += 1 }; return min(values[i % values.count], n - 1) } }
    check(WeatherPlan.pickFidget(plain: 4, weather: 0, lastPlain: nil, lastWeather: nil, roll: scripted([2])) == .plain(2), "mix: no weather clips = plain pick")
    check(WeatherPlan.pickFidget(plain: 4, weather: 2, lastPlain: nil, lastWeather: nil, roll: scripted([0, 1])) == .weather(1), "mix: roll 0 of 3 = weather clip")
    check(WeatherPlan.pickFidget(plain: 4, weather: 2, lastPlain: nil, lastWeather: nil, roll: scripted([1, 3])) == .plain(3), "mix: roll 1 of 3 = plain clip")
    check(WeatherPlan.pickFidget(plain: 0, weather: 2, lastPlain: nil, lastWeather: nil, roll: scripted([1])) == .weather(1), "mix: no plain fidgets = weather only")
    check(WeatherPlan.pickFidget(plain: 0, weather: 0, lastPlain: nil, lastWeather: nil, roll: scripted([0])) == nil, "mix: nothing to play")
    check(WeatherPlan.pickFidget(plain: 3, weather: 2, lastPlain: nil, lastWeather: 0, roll: scripted([0, 0])) == .weather(1), "mix: not the same weather clip twice")
    var weatherPicks = 0
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<3000 where WeatherPlan.pickFidget(plain: 5, weather: 2, lastPlain: nil, lastWeather: nil, roll: { Int.random(in: 0..<$0, using: &rng) }) == nil { weatherPicks = -1 }
    for _ in 0..<3000 { if case .weather? = WeatherPlan.pickFidget(plain: 5, weather: 2, lastPlain: nil, lastWeather: nil, roll: { Int.random(in: 0..<$0, using: &rng) }) { weatherPicks += 1 } }
    check(weatherPicks > 800 && weatherPicks < 1200, "mix: about a third are weather clips (\(weatherPicks)/3000)")
}

// v0.13 changelog + 待设置
do {
    let json = #"[{"version":"0.9.1","date":"2026-09-01","items":["a"]},{"version":"0.12.2","date":"2026-10-07","items":["x","y"]},{"version":"0.10.0","date":"2026-09-20","items":["b","c","d"]},{"version":"zzz","date":"","items":["bad"]}]"#
    let all = Changelog.parse(Data(json.utf8))
    check(all.map(\.version) == ["0.12.2", "0.10.0", "0.9.1"], "changelog: sorted by semantic version (0.10.0 > 0.9.1), bad version dropped")
    check(Changelog.parse(Data("not json".utf8)).isEmpty, "changelog: garbage → empty")
    check(Changelog.parse(Data(#"{"version":"1.0.0"}"#.utf8)).isEmpty, "changelog: wrong shape → empty")
    check(Changelog.parse(Data()).isEmpty, "changelog: empty data → empty")
    check(Changelog.newer(than: "0.9.1", upTo: "0.12.2", in: all).map(\.version) == ["0.12.2", "0.10.0"], "changelog: newer than seen, newest first")
    check(Changelog.newer(than: nil, upTo: "0.12.2", in: all).count == 3, "changelog: nil seen → everything up to current")
    check(Changelog.newer(than: "0.9.1", upTo: "0.10.0", in: all).map(\.version) == ["0.10.0"], "changelog: entries after current are excluded")
    check(Changelog.newer(than: "0.12.2", upTo: "0.12.2", in: all).isEmpty, "changelog: seen == current → none")
    check(Changelog.newer(than: "junk", upTo: "0.12.2", in: all).count == 3, "changelog: unparseable seen = nil")
    check(Changelog.newer(than: nil, upTo: "junk", in: all).isEmpty, "changelog: unparseable current → none")
    check(Changelog.cardText(current: "0.12.2", newItems: 3, todos: 0) == "升级到 v0.12.2 啦 · 3 条新功能", "changelog: card text")
    check(Changelog.cardText(current: "0.12.2", newItems: 3, todos: 2) == "升级到 v0.12.2 啦 · 3 条新功能\n还有 2 件事待设置", "changelog: card text with todos")
    check(Changelog.cardText(current: "0.12.2", newItems: 0, todos: 1) == "升级到 v0.12.2 啦\n还有 1 件事待设置", "changelog: card text without items")
    // launch plan: new / old user
    check(Changelog.plan(seen: nil, hadConfig: false, current: "0.12.2", in: all) == .markSeen, "plan: new user → silent")
    check(Changelog.plan(seen: nil, hadConfig: true, current: "0.12.2", in: all) == .card(newItems: 2), "plan: old user → newest entry only")
    check(Changelog.plan(seen: "0.9.1", hadConfig: true, current: "0.12.2", in: all) == .card(newItems: 5), "plan: seen older → all in between")
    check(Changelog.plan(seen: "0.12.2", hadConfig: true, current: "0.12.2", in: all) == .none, "plan: up to date → none")
    check(Changelog.plan(seen: "0.13.0", hadConfig: true, current: "0.12.2", in: all) == .none, "plan: downgrade → none")
    check(Changelog.plan(seen: "0.12.2", hadConfig: true, current: "0.12.3", in: all) == .markSeen, "plan: upgrade without entries → record only")
    check(Changelog.plan(seen: nil, hadConfig: true, current: nil, in: all) == .none, "plan: no bundle version → none")
    check(Changelog.plan(seen: nil, hadConfig: true, current: "0.12.2", in: []) == .markSeen, "plan: empty log → record only")
    // setup todos truth table
    func todos(city: Bool = true, water: Bool = true, stand: Bool = false, paired: Bool = true,
               older: Bool = false, dismissed: Set<String> = []) -> [String] {
        SetupTodos.compute(hasCity: city, waterOn: water, standOn: stand, paired: paired, partnerOlder: older, dismissed: dismissed).map(\.id)
    }
    check(todos().isEmpty, "todos: everything set → none")
    check(todos(city: false, water: false) == ["city", "reminders"], "todos: no city → city + reminders (no weather widget item any more)")
    check(todos(water: false, stand: false) == ["reminders"], "todos: both reminders off → reminders")
    check(todos(water: false, stand: true).isEmpty, "todos: stand on is enough")
    check(todos(older: true) == ["partnerUpgrade"], "todos: paired + partner older → partnerUpgrade")
    check(todos(paired: false, older: true).isEmpty, "todos: solo never has partnerUpgrade")
    check(todos(paired: true, older: false).isEmpty, "todos: partner version unknown/same → none")
    check(todos(city: false, water: false, older: true) == ["city", "reminders", "partnerUpgrade"], "todos: order city, reminders, partnerUpgrade")
    check(todos(city: false, water: false, older: true, dismissed: ["city", "partnerUpgrade"]) == ["reminders"], "todos: dismissed ids never come back")
    let all4 = SetupTodos.compute(hasCity: true, waterOn: false, standOn: false, paired: true, partnerOlder: true, dismissed: [])
    check(all4.map(\.action) == [.openToolsTab, .howToUpgradePartner], "todos: actions")
    check(all4.allSatisfy { !$0.title.isEmpty && !$0.button.isEmpty }, "todos: copy present")
    let wcs = ConfigStore(profile: "test-whatsnew-\(UUID().uuidString)")
    check(wcs.whatsNewSeen == nil && wcs.setupTodoDismissed.isEmpty, "v0.13: new keys default empty")
    wcs.whatsNewSeen = "0.13.0"; wcs.setupTodoDismissed = ["city", "reminders"]
    check(wcs.whatsNewSeen == "0.13.0" && wcs.setupTodoDismissed == ["city", "reminders"], "v0.13: new keys persist")
    wcs.whatsNewSeen = nil
    check(wcs.whatsNewSeen == nil, "v0.13: whatsNewSeen can be cleared")
}

// MARK: v0.13.1 reminder cycle status (小工具 tab)
do {
    var r = ActiveTimeReminder(interval: 3600)
    _ = r.tick(now: 1000, idleSeconds: 0, blocked: false)
    r.activeSeconds = 600
    check(r.status(now: 1000, idleSeconds: 0, blocked: false) == .counting(left: 3000), "cycle: 50 min left")
    check(r.status(now: 1060, idleSeconds: 10, blocked: false) == .counting(left: 2940), "cycle: live estimate counts time since the tick")
    check(r.status(now: 1060, idleSeconds: 400, blocked: false) == .away, "cycle: away resets")
    r.activeSeconds = 3600
    check(r.status(now: 1000, idleSeconds: 0, blocked: true) == .waiting(left: 0), "cycle: due but blocked")
    r.snooze(now: 1000)
    check(r.status(now: 1300, idleSeconds: 0, blocked: false) == .snoozed(left: 300), "cycle: snoozed")
    r.showing = true
    check(r.status(now: 1300, idleSeconds: 0, blocked: false) == .showing, "cycle: showing")
    check(ToolsCopy.cycleLine(.water, .counting(left: 2940)) == "还差约 49 分钟提醒你喝水（只算用电脑的时间）", "cycle copy: minutes rounded up")
    check(ToolsCopy.cycleLine(.stand, .snoozed(left: 30)) == "「等会儿」：1 分钟后再提醒", "cycle copy: snooze at least 1 min")
}

// MARK: v0.13.3 想 TA thought bubble rules
do {
    let ok = ThinkContext()
    check(ThinkRules.shouldShow(.hover, context: ok, lastShown: nil, now: 100), "think: allowed when free")
    check(!ThinkRules.shouldShow(.hover, context: ok, lastShown: 100, now: 130), "think: 60 s cooldown")
    check(ThinkRules.shouldShow(.hover, context: ok, lastShown: 100, now: 160), "think: cooldown over")
    check(!ThinkRules.shouldShow(.idle, context: ok, lastShown: 100, now: 130), "think: idle also cooled down")
    check(ThinkRules.shouldShow(.weather(.rain), context: ok, lastShown: 100, now: 110), "think: weather ignores cooldown")
    check(ThinkRules.shouldShow(.hover, context: ok, lastShown: 500, now: 100), "think: clock went back never blocks")
    let blockers: [(String, ThinkContext)] = [
        ("solo", ThinkContext(solo: true)), ("hidden", ThinkContext(hidden: true)), ("dnd", ThinkContext(dnd: true)),
        ("focus", ThinkContext(focus: true)), ("quiet", ThinkContext(quiet: true)), ("visit", ThinkContext(visitActive: true)),
        ("bubble", ThinkContext(bubbleShowing: true)), ("busy", ThinkContext(petBusy: true))]
    for (n, c) in blockers {
        check(!ThinkRules.shouldShow(.idle, context: c, lastShown: nil, now: 0), "think: blocked by \(n)")
        check(!ThinkRules.shouldShow(.weather(.snow), context: c, lastShown: nil, now: 0), "think: weather blocked by \(n)")
    }
    check(ThinkRules.idleDelay(unit: 0) == 1200 && ThinkRules.idleDelay(unit: 1) == 2400 && ThinkRules.idleDelay(unit: 5) == 2400, "think: idle delay 20–40 min")
    check(ThinkRules.weatherTrigger(previous: nil, hadData: true, current: .rain) == .rain, "think: clear → rain announces")
    check(ThinkRules.weatherTrigger(previous: nil, hadData: false, current: .rain) == nil, "think: first data announces nothing")
    check(ThinkRules.weatherTrigger(previous: .rain, hadData: true, current: .rain) == nil, "think: same look nothing")
    check(ThinkRules.weatherTrigger(previous: .rain, hadData: true, current: .snow) == .snow, "think: rain → snow")
    check(ThinkRules.weatherTrigger(previous: .rain, hadData: true, current: .hot) == .hot, "think: hot announces")
    check(ThinkRules.weatherTrigger(previous: .rain, hadData: true, current: .cold) == nil, "think: cold/windy/cloudy don't announce")
    check(ThinkRules.weatherTrigger(previous: .rain, hadData: true, current: nil) == nil, "think: look ended announces nothing")
    let sh = FakeWeather.places[1], la = FakeWeather.places[0]
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let rain = FakeWeather.snapshot(for: sh, now: now.timeIntervalSince1970)
    let bar = ThinkRules.barText(reason: .idle, place: sh, snapshot: rain, now: now)
    check(bar?.hasPrefix("上海 🌧 19° · ") == true, "think bar: city weather time (\(bar ?? "nil"))")
    check(ThinkRules.barText(reason: .weather(.rain), place: sh, snapshot: rain, now: now)?.hasPrefix("TA 那边下雨啦 🌧 19° · ") == true, "think bar: weather hint leads")
    check(ThinkRules.barText(reason: .weather(.cold), place: sh, snapshot: rain, now: now)?.hasPrefix("上海 ") == true, "think bar: no hint for cold")
    check(ThinkRules.barText(reason: .idle, place: nil, snapshot: rain, now: now) == nil, "think bar: no city → none")
    check(ThinkRules.barText(reason: .idle, place: sh, snapshot: nil, now: now) == nil, "think bar: no data → none")
    var old = rain; old.fetchedAt = now.timeIntervalSince1970 - 4 * 3600
    check(ThinkRules.barText(reason: .idle, place: sh, snapshot: old, now: now) == nil, "think bar: stale → none")
    check(ThinkRules.flourish(rain) == .rain, "think flourish: rain")
    check(ThinkRules.flourish(FakeWeather.snapshot(for: la, now: 0)) == .sun, "think flourish: clear day → sun")
    var night = FakeWeather.snapshot(for: la, now: 0); night.isDay = false
    check(ThinkRules.flourish(night) == .none && ThinkRules.flourish(nil) == .none, "think flourish: night/no data → none")
    var snow = rain; snow.condition = .snow
    check(ThinkRules.flourish(snow) == .snow, "think flourish: snow")
}

// MARK: v0.14 one-click updater
do {
    func json(_ s: String) -> Data { Data(s.utf8) }
    let good = """
    {"tag_name":"v0.14.0","html_url":"https://github.com/richardzhuang0412/LuluPet/releases/tag/v0.14.0","body":"notes","draft":false,"prerelease":false,
     "assets":[{"name":"checksums.txt","browser_download_url":"https://x/checksums.txt"},{"name":"LuluPet.zip","browser_download_url":"https://x/LuluPet.zip"}]}
    """
    let r = UpdateFeed.parse(json(good))
    check(r?.version == AppVersion(0, 14, 0) && r?.tag == "v0.14.0", "update feed: tag with v")
    check(r?.assetURL.absoluteString == "https://x/LuluPet.zip", "update feed: asset found by name, not position")
    check(r?.notes == "notes" && r?.pageURL?.absoluteString.hasSuffix("v0.14.0") == true, "update feed: body + page")
    check(UpdateFeed.parse(json(good.replacingOccurrences(of: "\"tag_name\":\"v0.14.0\"", with: "\"tag_name\":\"0.14.0\"")))?.version == AppVersion(0, 14, 0), "update feed: tag without v")
    check(UpdateFeed.parse(json(#"{"tag_name":"v0.14.0","assets":[{"name":"other.zip","browser_download_url":"https://x/o.zip"}]}"#)) == nil, "update feed: no LuluPet.zip asset → nil")
    check(UpdateFeed.parse(json(#"{"tag_name":"nightly","assets":[{"name":"LuluPet.zip","browser_download_url":"https://x/a"}]}"#)) == nil, "update feed: unparseable tag → nil")
    check(UpdateFeed.parse(json(good.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#))) == nil, "update feed: prerelease → nil")
    check(UpdateFeed.parse(json(good.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#))) == nil, "update feed: draft → nil")
    check(UpdateFeed.parse(json(good.replacingOccurrences(of: "https://x/LuluPet.zip", with: "file:///etc/passwd"))) == nil, "update feed: non-http asset URL → nil")
    check(UpdateFeed.parse(json("not json")) == nil && UpdateFeed.parse(json("[]")) == nil && UpdateFeed.parse(Data()) == nil, "update feed: bad data → nil")
    check(UpdateFeed.parse(json(#"{"tag_name":"v1.0.0","assets":[{"name":"LuluPet.zip","browser_download_url":"https://x/a"}]}"#))?.notes == "", "update feed: missing body → empty notes")

    check(UpdateFeed.latestURL().absoluteString == "https://api.github.com/repos/richardzhuang0412/LuluPet/releases/latest", "update url: default")
    check(UpdateFeed.latestURL(override: "http://127.0.0.1:8123/latest.json").absoluteString == "http://127.0.0.1:8123/latest.json", "update url: override")
    check(UpdateFeed.latestURL(override: "  ").host == "api.github.com" && UpdateFeed.latestURL(override: "ftp://x/y").host == "api.github.com"
          && UpdateFeed.latestURL(override: "garbage").host == "api.github.com", "update url: bad override → default")
    check(UpdateFeed.userAgent(version: "0.14.0") == "LuluPet/0.14.0" && UpdateFeed.userAgent(version: nil) == "LuluPet/dev", "update: User-Agent")
    check(UpdateFeed.headers(version: "0.14.0")["Accept"] == "application/vnd.github+json", "update: Accept header")

    let rel = r!
    check(UpdateRules.isNewer(rel, than: "0.13.3") && !UpdateRules.isNewer(rel, than: "0.14.0") && !UpdateRules.isNewer(rel, than: "0.15.0"), "update: isNewer")
    check(UpdateRules.isNewer(rel, than: "0.9.9") && !UpdateRules.isNewer(rel, than: nil) && !UpdateRules.isNewer(rel, than: "junk"), "update: isNewer is numeric; unknown current → false")

    check(UpdateRules.isCheckDue(lastCheck: nil, now: 1000), "update check: never → due")
    check(!UpdateRules.isCheckDue(lastCheck: 1000, now: 1000 + 86399) && UpdateRules.isCheckDue(lastCheck: 1000, now: 1000 + 86400), "update check: once a day")
    check(UpdateRules.isCheckDue(lastCheck: 5000, now: 1000), "update check: clock set back → due")
    check(UpdateRules.nextCheck(lastCheck: nil, now: 50) == 50 && UpdateRules.nextCheck(lastCheck: 100, now: 150) == 100 + 86400 && UpdateRules.nextCheck(lastCheck: 900, now: 50) == 50, "update check: next deadline")

    check(UpdateRules.shouldNotify(rel, current: "0.13.3", skipped: nil, manual: false), "update notify: newer, nothing skipped")
    check(!UpdateRules.shouldNotify(rel, current: "0.13.3", skipped: "0.14.0", manual: false), "update notify: skipped version stays quiet (auto)")
    check(UpdateRules.shouldNotify(rel, current: "0.13.3", skipped: "0.14.0", manual: true), "update notify: manual check ignores skip")
    check(UpdateRules.shouldNotify(rel, current: "0.13.3", skipped: "0.13.9", manual: false), "update notify: newer than the skipped one → tell me")
    check(!UpdateRules.shouldNotify(rel, current: "0.14.0", skipped: nil, manual: true), "update notify: not newer → never")

    check(UpdateRules.verify(bundleID: "com.lulupet.app", version: "0.14.0", current: "0.13.3") == .ok, "update verify: ok")
    check(UpdateRules.verify(bundleID: "com.evil.app", version: "0.14.0", current: "0.13.3") == .wrongBundleID, "update verify: wrong bundle id")
    check(UpdateRules.verify(bundleID: "com.lulupet.app", version: "0.13.3", current: "0.13.3") == .notNewer
          && UpdateRules.verify(bundleID: "com.lulupet.app", version: "0.13.0", current: "0.13.3") == .notNewer, "update verify: not newer")
    check(UpdateRules.verify(bundleID: "com.lulupet.app", version: nil, current: "0.13.3") == .unreadable
          && UpdateRules.verify(bundleID: nil, version: "1.0.0", current: "0.13.3") == .unreadable, "update verify: unreadable")

    let home = "/Users/me"
    check(UpdateRules.canSelfUpdate(bundlePath: "/Applications/LuluPet.app", home: home), "update location: /Applications")
    check(UpdateRules.canSelfUpdate(bundlePath: "/Users/me/Applications/LuluPet.app", home: home), "update location: ~/Applications")
    check(!UpdateRules.canSelfUpdate(bundlePath: "/Users/me/Downloads/LuluPet.app", home: home), "update location: Downloads → manual")
    check(!UpdateRules.canSelfUpdate(bundlePath: "/Volumes/LuluPet/LuluPet.app", home: home) && !UpdateRules.canSelfUpdate(bundlePath: "/Applications/Sub/LuluPet.app", home: home), "update location: DMG / nested → manual")
    check(!UpdateRules.canSelfUpdate(bundlePath: "/usr/local/bin/LuluPet", home: home) && !UpdateRules.canSelfUpdate(bundlePath: nil, home: home), "update location: not an .app → manual")
    check(UpdateRules.canSelfUpdate(bundlePath: "/tmp/t/LuluPet.app", home: home, extraAllowed: ["/tmp/t"]), "update location: test folder")

    let sh = UpdateInstaller.script(pid: 4242, newApp: "/tmp/w/unzipped/LuluPet.app", target: "/Applications/LuluPet.app", workDir: "/tmp/w",
                                    relaunchArgs: ["--profile", "it's"])
    check(sh.hasPrefix("#!/bin/sh") && sh.contains("kill -0 4242"), "update script: waits for the pid")
    check(sh.contains("/usr/bin/ditto '/tmp/w/unzipped/LuluPet.app' '/Applications/LuluPet.app.new'"), "update script: ditto to <app>.new")
    check(sh.contains("mv '/Applications/LuluPet.app' '/Applications/LuluPet.app.old'") && sh.contains("mv '/Applications/LuluPet.app.new' '/Applications/LuluPet.app'"), "update script: swap with backup")
    check(sh.contains("xattr -dr com.apple.quarantine '/Applications/LuluPet.app'") && sh.contains("rm -rf '/Applications/LuluPet.app.old'"), "update script: quarantine + cleanup")
    check(sh.contains("/usr/bin/open '/Applications/LuluPet.app' --args '--profile' 'it'\\''s'"), "update script: relaunch with quoted args")
    check(!sh.contains("Application Support") && !sh.contains("Preferences") && !sh.contains("defaults"), "update script: never touches user data")
    check(UpdateInstaller.shQuote("a b'c") == "'a b'\\''c'", "update script: shell quoting")

    check(UpdateCopy.upToDate("0.13.3") == "已经是最新版 v0.13.3" && UpdateCopy.menuLine("0.14.0") == "有新版本 v0.14.0", "update copy: up to date / menu")
    check(UpdateCopy.downloading(0.371) == "正在下载… 37%" && UpdateCopy.downloading(nil) == "正在下载…" && UpdateCopy.downloading(2) == "正在下载… 100%", "update copy: progress text")
    check(UpdateCopy.confirmBody.contains("聊天记录和设置不会丢"), "update copy: confirm mentions data is safe")
    check(UpdateCopy.cardText("0.14.0").contains("有新版本 v0.14.0"), "update copy: card")
    check(UpdateCopy.upgradeHelp(version: "0.14.0").contains("检查更新") && UpdateCopy.upgradeHelp(version: "0.14.0").contains("LuluPet-v0.14.0.zip"), "update copy: partner upgrade help (check + zip fallback)")

    // store keys + housekeeping hook
    let us = ConfigStore(profile: "test-\(UUID().uuidString)")
    check(us.updateLastCheck == nil && us.updateSkipped == nil, "v0.14: update keys default to absent")
    us.updateLastCheck = 1_800_000_000.5; us.updateSkipped = "0.14.0"
    check(us.updateLastCheck == 1_800_000_000.5 && us.updateSkipped == "0.14.0", "v0.14: update keys persist")
    us.updateSkipped = nil; us.updateLastCheck = nil
    check(us.updateLastCheck == nil && us.updateSkipped == nil, "v0.14: update keys can be cleared")
    let uh = HousekeepingDeadlines(updateCheck: 3000)
    check(HousekeepingTask.updateCheck.isWallClock && uh[.updateCheck] == 3000, "housekeeping: updateCheck is a wall-clock task")
    check(Housekeeping.due(uh, uptime: 1, wall: 3000) == [.updateCheck] && Housekeeping.due(uh, uptime: 1, wall: 2999).isEmpty, "housekeeping: updateCheck due at its deadline")
    check(HousekeepingDeadlines()[.updateCheck] == nil, "housekeeping: updateCheck not armed by default")
}

// MARK: v0.14.1 weather accuracy (NWS observations, overcast fix) + current location rules
do {
    // overcast false positive: WMO 3 needs cloud_cover >= 85 to be cloudy
    check(WeatherCondition(wmo: 3, cloudCover: 100) == .cloudy && WeatherCondition(wmo: 3, cloudCover: 85) == .cloudy, "overcast: wmo 3 with 85+ % cloud = cloudy")
    check(WeatherCondition(wmo: 3, cloudCover: 84) == .partlyCloudy && WeatherCondition(wmo: 3, cloudCover: 0) == .partlyCloudy, "overcast: wmo 3 under 85 % cloud = partly cloudy")
    check(WeatherCondition(wmo: 3, cloudCover: nil) == .cloudy && WeatherCondition(wmo: 3) == .cloudy, "overcast: wmo 3 without cloud cover stays cloudy")
    check(WeatherCondition(wmo: 61, cloudCover: 10) == .rain && WeatherCondition(wmo: 2, cloudCover: 100) == .partlyCloudy, "overcast: other codes ignore cloud cover")
    let om3 = try WeatherParse.snapshot(Data(#"{"current":{"temperature_2m":30.7,"weather_code":3,"cloud_cover":62,"wind_speed_10m":9,"is_day":1},"daily":{"temperature_2m_max":[33],"temperature_2m_min":[15]}}"#.utf8), now: 1)
    check(om3.condition == .partlyCloudy, "overcast: parse applies the cloud cover")
    let om3b = try WeatherParse.snapshot(Data(#"{"current":{"temperature_2m":30.7,"weather_code":3,"cloud_cover":100,"is_day":1}}"#.utf8), now: 1)
    check(om3b.condition == .cloudy, "overcast: parse keeps real overcast")

    // NWS text → condition (keyword order from the research doc)
    let texts: [(String, WeatherCondition?)] = [
        ("Thunderstorm", .thunder), ("Light Rain and Thunder", .thunder), ("Snow", .snow), ("Freezing Rain/Sleet", .snow), ("Ice Pellets", .snow), ("Blowing Snow", .snow),
        ("Light Drizzle", .drizzle), ("Rain", .rain), ("Heavy Rain", .rain), ("Rain Showers", .rain), ("Light Rain Fog/Mist", .rain),
        ("Fog/Mist", .fog), ("Haze", .fog), ("Smoke", .fog), ("Dust", .fog),
        ("Overcast", .cloudy), ("Mostly Cloudy", .cloudy), ("Cloudy", .cloudy),
        ("Partly Cloudy", .partlyCloudy), ("Partly Sunny", .partlyCloudy), ("Mostly Sunny", .partlyCloudy),
        ("Clear", .clear), ("Mostly Clear", .clear), ("Sunny", .clear), ("Fair", .clear), ("Fair/Windy", .clear), ("A Few Clouds", .clear),
        ("", nil), ("Windy", nil)]
    for (t, c) in texts { check(WeatherCondition(nwsText: t) == c, "nws text: \(t.isEmpty ? "(empty)" : t) → \(c.map { $0.label } ?? "nil")") }
    check(WeatherCondition(nwsCloudAmounts: ["CLR"]) == .clear && WeatherCondition(nwsCloudAmounts: ["SKC"]) == .clear && WeatherCondition(nwsCloudAmounts: ["FEW"]) == .clear, "nws layers: CLR / SKC / FEW = clear")
    check(WeatherCondition(nwsCloudAmounts: ["SCT"]) == .partlyCloudy && WeatherCondition(nwsCloudAmounts: ["FEW", "BKN"]) == .partlyCloudy, "nws layers: SCT / BKN = partly cloudy (largest wins)")
    check(WeatherCondition(nwsCloudAmounts: ["FEW", "OVC"]) == .cloudy && WeatherCondition(nwsCloudAmounts: ["VV"]) == .cloudy, "nws layers: OVC / VV = cloudy")
    check(WeatherCondition(nwsCloudAmounts: []) == nil && WeatherCondition(nwsCloudAmounts: ["XYZ"]) == nil, "nws layers: none / unknown = nil")

    // fixtures
    let pointsJSON = #"{"properties":{"gridId":"MTR","observationStations":"https://api.weather.gov/gridpoints/MTR/85,105/stations"}}"#
    let stationsJSON = #"""
    {"features":[
      {"geometry":{"type":"Point","coordinates":[-122.28,37.87]},"properties":{"stationIdentifier":"D3169","name":"Berkeley mesonet"}},
      {"geometry":{"type":"Point","coordinates":[-122.2269,37.7213]},"properties":{"stationIdentifier":"KOAK","name":"Oakland"}},
      {"geometry":{"type":"Point","coordinates":[-122.3748,37.6188]},"properties":{"stationIdentifier":"KSFO","name":"San Francisco Intl"}},
      {"geometry":{"type":"Point","coordinates":[-121.9,37.9]},"properties":{"stationIdentifier":"KFAR","name":"far"}},
      {"geometry":{"type":"Point","coordinates":[-120.0,36.0]},"properties":{"stationIdentifier":"KSJC"}},
      {"properties":{"stationIdentifier":"NOGEO"}},
      {"geometry":{"type":"Point","coordinates":[-122.0,37.0]},"properties":{}}]}
    """#
    check(NWSParse.stationsURL(points: Data(pointsJSON.utf8))?.absoluteString == "https://api.weather.gov/gridpoints/MTR/85,105/stations", "nws: points → stations URL")
    check(NWSParse.stationsURL(points: Data(#"{"properties":{"observationStations":"http://evil.example/x"}}"#.utf8)) == nil && NWSParse.stationsURL(points: Data("nope".utf8)) == nil, "nws: points without a (trusted) stations URL = nil")
    let sts = NWSParse.stations(Data(stationsJSON.utf8))
    check(sts.map(\.id) == ["D3169", "KOAK", "KSFO", "KFAR", "KSJC"] && sts[1].latitude == 37.7213 && sts[1].longitude == -122.2269, "nws: stations parsed (lon, lat order), bad features skipped")

    let berkeley = WeatherPlace(name: "伯克利", admin: nil, country: nil, latitude: 37.87, longitude: -122.27, timezone: "America/Los_Angeles")
    let cand = NWSSelect.candidates(sts, near: berkeley).map(\.id)
    check(cand == ["KOAK", "D3169"], "nws: within 25 km (KSFO, KFAR, KSJC are not), K airports first, then the others (\(cand))")
    check(NWSSelect.candidates([NWSStation(id: "KXXX", latitude: 38.5, longitude: -122.27)], near: berkeley).isEmpty, "nws: nothing within 25 km = no candidates")
    check(abs(NWSSelect.distanceKm(37.87, -122.27, 37.7213, -122.2269) - 16.7) < 0.5, "nws: haversine distance")
    let many = (0..<8).map { NWSStation(id: $0 == 6 ? "KAAA" : "W\($0)", latitude: 37.87 + Double($0) * 0.003, longitude: -122.27) }
    check(NWSSelect.candidates(many, near: berkeley).map(\.id) == ["W0", "W1", "W2"], "nws: airport beyond the nearest five is not preferred; at most 3 tries")

    @Sendable func obsJSON(_ items: [String]) -> Data { Data(#"{"features":[\#(items.joined(separator: ","))]}"#.utf8) }
    @Sendable func feature(temp: String, text: String, layers: String = "[]", at: String) -> String {
        #"{"properties":{"timestamp":"\#(at)","textDescription":"\#(text)","temperature":{"unitCode":"wmoUnit:degC","value":\#(temp)},"cloudLayers":\#(layers)}}"#
    }
    let now = NWSParse.date("2026-10-04T20:30:00+00:00")!.timeIntervalSince1970
    let obs = NWSParse.observations(obsJSON([
        feature(temp: "null", text: "Clear", at: "2026-10-04T20:25:00+00:00"),
        feature(temp: "24.4", text: "", layers: #"[{"base":{"value":null},"amount":"CLR"}]"#, at: "2026-10-04T20:20:00+00:00"),
        feature(temp: "25.0", text: "Mostly Cloudy", at: "2026-10-04T19:56:00+00:00"),
        feature(temp: "26.0", text: "Clear", at: "2026-10-04T18:00:00+00:00")]), stationId: "KSFO")
    check(obs.count == 3 && obs[0].temperature == 24.4 && obs[0].condition == .clear, "nws: null temperature dropped; empty text → cloud layers (CLR = clear)")
    check(NWSSelect.usable(obs, now: now)?.temperature == 24.4, "nws: first fresh reading wins")
    check(NWSSelect.usable(obs, now: now + 4800)?.temperature == 24.4 && NWSSelect.usable(obs, now: now + 5400) == nil, "nws: a reading counts up to 90 minutes old (20:20 → until 21:50), not after")
    check(NWSSelect.usable(obs, now: now + 6 * 3600) == nil, "nws: all readings stale = nil")
    check(NWSSelect.usable([NWSObservation(stationId: "K", temperature: 1, condition: nil, observedAt: now + 3600)], now: now) == nil, "nws: reading from the future is not used")
    let noSky = NWSParse.observations(obsJSON([feature(temp: "20", text: "", at: "2026-10-04T20:20:00+00:00")]), stationId: "W1")
    check(noSky.count == 1 && noSky[0].condition == nil, "nws: no text and no layers = unknown sky (kept for the temperature)")
    check(NWSParse.observations(Data("nope".utf8), stationId: "X").isEmpty && NWSParse.observations(Data(#"{"title":"Not Found"}"#.utf8), stationId: "X").isEmpty, "nws: bad observation json = []")
    check(NWSParse.date("2026-10-04T20:20:00.123+00:00") != nil, "nws: timestamp with fractional seconds")

    // merge
    let omSnap = WeatherSnapshot(condition: .cloudy, temperature: 33, high: 34, low: 15, windSpeed: 9, isDay: true, fetchedAt: 7)
    let merged = WeatherMerge.apply(omSnap, nws: NWSObservation(stationId: "KOAK", temperature: 28, condition: .clear, observedAt: now))
    check(merged == WeatherSnapshot(condition: .clear, temperature: 28, high: 34, low: 15, windSpeed: 9, isDay: true, fetchedAt: 7), "merge: temperature and sky from NWS, the rest Open-Meteo")
    check(WeatherMerge.apply(omSnap, nws: NWSObservation(stationId: "W", temperature: 20, condition: nil, observedAt: now)).condition == .cloudy, "merge: no NWS sky keeps Open-Meteo's")
    check(WeatherMerge.apply(omSnap, nws: nil) == omSnap, "merge: no observation = unchanged")
    let wide = WeatherMerge.apply(omSnap, nws: NWSObservation(stationId: "W", temperature: 36, condition: nil, observedAt: now))
    check(wide.high == 36 && wide.low == 15, "merge: high / low widened to include the reading")

    check(NWSSelect.mayBeUS(berkeley) && NWSSelect.mayBeUS(WeatherPlace(name: "Honolulu", admin: nil, country: nil, latitude: 21.3, longitude: -157.86, timezone: "Pacific/Honolulu")), "nws: US places may ask")
    check(!NWSSelect.mayBeUS(WeatherPlace(name: "上海", admin: nil, country: nil, latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai")), "nws: Shanghai never asks")
    check(NWSClient.userAgent(version: "0.14.1") == "LuluPet/0.14.1 (github.com/richardzhuang0412/LuluPet)", "nws: user agent")

    // NWSClient with fixtures: lookup cached, observation chosen, fallbacks
    final class Calls: @unchecked Sendable { var urls: [String] = []; let lock = NSLock(); func add(_ u: String) { lock.lock(); urls.append(u); lock.unlock() } }
    let calls = Calls()
    let obsFresh = obsJSON([feature(temp: "28", text: "Clear", at: "2026-10-04T20:20:00+00:00")])
    let obsOld = obsJSON([feature(temp: "28", text: "Clear", at: "2026-10-04T12:00:00+00:00")])
    let koakFresh: Bool = true
    let client = NWSClient(fetch: { url in
        calls.add(url.absoluteString)
        switch url.absoluteString {
        case "https://api.weather.gov/points/37.87,-122.27": return Data(pointsJSON.utf8)
        case "https://api.weather.gov/gridpoints/MTR/85,105/stations": return Data(stationsJSON.utf8)
        case "https://api.weather.gov/stations/KOAK/observations?limit=3": return koakFresh ? obsFresh : obsOld
        case "https://api.weather.gov/stations/KSFO/observations?limit=3": return obsOld
        case "https://api.weather.gov/stations/D3169/observations?limit=3": return obsJSON([feature(temp: "29.4", text: "", at: "2026-10-04T20:15:00+00:00")])
        case "https://api.weather.gov/points/31.23,121.47": throw WeatherClientError.http(404)
        default: throw WeatherClientError.http(500)
        }
    })
    let nwsSuite = "lulupet.test-nws-\(UUID().uuidString)"
    let nwsStore = WeatherStore(defaults: UserDefaults(suiteName: nwsSuite)!)
    let first = await client.observation(for: berkeley, store: nwsStore, now: now)
    check(first?.stationId == "KOAK" && first?.temperature == 28 && first?.condition == .clear, "nws client: nearest airport's fresh reading")
    check(calls.urls.count == 3, "nws client: first refresh = points + stations + one observation (\(calls.urls.count))")
    let before = calls.urls.count
    _ = await client.observation(for: berkeley, store: nwsStore, now: now + 1800)
    check(calls.urls.count - before == 1 && calls.urls.last == "https://api.weather.gov/stations/KOAK/observations?limit=3", "nws client: later refresh = one observation call, lookup cached")
    check(nwsStore.nwsLookup(for: berkeley)?.isUS == true && nwsStore.nwsLookup(for: berkeley)?.stations.count == 5, "nws client: lookup stored per place")
    // stale at KOAK/KSFO → falls to the mesonet station within the 3 tries
    let later = await client.observation(for: berkeley, store: nwsStore, now: NWSParse.date("2026-10-04T22:00:00+00:00")!.timeIntervalSince1970)
    check(later == nil, "nws client: everything older than 90 minutes = nil (caller falls back)")
    let third = await client.observation(for: berkeley, store: nwsStore, now: NWSParse.date("2026-10-04T20:40:00+00:00")!.timeIntervalSince1970)
    check(third?.stationId == "KOAK", "nws client: still fresh at +20 min")
    // outside coverage: 404 cached as not-US, never asked again within a week
    let shanghai = WeatherPlace(name: "上海", admin: nil, country: nil, latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai")
    let sh = await client.observation(for: shanghai, store: nwsStore, now: now)
    check(sh == nil && calls.urls.filter { $0.contains("31.23") }.isEmpty, "nws client: Shanghai never even asks NWS")
    let rural = WeatherPlace(name: "X", admin: nil, country: nil, latitude: 49.0, longitude: -100.0, timezone: "America/Chicago")   // plausibly US but unknown to the stub: 500
    let ruralObs = await client.observation(for: rural, store: nwsStore, now: now); check(ruralObs == nil && nwsStore.nwsLookup(for: rural) == nil, "nws client: a server error is not cached (retry next time)")
    let notUS = NWSClient(fetch: { _ in throw WeatherClientError.http(404) })
    let canada = WeatherPlace(name: "Toronto", admin: nil, country: nil, latitude: 43.65, longitude: -79.38, timezone: "America/Toronto")
    let c1 = await notUS.observation(for: canada, store: nwsStore, now: now); check(c1 == nil && nwsStore.nwsLookup(for: canada)?.isUS == false, "nws client: 404 from /points = not US, cached")
    let refetchCount = Calls()
    let notUS2 = NWSClient(fetch: { u in refetchCount.add(u.absoluteString); throw WeatherClientError.http(404) })
    let c2 = await notUS2.observation(for: canada, store: nwsStore, now: now + 86400); check(c2 == nil && refetchCount.urls.isEmpty, "nws client: not-US answer reused for days")
    let c3 = await notUS2.observation(for: canada, store: nwsStore, now: now + 8 * 86400); check(c3 == nil && refetchCount.urls.count == 1, "nws client: not-US answer expires after a week")
    // station fails → next station
    let flaky = NWSClient(fetch: { url in
        switch url.absoluteString {
        case "https://api.weather.gov/points/37.87,-122.27": return Data(pointsJSON.utf8)
        case "https://api.weather.gov/gridpoints/MTR/85,105/stations": return Data(stationsJSON.utf8)
        case "https://api.weather.gov/stations/D3169/observations?limit=3": return obsJSON([feature(temp: "29.4", text: "", at: "2026-10-04T20:15:00+00:00")])
        default: throw WeatherClientError.http(503)
        }
    })
    let fl = await flaky.observation(for: berkeley, store: nil, now: now)
    check(fl?.stationId == "D3169" && fl?.temperature == 29.4 && fl?.condition == nil, "nws client: failing airports → the mesonet station (temperature only)")
    UserDefaults(suiteName: nwsSuite)!.removePersistentDomain(forName: nwsSuite)

    // sky borrowed from an airport station when the temperature station has none (one extra call at most)
    let skyStations = (0..<5).map { #"{"geometry":{"coordinates":[-122.27,\#(37.87 + Double($0) * 0.003)]},"properties":{"stationIdentifier":"W\#($0)"}}"# }
        + [#"{"geometry":{"coordinates":[-122.2269,37.7213]},"properties":{"stationIdentifier":"KOAK"}}"#]
    let skyStationsJSON = #"{"features":[\#(skyStations.joined(separator: ","))]}"#
    let skyCalls = Calls()
    func skyClient(koak: Data) -> NWSClient {
        NWSClient(fetch: { url in
            skyCalls.add(url.absoluteString)
            switch url.absoluteString {
            case "https://api.weather.gov/points/37.87,-122.27": return Data(pointsJSON.utf8)
            case "https://api.weather.gov/gridpoints/MTR/85,105/stations": return Data(skyStationsJSON.utf8)
            case "https://api.weather.gov/stations/W0/observations?limit=3": return obsJSON([feature(temp: "29.4", text: "", at: "2026-10-04T20:15:00+00:00")])
            case "https://api.weather.gov/stations/KOAK/observations?limit=3": return koak
            default: throw WeatherClientError.http(503)
            }
        })
    }
    let withSky = await skyClient(koak: obsJSON([feature(temp: "28", text: "Clear", at: "2026-10-04T20:20:00+00:00")])).observation(for: berkeley, store: nil, now: now)
    check(withSky?.stationId == "W0" && withSky?.temperature == 29.4 && withSky?.condition == .clear && withSky?.skyStationId == "KOAK", "nws sky: temperature from the first station, sky (Clear) from the airport")
    check(skyCalls.urls.filter { $0.contains("/observations") }.count == 2, "nws sky: exactly one extra observation call")
    let noSkyAnywhere = await skyClient(koak: obsJSON([feature(temp: "28", text: "", at: "2026-10-04T20:20:00+00:00")])).observation(for: berkeley, store: nil, now: now)
    check(noSkyAnywhere?.temperature == 29.4 && noSkyAnywhere?.condition == nil && noSkyAnywhere?.skyStationId == nil, "nws sky: no station has a sky → condition stays nil (Open-Meteo's is used)")
    let staleSky = await skyClient(koak: obsJSON([feature(temp: "28", text: "Clear", at: "2026-10-04T12:00:00+00:00")])).observation(for: berkeley, store: nil, now: now)
    check(staleSky?.condition == nil, "nws sky: a stale airport reading is not borrowed")
    check(NWSSelect.skyStation(sts, near: berkeley, excluding: ["KOAK"]) == nil && NWSSelect.skyStation(sts, near: berkeley, excluding: [])?.id == "KOAK", "nws sky: nearest unasked K station within 25 km")

    // my city: auto flag + location rules
    let autoSuite = "lulupet.test-auto-\(UUID().uuidString)"
    let autoStore = WeatherStore(defaults: UserDefaults(suiteName: autoSuite)!)
    check(!autoStore.myPlaceAuto, "location: auto is off by default")
    autoStore.myPlaceAuto = true
    check(autoStore.myPlaceAuto && WeatherStore(defaults: UserDefaults(suiteName: autoSuite)!).myPlaceAuto, "location: auto persists")
    autoStore.myPlaceAuto = false
    check(!autoStore.myPlaceAuto, "location: auto off again")
    UserDefaults(suiteName: autoSuite)!.removePersistentDomain(forName: autoSuite)
    check(LocationRules.isDue(last: nil, now: 5) && !LocationRules.isDue(last: 1000, now: 1000 + 3 * 3600 - 1) && LocationRules.isDue(last: 1000, now: 1000 + 3 * 3600) && LocationRules.isDue(last: 1000, now: 500), "location: due when never, after 3 h, or when the clock went back")
    check(LocationRules.deadline(auto: false, last: nil, now: 50) == nil, "location: no deadline while auto is off")
    check(LocationRules.deadline(auto: true, last: nil, now: 50) == 50 && LocationRules.deadline(auto: true, last: 1000, now: 1500) == 1000 + 10800 && LocationRules.deadline(auto: true, last: 1000, now: 50_000) == 50_000, "location: deadline = last + 3 h, now when overdue")
    check(LocationRules.needsGeocode(current: nil, latitude: 37.87, longitude: -122.27), "location: no city yet = geocode")
    check(!LocationRules.needsGeocode(current: berkeley, latitude: 37.88, longitude: -122.26), "location: ~1.4 km move = same city")
    check(LocationRules.needsGeocode(current: berkeley, latitude: 37.80, longitude: -122.27), "location: ~7.8 km move = geocode again")
    var lh = HousekeepingDeadlines(); lh.location = 4000
    check(HousekeepingTask.location.isWallClock && lh[.location] == 4000 && Housekeeping.due(lh, uptime: 1, wall: 4000) == [.location] && HousekeepingDeadlines()[.location] == nil, "housekeeping: location deadline on the wall clock")
}

// v0.14.2: presence outfit + pose, and what the 想 TA bubble draws for them
do {
    for p in [PetPose.idle, .doze, .quiet, .focus, .dnd, .hidden] + WeatherLook.allCases.map(PetPose.weather) {
        check(PetPose(raw: p.raw) == p, "pose roundtrip \(p.raw)")
    }
    check(PetPose(raw: "weather:rain") == .weather(.rain) && PetPose.weather(.snow).raw == "weather:snow", "weather pose words")
    check(PetPose(raw: "levitating") == .idle && PetPose(raw: "weather:meteor") == .idle && PetPose(raw: "") == .idle, "unknown pose reads as idle")
    func d(hidden: Bool = false, dnd: Bool = false, focus: Bool = false, dozing: Bool = false, quiet: Bool = false,
           weather: WeatherLook? = nil, clips: Bool = false) -> PetPose {
        PetPose.derive(hidden: hidden, dnd: dnd, focus: focus, dozing: dozing, quiet: quiet, weather: weather, hasWeatherClips: clips)
    }
    check(d() == .idle, "derive: idle")
    check(d(hidden: true, dnd: true, focus: true, dozing: true, quiet: true, weather: .rain, clips: true) == .hidden, "derive: hidden wins")
    check(d(dnd: true, focus: true, dozing: true, quiet: true) == .dnd, "derive: dnd before focus")
    check(d(focus: true, dozing: true, quiet: true) == .focus, "derive: focus before doze")
    check(d(dozing: true, quiet: true, weather: .rain, clips: true) == .doze, "derive: doze before quiet")
    check(d(quiet: true, weather: .rain, clips: true) == .quiet, "derive: quiet before weather")
    check(d(weather: .rain, clips: true) == .weather(.rain), "derive: weather with clips")
    check(d(weather: .rain, clips: false) == .idle && d(weather: nil, clips: true) == .idle, "derive: weather without clips / look = idle")

    let look = PresenceLook(outfit: "pajama", pose: .weather(.rain))
    let pay = PresenceInfo.payload(lastSeen: 5, dnd: nil, look: look)
    check(pay["outfit"] as? String == "pajama" && pay["pose"] as? String == "weather:rain", "payload carries outfit + pose")
    check(Set(PresenceInfo.payload(lastSeen: 5, dnd: nil).keys) == ["lastSeen"], "payload without look = old shape")
    check(Set(PresenceInfo.payload(lastSeen: 5, dnd: nil, look: PresenceLook(outfit: "x")).keys) == ["lastSeen", "outfit"], "payload outfit only (sign-off)")
    let data = try JSONSerialization.data(withJSONObject: pay)
    check(PresenceInfo.decode(data) == PresenceInfo(lastSeen: 5, outfit: "pajama", pose: .weather(.rain)), "presence roundtrip outfit + pose")
    check(PresenceInfo.decode(Data(#"{"lastSeen":1234}"#.utf8)) == PresenceInfo(lastSeen: 1234), "old payload without outfit / pose still decodes")
    check(PresenceInfo.decode(Data(#"{"lastSeen":1,"pose":"hover-board","outfit":"lace"}"#.utf8)) == PresenceInfo(lastSeen: 1, outfit: "lace", pose: .idle), "unknown pose → idle, outfit kept")
    check(PresenceInfo.decode(Data(#"{"lastSeen":1,"pose":7,"outfit":""}"#.utf8)) == PresenceInfo(lastSeen: 1), "odd types / empty outfit ignored")
    check(PresenceLook.cleanOutfit("../x") == nil && PresenceLook.cleanOutfit(String(repeating: "a", count: 65)) == nil && PresenceLook.cleanOutfit("lace") == "lace", "outfit sanitised")

    let rainy: (WeatherLook) -> Bool = { $0 == .rain }
    check(ThinkPoseLook.resolve(nil, hasFocusClip: true, hasWeatherClip: rainy) == .idleLoop, "bubble: no pose = idle")
    check(ThinkPoseLook.resolve(.hidden, hasFocusClip: false, hasWeatherClip: rainy) == .idleLoop, "bubble: hidden = idle")
    check(ThinkPoseLook.resolve(.doze, hasFocusClip: false, hasWeatherClip: rainy) == .dozeStill, "bubble: doze")
    check(ThinkPoseLook.resolve(.quiet, hasFocusClip: false, hasWeatherClip: rainy) == .quietStill, "bubble: quiet")
    check(ThinkPoseLook.resolve(.focus, hasFocusClip: true, hasWeatherClip: rainy) == .focusClip, "bubble: focus clip")
    check(ThinkPoseLook.resolve(.focus, hasFocusClip: false, hasWeatherClip: rainy) == .focusStill, "bubble: focus without clip = still + 🍅")
    check(ThinkPoseLook.resolve(.dnd, hasFocusClip: false, hasWeatherClip: rainy) == .dndStill, "bubble: dnd")
    check(ThinkPoseLook.resolve(.weather(.rain), hasFocusClip: false, hasWeatherClip: rainy) == .weatherClip(.rain), "bubble: weather clip")
    check(ThinkPoseLook.resolve(.weather(.snow), hasFocusClip: false, hasWeatherClip: rainy) == .idleLoop, "bubble: weather without clip = idle")
    check(ThinkPoseLook.dndSign(DNDStatus(mood: "angry", untilMs: 0)) == "😤 生气中" && ThinkPoseLook.dndSign(nil) == "🔕 勿扰中"
          && ThinkPoseLook.dndSign(DNDStatus(mood: "newmood", untilMs: 0)) == "🔕 勿扰中", "bubble: dnd sign from TA's mood")

    let have = ["lace", "pajama", "bear"]
    check(ThinkOutfit.pick(published: "pajama", lastMessage: "bear", available: have, preferred: "lace") == "pajama", "outfit: published first")
    check(ThinkOutfit.pick(published: "nope", lastMessage: "bear", available: have, preferred: "lace") == "bear", "outfit: unknown published → last message")
    check(ThinkOutfit.pick(published: nil, lastMessage: "nope", available: have, preferred: "lace") == "lace", "outfit: → preferred")
    check(ThinkOutfit.pick(published: nil, lastMessage: nil, available: have, preferred: nil) == "lace" && ThinkOutfit.pick(published: "x", lastMessage: nil, available: [], preferred: nil) == nil, "outfit: first available / none")
}

try? FileManager.default.removeItem(at: tmp)
// UserDefaults suites leave their plist behind even after removePersistentDomain; delete test ones.
let prefsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
for f in (try? FileManager.default.contentsOfDirectory(atPath: prefsDir.path)) ?? [] where f.hasPrefix("lulupet.test-") {
    try? FileManager.default.removeItem(at: prefsDir.appendingPathComponent(f))
}
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
