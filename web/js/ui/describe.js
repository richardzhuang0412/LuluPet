// Text for a message (notifications, the away card, the 记录 tab); moved out of the v1 stage.js.

import { nameOf } from "./dom.js";
import { stickerById } from "./assets.js";
import { UNKNOWN_KIND, decodeReply, replyLine, unknownStickerText, reminderKind, remindBubble } from "./deps.js";

/** Text for a message bubble (also used by notifications and the away card). */
export function describe(msg) {
  const name = nameOf(msg.character || msg.from);
  if (msg.kind === "text") return { line: msg.text ?? "" };
  if (msg.kind === "sticker") {
    const s = stickerById(msg.stickerId);
    return s ? { line: s.label, sticker: s } : { line: unknownStickerText(msg) };
  }
  if (msg.kind === "poke") return { line: `${name}给你发了一颗爱心 ❤️` };
  if (msg.kind === "visit") return { line: `${name}跑来找你玩啦` };
  const kind = reminderKind(msg);
  if (kind) {
    const b = remindBubble(kind, name);
    return { line: b.line, header: b.header, remind: kind };
  }
  const reply = decodeReply(msg);
  if (reply) return { line: replyLine(reply) };
  return { line: UNKNOWN_KIND };
}
