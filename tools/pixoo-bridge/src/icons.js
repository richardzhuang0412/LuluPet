// Small hand-drawn pixel icons (our own drawings, no third-party art): emoji that appear in LuluPet lines
// (「喝水啦 💧」「起来动动 🧍」「TA 说等会儿再喝 ⏰」…), status badges and the poke hearts.
// Each icon: rows of characters, "." = transparent, other characters index `palette`.

const PALETTE = {
  r: [235, 50, 70],     // heart red
  p: [255, 120, 150],   // pink
  w: [255, 255, 255],
  b: [70, 150, 255],    // water blue
  c: [150, 210, 255],   // light blue highlight
  y: [255, 205, 60],    // yellow
  o: [255, 140, 40],    // orange
  g: [70, 190, 90],     // green
  k: [120, 120, 130],   // grey
  t: [230, 70, 50],     // tomato red
  s: [250, 200, 160],   // skin
  n: [90, 120, 220],    // navy-ish (clothes)
};

const ICONS = {
  drop: [
    "....b....",
    "....b....",
    "...bbb...",
    "...bbb...",
    "..bbbbb..",
    "..bcbbb..",
    "..bcbbb..",
    "...bbb...",
    ".........",
  ],
  heart: [
    ".rr.rr.",
    "rrrrrrr",
    "rrrrrrr",
    ".rrrrr.",
    "..rrr..",
    "...r...",
  ],
  heartSmall: [
    "p.p",
    "ppp",
    ".p.",
  ],
  heart9: [
    ".........",
    ".rr...rr.",
    "rrrr.rrrr",
    "rrrrrrrrr",
    ".rrrrrrr.",
    "..rrrrr..",
    "...rrr...",
    "....r....",
    ".........",
  ],
  person: [
    "...ss....",
    "...ss....",
    "..nnnn...",
    ".n.nn.n..",
    "...nn....",
    "...nn....",
    "...n.n...",
    "...n.n...",
    ".........",
  ],
  clock: [
    "..kkkkk..",
    ".kwwwwwk.",
    "kwwwkwwwk",
    "kwwwkwwwk",
    "kwwwkkwwk",
    "kwwwwwwwk",
    ".kwwwwwk.",
    "..kkkkk..",
    ".........",
  ],
  bellOff: [
    "...y...k",
    "..yyy.k.",
    ".yyyyk..",
    ".yyyky..",
    ".yykyy..",
    "yykyyyy.",
    ".k......",
    "k..yy...",
  ],
  tomato: [
    "..g.g..",
    "...g...",
    ".ttttt.",
    "ttttttt",
    "ttwtttt",
    "ttttttt",
    ".ttttt.",
  ],
  sparkle: [
    "....y....",
    "....y....",
    "...yyy...",
    "yyyyyyyyy",
    "...yyy...",
    "....y....",
    "....y....",
    ".........",
    ".........",
  ],
  moon: [
    "...yyy...",
    "..yy.....",
    ".yy......",
    ".yy......",
    ".yy......",
    "..yy.....",
    "...yyy...",
    ".........",
    ".........",
  ],
  smile: [
    "..yyyyy..",
    ".yyyyyyy.",
    "yykyyykyy",
    "yyyyyyyyy",
    "yyyyyyyyy",
    "yykyyykyy",
    ".yykkkyy.",
    "..yyyyy..",
    ".........",
  ],
};

function compile(rows) {
  const h = rows.length, w = Math.max(...rows.map((r) => r.length));
  const px = [];
  rows.forEach((row, y) => {
    for (let x = 0; x < row.length; x++) {
      const c = PALETTE[row[x]];
      if (c) px.push([x, y, c]);
    }
  });
  return { w, h, px };
}

export const icons = Object.fromEntries(Object.entries(ICONS).map(([k, v]) => [k, compile(v)]));

/** Emoji code point → icon name (drawn in colour instead of the font). Others with no glyph are skipped. */
export const EMOJI_ICONS = new Map([
  [0x1f4a7, "drop"],      // 💧
  [0x2764, "heart9"],     // ❤
  [0x1f495, "heart9"],    // 💕
  [0x1f496, "heart9"],    // 💖
  [0x1f497, "heart9"],    // 💗
  [0x1f49e, "heart9"],    // 💞
  [0x1f970, "heart9"],    // 🥰
  [0x2665, "heart9"],     // ♥
  [0x1f9cd, "person"],    // 🧍
  [0x23f0, "clock"],      // ⏰
  [0x1f515, "bellOff"],   // 🔕
  [0x1f345, "tomato"],    // 🍅
  [0x2728, "sparkle"],    // ✨
  [0x1f319, "moon"],      // 🌙
  [0x1f60a, "smile"],     // 😊
  [0x1f604, "smile"],     // 😄
  [0x1f600, "smile"],     // 😀
]);
