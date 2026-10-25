// 桌宠模式 「跟桌面壁纸对齐」 (pure, no DOM): where the desktop picture lies behind a window, so the window can draw
// that slice of it and look see-through. macOS draws the picture over the whole display (menu bar included):
//   fill    = 「填充屏幕」: scale to cover, centred, overflow cropped (the macOS default)
//   fit     = 「适合于屏幕」: scale to fit inside, centred (bars around it)
//   stretch = 「拉伸以充满屏幕」: both axes scaled to the display
//   center  = 「居中」: natural size (in CSS px), centred
// All lengths are CSS px. screen = {left, top, width, height} of the display the window is on (left/top in the same
// global coordinates as window.screenX/Y); view = the page's top-left on screen ({x, y}); image = {width, height}.

export const FITS = ["fill", "fit", "stretch", "center"];

/** The picture's rectangle relative to the display's top-left: {x, y, width, height}. */
export function pictureRect(screenW, screenH, imgW, imgH, fit = "fill") {
  if (!(screenW > 0 && screenH > 0 && imgW > 0 && imgH > 0)) return { x: 0, y: 0, width: Math.max(0, screenW), height: Math.max(0, screenH) };
  let w, hgt;
  if (fit === "stretch") { w = screenW; hgt = screenH; }
  else if (fit === "center") { w = imgW; hgt = imgH; }
  else {
    const s = fit === "fit" ? Math.min(screenW / imgW, screenH / imgH) : Math.max(screenW / imgW, screenH / imgH);
    w = imgW * s; hgt = imgH * s;
  }
  return { x: (screenW - w) / 2, y: (screenH - hgt) / 2, width: w, height: hgt };
}

/** Where the page's top-left sits on screen: the outer origin plus the frame (borders split evenly, title bar on top). */
export function viewOrigin({ screenX, screenY, outerWidth, outerHeight, innerWidth, innerHeight }) {
  const side = Math.max(0, (outerWidth - innerWidth) / 2);
  const top = Math.max(0, outerHeight - innerHeight - side);
  return { x: screenX + side, y: screenY + top };
}

/**
 * CSS for the page background: background-size / background-position in px (rounded to 0.1 px), so the part of the
 * picture under the window is what the window shows. → {size: [w, h], position: [x, y]}.
 */
export function wallpaperSlice({ screen, image, view, fit = "fill" }) {
  const r = pictureRect(screen.width, screen.height, image.width, image.height, FITS.includes(fit) ? fit : "fill");
  const round = (v) => Math.round(v * 10) / 10;
  return {
    size: [round(r.width), round(r.height)],
    position: [round(screen.left + r.x - view.x), round(screen.top + r.y - view.y)],
  };
}

/** The screen point (CSS px) a page point shows, for tests: inverse check of wallpaperSlice. */
export function imagePointAt(slice, image, px, py) {
  return { x: ((px - slice.position[0]) / slice.size[0]) * image.width, y: ((py - slice.position[1]) / slice.size[1]) * image.height };
}
