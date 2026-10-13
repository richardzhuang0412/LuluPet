import Foundation
import LuluCore

// Web v1 (docs/superpowers/specs/2026-10-06-web-design.md §10–11): the shared vectors in web/tests/vectors/wire.json
// are checked here against LuluCore, and by `node --test web/tests/` against the JS port (web/js/core), so the two
// cannot drift apart. `seatYield` / `readCursor` have no LuluCore counterpart and are only checked in JS.

private func wvAny(_ v: JSONValue) -> Any {
    switch v {
    case .null: return NSNull()
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let d): return d
    case .string(let s): return s
    case .array(let a): return a.map(wvAny)
    case .object(let o): return o.mapValues(wvAny)
    }
}

/// A decoded message in the JS shape (`decodeChild`): absent fields left out, unknown ones under `extra`.
private func wvMessage(_ m: Message) -> [String: Any] {
    var d: [String: Any] = ["id": m.id, "from": m.from.rawValue, "kind": m.kind.rawValue, "ts": m.ts]
    if let x = m.text { d["text"] = x }
    if let x = m.stickerId { d["stickerId"] = x }
    if let x = m.v { d["v"] = x }
    if let x = m.outfit { d["outfit"] = x }
    if let x = m.trip { d["trip"] = x }
    if let x = m.remindRaw { d["remind"] = x }
    if let x = m.ackOf { d["ackOf"] = x }
    if let x = m.answer { d["answer"] = x }
    if let x = m.late { d["late"] = x }
    if let x = m.character { d["character"] = x.rawValue }
    if !m.extra.isEmpty { d["extra"] = m.extra.mapValues(wvAny) }
    return d
}

private func wvPresence(_ p: PresenceInfo) -> [String: Any] {
    var d: [String: Any] = [:]
    if let x = p.lastSeen { d["lastSeen"] = x }
    if let x = p.dnd { d["dnd"] = ["mood": x.mood, "until": x.untilMs] }
    if let x = p.focus { d["focus"] = ["phase": x.phase, "until": x.until] }
    if let x = p.character { d["character"] = x.rawValue }
    if let x = p.mode { d["mode"] = x.rawValue }
    if let x = p.device { d["device"] = x }
    if let x = p.app { d["app"] = x }
    if let x = p.place { d["place"] = x.json }
    if let x = p.outfit { d["outfit"] = x }
    if let x = p.pose { d["pose"] = x.raw }
    return d
}

private func wvEqual(_ a: Any?, _ b: Any?) -> Bool {
    let x: Any = a ?? NSNull(), y: Any = b ?? NSNull()
    return (x as AnyObject).isEqual(y as AnyObject)
}

private func wvJSON(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
private func wvInt64(_ v: Any?) -> Int64? { (v as? NSNumber)?.int64Value }
private func wvDouble(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
private func wvString(_ v: Any?) -> String? { v as? String }
private func wvCounts(_ v: Any?) -> [String: Int] { ((v as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue } }
private func wvRecent(_ v: Any?) -> [String: Int64] { ((v as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value } }

func runWebVectors() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = root.appendingPathComponent("web/tests/vectors/wire.json")
    guard let data = try? Data(contentsOf: file), let v = wvJSON(data) as? [String: Any], let now = wvInt64(v["now"]) else {
        check(false, "web vectors: could not read \(file.path)")
        return
    }
    let list = { (k: String) -> [[String: Any]] in (v[k] as? [[String: Any]]) ?? [] }
    func decoded(_ c: [String: Any]) -> Message? {
        Message.decode(firebaseKey: c["key"] as? String ?? "", value: c["value"] ?? NSNull(), now: now)
    }

    // Message decode / encode
    check(list("decode").count >= 30, "web vectors: decode cases present")
    for c in list("decode") {
        let name = c["name"] as? String ?? "?"
        let got = decoded(c).map(wvMessage)
        check(wvEqual(got, c["expect"]), "web vectors decode: \(name) → \(String(describing: got))")
    }
    for c in list("encode") {
        let got = decoded(c).flatMap { wvJSON($0.firebasePayload()) }
        check(wvEqual(got, c["expect"]), "web vectors encode: \(c["name"] ?? "?") → \(String(describing: got))")
    }
    for c in list("factories") {
        let me = c["me"] as? [String: Any] ?? [:]
        guard let from = Role(rawValue: me["from"] as? String ?? ""), let ts = wvInt64(c["ts"]) else { check(false, "web vectors factory: bad case"); continue }
        var m: Message
        switch c["factory"] as? String {
        case "text": m = .text(c["text"] as? String ?? "", from: from, ts: ts)
        case "sticker": m = .sticker(c["stickerId"] as? String ?? "", from: from, ts: ts, label: c["label"] as? String)
        case "poke": m = .poke(from: from, ts: ts)
        case "remind": m = .remind(ReminderKind(rawValue: c["remind"] as? String ?? "")!, from: from, ts: ts)
        case "reply":
            m = RemindReply(kind: ReminderKind(rawValue: c["remind"] as? String ?? "")!,
                            answer: RemindReply.Answer(rawValue: c["answer"] as? String ?? "")!)
                .message(from: from, ackOf: c["ackOf"] as? String ?? "", ts: ts)
        default: check(false, "web vectors factory: unknown \(c["factory"] ?? "?")"); continue
        }
        m.character = PetCharacter(rawValue: me["character"] as? String ?? "")
        m.outfit = me["outfit"] as? String
        m.trip = Message.tripLocal
        check(wvEqual(wvJSON(m.firebasePayload()), c["expect"]), "web vectors factory: \(c["factory"] ?? "?") \(c["remind"] ?? "")")
    }
    for c in list("replies") {
        let r = decoded(c).flatMap(RemindReply.decode)
        let got: Any? = r.map { ["kind": $0.kind.rawValue, "answer": $0.answer.rawValue, "late": $0.late] as [String: Any] }
        check(wvEqual(got, c["expect"]) && wvEqual(r?.line, c["line"]), "web vectors reply: \(c["name"] ?? "?")")
    }

    // Wire limits
    for c in list("clipUTF16") {
        check(WireLimits.clipUTF16(c["s"] as? String ?? "", max: c["max"] as? Int ?? 0) == c["expect"] as? String, "web vectors clipUTF16: \(c["s"] ?? "") / \(c["max"] ?? "")")
    }
    for c in list("field") {
        check(WireLimits.field(c["s"] as? String) == c["expect"] as? String, "web vectors field: \(c["s"] ?? "nil")")
    }
    for c in list("pushKeyPrefix") {
        check(String(PushKey.generate(at: wvInt64(c["ms"]) ?? -1).prefix(8)) == c["prefix"] as? String, "web vectors push key prefix: \(c["ms"] ?? "")")
    }
    for c in list("pushKeyValid") {
        check(PushKey.isValid(c["s"] as? String ?? "") == (c["expect"] as? Bool), "web vectors push key valid: \(c["s"] ?? "")")
    }
    for c in list("outboxVerdict") {
        let verdict = OutboxPolicy.verdict(status: c["status"] as? Int, streamConnected: c["streamConnected"] as? Bool ?? false)
        check((verdict == .park ? "park" : "retry") == c["expect"] as? String, "web vectors outbox verdict: \(c["status"] ?? "nil") \(c["streamConnected"] ?? "")")
    }
    for c in list("backoff") {
        check(StreamBackoff.afterConnection(current: wvDouble(c["current"]) ?? 0, livedFor: wvDouble(c["livedFor"]) ?? 0) == wvDouble(c["expect"]), "web vectors backoff: \(c)")
    }
    for c in list("queueFold") {
        let n = c["n"] as? Int ?? 0
        let r = QueueFold.split(Array(0..<n), cap: c["cap"] as? Int ?? 0)
        check(r.folded.count == c["folded"] as? Int && wvEqual(r.kept, c["kept"]), "web vectors queue fold: \(n) / \(c["cap"] ?? "")")
    }
    for c in list("cursorClamp") {
        let ts = wvInt64(c["ts"]) ?? 0, n = wvInt64(c["now"]) ?? 0
        check(WireLimits.isFuture(ts: ts, now: n) == c["isFuture"] as? Bool && WireLimits.clampCursor(ts, now: n) == wvInt64(c["clamp"]), "web vectors cursor clamp: \(ts)")
    }

    // Presence
    for c in list("presence") {
        let body = (try? JSONSerialization.data(withJSONObject: c["json"] ?? NSNull(), options: [.fragmentsAllowed])) ?? Data()
        let got = PresenceInfo.decode(body).map(wvPresence)
        var expect = c["expect"] as? [String: Any]
        expect?["client"] = nil   // web-only field (LuluCore 0.16 ignores it)
        check(wvEqual(got, expect), "web vectors presence: \(c["name"] ?? "?") → \(String(describing: got))")
    }
    for c in list("online") {
        check(Presence.isOnline(lastSeen: wvInt64(c["lastSeen"]), now: wvInt64(c["now"]) ?? 0) == c["expect"] as? Bool, "web vectors online: \(c["lastSeen"] ?? "nil")")
    }

    // Stickers
    if let s = v["stickers"] as? [String: Any] {
        let library = s["library"] as? [String] ?? []
        if let sc = s["sendCounts"] as? [String: Any] {
            let msgs = ((sc["messages"] as? [[String: Any]]) ?? []).compactMap(decoded)
            let got = StickerPanel.sendCounts(from: msgs, me: Role(rawValue: sc["me"] as? String ?? "") ?? .lulu)
            check(wvEqual(got, sc["expect"]), "web vectors sticker sendCounts")
        }
        for c in (s["ranked"] as? [[String: Any]]) ?? [] {
            let got = StickerPanel.ranked(counts: wvCounts(c["counts"]), recent: wvRecent(c["recent"]), visible: c["visible"] as? [String] ?? [])
            check(wvEqual(got, c["expect"]), "web vectors sticker ranked: \(got.prefix(6))")
        }
        let counts = wvCounts(s["counts"]), recent = wvRecent(s["recent"])
        for c in (s["quickBar"] as? [[String: Any]]) ?? [] {
            let stored = c["stored"] as? [String] ?? [], visible = c["visible"] as? [String] ?? []
            let shown = StickerPanel.shownBar(stored: stored, visible: visible, counts: counts, recent: recent)
            check(wvEqual(StickerPanel.quickBar(stored: stored, visible: visible), c["quickBar"])
                  && StickerPanel.hiddenOnBar(stored: stored, visible: visible) == c["hiddenOnBar"] as? Int
                  && wvEqual(shown, c["shownBar"])
                  && wvEqual(StickerPanel.frequent(quickBar: shown, counts: counts, recent: recent, visible: visible), c["frequent"]),
                  "web vectors sticker bar: \(stored)")
        }
        for c in (s["seedQuickBar"] as? [[String: Any]]) ?? [] {
            let got = StickerPanel.seedQuickBar(favorites: c["favorites"] as? [String], counts: wvCounts(c["counts"]), recent: wvRecent(c["recent"]), library: library)
            check(wvEqual(got, c["expect"]), "web vectors sticker seed: \(got)")
        }
        for c in (s["equipped"] as? [[String: Any]]) ?? [] {
            let r = StickerPanel.equipped(c["id"] as? String ?? "", in: c["stored"] as? [String] ?? [], visible: c["visible"] as? [String] ?? [])
            check(wvEqual(["list": r.list, "replaced": r.replaced ?? NSNull()] as [String: Any], c["expect"]), "web vectors sticker equipped: \(r)")
        }
        for c in (s["removed"] as? [[String: Any]]) ?? [] {
            check(wvEqual(StickerPanel.removed(c["id"] as? String ?? "", from: c["stored"] as? [String] ?? []), c["expect"]), "web vectors sticker removed")
        }
    } else {
        check(false, "web vectors: stickers section")
    }

    // Weather
    if let w = v["weather"] as? [String: Any] {
        for c in (w["wmo"] as? [[String: Any]]) ?? [] {
            check(WeatherCondition(wmo: c["code"] as? Int ?? -1, cloudCover: wvDouble(c["cloudCover"])).rawValue == c["expect"] as? String, "web vectors wmo: \(c["code"] ?? "") \(c["cloudCover"] ?? "")")
        }
        for c in (w["emoji"] as? [[String: Any]]) ?? [] {
            let cond = WeatherCondition(rawValue: c["condition"] as? String ?? "")
            check(cond?.emoji(isDay: c["isDay"] as? Bool ?? true) == c["emoji"] as? String && cond?.label == c["label"] as? String, "web vectors weather emoji: \(c["condition"] ?? "")")
        }
        for c in (w["forecast"] as? [[String: Any]]) ?? [] {
            let body = (try? JSONSerialization.data(withJSONObject: c["json"] ?? [:])) ?? Data()
            let snap = try? WeatherParse.snapshot(body, now: wvDouble(c["now"]) ?? 0)
            let got: Any? = snap.map { s -> [String: Any] in
                ["condition": s.condition.rawValue, "temperature": s.temperature, "high": s.high ?? NSNull(), "low": s.low ?? NSNull(),
                 "windSpeed": s.windSpeed ?? NSNull(), "isDay": s.isDay, "fetchedAt": s.fetchedAt]
            }
            check(wvEqual(got, c["expect"]), "web vectors forecast: \(c["name"] ?? "?") → \(String(describing: got))")
        }
    }

    // Pair code, content policy
    for c in list("pairCode") {
        let n = PairCode.normalize(c["raw"] as? String ?? "")
        check(n == c["normalized"] as? String && PairCode.isValid(n) == c["valid"] as? Bool, "web vectors pair code: \(c["raw"] ?? "")")
    }
    for c in list("policy") {
        let mine = PairMode(rawValue: c["myMode"] as? String ?? "") ?? .couple
        let p = ContentPolicy(myMode: mine, partnerMode: PairMode(rawValue: c["partnerMode"] as? String ?? ""), me: .lulu, partner: .lumei)
        check(p.allowsIntimate == c["allowsIntimate"] as? Bool, "web vectors policy: \(c["myMode"] ?? "") / \(c["partnerMode"] ?? "nil")")
    }

    // Away card (AwaySummary + the 5-minute stale rule for pokes / replies)
    if let a = v["away"] as? [String: Any], let e = a["expect"] as? [String: Any] {
        let n = wvInt64(a["now"]) ?? now
        let msgs = ((a["messages"] as? [[String: Any]]) ?? []).compactMap(decoded)
            .filter { !(($0.kind == .poke || Visits.isRemindAck($0)) && n - $0.ts >= 300_000) }
        if let s = AwaySummary.build(msgs, me: Role(rawValue: a["me"] as? String ?? ""), stickerLabel: { _ in nil }) {
            let stickers = s.stickers.map { ["id": $0.id, "count": $0.count] as [String: Any] }
            let got: [String: Any] = [
                "text": s.texts, "sticker": s.stickers.reduce(0) { $0 + $1.count }, "poke": s.pokes, "remind": s.waterCalls + s.standCalls,
                "later": s.laterReplies, "other": s.visits + s.unknown, "water": s.waterCalls, "stand": s.standCalls, "acks": s.acks,
                "visits": s.visits, "unknown": s.unknown, "stickers": stickers, "latestText": s.latestText ?? NSNull(), "total": s.total,
            ]
            check(wvEqual(got, e), "web vectors away: \(got)")
        } else {
            check(false, "web vectors away: empty summary")
        }
    }

    // ActiveTimeReminder sequences (seconds)
    for (i, seq) in list("reminder").enumerated() {
        var r = ActiveTimeReminder(interval: wvDouble(seq["interval"]) ?? 3600)
        for step in (seq["steps"] as? [[String: Any]]) ?? [] {
            let op = step["op"] as? [Any] ?? []
            let name = op.first as? String ?? ""
            let a = op.count > 1 ? op[1] : nil, b = op.count > 2 ? op[2] : nil, c = op.count > 3 ? op[3] : nil
            var due: Bool?
            switch name {
            case "tick": due = r.tick(now: wvDouble(a) ?? 0, idleSeconds: wvDouble(b) ?? 0, blocked: c as? Bool ?? false)
            case "snooze": r.snooze(now: wvDouble(a) ?? 0)
            case "done": r.done(now: wvDouble(a) ?? 0)
            case "resume": r.resume(now: wvDouble(a) ?? 0)
            case "set":
                let s = a as? [String: Any] ?? [:]
                if let x = wvDouble(s["activeSeconds"]) { r.activeSeconds = x }
                if let x = wvDouble(s["lastTick"]) { r.lastTick = x }
                if let x = wvDouble(s["snoozeUntil"]) { r.snoozeUntil = x }
                if let x = s["showing"] as? Bool { r.showing = x }
            default: check(false, "web vectors reminder: unknown op \(name)")
            }
            let st = step["state"] as? [String: Any] ?? [:]
            let ok = (due == nil || due == step["due"] as? Bool)
                && r.interval == wvDouble(st["interval"]) && r.activeSeconds == wvDouble(st["activeSeconds"])
                && r.lastTick == wvDouble(st["lastTick"]) && r.snoozeUntil == wvDouble(st["snoozeUntil"]) && r.showing == st["showing"] as? Bool
            check(ok, "web vectors reminder #\(i) \(op): \(r)")
        }
    }

    runWebVectorsV2(v, now: now)   // eye drops + the web v2 ports (2026-10-12 spec §7 W1)
}

// MARK: - Web v2 (docs/superpowers/specs/2026-10-12-eyedrops-and-web-v2.md §7 W1)

/// Replays the vectors' scripted random units: `Int.random(in: 0..<n)` maps a generator value r to floor(r × n / 2^64),
/// so returning u × 2^64 makes Swift pick floor(u × n), like the JS ports' `Math.floor(rand() * n)`.
private struct WVScriptedRandom: RandomNumberGenerator {
    var units: [Double]
    var i = 0
    init(_ units: [Double]) { self.units = units.isEmpty ? [0] : units }
    mutating func next() -> UInt64 {
        defer { i += 1 }
        return UInt64(units[i % units.count] * 18_446_744_073_709_551_616.0)
    }
}

private func wvNull(_ v: Any?) -> Any { v ?? NSNull() }
private func wvUnits(_ v: Any?) -> [Double] { ((v as? [Any]) ?? []).compactMap(wvDouble) }
private func wvInts(_ v: Any?) -> [Int] { ((v as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
private func wvRolls(_ v: Any?) -> (Int) -> Int {
    var rs = wvInts(v)
    return { _ in rs.isEmpty ? 0 : rs.removeFirst() }
}
private func wvCalendar(_ tz: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = tz
    return c
}
private func wvDate(_ ms: Any?) -> Date { Date(timeIntervalSince1970: (wvDouble(ms) ?? 0) / 1000) }
private func wvSnapshot(_ v: Any?) -> WeatherSnapshot? {
    guard let d = v as? [String: Any], let cond = WeatherCondition(rawValue: d["condition"] as? String ?? "") else { return nil }
    return WeatherSnapshot(condition: cond, temperature: wvDouble(d["temperature"]) ?? 0, high: wvDouble(d["high"]), low: wvDouble(d["low"]),
                           windSpeed: wvDouble(d["windSpeed"]), isDay: d["isDay"] as? Bool ?? true, fetchedAt: wvDouble(d["fetchedAt"]) ?? 0)
}
/// A JS message object (`{id, from, kind, ts, …}`) as LuluCore decodes it.
private func wvMsg(_ v: Any?) -> Message? {
    guard var d = v as? [String: Any] else { return nil }
    let id = d.removeValue(forKey: "id") as? String ?? "-x"
    if d["from"] == nil { d["from"] = "lumei" }
    if d["ts"] == nil { d["ts"] = 1 }
    return Message.decode(firebaseKey: id, value: d, now: Int64.max / 2)
}
private func wvPomodoro(_ v: Any?) -> PomodoroState? {
    let data = (try? JSONSerialization.data(withJSONObject: v ?? [:])) ?? Data()
    return try? JSONDecoder().decode(PomodoroState.self, from: data)
}
private func wvPomodoroJSON(_ s: PomodoroState) -> [String: Any] {
    ["phase": s.phase.rawValue, "until": wvNull(s.until), "pausedRemaining": wvNull(s.pausedRemaining), "completedFocus": s.completedFocus]
}
private func wvReaction(_ r: Reaction?) -> Any {
    guard let r else { return NSNull() }
    return ["couples": r.couples, "visitor": r.visitor, "sounds": r.sounds] as [String: Any]
}
private func wvThinkReason(_ s: String) -> ThinkReason {
    switch s {
    case "hover": return .hover
    case "peek": return .peek
    default:
        if s.hasPrefix("weather:"), let l = WeatherLook(rawValue: String(s.dropFirst(8))) { return .weather(l) }
        return .idle
    }
}
private func wvContext(_ v: Any?) -> ThinkContext {
    let d = v as? [String: Any] ?? [:]
    let b = { (k: String) in d[k] as? Bool ?? false }
    return ThinkContext(solo: b("solo"), hidden: b("hidden"), dnd: b("dnd"), focus: b("focus"), quiet: b("quiet"),
                        visitActive: b("visitActive"), bubbleShowing: b("bubbleShowing"), petBusy: b("petBusy"))
}

func runWebVectorsV2(_ v: [String: Any], now: Int64) {
    let sec = { (k: String) -> [String: Any] in (v[k] as? [String: Any]) ?? [:] }
    let list = { (d: [String: Any], k: String) -> [[String: Any]] in (d[k] as? [[String: Any]]) ?? [] }

    // Eye drops
    let ed = sec("eyedrops")
    let tz = TimeZone(identifier: ed["tz"] as? String ?? "") ?? .current
    check(list(ed, "plan").count >= 25 && list(ed, "progress").count >= 8, "web vectors eyedrops: cases present")
    for c in list(ed, "suggested") {
        check(EyeDrops.suggestedTimes(c["n"] as? Int ?? 0) == c["expect"] as? [String], "web vectors eyedrops suggested \(c["n"] ?? "")")
    }
    for c in list(ed, "slotKey") { check(wvEqual(EyeDrops.slotKey(c["time"] as? String ?? ""), c["key"]), "web vectors eyedrops slotKey \(c["time"] ?? "")") }
    for c in list(ed, "slotTime") { check(wvEqual(EyeDrops.slotTime(c["key"] as? String ?? ""), c["time"]), "web vectors eyedrops slotTime \(c["key"] ?? "")") }
    for c in list(ed, "validate") {
        let r = EyeDrops.validateTimes(c["times"] as? [String] ?? [])
        check(wvEqual(["ok": r.ok, "times": r.times, "error": wvNull(r.error)] as [String: Any], c["expect"]), "web vectors eyedrops validate \(c["times"] ?? "") → \(r)")
    }
    for c in list(ed, "instant") {
        let got = EyeDrops.slotInstant(day: c["day"] as? String ?? "", time: c["time"] as? String ?? "", tz: tz)
        check(got == wvInt64(c["expect"]), "web vectors eyedrops instant \(c["day"] ?? "") \(c["time"] ?? "") → \(String(describing: got))")
    }
    for c in list(ed, "dayKey") { check(EyeDrops.dayKey(wvInt64(c["ms"]) ?? 0, tz: tz) == c["expect"] as? String, "web vectors eyedrops dayKey \(c["ms"] ?? "")") }
    for c in list(ed, "decode") {
        let r = EyeDrops.decode(json: c["json"])
        let got: [String: Any] = ["settings": wvNull(r.settings?.json), "days": EyeDrops.daysJSON(r.days)]
        check(wvEqual(got, c["expect"]), "web vectors eyedrops decode \(c["name"] ?? "") → \(got)")
    }
    for c in list(ed, "nag") {
        let got = EyeDropsNag(json: c["json"], nowMs: wvInt64(c["now"]) ?? 0)?.json
        check(wvEqual(got, c["expect"]), "web vectors eyedrops nag \(c["json"] ?? "") → \(String(describing: got))")
    }
    for c in list(ed, "merge") {
        let got = EyeDrops.mergeSettings(local: EyeDropsSettings(json: c["local"]), remote: EyeDropsSettings(json: c["remote"]))?.json
        check(wvEqual(got, c["expect"]), "web vectors eyedrops merge")
    }
    for c in list(ed, "plan") {
        let n = wvInt64(c["now"]) ?? 0
        let p = EyeDrops.plan(settings: EyeDropsSettings(json: c["settings"]), today: EyeDrops.decodeDays(json: c["today"]),
                              nag: EyeDropsNag(json: c["nag"], nowMs: n), now: n, active: c["active"] as? Bool ?? true, tz: tz)
        let got: [String: Any] = ["action": p.action.rawValue, "slot": wvNull(p.slot), "nextWakeMs": p.nextWakeMs]
        check(wvEqual(got, c["expect"]), "web vectors eyedrops plan: \(c["name"] ?? "") → \(got)")
    }
    for c in list(ed, "afterShow") {
        let n = wvInt64(c["now"]) ?? 0
        let got = EyeDrops.afterShow(EyeDropsNag(json: c["nag"], nowMs: n), slot: c["slot"] as? String ?? "", now: n).json
        check(wvEqual(got, c["expect"]) && EyeDrops.afterDone(EyeDropsNag(json: got, nowMs: n)) == nil, "web vectors eyedrops afterShow \(got)")
    }
    for c in list(ed, "progress") {
        let n = wvInt64(c["now"]) ?? 0
        let p = EyeDrops.progress(settings: EyeDropsSettings(json: c["settings"]), today: EyeDrops.decodeDays(json: c["today"]), now: n, tz: tz,
                                  nag: EyeDropsNag(json: c["nag"], nowMs: n))
        let slots: [[String: Any]] = p.slots.map { s in
            var d: [String: Any] = ["time": s.time, "state": s.state.rawValue]
            if let dev = s.device { d["device"] = dev }
            return d
        }
        let got: [String: Any] = ["done": p.done, "total": p.total, "slots": slots]
        check(wvEqual(got, c["expect"]) && p.badge == c["badge"] as? String, "web vectors eyedrops progress: \(c["name"] ?? "") → \(got) \(p.badge)")
    }
    for c in list(ed, "bubble") {
        let b = EyeDrops.bubbleCopy(slot: c["slot"] as? String ?? "", index: c["index"] as? Int ?? 0, total: c["total"] as? Int ?? 0)
        check(wvEqual(["header": b.header, "line": b.line, "done": b.done, "later": b.later] as [String: Any], c["expect"]), "web vectors eyedrops bubble \(b.line)")
    }

    // 勿扰
    let dnd = sec("dnd")
    let dtz = TimeZone(identifier: dnd["tz"] as? String ?? "") ?? .current
    let dcal = wvCalendar(dtz)
    for c in list(dnd, "until") {
        let got = DNDDuration(rawValue: c["duration"] as? String ?? "")?.until(now: wvDouble(c["now"]) ?? 0, calendar: dcal)
        check(got == wvDouble(c["expect"]), "web vectors dnd until \(c["duration"] ?? "") → \(String(describing: got))")
    }
    for (i, seq) in ((dnd["sequences"] as? [[[String: Any]]]) ?? []).enumerated() {
        var st = DNDState()
        for step in seq {
            let op = step["op"] as? [Any] ?? []
            let name = op.first as? String ?? ""
            let t = wvDouble(op.last) ?? 0
            var span: DNDSpan?
            switch name {
            case "mood": st.mood = DNDMood(rawValue: op[1] as? String ?? "") ?? .unsaid
            case "turnOn": st.turnOn(DNDDuration(rawValue: op[1] as? String ?? "")!, now: t, calendar: dcal)
            case "turnOff": span = st.turnOff(now: t)
            case "expire": span = st.expire(now: t)
            default: check(false, "web vectors dnd: unknown op \(name)")
            }
            let state: [String: Any] = ["until": wvNull(st.until), "mood": st.mood.rawValue, "since": wvNull(st.since)]
            let spanJ: Any = span.map { ["start": $0.startMs, "end": $0.endMs, "mood": $0.mood] as [String: Any] } ?? NSNull()
            let status: Any = st.status(now: t).map { ["mood": $0.mood, "until": $0.untilMs] as [String: Any] } ?? NSNull()
            check(wvEqual(state, step["state"]) && wvEqual(spanJ, step["span"]) && st.isOn(now: t) == step["on"] as? Bool
                  && wvEqual(status, step["status"]) && wvEqual(st.endDeadline, step["endDeadline"])
                  && st.offTitle(calendar: dcal) == step["offTitle"] as? String && st.statusLine(calendar: dcal) == step["statusLine"] as? String,
                  "web vectors dnd sequence #\(i) \(op): \(state) \(spanJ) \(st.statusLine(calendar: dcal))")
        }
    }
    for c in list(dnd, "spans") {
        let s = c["span"] as? [String: Any] ?? [:]
        let span = DNDSpan(startMs: wvInt64(s["start"]) ?? 0, endMs: wvInt64(s["end"]) ?? 0, mood: s["mood"] as? String ?? "")
        check(span.label(calendar: dcal) == c["label"] as? String, "web vectors dnd span \(span.label(calendar: dcal))")
    }
    for c in list(dnd, "lines") {
        let st = DNDStatus(json: c["dnd"])
        check(DND.bounceLine(st) == c["bounce"] as? String && wvEqual(st.map(DND.partnerStatusLine), c["partner"]), "web vectors dnd lines \(c["dnd"] ?? "")")
    }
    for c in list(dnd, "cardTitle") { check(DND.cardTitle(count: c["n"] as? Int ?? 0) == c["expect"] as? String, "web vectors dnd card title") }
    for c in list(dnd, "moods") {
        let m = DNDMood(rawValue: c["mood"] as? String ?? "")
        check(m?.emoji == c["emoji"] as? String && m?.title == c["title"] as? String && wvEqual(m?.reason, c["reason"]) && m?.sign == c["sign"] as? String,
              "web vectors dnd mood \(c["mood"] ?? "")")
    }

    // Pomodoro + ToolsCopy
    let pomo = sec("pomodoro")
    for (i, seq) in list(pomo, "sequences").enumerated() {
        let cj = seq["config"] as? [String: Any] ?? [:]
        var config = PomodoroConfig()
        config.focus = wvDouble(cj["focus"]) ?? config.focus
        config.shortBreak = wvDouble(cj["shortBreak"]) ?? config.shortBreak
        config.longBreak = wvDouble(cj["longBreak"]) ?? config.longBreak
        config.roundsPerLong = cj["roundsPerLong"] as? Int ?? config.roundsPerLong
        var st = PomodoroState.idle
        for step in list(seq, "steps") {
            let op = step["op"] as? [Any] ?? []
            let t = op.count > 1 ? wvDouble(op[1]) ?? 0 : 0
            var event: Any = NSNull()
            switch op.first as? String ?? "" {
            case "start": st.start(now: t, config: config)
            case "pause": st.pause(now: t)
            case "resume": st.resume(now: t)
            case "stop": st.stop()
            case "skipBreak": st.skipBreak()
            case "advance":
                switch st.advance(now: t, config: config) {
                case .focusDone(let next)?: event = ["type": "focusDone", "next": next.rawValue]
                case .breakDone?: event = ["type": "breakDone"]
                case nil: break
                }
            default: check(false, "web vectors pomodoro: unknown op \(op)")
            }
            let ok = wvEqual(wvPomodoroJSON(st), step["state"]) && wvEqual(event, step["event"]) && wvEqual(st.remaining(now: t), step["remaining"])
                && st.isPaused == step["paused"] as? Bool && wvEqual(st.focusStatus?.json, step["focusStatus"])
                && ToolsCopy.pomodoroState(st, now: t) == step["line"] as? String && st.endedLongAgo(now: t) == step["endedLongAgo"] as? Bool
            check(ok, "web vectors pomodoro #\(i) \(op): \(wvPomodoroJSON(st)) \(event) \(ToolsCopy.pomodoroState(st, now: t))")
        }
    }
    for c in list(pomo, "decode") {
        check(wvEqual(wvPomodoro(c["json"]).map(wvPomodoroJSON), c["expect"]), "web vectors pomodoro decode \(c["json"] ?? "")")
    }
    for c in list(pomo, "copy") {
        let k = ReminderKind(rawValue: c["kind"] as? String ?? "")!, iv = wvDouble(c["interval"]) ?? 0
        check(ToolsCopy.menuTitle(k, interval: iv) == c["menuTitle"] as? String && ToolsCopy.explanation(k, interval: iv) == c["explanation"] as? String
              && ToolsCopy.menuHint(k) == c["menuHint"] as? String, "web vectors tools copy \(k)")
    }
    for c in list(pomo, "durations") {
        let cj = c["config"] as? [String: Any] ?? [:]
        var config = PomodoroConfig()
        config.focus = wvDouble(cj["focus"]) ?? 0
        config.shortBreak = wvDouble(cj["shortBreak"]) ?? 0
        check(ToolsCopy.pomodoroDurations(config) == c["expect"] as? String, "web vectors pomodoro durations")
    }
    for c in list(pomo, "cycle") {
        let s = c["status"] as? [String: Any] ?? [:]
        let left = wvDouble(s["left"]) ?? 0
        let status: ActiveTimeReminder.Status
        switch s["phase"] as? String ?? "" {
        case "showing": status = .showing
        case "snoozed": status = .snoozed(left: left)
        case "away": status = .away
        case "waiting": status = .waiting(left: left)
        default: status = .counting(left: left)
        }
        check(ToolsCopy.cycleLine(ReminderKind(rawValue: c["kind"] as? String ?? "")!, status) == c["expect"] as? String, "web vectors cycle line \(s)")
    }
    check(ToolsCopy.pomodoroHint == pomo["hint"] as? String, "web vectors pomodoro hint")

    // Outfits
    let of = sec("outfits")
    let ocal = wvCalendar(TimeZone(identifier: of["tz"] as? String ?? "") ?? .current)
    let seasons = of["seasons"] as? [String: String] ?? [:], outfits = of["outfits"] as? [String] ?? []
    for c in list(of, "inSeason") {
        let got = OutfitSeason(rawValue: c["season"] as? String ?? "")?.contains(wvDate(c["ms"]), calendar: ocal) ?? false
        check(got == c["expect"] as? Bool, "web vectors outfit season \(c["season"] ?? "") \(c["ms"] ?? "")")
    }
    for c in list(of, "launch") {
        let d = wvDate(c["ms"])
        check(wvEqual(OutfitRules.launchOutfit(outfits, seasons: seasons, on: d, calendar: ocal), c["launch"])
              && wvEqual(OutfitRules.eligible(outfits, seasons: seasons, on: d, calendar: ocal), c["eligible"]), "web vectors outfit launch \(d)")
    }
    for c in list(of, "resolvePin") {
        let got = OutfitRules.resolvePin(c["pinned"] as? String, outfits: outfits, seasons: seasons, on: wvDate(c["ms"]), calendar: ocal)
        check(wvEqual(got, c["expect"]), "web vectors outfit pin \(c["pinned"] ?? "nil")")
    }
    for c in list(of, "next") {
        var rng = WVScriptedRandom(wvUnits(c["rands"]))
        let got = OutfitRules.next(after: c["current"] as? String, outfits: outfits, seasons: seasons, on: wvDate(c["ms"]), calendar: ocal, using: &rng)
        check(wvEqual(got, c["expect"]), "web vectors outfit next \(c["current"] ?? "nil") \(c["rands"] ?? "") → \(String(describing: got))")
    }
    if let c = of["nextNone"] as? [String: Any] {
        var rng = WVScriptedRandom([0.5])
        check(wvEqual(OutfitRules.next(after: "a", outfits: ["a"], seasons: [:], on: Date(), using: &rng), c["expect"]), "web vectors outfit next none")
    }
    var hist = OutfitHistory()
    for step in list(of, "history") {
        let op = step["op"] as? [Any] ?? []
        var out: String?
        if op.first as? String == "push" { hist.push(op[1] as? String ?? "") } else { out = hist.pop(valid: op[1] as? [String] ?? [], current: op[2] as? String) }
        check(hist.stack == step["stack"] as? [String] && wvEqual(out, step["outfit"])
              && hist.canGoBack(valid: ["a", "b", "c", "x"], current: "a") == step["canGoBack"] as? Bool, "web vectors outfit history \(op) → \(hist.stack)")
    }
    for c in list(of, "choices") {
        let got = OutfitChoice.list(outfits: outfits, labels: c["labels"] as? [String: String] ?? [:], seasons: seasons, current: c["current"] as? String,
                                    pinned: c["pinned"] as? String, on: wvDate(c["ms"]), calendar: ocal)
            .map { ["name": $0.name, "title": $0.title, "current": $0.current, "enabled": $0.enabled] as [String: Any] }
        check(wvEqual(got, c["expect"]), "web vectors outfit choices \(got)")
    }
    for c in list(of, "visitorOutfit") {
        let got = OutfitRules.visitorOutfit(requested: c["requested"] as? String, available: c["available"] as? [String] ?? [], fallback: c["fallback"] as? String)
        check(wvEqual(got, c["expect"]), "web vectors visitor outfit")
    }

    // Pose
    let pose = sec("pose")
    for c in list(pose, "derive") {
        let i = c["input"] as? [String: Any] ?? [:]
        let b = { (k: String) in i[k] as? Bool ?? false }
        let got = PetPose.derive(hidden: b("hidden"), dnd: b("dnd"), focus: b("focus"), dozing: b("dozing"), quiet: b("quiet"),
                                 weather: (i["weather"] as? String).flatMap(WeatherLook.init(rawValue:)), hasWeatherClips: b("hasWeatherClips")).raw
        check(got == c["expect"] as? String, "web vectors pose derive \(i) → \(got)")
    }
    for c in list(pose, "thinkLook") {
        let looks = c["weatherClips"] as? [String] ?? []
        let r = ThinkPoseLook.resolve((c["pose"] as? String).map(PetPose.init(raw:)), hasFocusClip: c["hasFocusClip"] as? Bool ?? false,
                                      hasWeatherClip: { looks.contains($0.rawValue) })
        let got: String
        switch r {
        case .idleLoop: got = "idleLoop"
        case .dozeStill: got = "dozeStill"
        case .quietStill: got = "quietStill"
        case .focusClip: got = "focusClip"
        case .focusStill: got = "focusStill"
        case .dndStill: got = "dndStill"
        case .weatherClip(let l): got = "weatherClip:\(l.rawValue)"
        }
        check(got == c["expect"] as? String, "web vectors think pose look \(c["pose"] ?? "nil") → \(got)")
    }
    for c in list(pose, "dndSign") { check(ThinkPoseLook.dndSign(DNDStatus(json: c["dnd"])) == c["expect"] as? String, "web vectors dnd sign") }
    for c in list(pose, "thinkOutfit") {
        let got = ThinkOutfit.pick(published: c["published"] as? String, lastMessage: c["lastMessage"] as? String,
                                   available: c["available"] as? [String] ?? [], preferred: c["preferred"] as? String)
        check(wvEqual(got, c["expect"]), "web vectors think outfit")
    }

    // Idle
    let idle = sec("idle")
    for c in list(idle, "fidgetDelay") {
        check(IdleRules.fidgetDelay(fixed: wvDouble(c["fixed"]), unit: wvDouble(c["unit"]) ?? 0) == wvDouble(c["expect"]), "web vectors fidget delay")
    }
    for c in list(idle, "pickFidget") {
        let got = IdleRules.pickFidget(count: c["count"] as? Int ?? 0, last: c["last"] as? Int, roll: wvRolls(c["rolls"]))
        check(wvEqual(got, c["expect"]), "web vectors pick fidget \(c)")
    }
    if let dz = idle["doze"] as? [String: Any] {
        var clock = DozeClock(threshold: wvDouble(dz["threshold"]) ?? 0, now: wvDouble(dz["start"]) ?? 0)
        for step in list(dz, "steps") {
            let op = step["op"] as? [Any] ?? []
            let t = wvDouble(op.count > 1 ? op[1] : nil) ?? 0
            var out: Any = NSNull()
            switch op.first as? String ?? "" {
            case "check":
                switch clock.check(now: t, blocked: op[2] as? Bool ?? false) {
                case .wait(let s): out = ["type": "wait", "seconds": s] as [String: Any]
                case .doze: out = ["type": "doze"]
                case .none: out = ["type": "none"]
                }
            case "activity": out = clock.activity(now: t)
            default: out = clock.isDue(now: t)
            }
            let state: [String: Any] = ["threshold": clock.threshold, "lastActivity": clock.lastActivity, "dozing": clock.dozing]
            check(wvEqual(out, step["out"]) && wvEqual(state, step["state"]), "web vectors doze \(op) → \(out)")
        }
    }
    for c in list(idle, "restPose") {
        let got = RestPose.pick(dozing: c["dozing"] as? Bool ?? false, quiet: c["quiet"] as? Bool ?? false, dnd: c["dnd"] as? Bool ?? false)
        check(got.rawValue == c["expect"] as? String, "web vectors rest pose")
    }

    // Reactions
    let rx = sec("reactions")
    let table = ReactionTable(entries: ReactionTable.parse((try? JSONSerialization.data(withJSONObject: rx["table"] ?? [:])) ?? Data()))
    check(wvEqual(table.entries.mapValues { wvReaction($0) }, rx["parsed"]), "web vectors reactions parse")
    for c in list(rx, "lookup") {
        let r = table.reaction(kind: Message.Kind(rawValue: c["kind"] as? String ?? ""), stickerId: c["stickerId"] as? String)
        check(wvEqual(wvReaction(r), c["expect"]) && wvEqual(r?.visitorClips(for: .lulu) ?? [], c["lulu"]) && wvEqual(r?.visitorClips(for: .lumei) ?? [], c["lumei"]),
              "web vectors reaction \(c["kind"] ?? "") \(c["stickerId"] ?? "nil")")
    }
    check(wvEqual(wvReaction(ReactionTable().reaction(kind: .text, stickerId: nil)), (rx["lookupEmpty"] as? [String: Any])?["expect"]), "web vectors reaction empty table")
    for c in list(rx, "click") {
        check(wvEqual(table.clickClips(for: Role(rawValue: c["character"] as? String ?? "") ?? .lulu), c["expect"]), "web vectors click clips")
    }
    for c in list(rx, "poolPick") {
        var rng = WVScriptedRandom(wvUnits(c["rands"]))
        check(wvEqual(PoolPick.pick(c["pool"] as? [String] ?? [], last: c["last"] as? String, using: &rng), c["expect"]), "web vectors pool pick \(c)")
    }

    // Sounds
    let snd = sec("sounds")
    let parsed = SoundManifest.parseFull((try? JSONSerialization.data(withJSONObject: snd["manifest"] ?? [:])) ?? Data())
    let pj = snd["parsed"] as? [String: Any] ?? [:]
    let intimateJS = (pj["intimate"] as? [String: [String]] ?? [:]).mapValues { Set($0) }
    check(wvEqual(parsed.entries, pj["entries"]) && wvEqual(parsed.only, pj["only"]) && parsed.intimate == intimateJS, "web vectors sound manifest parse")
    let sm = SoundManifest(entries: parsed.entries, only: parsed.only, intimate: parsed.intimate)
    for c in list(snd, "files") {
        let got = sm.files(for: c["key"] as? String ?? "", visitor: (c["visitor"] as? String).flatMap(Role.init(rawValue:)), allowIntimate: c["allowIntimate"] as? Bool ?? true)
        check(wvEqual(got, c["expect"]), "web vectors sound files \(c["key"] ?? "") \(c["visitor"] ?? "nil") → \(got)")
    }
    for c in list(snd, "forCouple") { check(SoundEvent.forCouple(c["name"] as? String).rawValue == c["expect"] as? String, "web vectors sound for couple \(c["name"] ?? "nil")") }
    for c in list(snd, "forSticker") { check(wvEqual(SoundEvent.forSticker(c["id"] as? String)?.rawValue, c["expect"]), "web vectors sound for sticker \(c["id"] ?? "nil")") }
    for c in list(snd, "meetingKeys") {
        let got = SoundEvent.meetingKeys(reaction: c["reaction"] as? [String] ?? [], clipSound: c["clipSound"] as? String,
                                         fallback: c["fallback"] as? [String] ?? [], couple: c["couple"] as? String)
        check(wvEqual(got, c["expect"]), "web vectors meeting keys \(got)")
    }
    for c in list(snd, "presetIndex") {
        check(SoundDefaults.presetIndex(for: Float(wvDouble(c["volume"]) ?? 0)) == c["expect"] as? Int, "web vectors preset index \(c["volume"] ?? "")")
    }
    var gate = SoundGate(enabled: true, throttle: 0.3)
    for step in list(snd, "gate") {
        let op = step["op"] as? [Any] ?? []
        var out: Any = NSNull()
        switch op.first as? String ?? "" {
        case "decide":
            switch gate.decide(op[1] as? String ?? "", now: wvDouble(op[2]) ?? 0) {
            case .play: out = "play"
            case .muted: out = "muted"
            case .hidden: out = "hidden"
            case .throttled: out = "throttled"
            case .awayOnly: out = "awayOnly"
            }
        case "away": gate.beginAwayOnly(now: wvDouble(op[1]) ?? 0, duration: wvDouble(op[2]) ?? 0)
        case "endAway": gate.endAwayOnly()
        case "hidden": gate.hidden = op[1] as? Bool ?? false
        case "enabled": gate.enabled = op[1] as? Bool ?? false
        default: break
        }
        check(wvEqual(out, step["out"]) && gate.allowsBGM == step["allowsBGM"] as? Bool, "web vectors sound gate \(op) → \(out)")
    }
    var picker = SoundPicker()
    for c in list(snd, "picker") {
        var rng = WVScriptedRandom(wvUnits(c["rands"]))
        check(wvEqual(picker.pick(c["key"] as? String ?? "", from: c["files"] as? [String] ?? [], using: &rng), c["expect"]), "web vectors sound picker \(c)")
    }

    // 想 TA
    let th = sec("think")
    for c in list(th, "shouldShow") {
        let got = ThinkRules.shouldShow(wvThinkReason(c["reason"] as? String ?? ""), context: wvContext(c["context"]),
                                        lastShown: wvDouble(c["lastShown"]), now: wvDouble(c["now"]) ?? 0)
        check(got == c["expect"] as? Bool, "web vectors think shouldShow \(c["reason"] ?? "") \(c["context"] ?? "")")
    }
    for c in list(th, "peek") {
        let got: [String: Any]
        switch ThinkRules.peekVerdict(context: wvContext(c["context"]), partnerEverSeen: c["partnerEverSeen"] as? Bool ?? false) {
        case .show: got = ["verdict": "show"]
        case .ignore: got = ["verdict": "ignore"]
        case .wait: got = ["verdict": "wait"]
        case .toast(let t): got = ["verdict": "toast", "text": t]
        }
        check(wvEqual(got, c["expect"]), "web vectors peek verdict \(got)")
    }
    for c in list(th, "weatherTrigger") {
        let got = ThinkRules.weatherTrigger(previous: (c["previous"] as? String).flatMap(WeatherLook.init(rawValue:)), hadData: c["hadData"] as? Bool ?? false,
                                            current: (c["current"] as? String).flatMap(WeatherLook.init(rawValue:)))
        check(wvEqual(got?.rawValue, c["expect"]), "web vectors weather trigger")
    }
    for c in list(th, "flourish") {
        let got: String
        switch ThinkRules.flourish(wvSnapshot(c["snapshot"])) {
        case .rain: got = "rain"
        case .snow: got = "snow"
        case .sun: got = "sun"
        case .none: got = "none"
        }
        check(got == c["expect"] as? String, "web vectors flourish \(got)")
    }
    for c in list(th, "bar") {
        let got = ThinkRules.barText(reason: wvThinkReason(c["reason"] as? String ?? ""), place: WeatherPlace(json: c["place"]),
                                     snapshot: wvSnapshot(c["snapshot"]), now: wvDate(c["nowMs"]))
        check(wvEqual(got, c["expect"]), "web vectors think bar → \(got ?? "nil")")
    }
    for c in list(th, "peekBar") {
        let got = ThinkRules.peekBarText(online: c["online"] as? Bool ?? false, place: WeatherPlace(json: c["place"]),
                                         snapshot: wvSnapshot(c["snapshot"]), now: wvDate(c["nowMs"]))
        check(wvEqual(got, c["expect"]), "web vectors peek bar → \(got ?? "nil")")
    }
    for c in list(th, "localTime") {
        let got = LocalTime.format(timezone: c["timezone"] as? String ?? "", now: wvDate(c["ms"]))
        check(got == c["expect"] as? String, "web vectors local time → \(got)")
    }
    for c in list(th, "idleDelay") { check(ThinkRules.idleDelay(unit: wvDouble(c["unit"]) ?? 0) == wvDouble(c["expect"]), "web vectors think idle delay") }

    // Weather looks
    let wl = sec("weatherlook")
    for c in list(wl, "of") {
        let got = wvSnapshot(c["snapshot"]).flatMap(WeatherLook.of)?.rawValue
        check(wvEqual(got, c["expect"]), "web vectors weather look \(c["snapshot"] ?? "") → \(got ?? "nil")")
    }
    for c in list(wl, "clipLooks") {
        check(WeatherLook(rawValue: c["look"] as? String ?? "")?.clipLooks.map(\.rawValue) == c["expect"] as? [String], "web vectors clip looks")
    }
    for c in list(wl, "pick") {
        let r = WeatherPlan.pickFidget(plain: c["plain"] as? Int ?? 0, weather: c["weather"] as? Int ?? 0, lastPlain: c["lastPlain"] as? Int,
                                       lastWeather: c["lastWeather"] as? Int, roll: wvRolls(c["rolls"]))
        let got: Any
        switch r {
        case .plain(let i)?: got = ["kind": "plain", "index": i]
        case .weather(let i)?: got = ["kind": "weather", "index": i]
        case nil: got = NSNull()
        }
        check(wvEqual(got, c["expect"]), "web vectors weather fidget \(c) → \(got)")
    }
    for c in list(wl, "needsRefresh") {
        let a = (c["args"] as? [Bool]) ?? [false, false, false, false]
        check(WeatherPlan.needsRefresh(hasPlace: a[0], partnerHasPlace: a[1], composeOpen: a[2], hasClips: a[3]) == c["expect"] as? Bool, "web vectors needs refresh")
    }

    // Visits
    let vs = sec("visits")
    for c in list(vs, "coupleMove") {
        let got = Visits.coupleMove(for: Message.Kind(rawValue: c["kind"] as? String ?? ""), text: c["text"] as? String, label: c["label"] as? String).rawValue
        check(got == c["expect"] as? String, "web vectors couple move \(c)")
    }
    for c in list(vs, "keywordCouples") { check(wvEqual(Visits.keywordCouples(text: c["text"] as? String), c["expect"]), "web vectors keyword couples") }
    let croot = FileManager.default.temporaryDirectory.appendingPathComponent("lulu-wv-\(UUID().uuidString)/Couples")
    for (name, spec) in (vs["couples"] as? [String: [String: Any]]) ?? [:] {
        let dir = croot.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let intimate = spec["intimate"] as? Bool == true ? #","intimate":true"# : ""
        try? Data(#"{"frames":1,"delays":[0.1],"width":1,"height":1\#(intimate)}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
    }
    let catalog = CoupleCatalog(root: croot)
    for c in list(vs, "meeting") {
        let p = c["policy"] as? [String: Any] ?? [:]
        let policy = ContentPolicy(myMode: PairMode(rawValue: p["myMode"] as? String ?? "") ?? .couple,
                                   partnerMode: (p["partnerMode"] as? String).flatMap(PairMode.init(rawValue:)),
                                   me: PetCharacter(rawValue: p["me"] as? String ?? "") ?? .lulu,
                                   partner: (p["partner"] as? String).flatMap(PetCharacter.init(rawValue:)))
        var rng = WVScriptedRandom(wvUnits(c["rands"]))
        let got = Visits.meetingCouple(pool: c["pool"] as? [String] ?? [], preferred: Visits.CoupleMove(rawValue: c["preferred"] as? String ?? "") ?? .hug,
                                       catalog: catalog, policy: policy, last: c["last"] as? String, using: &rng)
        check(wvEqual(got, c["expect"]), "web vectors meeting couple \(c["pool"] ?? "") \(p) → \(got ?? "nil")")
    }
    try? FileManager.default.removeItem(at: croot.deletingLastPathComponent())
    for c in list(vs, "timing") {
        let k = Message.Kind(rawValue: c["kind"] as? String ?? "")
        check(Visits.dwell(for: k) == wvDouble(c["dwell"]) && Visits.deliveryAway(for: k) == wvDouble(c["deliveryAway"])
              && Visits.sendsWhenOffline(k) == c["sendsWhenOffline"] as? Bool, "web vectors visit timing \(c["kind"] ?? "")")
    }
    for c in list(vs, "collision") {
        let got = Visits.resolveCollision(partnerTs: wvInt64(c["partnerTs"]) ?? 0, myTs: wvInt64(c["myTs"]) ?? 0, partner: Role(rawValue: c["partner"] as? String ?? "") ?? .lulu)
        check(got.rawValue == c["expect"] as? String, "web vectors collision \(c)")
    }
    for c in list(vs, "collisionPlan") {
        guard let mine = wvMsg(c["mine"]), let theirs = wvMsg(c["theirs"]), let me = Role(rawValue: c["me"] as? String ?? "") else { check(false, "web vectors collision plan: bad case"); continue }
        let plan = Visits.collisionPlan(mine: mine, theirs: theirs, me: me)
        let steps: [[String: Any]] = plan.steps.map { s in
            switch s {
            case .turnBack: return ["step": "turnBack"]
            case .hostVisitor(let m): return ["step": "hostVisitor", "message": wvMessage(m)]
            case .dwell(let t): return ["step": "dwell", "seconds": t]
            case .leaveTogether: return ["step": "leaveTogether"]
            case .stayAway(let t): return ["step": "stayAway", "seconds": t]
            case .comeHome: return ["step": "comeHome"]
            case .showPinned(let m): return ["step": "showPinned", "message": wvMessage(m)]
            case .stayAwayFor(let t): return ["step": "stayAwayFor", "seconds": t]
            case .comeHomeWithVisitor(let m): return ["step": "comeHomeWithVisitor", "message": wvMessage(m)]
            }
        }
        check(wvEqual(["winner": plan.winner.rawValue, "steps": steps] as [String: Any], c["expect"]), "web vectors collision plan \(plan.winner) \(steps)")
    }
    for (i, seq) in ((vs["location"] as? [[[String: Any]]]) ?? []).enumerated() {
        var loc = PetLocation()
        for step in seq {
            let op = step["op"] as? [Any] ?? []
            let a: Any? = op.count > 1 ? op[1] : nil
            var out: Any = NSNull()
            switch op.first as? String ?? "" {
            case "send":
                let d = a as? [String: Any] ?? [:]
                switch loc.planSend(kind: Message.Kind(rawValue: d["kind"] as? String ?? ""), now: wvDouble(d["now"]) ?? 0,
                                    visitorHere: d["visitorHere"] as? Bool ?? false, reachable: d["reachable"] as? Bool ?? false,
                                    partnerDND: d["partnerDND"] as? Bool ?? false) {
                case .deliver(let t): out = ["type": "deliver", "away": t] as [String: Any]
                case .extendAway(let t): out = ["type": "extendAway", "away": t] as [String: Any]
                case .localMeeting: out = ["type": "localMeeting"]
                case .bounce(let send): out = ["type": "bounce", "send": send] as [String: Any]
                case .coolingDown(let r): out = ["type": "coolingDown", "remaining": r] as [String: Any]
                case .sendOnly: out = ["type": "sendOnly"]
                }
            case "sent": loc.sent(ts: wvInt64(a) ?? 0)
            case "reachedAway": loc.reachedAway(now: wvDouble(a) ?? 0)
            case "startReturn": loc.startReturn()
            case "arrivedHome": loc.arrivedHome()
            case "incoming":
                let d = a as? [String: Any] ?? [:]
                var m = Message.text("x", from: .lumei, ts: wvInt64(d["ts"]) ?? 0)
                m.trip = d["trip"] as? String
                out = loc.incoming(m).rawValue
            case "beginCollision": loc.beginCollision(Visits.CollisionWinner(rawValue: a as? String ?? "") ?? .me)
            case "endCollision": loc.endCollision()
            case "setReturn": loc.setReturn(at: wvDouble(a) ?? 0)
            case "leaveAgain": loc.leaveAgain(away: wvDouble(a) ?? 0)
            case "awayRemaining": out = wvNull(loc.awayRemaining(now: wvDouble(a) ?? 0))
            default: check(false, "web vectors location: unknown op \(op)")
            }
            let state: [String: Any] = ["place": loc.place.rawValue, "tripTs": wvNull(loc.tripTs), "bouncing": loc.bouncing, "awayFor": loc.awayFor,
                                        "awayEnds": wvNull(loc.awayEnds), "collision": wvNull(loc.collision?.rawValue)]
            check(wvEqual(out, step["out"]) && wvEqual(state, step["state"]), "web vectors location #\(i) \(op) → \(out) \(state)")
        }
    }
    for c in list(vs, "stay") {
        var clock = VisitorStayClock()
        if let s = wvDouble(c["startedAt"]) { clock.start(now: s) }
        let t = wvDouble(c["now"]) ?? 0
        let d = Visits.stayDecision(now: t, stayUntil: wvDouble(c["stayUntil"]) ?? 0, bubblesWaiting: c["bubblesWaiting"] as? Bool ?? false, clock: clock)
        let raw: String
        switch d {
        case .wait: raw = "wait"
        case .leave: raw = "leave"
        case .leaveLeavingBubbles: raw = "leaveLeavingBubbles"
        }
        // `remaining` within 1e-9: JSONSerialization may parse a long decimal a hair off the double JS printed.
        let rem = clock.remaining(now: t), want = wvDouble(c["remaining"])
        let remOK = rem == nil ? want == nil : want.map { abs($0 - rem!) < 1e-9 } ?? false
        check(raw == c["expect"] as? String && remOK, "web vectors stay decision \(c)")
    }
    for c in list(vs, "focus") {
        let f = FocusStatus(json: c["focus"]), n = wvInt64(c["nowMs"]) ?? 0
        check(Visits.partnerFocusHolds(f, partnerOnline: c["partnerOnline"] as? Bool ?? false, nowMs: n) == c["holds"] as? Bool
              && wvEqual(f.map { Visits.partnerFocusLine(name: "噜妹", focus: $0, nowMs: n) }, c["line"]), "web vectors partner focus \(c)")
    }
    for c in list(vs, "holding") {
        let st = wvPomodoro(c["state"]) ?? .idle
        check(Visits.isHoldingForFocus(state: st, now: wvDouble(c["now"]) ?? 0) == c["expect"] as? Bool, "web vectors holding for focus \(c)")
    }
    for c in list(vs, "remindAck") { check(Visits.remindAckLine(ReminderKind(rawValue: c["kind"] as? String ?? "")!) == c["expect"] as? String, "web vectors remind ack") }

    // History
    let hs = sec("history")
    let htz = TimeZone(identifier: hs["tz"] as? String ?? "") ?? .current
    let hcal = wvCalendar(htz)
    let hnow = wvDate(hs["now"])
    let hmsgs = ((hs["messages"] as? [Any]) ?? []).compactMap(wvMsg)
    let spans = ((hs["spans"] as? [[String: Any]]) ?? []).map { DNDSpan(startMs: wvInt64($0["start"]) ?? 0, endMs: wvInt64($0["end"]) ?? 0, mood: $0["mood"] as? String ?? "") }
    check(hmsgs.count == 6, "web vectors history: messages decode")
    for c in list(hs, "page") {
        let r = HistoryTimeline.page(hmsgs, limit: c["limit"] as? Int ?? 0, before: wvMsg(c["before"]))
        check(wvEqual(["ids": r.messages.map(\.id), "hasMore": r.hasMore] as [String: Any], c["expect"]), "web vectors history page \(c["limit"] ?? "")")
    }
    for c in list(hs, "rows") {
        let msgs = Array(hmsgs.dropFirst(c["from"] as? Int ?? 0))
        let rows = HistoryTimeline.rows(msgs, dndSpans: c["noSpans"] as? Bool == true ? [] : spans, complete: c["complete"] as? Bool ?? false, now: hnow, calendar: hcal)
        let got: [[String: Any]] = rows.map { r in
            switch r {
            case .day(let l, let k): return ["type": "day", "label": l, "key": k]
            case .message(let m): return ["type": "message", "id": m.id]
            case .dnd(let l, let k): return ["type": "dnd", "label": l, "key": k]
            }
        }
        check(wvEqual(got, c["expect"]), "web vectors history rows \(c["from"] ?? "") \(c["complete"] ?? "") → \(got)")
    }
    for c in list(hs, "dayLabel") {
        let got = HistoryTimeline.dayLabel(wvDate(c["ms"]), now: wvDate(c["now"]), calendar: hcal)
        check(got == c["expect"] as? String, "web vectors history day label → \(got)")
    }
    for c in list(hs, "timeLabel") { check(HistoryTimeline.timeLabel(wvInt64(c["ms"]) ?? 0, calendar: hcal) == c["expect"] as? String, "web vectors history time label") }
    for c in list(hs, "remindLine") {
        guard let m = wvMsg(c["message"]) else { check(false, "web vectors remind line: bad message"); continue }
        let got = Visits.remindHistoryLine(m, fromMe: c["fromMe"] as? Bool ?? false)
        check(wvEqual(got, c["expect"]), "web vectors remind history line \(c["message"] ?? "") → \(got ?? "nil")")
    }

    // presence.js v2 heartbeat / sign-off (LuluCore's payload has no `client`: web-only)
    func identity(_ d: [String: Any]) -> (PetCharacter?, PairMode?, String?, String?, WeatherPlace?) {
        ((d["character"] as? String).flatMap(PetCharacter.init(rawValue:)), (d["mode"] as? String).flatMap(PairMode.init(rawValue:)),
         d["device"] as? String, d["outfit"] as? String, WeatherPlace(json: d["place"]))
    }
    for c in (v["heartbeat"] as? [[String: Any]]) ?? [] {
        let (ch, mode, dev, outfit, place) = identity(c["identity"] as? [String: Any] ?? [:])
        let look = c["look"] as? [String: Any] ?? [:]
        var expect = c["expect"] as? [String: Any] ?? [:]
        expect["client"] = nil
        let got = PresenceInfo.payload(lastSeen: wvInt64(c["now"]) ?? 0, dnd: DNDStatus(json: look["dnd"]), focus: FocusStatus(json: look["focus"]),
                                       character: ch, mode: mode, device: dev, place: place,
                                       look: PresenceLook(outfit: outfit, pose: PetPose(raw: expect["pose"] as? String ?? "")))
        check(wvEqual(got, expect), "web vectors heartbeat \(c["name"] ?? "") → \(got)")
    }
    for c in (v["signOff"] as? [[String: Any]]) ?? [] {
        let (ch, mode, dev, outfit, place) = identity(c["identity"] as? [String: Any] ?? [:])
        let extra = c["extra"] as? [String: Any] ?? [:]
        var expect = c["expect"] as? [String: Any] ?? [:]
        expect["client"] = nil
        let got = PresenceInfo.payload(lastSeen: 0, dnd: DNDStatus(json: extra["dnd"]), character: ch, mode: mode, device: dev, place: place,
                                       look: PresenceLook(outfit: outfit, pose: nil))
        check(wvEqual(got, expect), "web vectors sign-off \(c["name"] ?? "") → \(got)")
    }
}
