// 换装 controller (Outfits, W1 outfits.js). Keys in the Mac format: `outfitPinned` {character: id} (= pinnedOutfit),
// `outfitHistory` {character: [ids]} (latest first, ≤ 10), `outfitCurrent` {character: id}.
// While my Mac holds the seat (yielding) the pet wears what the Mac published and the picker is greyed (spec §4.4);
// when this page takes the seat over it starts from that outfit and changes every 30 minutes unless pinned
// (seasonal weights and holiday windows from W1).

import { v2, TZ } from "./deps.js";
import { store } from "./store.js";
import { outfitOf, outfitLabel, outfitIds } from "./assets.js";

const AUTO_EVERY_MS = 30 * 60_000;

export function createOutfits({ scheduler, onChange }) {
  const O = v2.outfits;
  let character = "lulu";
  let yielding = true;
  let macOutfit = null;
  let timer = null;

  const dict = (k) => { const v = store.get(k, {}); return v && typeof v === "object" && !Array.isArray(v) ? v : {}; };
  const ids = () => outfitIds(character).map((o) => o.id);
  const seasons = () => Object.fromEntries(outfitIds(character).filter((o) => o.season).map((o) => [o.id, o.season]));
  const pinned = () => O.resolvePin(dict("outfitPinned")[character] ?? null, ids(), seasons(), Date.now(), TZ);
  const own = () => outfitOf(character, pinned(), dict("outfitCurrent")[character], macOutfit,
    O.launchOutfit(ids(), seasons(), Date.now(), TZ));
  const stack = () => O.decodeHistory(dict("outfitHistory")[character]);

  function setOwn(id, pushOld = true) {
    const cur = own();
    if (!id || id === cur) return;
    if (pushOld && cur) store.set("outfitHistory", { ...dict("outfitHistory"), [character]: O.historyPush(stack(), cur) });
    store.set("outfitCurrent", { ...dict("outfitCurrent"), [character]: id });
    if (dict("outfitPinned")[character]) store.set("outfitPinned", { ...dict("outfitPinned"), [character]: id });
    arm();
    onChange();
  }

  function arm() {
    if (timer != null) scheduler.clearTimeout(timer);
    timer = null;
    if (yielding || pinned()) return;
    timer = scheduler.setTimeout(change, AUTO_EVERY_MS);
  }

  function change() {
    if (yielding) return;
    setOwn(O.nextOutfit(own(), ids(), seasons(), Date.now(), TZ, Math.random));
  }

  return {
    /** From mySeat: my character, whether my Mac has the seat, and the outfit it last published. */
    setSeat({ character: ch, yielding: y, outfit }) {
      const takeover = yielding && !y;
      const changed = ch !== character || y !== yielding || (outfit ?? macOutfit) !== macOutfit;
      character = ch;
      yielding = y;
      macOutfit = outfit ?? macOutfit;
      if (takeover && !pinned() && macOutfit) store.set("outfitCurrent", { ...dict("outfitCurrent"), [character]: outfitOf(character, macOutfit) });
      if (changed) { arm(); onChange(); }
    },
    /** What my pet wears now. */
    current: () => (yielding ? outfitOf(character, macOutfit) : own()),
    yielding: () => yielding,
    isPinned: () => !!dict("outfitPinned")[character],
    canGoBack: () => !yielding && O.canGoBack(stack(), ids(), own()),
    change,
    back() {
      if (yielding) return;
      const { stack: rest, outfit } = O.historyPop(stack(), ids(), own());
      store.set("outfitHistory", { ...dict("outfitHistory"), [character]: rest });
      if (outfit) setOwn(outfit, false);
    },
    choose(id) { if (!yielding) setOwn(id); },
    togglePin() {
      if (yielding) return;
      const p = dict("outfitPinned");
      if (p[character]) delete p[character]; else p[character] = own();
      store.set("outfitPinned", p);
      arm();
      onChange();
    },
    /** 选择造型 rows: [{id, label, enabled}] (节日限定 ones only in their season or when pinned). */
    list() {
      const labels = Object.fromEntries(ids().map((id) => [id, outfitLabel(character, id)]));
      return O.choices(ids(), labels, seasons(), own(), dict("outfitPinned")[character] ?? null, Date.now(), TZ)
        .map((c) => ({ id: c.name, label: c.title, enabled: c.enabled }));
    },
    label: () => outfitLabel(character, yielding ? outfitOf(character, macOutfit) : own()),
  };
}
