import AppKit

/// Hidden `--offscreen` test flag: this instance's windows stay "on screen" for AppKit (same frames, same
/// geometry, `--snapshot` renders them as usual) but sit below the desktop picture and ignore the mouse, and
/// the 🍊 menu-bar item is hidden — so test instances never show up on the user's real desktop.
/// (Moving windows off every screen instead would change the visit geometry, which is measured against the
/// screen the pet is on.)
enum Offscreen {
    static let enabled = CommandLine.arguments.contains("--offscreen")
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
}

extension NSWindow {
    /// `level = normal`, or below the desktop picture with `--offscreen`.
    func setLuluLevel(_ normal: NSWindow.Level) {
        if Offscreen.enabled {
            level = Offscreen.level
            ignoresMouseEvents = true
        } else {
            level = normal
        }
    }
}
