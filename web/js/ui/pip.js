// 置顶小窗 (Document PiP, spec §3.2): the world element is moved — whole, state and all — into an always-on-top window
// with a mini bar (❤️ 💬 👁️ ↩︎). 💬 grows it to 360×560 with the compose panel inside; ↩︎ closes it and focuses the app
// window. Closing the PiP (pagehide) puts everything back. The main document's JS drives the PiP DOM.
// ?dev=pip renders the same layout in a fixed box on the page (PiP needs a real gesture; automation can't open it).

import { h } from "./dom.js";
import { store } from "./store.js";

const SMALL = { width: 300, height: 260 };
const BIG = { width: 360, height: 560 };

export const pipSupported = () => "documentPictureInPicture" in window;

/**
 * world: {element, mountIn(doc)}; worldHome: where the element lives normally; compose: {el, focus()}, composeHome;
 * onHeart(); eyeLabel() → "👁️ 2/4" | ""; onEye(); onDoc(doc) for input watching / sound unlock; onState(open).
 */
export function createPip({ world, worldHome, compose, composeHome, onHeart, eyeLabel, onEye, onDoc, onState }) {
  let win = null;
  let root = null;
  let sim = null;
  let expanded = false;
  let bar = null;

  const css = (doc, href) => doc.head.append(Object.assign(doc.createElement("link"), { rel: "stylesheet", href: new URL(href, location.href).href }));
  const tool = (label, title, fn) => h("button.pip-tool", { type: "button", title, "aria-label": title, onclick: fn }, label);

  function mount(doc) {
    const eye = tool("👁️", "眼药水", () => onEye());
    eye.classList.add("eye");
    bar = h("div.pip-bar",
      tool("❤️", "给TA发一颗爱心", () => onHeart()),
      tool("💬", "传话", () => toggleCompose()),
      eye,
      tool("↩︎", "回到大窗口", () => back()));
    root.classList.add("pip");
    root.append(h("div.pip-world", world.element), bar, h("div.pip-compose", { hidden: true }));
    world.mountIn(doc);
    onDoc?.(doc);
    refresh();
    onState(true);
  }

  async function open() {
    if (win || !pipSupported()) return;
    const size = store.get("pipSize") || SMALL;
    win = await window.documentPictureInPicture.requestWindow({ width: size.width || SMALL.width, height: size.height || SMALL.height });
    const doc = win.document;
    doc.title = "噜噜";
    doc.documentElement.lang = "zh-CN";
    css(doc, "css/app.css");
    css(doc, "css/pip.css");
    root = doc.body;
    mount(doc);
    win.addEventListener("pagehide", restore, { once: true });
  }

  function openSim(host) {
    sim = h("div.pip-sim", { "aria-label": "小窗（模拟）" });
    host.append(sim);
    win = window;
    root = sim;
    mount(document);
  }

  function restore() {
    if (win && win !== window && !expanded && win.innerWidth > 0) store.set("pipSize", { width: win.innerWidth, height: win.innerHeight });
    if (expanded) collapse(true);
    worldHome.append(world.element);
    world.mountIn(document);
    bar?.remove();
    bar = null;
    sim?.remove();
    sim = null;
    win = null;
    root = null;
    onState(false);
  }

  function back() {
    close();
    window.focus();
  }

  function close() { if (win && win !== window) win.close(); else if (sim) restore(); }

  function expand() {
    if (!root || expanded) return;
    expanded = true;
    const slot = root.querySelector(".pip-compose");
    slot.append(compose.el);
    slot.hidden = false;
    root.classList.add("expanded");
    if (!sim) try { win.resizeTo(BIG.width, BIG.height); } catch { /* needs a gesture; the panel still scrolls */ }
    compose.focus();
  }

  function collapse(silent) {
    if (!expanded) return;
    expanded = false;
    composeHome.append(compose.el);
    if (root) {
      root.querySelector(".pip-compose").hidden = true;
      root.classList.remove("expanded");
    }
    if (!sim && !silent && win) try { win.resizeTo(SMALL.width, SMALL.height); } catch { /* ignore */ }
  }

  function toggleCompose() { if (expanded) collapse(); else expand(); }

  /** The 👁️ button shows 「👁️ 2/4」 / 「👁️ 该滴了」; hidden when eye drops are off. */
  function refresh() {
    const eye = bar?.querySelector(".eye");
    if (!eye) return;
    const l = eyeLabel();
    eye.hidden = !l;
    eye.textContent = l || "👁️";
    eye.classList.toggle("due", l.includes("该滴了"));
  }

  return {
    open, openSim, close, refresh, toggleCompose,
    isOpen: () => !!win,
    isExpanded: () => expanded,
    doc: () => (win ? win.document : null),
  };
}
