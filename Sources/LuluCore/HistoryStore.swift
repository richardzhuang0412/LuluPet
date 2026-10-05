import Foundation

/// Durable local message history (both directions): append-only JSON Lines, one `Message` per line,
/// deduplicated by id (the Firebase push id; a sent message also remembers its `localId`).
///
/// Crash safety: each append is one `write` on an `O_APPEND` descriptor under `flock`, followed by fsync.
/// A torn last line (crash mid-write) is ignored when reading and sealed with a newline before the next
/// append. The file is never rewritten, truncated or deleted — see docs/upgrade-compat.md.
/// Several stores (or processes) may share one directory; each read picks up what others appended.
public final class HistoryStore: @unchecked Sendable {
    public let fileURL: URL

    private let lock = NSLock()
    private var byId: [String: Message] = [:]
    private var ids = Set<String>()        // push ids and local ids
    private var consumed: UInt64 = 0       // bytes of the file already parsed (always ends at a newline)
    private var sortedCache: [Message]?    // `all()`, rebuilt only after new lines were parsed

    /// `~/Library/Application Support/LuluPet/<profile or "default">`.
    public static func defaultDirectory(profile: String?) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LuluPet", isDirectory: true)
            .appendingPathComponent(profile ?? "default", isDirectory: true)
    }

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.jsonl")
    }

    /// All messages, oldest first.
    public func all() -> [Message] {
        lock.lock(); defer { lock.unlock() }
        refresh()
        return sorted()
    }

    /// v0.4 history tab: the newest `limit` messages older than `before` (all when nil), oldest first,
    /// plus whether even older ones exist.
    public func page(limit: Int, before: Message? = nil) -> (messages: [Message], hasMore: Bool) {
        lock.lock(); defer { lock.unlock() }
        refresh()
        return HistoryTimeline.page(sorted(), limit: limit, before: before)
    }

    /// Caller holds `lock`.
    private func sorted() -> [Message] {
        if let sortedCache { return sortedCache }
        let s = byId.values.sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
        sortedCache = s
        return s
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        refresh()
        return byId.count
    }

    public func contains(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        refresh()
        return ids.contains(id)
    }

    /// Appends `message` unless its id (or local id) is already stored. Returns true if written.
    @discardableResult
    public func append(_ message: Message) -> Bool {
        merge([message]) == 1
    }

    /// Appends every message not yet stored, in one write. Returns how many were added.
    @discardableResult
    public func merge(_ messages: [Message]) -> Int {
        lock.lock(); defer { lock.unlock() }
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)   // prelaunch-A: private (was 0644)
        guard fd >= 0 else { NSLog("[lulu] history: cannot open %@ (errno %d)", fileURL.path, errno); return 0 }
        fchmod(fd, 0o600)   // ... also for a file an older version created world-readable
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); try? handle.close() }
        refresh()   // under the file lock, so another store's appends are seen before deduping

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        var added: [Message] = []
        var seen = Set<String>()
        for m in messages where !m.id.isEmpty {
            let keys = [m.id] + (m.localId.map { [$0] } ?? [])
            guard !keys.contains(where: { ids.contains($0) || seen.contains($0) }),
                  let line = try? encoder.encode(m) else { continue }
            seen.formUnion(keys)
            out.append(line)
            out.append(0x0A)
            added.append(m)
        }
        guard !out.isEmpty else { return 0 }
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
           size > consumed {
            // Unparsed bytes after the last newline: a torn line from a crash. Seal it off.
            out.insert(0x0A, at: 0)
        }
        do {
            try handle.write(contentsOf: out)
            try handle.synchronize()
        } catch {
            NSLog("[lulu] history: write failed: %@", String(describing: error))
            return 0
        }
        refresh()
        return added.count
    }

    /// Parses complete lines appended since the last read. Caller holds `lock`.
    private func refresh() {
        guard let h = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: consumed)) != nil,
              let data = try? h.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        consumed += UInt64(complete.count)
        let decoder = JSONDecoder()
        for line in complete.split(separator: 0x0A) {
            guard let m = try? decoder.decode(Message.self, from: Data(line)), !m.id.isEmpty else { continue }  // torn/corrupt line
            ids.insert(m.id)
            if let l = m.localId { ids.insert(l) }
            if byId[m.id] == nil { byId[m.id] = m; sortedCache = nil }
        }
    }
}
