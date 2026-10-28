// Frame sampling (pure). The Pixoo plays an uploaded animation with ONE speed for all frames (PicSpeed, ms per
// frame) and takes at most 59 frames (Divoom doc: PicNum "smaller than 60"); every frame is one HTTP request, so we
// keep animations short. A clip's per-frame delays (manifest `delays`, seconds) are turned into N evenly timed
// samples: N = min(maxFrames, frames), each sample shows the frame that is on screen at the middle of its slot, so
// frames are dropped evenly and the total duration stays the same.

export const MIN_FRAME_MS = 50;
export const MAX_FRAME_MS = 2000;

/**
 * clip = {seq: [cell…], delays: [seconds…]} (manifest clip). → {cells: [cell index…], frameMs}.
 * `cells.length * frameMs` ≈ the clip's total duration (unless clamped by MIN/MAX_FRAME_MS).
 */
export function sampleClip(clip, maxFrames = 40) {
  const seq = Array.isArray(clip.seq) && clip.seq.length ? clip.seq : [0];
  const delays = seq.map((_, i) => {
    const d = Number(clip.delays?.[i]);
    return Number.isFinite(d) && d > 0 ? d * 1000 : 100;
  });
  const total = delays.reduce((a, b) => a + b, 0);
  if (seq.length === 1) return { cells: [seq[0]], frameMs: clampMs(total) };
  let n = Math.max(1, Math.min(maxFrames, seq.length));
  if (total / n < MIN_FRAME_MS) n = Math.max(1, Math.floor(total / MIN_FRAME_MS));
  const frameMs = total / n;
  const cells = [];
  let j = 0, end = delays[0];
  for (let i = 0; i < n; i++) {
    const t = (i + 0.5) * frameMs;
    while (t >= end && j < seq.length - 1) { j++; end += delays[j]; }
    cells.push(seq[j]);
  }
  return { cells, frameMs: clampMs(Math.round(frameMs)) };
}

/**
 * The first `n` frames at the clip's own pace (no stretching): for text pages, where only a few frames can be
 * uploaded per page. The renderer plays them forward and back (ping-pong) so the loop has no jump.
 */
export function sampleWindow(clip, n) {
  const seq = Array.isArray(clip.seq) && clip.seq.length ? clip.seq : [0];
  const k = Math.max(1, Math.min(n, seq.length));
  const ms = seq.slice(0, k).map((_, i) => {
    const d = Number(clip.delays?.[i]);
    return Number.isFinite(d) && d > 0 ? d * 1000 : 100;
  });
  return { cells: seq.slice(0, k), frameMs: clampMs(ms.reduce((a, b) => a + b, 0) / k) };
}

/** [a, b, c, d] → [a, b, c, d, c, b]: loops smoothly. */
export function pingPong(frames) {
  return frames.length > 2 ? [...frames, ...frames.slice(1, -1).reverse()] : frames.slice();
}

function clampMs(ms) {
  return Math.min(MAX_FRAME_MS, Math.max(MIN_FRAME_MS, Math.round(ms)));
}
