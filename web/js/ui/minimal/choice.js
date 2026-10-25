// First run on a desktop: 完整宠物 or 极简（适合上班）. Resolves true for 极简. Saved per device; changeable in 设置.

import { h, setChildren } from "../dom.js";
import { minimalPrefs } from "./mode.js";

export function chooseMode(host) {
  return new Promise((resolve) => {
    const pick = (minimal) => {
      minimalPrefs.set({ on: minimal });
      host.hidden = true;
      document.body.classList.remove("choosing");
      resolve(minimal);
    };
    const option = (minimal, title, lines) => h("button.choice-opt", { type: "button", dataset: { kind: minimal ? "minimal" : "full" }, onclick: () => pick(minimal) },
      h("span.choice-title", title), lines.map((l) => h("span.choice-line", l)));
    setChildren(host, h("div.choice", { role: "dialog", "aria-labelledby": "choice-h" },
      h("h1#choice-h.choice-h", "在这台电脑上怎么用？"),
      h("p.choice-sub", "只影响这台电脑。TA 那边一切照常，随时可以在 设置 里换。"),
      h("div.choice-opts",
        option(false, "完整宠物", ["宠物在屏幕上走来走去，会串门、冒气泡", "有动画和小小的提示音"]),
        option(true, "极简（适合上班）", ["没有宠物和动画，一个安静的小面板", "传话、TA 的提醒、喝水 / 站立 / 眼药水 / 番茄钟", "提醒走系统通知"]))));
    document.body.classList.add("choosing");
    host.hidden = false;
    host.querySelector(".choice-opt")?.focus({ preventScroll: true });
  });
}
