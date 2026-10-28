// Scene → segments of 64×64 RGB frames. A segment is one Pixoo animation (uploaded once, looped by the device):
//   {frames: [Uint8Array(64*64*3)…], frameMs, holdMs, label}
// holdMs = how long to leave it on screen (Infinity for idle). Text longer than one page becomes one segment per
// page (each page is a new upload), so keep `textFrames` small.

import { newFrame, blit, drawIcon, drawZ, setPx, SIZE } from "./canvas.js";
import { layoutPages, drawLine, width } from "./font.js";
import { pingPong } from "./frames.js";

export const LAYOUT = Object.freeze({
  full: { boxW: 64, boxH: 60, bottom: 63 },     // character alone
  top: { boxW: 64, boxH: 38, bottom: 39 },      // character above two text lines
  textWidth: 62,
  lineBaselines: [50, 62],
  textColor: [255, 244, 228],
  lineColor: [255, 214, 120],
});

const RUN_IN_MS = 1400;
const RUN_IN_REST_FRAMES = 4;

export class Renderer {
  constructor({ assets, font, cfg }) {
    this.assets = assets;
    this.font = font;
    this.cfg = cfg;
  }

  async character(scene, layout, maxFrames, still = false) {
    return this.assets.clipFrames(scene.clip, { boxW: layout.boxW, boxH: layout.boxH, maxFrames, refKey: scene.refClip, still });
  }

  /** → {segments, totalMs} */
  async render(scene) {
    switch (scene.kind) {
      case "idle": return this.idle(scene);
      case "poke": return this.poke(scene);
      case "sticker": return this.sticker(scene);
      case "visit": return this.visit(scene);
      case "text": return this.captioned(scene, scene.text, LAYOUT.textColor);
      case "remind":
      case "unknown": return this.captioned(scene, scene.line, LAYOUT.lineColor);
      default: throw new Error(`unknown scene kind ${scene.kind}`);
    }
  }

  async idle(scene) {
    const ch = await this.character(scene, LAYOUT.full, this.cfg.maxFrames, !!scene.still);
    const place = (s) => ({ x: Math.round((SIZE - s.w) / 2), y: LAYOUT.full.bottom + 1 - s.h });
    let frames, frameMs = ch.frameMs;
    if (scene.zzz) {
      // dimmed still + a slowly growing "Zzz"
      frameMs = 700;
      frames = [0, 1, 2, 3].map((k) => {
        const f = newFrame();
        const s = ch.frames[0];
        const p = place(s);
        blit(f, s, p.x, p.y, scene.dim ?? 1);
        const c = [170, 190, 255];
        if (k >= 1) drawZ(f, 50, 14, 3, c);
        if (k >= 2) drawZ(f, 54, 8, 4, c);
        if (k >= 3) drawZ(f, 58, 1, 5, c);
        return f.data;
      });
    } else {
      frames = ch.frames.map((s) => {
        const f = newFrame();
        const p = place(s);
        blit(f, s, p.x, p.y, scene.dim ?? 1);
        if (scene.badge === "dnd") drawIcon(f, "bellOff", 55, 1);
        if (scene.badge === "focus") drawIcon(f, "tomato", 56, 1);
        return f.data;
      });
      if (scene.still) frameMs = 1000;
    }
    return { segments: [{ frames, frameMs, holdMs: Infinity, label: scene.key ?? "idle" }], totalMs: Infinity };
  }

  async poke(scene) {
    const ch = await this.character(scene, LAYOUT.full, this.cfg.maxFrames);
    const n = ch.frames.length;
    const loopMs = n * ch.frameMs;
    const cycles = Math.max(1, Math.round(loopMs / 2400));
    const hearts = [
      { x: 3, phase: 0, icon: "heart" },
      { x: 54, phase: 0.33, icon: "heart" },
      { x: 10, phase: 0.66, icon: "heartSmall" },
      { x: 50, phase: 0.15, icon: "heartSmall" },
    ];
    const frames = ch.frames.map((s, i) => {
      const f = newFrame();
      blit(f, s, Math.round((SIZE - s.w) / 2), LAYOUT.full.bottom + 1 - s.h);
      for (const h of hearts) {
        const t = ((i / n) * cycles + h.phase) % 1;
        const y = 54 - t * 52;
        const x = h.x + Math.round(Math.sin(t * Math.PI * 4) * 2);
        const fade = t < 0.8 ? 1 : (1 - t) / 0.2;
        drawIcon(f, h.icon, x, y, fade);
      }
      return f.data;
    });
    return { segments: [{ frames, frameMs: ch.frameMs, holdMs: scene.durationMs, label: "poke" }], totalMs: scene.durationMs };
  }

  async sticker(scene) {
    const label = this.cfg.stickerLabel && scene.label ? layoutPages(this.font, scene.label, { maxWidth: LAYOUT.textWidth, perPage: 1, maxPages: 1 }) : null;
    const withLabel = label && !label.truncated && label.pages[0][0].length > 0;
    const boxH = withLabel ? 50 : 64;
    const st = await this.assets.stickerFrames(scene.sticker, { boxW: 64, boxH, maxFrames: this.cfg.maxFrames });
    const frames = st.frames.map((s) => {
      const f = newFrame();
      blit(f, s, Math.round((SIZE - s.w) / 2), Math.round((boxH - s.h) / 2));
      if (withLabel) {
        const line = label.pages[0][0];
        drawLine(f, this.font, line, Math.round((SIZE - width(line)) / 2), 62, LAYOUT.lineColor);
      }
      return f.data;
    });
    return { segments: [{ frames, frameMs: st.frameMs, holdMs: scene.durationMs, label: `sticker:${scene.sticker}` }], totalMs: scene.durationMs };
  }

  async visit(scene) {
    const ch = await this.character(scene, LAYOUT.top, this.cfg.maxFrames);
    const frameMs = ch.frameMs;
    const moving = Math.max(4, Math.ceil(RUN_IN_MS / frameMs));
    const n = Math.min(this.cfg.maxFrames, moving + RUN_IN_REST_FRAMES);
    const run = [];
    for (let i = 0; i < n; i++) {
      const s = ch.frames[i % ch.frames.length];
      const endX = Math.round((SIZE - s.w) / 2);
      const t = Math.min(1, i / (n - RUN_IN_REST_FRAMES));
      const ease = 1 - (1 - t) ** 2;
      const x = Math.round(-s.w + (endX + s.w) * ease);
      const f = newFrame();
      blit(f, s, x, LAYOUT.top.bottom + 1 - s.h);
      if (t < 1) {   // a little dust behind the feet
        const c = [110, 100, 90];
        setPx(f, x - 2 - (i % 2), LAYOUT.top.bottom - 1, c);
        setPx(f, x - 4 + (i % 2), LAYOUT.top.bottom, c);
      }
      run.push(f.data);
    }
    const runMs = n * frameMs;
    const rest = await this.captioned({ ...scene, durationMs: Math.max(1000, scene.durationMs - runMs) }, scene.line, LAYOUT.lineColor, ch);
    return {
      segments: [{ frames: run, frameMs, holdMs: runMs, label: "visit:run-in" }, ...rest.segments],
      totalMs: runMs + rest.totalMs,
    };
  }

  /** Character on top, `text` paged below (2 lines per page). */
  async captioned(scene, text, color, ch = null) {
    const { textPageMs = 5000, textMaxPages = 12 } = this.cfg.durations ?? {};
    const { pages } = layoutPages(this.font, text, { maxWidth: LAYOUT.textWidth, perPage: 2, maxPages: textMaxPages });
    if (pages.length > 1) {
      // every page is a new upload: a few frames at the clip's own pace, played forward and back
      const unique = Math.max(1, Math.floor((this.cfg.textFrames + 2) / 2));
      const w = await this.assets.clipFrames(scene.clip, { boxW: LAYOUT.top.boxW, boxH: LAYOUT.top.boxH, maxFrames: unique, refKey: scene.refClip, window: true });
      ch = { frames: pingPong(w.frames), frameMs: w.frameMs };
    } else if (!ch) ch = await this.character(scene, LAYOUT.top, this.cfg.maxFrames);
    const total = Math.max(scene.durationMs ?? 0, pages.length * textPageMs);
    const segments = pages.map((page, pi) => {
      const frames = ch.frames.map((s) => {
        const f = newFrame();
        blit(f, s, Math.round((SIZE - s.w) / 2), LAYOUT.top.bottom + 1 - s.h);
        page.forEach((line, li) => {
          drawLine(f, this.font, line, Math.max(1, Math.round((SIZE - width(line)) / 2)), LAYOUT.lineBaselines[li], color);
        });
        if (pages.length > 1) pageDots(f, pi, pages.length);
        return f.data;
      });
      const holdMs = pi === pages.length - 1 ? total - textPageMs * (pages.length - 1) : textPageMs;
      return { frames, frameMs: ch.frameMs, holdMs, label: `${scene.kind}:page ${pi + 1}/${pages.length}` };
    });
    return { segments, totalMs: total };
  }
}

function pageDots(f, current, count) {
  const x0 = SIZE - 1 - (count - 1) * 2;
  for (let i = 0; i < count; i++) setPx(f, x0 + i * 2, 0, i === current ? [255, 255, 255] : [70, 70, 70]);
}

