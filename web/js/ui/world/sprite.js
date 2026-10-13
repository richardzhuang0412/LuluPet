// Canvas player for the manifest's sprite sheets (per-frame delays, so no CSS steps()). Played frame i shows cell
// seq[i] for delays[i] s. Timers come from the world's rehomable timer set, so playback keeps going when the world
// moves into the PiP window. Nothing is drawn while the document is hidden.

const images = new Map();   // url → Promise<HTMLImageElement>

/** A sprite sheet image, fetched once (any same-origin document can draw it). */
export function loadImage(doc, url) {
  if (!images.has(url)) {
    images.set(url, new Promise((resolve, reject) => {
      const img = doc.createElement("img");
      img.decoding = "async";
      img.onload = () => resolve(img);
      img.onerror = () => { images.delete(url); reject(new Error("image " + url)); };
      img.src = url;
    }));
  }
  return images.get(url);
}

export class SpritePlayer {
  /** `url(file)` → absolute URL of a manifest file. */
  constructor(canvas, timers, url) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.timers = timers;
    this.url = url;
    this.timer = 0;
    this.token = 0;
    this.current = null;
    /** Called once the first frame of a new clip is on the canvas (the actor sizes itself then). */
    this.onClip = null;
  }

  /**
   * Plays `clip` (manifest clip meta). loop=false → onEnd() after the last frame; still=true → `frame` (default 0)
   * only. `speed` > 1 plays faster.
   */
  async play(clip, opts = {}) {
    const token = ++this.token;
    this.timers.cancel(this.timer);
    this.current = null;
    if (!clip) { opts.onEnd?.(); return; }
    let img;
    try { img = await loadImage(this.canvas.ownerDocument, this.url(clip.file)); } catch { if (token === this.token) opts.onEnd?.(); return; }
    if (token !== this.token) return;
    if (this.canvas.width !== clip.w || this.canvas.height !== clip.h) {
      this.canvas.width = clip.w;
      this.canvas.height = clip.h;
    }
    const frames = clip.seq?.length || clip.frames || 1;
    this.current = { clip, opts, frame: Math.min(opts.frame || 0, frames - 1) };
    this.onClip?.(clip);
    const step = () => {
      if (token !== this.token) return;
      const cur = this.current;
      const i = cur.frame;
      if (this.canvas.ownerDocument.hidden) {
        // Unseen: draw nothing, but a one-shot clip still ends on time (a visit must not stall in a hidden tab).
        if (opts.still || opts.loop) { this.timer = this.timers.after(1000, step); return; }
        let rest = 0;
        for (let k = i; k < frames; k++) rest += Math.max(20, ((clip.delays?.[k] ?? 0.1) * 1000) / (opts.speed || 1));
        this.timer = this.timers.after(rest, () => { if (token === this.token) { this.current = null; opts.onEnd?.(); } });
        return;
      }
      const cell = clip.seq ? clip.seq[i] : i;
      const sx = (cell % clip.cols) * clip.w, sy = Math.floor(cell / clip.cols) * clip.h;
      this.ctx.clearRect(0, 0, clip.w, clip.h);
      this.ctx.drawImage(img, sx, sy, clip.w, clip.h, 0, 0, clip.w, clip.h);
      if (opts.still) return;
      const delay = Math.max(20, ((clip.delays?.[i] ?? 0.1) * 1000) / (opts.speed || 1));
      if (i + 1 >= frames && !opts.loop) {
        this.timer = this.timers.after(delay, () => { if (token === this.token) { this.current = null; opts.onEnd?.(); } });
        return;
      }
      cur.frame = (i + 1) % frames;
      this.timer = this.timers.after(delay, step);
    };
    step();
  }

  /** Total play time of a clip in ms (one pass). */
  static durationMs(clip, speed = 1) {
    const n = clip?.seq?.length || clip?.frames || 0;
    let s = 0;
    for (let i = 0; i < n; i++) s += Math.max(0.02, clip.delays?.[i] ?? 0.1);
    return (s * 1000) / speed;
  }

  stop() {
    this.token++;
    this.timers.cancel(this.timer);
    this.current = null;
  }
}
