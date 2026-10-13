// 「想 TA」 / 「偷看」 thought cloud (port of ThinkBubbleWindow): three little circles rise from my pet's head, a cloud
// pops in with TA's character drawn as on TA's desk (outfit + pose), a pill with TA's city / weather / local time
// under it, and a tiny weather flourish. 6 s (a peek: 9 s, and a click closes it).
//
// scene = {character, outfit, pose, dndSign?, bar?, flourish?: "rain"|"snow"|"sun"|"none"}

import { h } from "./dom.js";
import { SpritePlayer } from "./sprite.js";
import { thinkLook, toolClipPool } from "./rules.js";

/** What the cloud draws for TA's pose → {clip, still, dim, badge: {sign|tiny}} (null without sprites). */
export function sceneLook(catalog, scene, roll = (n) => Math.floor(Math.random() * n)) {
  const c = catalog.characterOf(scene?.character);
  const o = catalog.outfit(c, scene?.outfit);
  if (!o?.idle) return null;
  const focus = (catalog.toolPool("focus", c) ?? toolClipPool("focus", c)).map((n) => o.named(n)).find(Boolean)?.clip || null;
  const kind = thinkLook(scene?.pose, !!focus, (look) => catalog.weather(c, look).length > 0);
  const quiet = o.action("quiet") || o.idle;
  if (kind === "dozeStill") {
    const sleep = o.action("sleep");
    return sleep ? { clip: sleep, still: true, badge: { tiny: "z z" } } : { clip: o.idle, still: true, dim: true, badge: { tiny: "z z" } };
  }
  if (kind === "quietStill") return { clip: quiet, still: true };
  if (kind === "focusClip") return { clip: focus, loop: true };
  if (kind === "focusStill") return { clip: quiet, still: true, badge: { tiny: "🍅" } };
  if (kind === "dndStill") return { clip: quiet, still: true, badge: { sign: scene?.dndSign || "🔕 勿扰中" } };
  if (kind && typeof kind === "object" && kind.weather) {
    const list = catalog.weather(c, kind.weather);
    return { clip: list[Math.min(list.length - 1, roll(list.length))].clip, loop: true };
  }
  return { clip: o.idle, loop: true };
}

export function createThink(world) {
  let box = null;
  let player = null;
  let closeTimer = 0;
  let onDone = null;

  function close() {
    world.timers.cancel(closeTimer);
    player?.stop();
    player = null;
    if (box) {
      const b = box;
      box = null;
      b.classList.add("out");
      world.timers.after(350, () => b.remove());
    }
    const done = onDone;
    onDone = null;
    done?.();
  }

  /** Shows the cloud over `anchor` (my pet). → false when there is nothing to draw. */
  function show({ scene, peek, durationMs, anchor, done }) {
    const look = sceneLook(world.catalog, scene);
    if (!look) return false;
    if (box) close();
    const doc = world.doc;
    const canvas = h(doc, "canvas.lw-canvas");
    const charBox = h(doc, "div.lw-think-char", canvas);
    const kids = [h(doc, "div.lw-think-dot.d1"), h(doc, "div.lw-think-dot.d2"), h(doc, "div.lw-think-dot.d3")];
    const flourish = scene.flourish && scene.flourish !== "none" ? scene.flourish : null;
    const cloud = h(doc, "div.lw-think-cloud", flourish ? h(doc, "div.lw-flourish." + flourish) : null, charBox);
    if (look.badge?.sign) cloud.append(h(doc, "div.lw-think-sign", look.badge.sign));
    if (look.badge?.tiny) cloud.append(h(doc, "div.lw-think-tiny", look.badge.tiny));
    if (scene.bar) cloud.append(h(doc, "div.lw-think-bar", scene.bar));
    kids.push(cloud);
    box = h(doc, "div.lw-think" + (peek ? ".peek" : ""), { "aria-label": peek ? "偷看 TA" : "想 TA" }, kids);
    if (peek) box.addEventListener("click", (e) => { e.stopPropagation(); close(); });
    world.layer.append(box);
    // Place: the dots start at my pet's head; the cloud leans to the side with more room.
    const W = world.width, H = world.height;
    const cw = Math.min(170, W - 16), ch = Math.min(150, H - 24);
    box.style.setProperty("--cw", cw + "px");
    box.style.setProperty("--ch", ch + "px");
    const headX = anchor.liveX, headY = Math.min(H - 10, anchor.height * 0.92);
    const toLeft = headX > W / 2;
    const cloudLeft = Math.min(Math.max(6, toLeft ? headX - cw - 10 : headX + 10), W - cw - 6);
    box.style.setProperty("--hx", headX.toFixed(0) + "px");
    box.style.setProperty("--hy", headY.toFixed(0) + "px");
    box.style.setProperty("--dir", toLeft ? "-1" : "1");
    cloud.style.left = cloudLeft.toFixed(0) + "px";
    cloud.style.bottom = Math.max(4, Math.min(H - ch - 4, headY - 10)).toFixed(0) + "px";
    // TA's sprite, about 45 % of the cloud's height.
    player = new SpritePlayer(canvas, world.timers, world.catalog.url);
    const o = world.catalog.outfit(scene.character, scene.outfit);
    player.onClip = (clip) => {
      const k = clip.src?.[1] && o ? clip.src[1] / o.idleHeight : 1;
      const ph = ch * 0.5 * k;
      canvas.style.height = ph.toFixed(0) + "px";
      canvas.style.width = (ph * clip.w / clip.h).toFixed(0) + "px";
    };
    if (look.dim) charBox.classList.add("dim");
    player.play(look.clip, { loop: !look.still, still: look.still });
    onDone = done || null;
    closeTimer = world.timers.after(durationMs, close);
    return true;
  }

  return { show, close, get showing() { return !!box; } };
}
