import AppKit

/// Finds the pet windows of *other* LuluPet processes (e.g. 噜噜 and 噜妹 on one Mac) so pets and
/// their panels don't pile up on each other.
///
/// Window titles of other processes are only visible with Screen Recording permission, so besides
/// the pet panel's title each instance also registers its pet's window number in a small file under
/// the user's temp dir (`LuluPet-pets/<pid>`). Entries are validated against the live window list,
/// so stale files from crashed instances are harmless.
@MainActor
enum PetNeighbors {
    static let petWindowTitle = "LuluPetPet"

    struct Pet {
        var windowNumber: Int
        /// Whole pet window (sprite + transparent headroom), Cocoa screen coordinates.
        var frame: NSRect
        /// Just the visible sprite (without the headroom).
        var spriteFrame: NSRect { NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(0, frame.height - PetWindow.topMargin)) }
    }

    private static let registryDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LuluPet-pets")
    private static var ownRegistryFile: URL { registryDir.appendingPathComponent("\(getpid())") }

    static func register(windowNumber: Int) {
        try? FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
        // Drop entries of instances that are gone (killed without a chance to unregister).
        for pid in registeredWindows().keys where kill(pid, 0) != 0 && errno == ESRCH {
            try? FileManager.default.removeItem(at: registryDir.appendingPathComponent("\(pid)"))
        }
        try? String(windowNumber).write(to: ownRegistryFile, atomically: true, encoding: .utf8)
    }

    static func unregister() {
        try? FileManager.default.removeItem(at: ownRegistryFile)
    }

    private static var cache: (time: TimeInterval, pets: [Pet])?

    /// On-screen pet windows of other LuluPet processes. `maxAge` lets callers that run often
    /// (bubble following a drag) reuse a recent answer.
    static func others(maxAge: TimeInterval = 0) -> [Pet] {
        let now = ProcessInfo.processInfo.systemUptime
        if maxAge > 0, let cache, now - cache.time <= maxAge { return cache.pets }
        let pets = query()
        cache = (now, pets)
        return pets
    }

    private static func query() -> [Pet] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = getpid()
        let registered = registeredWindows()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var isLulu: [pid_t: Bool] = [:]
        var pets: [Pet] = []
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let named = (info[kCGWindowName as String] as? String) == petWindowTitle
            guard named || registered[pid] == number else { continue }
            if isLulu[pid] == nil {
                isLulu[pid] = NSRunningApplication(processIdentifier: pid)?.executableURL?.lastPathComponent == "LuluPet"
            }
            guard isLulu[pid] == true else { continue }
            // CG window bounds: top-left origin at the primary screen's top edge.
            let frame = NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            pets.append(Pet(windowNumber: number, frame: frame))
        }
        return pets
    }

    private static func registeredWindows() -> [pid_t: Int] {
        let files = (try? FileManager.default.contentsOfDirectory(at: registryDir, includingPropertiesForKeys: nil)) ?? []
        var out: [pid_t: Int] = [:]
        for f in files {
            guard let pid = pid_t(f.lastPathComponent),
                  let n = (try? String(contentsOf: f, encoding: .utf8)).flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            else { continue }
            out[pid] = n
        }
        return out
    }

    /// For panels shown next to our pet: the first candidate origin that fits on `visibleFrame`
    /// and doesn't cover another pet's sprite; else the first that fits; else the first, clamped.
    static func bestOrigin(_ candidates: [NSPoint], size: NSSize, in vf: NSRect, margin: CGFloat = 4,
                           avoiding sprites: [NSRect]? = nil) -> NSPoint {
        let inner = vf.insetBy(dx: margin, dy: margin)
        func clamp(_ p: NSPoint) -> NSPoint {
            NSPoint(x: min(max(p.x, inner.minX), inner.maxX - size.width), y: min(max(p.y, inner.minY), inner.maxY - size.height))
        }
        let fits = candidates.filter { inner.contains(NSRect(origin: $0, size: size)) }
        let sprites = sprites ?? others().map(\.spriteFrame)
        func isFree(_ p: NSPoint) -> Bool { !sprites.contains { $0.intersects(NSRect(origin: p, size: size)) } }
        // Preferred spots first; then the same spots pushed back on screen (may overlap our own
        // pet a little, which beats covering the other one); then the first spot that fits.
        if let free = fits.first(where: isFree) ?? candidates.map(clamp).first(where: isFree) { return free }
        return clamp(fits.first ?? candidates.first ?? inner.origin)
    }
}
