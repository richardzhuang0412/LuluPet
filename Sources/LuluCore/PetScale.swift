import CoreGraphics
import Foundation

/// v0.7 pet size ("大小"): one factor for everything on this desk (home pet, visitor, couple clips,
/// effects, visit geometry). Stored under the UserDefaults key `petScale` (Double; absent = 1.0,
/// see docs/upgrade-compat.md). Frames are built at the sources' native height (tools/build_sprites.py),
/// which is about 2x the 170 pt idle, so 1.6x still looks crisp enough on a Retina screen.
public enum PetScale {
    public static let standard: Double = 1.0
    public static let min: Double = 0.6
    public static let max: Double = 1.6

    public struct Preset: Equatable, Sendable {
        public let title: String
        public let scale: Double
    }

    /// Menu 大小: 小 / 标准 / 大 (checkmark only when the scale is exactly one of these).
    public static let presets: [Preset] = [
        Preset(title: "小", scale: 0.75),
        Preset(title: "标准", scale: 1.0),
        Preset(title: "大", scale: 1.3),
    ]

    /// Index of the preset `scale` is (within rounding), nil after a free drag to another size.
    public static func presetIndex(for scale: Double) -> Int? {
        presets.firstIndex { abs($0.scale - scale) < 0.001 }
    }

    /// Clamps to [min, max]; NaN / infinity = standard.
    public static func clamp(_ s: Double) -> Double {
        guard s.isFinite else { return standard }
        return Swift.min(max, Swift.max(min, s))
    }

    /// Live drag preview: inside the limits the scale follows the pointer; beyond them it resists
    /// (rubber band, at most `overshoot` past the limit) so the pet visibly "stops" instead of
    /// jumping. On mouse-up `clamp` snaps it back.
    public static func rubberBand(_ s: Double, overshoot: Double = 0.04) -> Double {
        guard s.isFinite else { return standard }
        func resist(_ excess: Double) -> Double { overshoot * (1 - 1 / (1 + excess / overshoot)) }
        if s > max { return max + resist(s - max) }
        if s < min { return min - resist(min - s) }
        return s
    }

    /// Value to persist: clamped and rounded to 0.01 (so 1.2999999 from a drag reads back as 1.3).
    public static func normalized(_ s: Double) -> Double { (clamp(s) * 100).rounded() / 100 }

    /// Scale while dragging the bottom-right handle: `start` = scale at mouse-down, `delta` = pointer
    /// movement (screen points, y up), `sprite` = sprite size at mouse-down. The pet grows when the
    /// pointer moves right and / or up (away from the bottom-left anchor): the movement projected on
    /// the sprite's diagonal, relative to that diagonal. Not clamped.
    public static func dragged(start: Double, delta: CGVector, sprite: CGSize) -> Double {
        let d2 = sprite.width * sprite.width + sprite.height * sprite.height
        guard d2 > 0 else { return start }
        let t = (delta.dx * sprite.width + delta.dy * sprite.height) / d2
        return start * Double(1 + t)
    }

    /// Window origin after a size change so the sprite's bottom-left corner (the feet on the left)
    /// stays put. The sprite is horizontally centred in its window. `oldFrame` = window frame now,
    /// `oldSpriteWidth` / `newSpriteWidth` = visible sprite widths, `newWindowWidth` = the new window width.
    public static func anchoredOrigin(oldFrame: CGRect, oldSpriteWidth: CGFloat, newSpriteWidth: CGFloat,
                                      newWindowWidth: CGFloat) -> CGPoint {
        let spriteLeft = oldFrame.midX - oldSpriteWidth / 2
        return CGPoint(x: spriteLeft + newSpriteWidth / 2 - newWindowWidth / 2, y: oldFrame.minY)
    }

    /// Keeps a window of `size` at `origin` horizontally on `screen` (after growing near the right edge).
    public static func keepOnScreen(_ origin: CGPoint, size: CGSize, screen: CGRect) -> CGPoint {
        var x = origin.x
        if x + size.width > screen.maxX { x = screen.maxX - size.width }
        if x < screen.minX { x = screen.minX }
        return CGPoint(x: x, y: origin.y)
    }
}
