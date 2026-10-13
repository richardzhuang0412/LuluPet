// Two-character clips (couples.json): both pets are hidden while one sprite stands in for them, centred between
// them, drawn at the pets' height × the clip's heightFactor and mirrored so each character lands on its own side.

import { Actor } from "./pet.js";

/** couple = catalog couple {clip, heightFactor}; → the stand-in actor (already playing). */
export function playCouple(world, { couple, centerX, mirrored, baseH, speed = 1, done }) {
  const a = new Actor(world, "couple");
  const clip = couple.clip;
  a.clips = { idle: clip, idleHeight: clip.src?.[1] || clip.h, action: () => null, named: () => null };
  a.heightFactor = couple.heightFactor || 1;
  a.setBaseHeight(baseH);
  a.setX(centerX);
  world.layer.append(a.el);
  a.setMirrored(mirrored);
  a.busy = true;
  a.player.play(clip, {
    speed,
    onEnd: () => {
      a.player.stop();
      a.el.remove();
      done?.();
    },
  });
  return a;
}
