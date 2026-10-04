import AppKit

/// Launched from Finder / Dock / `open` (parent is launchd), stderr goes nowhere — send NSLog output to
/// ~/Library/Logs/LuluPet/LuluPet[-<profile>].log instead (rotated at 5 MB) so problems can be diagnosed.
private func redirectLogsIfLaunchedByLaunchd() {
    guard getppid() == 1 else { return }
    let args = CommandLine.arguments
    let profile = args.firstIndex(of: "--profile").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LuluPet")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(profile.map { "LuluPet-\($0).log" } ?? "LuluPet.log")
    if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 5_000_000 {
        let old = file.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }
    freopen(file.path, "a", stderr)
    setvbuf(stderr, nil, _IOLBF, 0)
}

redirectLogsIfLaunchedByLaunchd()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    // SIGTERM (logout, `kill`, shutdown) goes through a normal terminate so we can sign off presence.
    signal(SIGTERM, SIG_IGN)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler { app.terminate(nil) }
    sigterm.resume()
    withExtendedLifetime((delegate, sigterm)) { app.run() }
}
