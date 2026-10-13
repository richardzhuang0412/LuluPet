// 连接 (first run, and 设置 → 连接 → 改连接设置): database URL, pair code, seat confirmation (read both seats first —
// taking TA's seat is the most likely accident), 「清除本机设置」. The config never goes into the URL.

import { h, setChildren, ago } from "./dom.js";
import { pairCode, checkDatabaseURL, deleteHistory } from "./deps.js";
import { store } from "./store.js";
import { outfitLabel } from "./assets.js";

const SEAT_NAME = { lulu: "噜噜座", lumei: "噜妹座" };

/** GET /pairs/{code}/presence.json → {lulu, lumei} (10 s timeout). Throws {status} / Error. */
export async function readSeats(db, code) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 10_000);
  try {
    const r = await fetch(`${db}/pairs/${encodeURIComponent(code)}/presence.json`, { signal: ctl.signal, cache: "no-store" });
    if (!r.ok) throw Object.assign(new Error("http"), { status: r.status });
    const j = await r.json();
    return { lulu: j?.lulu ?? null, lumei: j?.lumei ?? null };
  } finally {
    clearTimeout(t);
  }
}

function seatLine(seat, p) {
  if (!p || typeof p !== "object") return `${SEAT_NAME[seat]}：还没人坐过`;
  const parts = [];
  const seen = typeof p === "number" ? p : p.lastSeen;
  if (seen > 0) parts.push(Date.now() - seen <= 75_000 ? "现在在线" : `最后在线 ${ago(seen)}`);
  else parts.push("已签退");
  const ch = p.character === "lulu" || p.character === "lumei" ? p.character : seat;
  const ol = typeof p.outfit === "string" ? outfitLabel(ch, p.outfit) : "";
  if (ol) parts.push(`造型 ${ol}`);
  if (typeof p.place?.name === "string") parts.push(p.place.name.slice(0, 64));
  if (typeof p.device === "string" && p.device.startsWith("web-")) parts.push("网页版");
  return `${SEAT_NAME[seat]}：${parts.join(" · ")}`;
}

function errorLine(e) {
  const s = e?.status;
  if (s === 404) return "数据库地址有误 (HTTP 404)";
  if (s === 401 || s === 403) return `数据库规则拒绝访问 (HTTP ${s})`;
  if (s === 400) return "数据库规则缺少 ts 索引 (HTTP 400)";
  if (s) return `读不到座位 (HTTP ${s})`;
  return "网络断开，读不到座位（公司网络或代理可能拦了 firebaseio.com）";
}

/**
 * The settings form. `onSave(config)` when a seat is confirmed; `seatsReader(db, code)` (dev swaps a fake one);
 * `reminders` = the running createReminders() (or null before the first config).
 */
export function createSetup({ current, onSave, seatsReader = readSeats }) {
  const dbInput = h("input#db", { type: "url", inputmode: "url", autocomplete: "off", spellcheck: "false",
    placeholder: "https://<项目>.firebaseio.com", value: current?.databaseURL ?? "" });
  const codeInput = h("input#code", { type: "text", autocomplete: "off", spellcheck: "false", autocapitalize: "characters",
    placeholder: "24 位配对码", value: current?.pairCode ?? "", maxlength: "40" });
  const dbMsg = h("div.field-msg");
  const codeMsg = h("div.field-msg");
  const seatBox = h("div.seat-box", { hidden: true });
  const readBtn = h("button.btn.primary", { type: "button", onclick: () => read() }, "下一步：选座位");

  function checkDb() {
    const raw = dbInput.value.trim();
    const v = raw ? checkDatabaseURL(raw) : null;
    dbMsg.textContent = !raw ? "" : v.url ? "数据库地址没问题 ✓" : v.reason;
    dbMsg.className = "field-msg " + (!raw ? "" : v.url ? "ok" : "bad");
    return v?.url ?? null;
  }
  function checkCode() {
    const raw = codeInput.value;
    const n = pairCode.normalize(raw);
    const ok = n && pairCode.isValid(n);
    codeMsg.textContent = !raw.trim() ? "" : ok ? "配对码没问题 ✓" : "配对码要 24 位：大写字母和数字，不含 0、O、1、I（大小写、空格没关系）";
    codeMsg.className = "field-msg " + (!raw.trim() ? "" : ok ? "ok" : "bad");
    return ok ? n : null;
  }
  dbInput.addEventListener("input", checkDb);
  codeInput.addEventListener("input", checkCode);

  async function read() {
    const db = checkDb(), code = checkCode();
    if (!db || !code) {
      if (!db) dbMsg.textContent ||= "请先填数据库地址";
      if (!code) codeMsg.textContent ||= "请先填配对码";
      return;
    }
    readBtn.disabled = true;
    setChildren(seatBox, h("div.muted", "正在读两个座位…"));
    seatBox.hidden = false;
    try {
      const seats = await seatsReader(db, code);
      showSeats(db, code, seats);
    } catch (e) {
      setChildren(seatBox, h("div.field-msg.bad", "未连接：" + errorLine(e)));
    } finally {
      readBtn.disabled = false;
    }
  }

  function showSeats(db, code, seats) {
    let picked = current?.pairCode === code ? current.seat : null;
    const confirm = h("button.btn.primary", { type: "button", disabled: !picked, onclick: () => {
      if (!picked) return;
      const cfg = { databaseURL: db, pairCode: code, seat: picked };
      store.set("config", cfg);
      onSave(cfg);
    } }, current ? "保存" : "开始");
    const options = ["lulu", "lumei"].map((seat) => {
      const radio = h("input", { type: "radio", name: "seat", value: seat, checked: picked === seat });
      radio.addEventListener("change", () => { picked = seat; confirm.disabled = false; });
      return h("label.seat-option", radio, h("span.seat-text", seatLine(seat, seats[seat])));
    });
    setChildren(seatBox,
      h("div.seat-q", "我的 Mac 坐的是哪一边？"),
      h("div.muted.small", "选你自己那台 Mac 的座位（看「最后在线」和造型认一下）。选错会抢 TA 的座位。"),
      options,
      h("div.row-end", confirm));
  }

  const clearBtn = h("button.btn.danger", { type: "button", onclick: () => {
    if (!window.confirm("清除这个浏览器里的噜噜设置（数据库地址、配对码、座位、已读位置、未发出的消息、聊天记录）？")) return;
    store.clearAll();
    Promise.resolve(deleteHistory()).catch(() => {}).finally(() => location.reload());
  } }, "清除本机设置");

  const el = h("section.setup", { "aria-label": "设置" },
    h("h2", current ? "连接" : "第一次用：连上你们的噜噜"),
    h("p.muted", "和 Mac 上 🍊 → 设置 → 通用 里填的一样。只存在这个浏览器里，不会出现在网址里。"),
    h("label.field", h("span.field-label", "Firebase 数据库地址"), dbInput, dbMsg),
    h("label.field", h("span.field-label", "配对码"), codeInput, codeMsg),
    h("div.row-end", readBtn),
    seatBox,
    current ? h("div.row-end", clearBtn) : null);

  checkDb();
  checkCode();
  return { el };
}
