import Foundation

/// v0.8.1 省电: event-driven hover watch for the home pet (resize handle + waking quiet mode).
///
/// Instead of polling the pointer 10×/s, PetWindow listens to mouse-moved events (a global + local
/// `NSEvent` monitor and a tracking area on the pet view). A mouse that doesn't move costs nothing; a
/// move far from the pet is dropped after one rect test. Pure geometry here so it can be tested.
public enum HoverWatch {
    /// Mouse moves within this distance of the pet window are worth a hover check.
    public static let nearMargin: CGFloat = 32
    /// Extra slack around the handle so the pointer can reach it from the sprite.
    public static let handleSlack: CGFloat = 6
    /// While the handle is visible (only then), a slow poll catches a missed exit (e.g. the pet ran away
    /// under a still pointer) and fades it out.
    public static let fallbackPoll: TimeInterval = 1

    /// Should a mouse move at `pointer` run a hover check? Always while the handle is shown or the pointer
    /// was over the sprite (so leaving is noticed), else only near the window.
    public static func needsCheck(pointer: CGPoint, window: CGRect, handleShown: Bool, pointerOver: Bool) -> Bool {
        handleShown || pointerOver || window.insetBy(dx: -nearMargin, dy: -nearMargin).contains(pointer)
    }

    /// `over` = the pointer is over the visible sprite (wakes quiet mode on the rising edge);
    /// `show` = the handle should be visible (over the sprite or over the handle itself).
    public static func state(pointer: CGPoint, sprite: CGRect, handle: CGRect) -> (over: Bool, show: Bool) {
        let over = sprite.contains(pointer)
        return (over, over || handle.insetBy(dx: -handleSlack, dy: -handleSlack).contains(pointer))
    }
}
