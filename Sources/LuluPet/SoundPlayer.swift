import AppKit
import AVFoundation
import LuluCore

/// v0.5 sounds: plays `Resources/Sounds/sounds.json` events through a small pool of preloaded
/// AVAudioPlayers. The rules (random pick without immediate repeat, 0.3 s per-event throttle, mute,
/// silence while hidden, "only the card's sound" after being shown again) live in LuluCore `SoundGate`
/// / `SoundPicker`. Every play is logged as "[lulu] sound: <event> <file>".
@MainActor
final class SoundPlayer {
    private let root: URL
    private let manifest: SoundManifest
    private var gate: SoundGate
    private var picker = SoundPicker()
    private var rng: any RandomNumberGenerator = SystemRandomNumberGenerator()
    /// Up to `perFile` players per file, so a sound can overlap itself (different events, same file).
    private var pool: [String: [AVAudioPlayer]] = [:]
    private static let perFile = 3
    private var bgm: AVAudioPlayer?

    private(set) var volume: Float
    private(set) var bgmEnabled: Bool
    var enabled: Bool { gate.enabled }

    init(root: URL, enabled: Bool, volume: Float, bgmEnabled: Bool) {
        self.root = root
        let raw = SoundManifest(url: root.appendingPathComponent("sounds.json"))
        let r = raw.resolved { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        manifest = r.manifest
        gate = SoundGate(enabled: enabled)
        self.volume = volume
        self.bgmEnabled = bgmEnabled
        for m in r.missing { NSLog("[lulu] sound: warning: missing file (%@), skipped", m) }
        // Preload everything but the (possibly long) background music.
        for (key, files) in manifest.entries where key != SoundEvent.bgmKey {
            for f in files where pool[f] == nil { if let p = makePlayer(f) { pool[f] = [p] } }
        }
        let events = manifest.entries.keys.filter { $0 != SoundEvent.bgmKey }.sorted()
        NSLog("[lulu] sound: %ld event(s) %@, %ld file(s) preloaded, %@, volume %.2f, bgm %@",
              events.count, events.joined(separator: ","), pool.count, enabled ? "on" : "off", volume,
              bgmEnabled ? "on (\(manifest.files(for: SoundEvent.bgmKey).count) file(s))" : "off")
    }

    private func makePlayer(_ file: String) -> AVAudioPlayer? {
        do {
            let p = try AVAudioPlayer(contentsOf: root.appendingPathComponent(file))
            p.prepareToPlay()
            return p
        } catch {
            NSLog("[lulu] sound: cannot load %@: %@", file, error.localizedDescription)
            return nil
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Events

    func play(_ event: SoundEvent, visitor: Role? = nil, allowIntimate: Bool = true) {
        play(key: event.rawValue, visitor: visitor, allowIntimate: allowIntimate)
    }

    /// A built-in event or a custom sounds.json key (reactions.json / couples.json `"sound"`).
    /// `visitor` = the character the event is about (v0.9: files restricted to a character only play for it).
    /// v0.11 `allowIntimate` false (friend / solo): files flagged intimate are skipped.
    func play(key: String, visitor: Role? = nil, allowIntimate: Bool = true) {
        let files = manifest.files(for: key, visitor: visitor, allowIntimate: allowIntimate)
        guard !files.isEmpty else {   // no sound for this event: silently nothing (but say when the policy took it away)
            if !allowIntimate, !manifest.files(for: key, visitor: visitor, allowIntimate: true).isEmpty {
                NSLog("[lulu] sound: %@ skipped (intimate not allowed)", key)
            }
            return
        }
        let d = gate.decide(key, now: now)
        guard d == .play else {
            NSLog("[lulu] sound: %@ skipped (%@)", key, String(describing: d))
            return
        }
        guard let file = picker.pick(key, from: files, using: &rng) else { return }
        start(file, volume: volume)
        NSLog("[lulu] sound: %@ %@", key, file)
    }

    /// The first of `keys` that has a sound (e.g. a reaction pool, then the couple's sound).
    /// An event whose files are all intimate counts as having none when they are not allowed, so the next key
    /// (typically the category sound) plays instead.
    func playFirstAvailable(_ keys: [String], visitor: Role? = nil, allowIntimate: Bool = true) {
        if let k = keys.first(where: { !manifest.files(for: $0, visitor: visitor, allowIntimate: allowIntimate).isEmpty }) {
            play(key: k, visitor: visitor, allowIntimate: allowIntimate)
        }
        if !allowIntimate {   // log the keys the policy took away before the one that plays
            for k in keys.prefix(while: { manifest.files(for: $0, visitor: visitor, allowIntimate: allowIntimate).isEmpty })
            where !manifest.files(for: k, visitor: visitor, allowIntimate: true).isEmpty {
                NSLog("[lulu] sound: %@ skipped (intimate not allowed)", k)
            }
        }
    }

    private func start(_ file: String, volume: Float) {
        var players = pool[file] ?? []
        let p: AVAudioPlayer
        if let idle = players.first(where: { !$0.isPlaying }) {
            p = idle
        } else if players.count < Self.perFile, let fresh = makePlayer(file) {
            p = fresh
            players.append(fresh)
            pool[file] = players
        } else if let oldest = players.first {
            p = oldest   // all busy: restart the first one
        } else {
            return
        }
        p.volume = volume
        p.currentTime = 0
        p.play()
    }

    /// Settings「试听」: one random event sound at the current volume, even while muted.
    func preview() {
        let keys = [SoundEvent.poke, .click, .happy, .hug, .bubble, .arrive].map(\.rawValue) + manifest.entries.keys.sorted()
        guard let key = keys.first(where: { !manifest.files(for: $0).isEmpty && $0 != SoundEvent.bgmKey }),
              let file = picker.pick(key, from: manifest.files(for: key), using: &rng) else {
            NSLog("[lulu] sound: preview: no sounds installed")
            NSSound.beep()
            return
        }
        start(file, volume: volume)
        NSLog("[lulu] sound: preview %@ %@ (volume %.2f)", key, file, volume)
    }

    var hasSounds: Bool { manifest.entries.keys.contains { $0 != SoundEvent.bgmKey } }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        gate.enabled = on
        NSLog("[lulu] sound: %@", on ? "on" : "off")
        if !on { stopAll() }
    }

    func setVolume(_ v: Float) {
        volume = min(1, max(0, v))
        bgm?.volume = volume * SoundDefaults.bgmFactor
        NSLog("[lulu] sound: volume %.2f", volume)
    }

    func setBGMEnabled(_ on: Bool) {
        bgmEnabled = on
        NSLog("[lulu] sound: bgm %@", on ? "on" : "off")
        if on { playBGMOnce(reason: "turned on") } else { stopBGM() }
    }

    // MARK: Hidden / away

    /// The pet was hidden (stops everything) or shown again (background music once, if on).
    func setHidden(_ hidden: Bool) {
        guard hidden != gate.hidden else { return }
        gate.hidden = hidden
        // Background music plays only at app launch (and when switched on) — never on re-show, which also
        // happens on Space switches and entering / leaving full screen (auto-hide).
        if hidden { stopAll() }
    }

    /// The "你不在的时候…" batch is replayed: only the card's sound, until `endAwayOnly()` (or 30 s).
    func beginAwayOnly() { gate.beginAwayOnly(now: now, duration: 30) }
    func endAwayOnly() {
        if gate.awayOnlyUntil != nil { gate.endAwayOnly() }
    }

    /// Launch (or switched on): a random `bgm` entry once at half the master volume, never looped.
    func playBGMOnce(reason: String) {
        guard bgmEnabled, gate.allowsBGM, bgm?.isPlaying != true else { return }
        let files = manifest.files(for: SoundEvent.bgmKey)
        guard let file = picker.pick(SoundEvent.bgmKey, from: files, using: &rng), let p = makePlayer(file) else { return }
        p.numberOfLoops = 0
        p.volume = volume * SoundDefaults.bgmFactor
        p.play()
        bgm = p
        NSLog("[lulu] sound: bgm %@ (%@)", file, reason)
    }

    private func stopBGM() {
        bgm?.stop()
        bgm = nil
    }

    private func stopAll() {
        for players in pool.values { for p in players where p.isPlaying { p.stop() } }
        stopBGM()
    }
}
