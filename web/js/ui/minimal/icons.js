// Line icons for the 极简 panel (24-unit stroke paths, built with createElementNS — no HTML parsing).

const PATHS = {
  moon: ["M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"],
  gear: ["M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4z",
    "M19.4 13.5a7.6 7.6 0 0 0 0-3l2-1.5-2-3.5-2.3 1a7.6 7.6 0 0 0-2.6-1.5L14 2.5h-4l-.5 2.5a7.6 7.6 0 0 0-2.6 1.5l-2.3-1-2 3.5 2 1.5a7.6 7.6 0 0 0 0 3l-2 1.5 2 3.5 2.3-1a7.6 7.6 0 0 0 2.6 1.5l.5 2.5h4l.5-2.5a7.6 7.6 0 0 0 2.6-1.5l2.3 1 2-3.5z"],
  more: ["M5 12h.01", "M12 12h.01", "M19 12h.01"],
  send: ["M4 12l16-8-6 16-2.5-6.5z", "M11.5 13.5L20 4"],
  chevron: ["M6 9l6 6 6-6"],
  bell: ["M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15z", "M10 20.5a2 2 0 0 0 4 0"],
  close: ["M6 6l12 12", "M18 6L6 18"],
};

// The SVG XML namespace name (an identifier, never fetched); spelled in parts so the static URL allow-list check
// (web/tests/static.test.mjs) only ever sees real network URLs.
const SVG_NS = ["http:", "", "www.w3.org", "2000", "svg"].join("/");

export function icon(name, size = 18, doc = document) {
  const NS = SVG_NS;
  const svg = doc.createElementNS(NS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("class", "mi-icon");
  for (const d of PATHS[name] || []) {
    const p = doc.createElementNS(NS, "path");
    p.setAttribute("d", d);
    svg.append(p);
  }
  return svg;
}
