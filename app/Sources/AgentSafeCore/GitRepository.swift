import Compression
import Foundation

// Reads a git repository's object database and refs directly from `.git`, without
// running `git`: the app is sandboxed, and `/usr/bin/git` is a developer-tools shim that
// cannot be relied on there. Read-only. Supports what `git` writes by default on a Mac:
// SHA-1 objects, loose objects, pack index v2 with both delta kinds, loose and packed refs.

public struct GitObjectID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let high: UInt64
    let mid: UInt64
    let low: UInt32

    /// Reads 20 raw bytes at `offset`.
    init(raw: UnsafeRawBufferPointer, at offset: Int) {
        var h: UInt64 = 0, m: UInt64 = 0, l: UInt32 = 0
        for i in 0..<8 { h = h << 8 | UInt64(raw[offset + i]) }
        for i in 8..<16 { m = m << 8 | UInt64(raw[offset + i]) }
        for i in 16..<20 { l = l << 8 | UInt32(raw[offset + i]) }
        high = h; mid = m; low = l
    }

    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count == 40 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 {
            guard let a = Self.nibble(chars[2 * i]), let b = Self.nibble(chars[2 * i + 1]) else { return nil }
            bytes[i] = a << 4 | b
        }
        self = bytes.withUnsafeBytes { GitObjectID(raw: $0, at: 0) }
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }

    public var hex: String { String(format: "%016llx%016llx%08x", high, mid, low) }
    public var description: String { hex }
    var isZero: Bool { high == 0 && mid == 0 && low == 0 }
    var firstByte: Int { Int(high >> 56) }

    public static func < (a: GitObjectID, b: GitObjectID) -> Bool { (a.high, a.mid, a.low) < (b.high, b.mid, b.low) }
}

public enum GitReadError: Error, Equatable {
    /// A format this reader does not support (SHA-256 objects, reftable, pack index v1).
    case unsupported(String)
    /// An object the repository refers to is not on disk (a partial clone, a missing alternate).
    case missingObject(String)
    case corrupt(String)
}

public enum GitObjectKind: Sendable { case commit, tree, blob, tag }

public struct GitCommit: Sendable {
    public let tree: GitObjectID
    public let parents: [GitObjectID]
    /// Lowercased. Empty when the commit has none.
    public let authorEmail: String
    public let committerEmail: String
}

public struct GitTreeEntry: Sendable {
    public let name: String
    public let id: GitObjectID
    public let isTree: Bool
    /// A regular or executable file. Symlinks and submodule entries are neither.
    public let isFile: Bool
}

/// A minimal reader for git's config format: sections, subsections, keys and values.
struct GitConfig {
    struct Entry { let section: String; let subsection: String?; let key: String; let value: String }
    let entries: [Entry]

    init(url: URL) { self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "") }

    init(text: String) {
        var out: [Entry] = []
        var section = "", subsection: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), let close = line.lastIndex(of: "]") {
                let header = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let quote = header.firstIndex(of: "\"") {
                    section = header[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
                    subsection = String(header[header.index(after: quote)...]).replacingOccurrences(of: "\"", with: "")
                } else if let dot = header.firstIndex(of: ".") {
                    section = header[..<dot].lowercased()
                    subsection = header[header.index(after: dot)...].lowercased()
                } else {
                    section = header.lowercased()
                    subsection = nil
                }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                out.append(Entry(section: section, subsection: subsection, key: line.lowercased(), value: "true"))
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.count >= 2, let end = value.dropFirst().firstIndex(of: "\"") {
                value = String(value[value.index(after: value.startIndex)..<end])
            } else if let comment = value.range(of: #"\s[#;]"#, options: .regularExpression) {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            out.append(Entry(section: section, subsection: subsection, key: key, value: value))
        }
        entries = out
    }

    func value(_ section: String, _ key: String, subsection: String? = nil) -> String? {
        entries.last { $0.section == section && $0.key == key && $0.subsection == subsection }?.value
    }

    /// Every value of `key` in `section`, whatever the subsection, in file order.
    func allValues(_ section: String, _ key: String) -> [String] {
        entries.filter { $0.section == section && $0.key == key }.map(\.value)
    }

    /// Every `[section "x"] key = value`, by subsection.
    func values(_ section: String, _ key: String) -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries where entry.section == section && entry.key == key {
            if let sub = entry.subsection { out[sub] = entry.value }
        }
        return out
    }
}

/// One `.pack` file and its `.idx` (version 2).
final class GitPack {
    let pack: Data
    private let index: Data
    let count: Int
    /// Cumulative object counts by first ID byte, checked to be non-decreasing and to end at `count`.
    private let fanout: [Int]
    /// Object start offsets by index position, each checked to lie inside the pack.
    private let offsets: [Int]
    /// The same offsets in pack order, to find where each compressed entry ends.
    private let sortedOffsets: [Int]

    /// Every value read from the index is checked here, once, so the lookups below can
    /// never read outside the file: a damaged or crafted `.idx` must throw, not crash.
    init(pack packURL: URL, index indexURL: URL) throws {
        pack = try Data(contentsOf: packURL, options: .alwaysMapped)
        index = try Data(contentsOf: indexURL, options: .alwaysMapped)
        guard pack.count >= 32, pack.prefix(4) == Data("PACK".utf8) else { throw GitReadError.corrupt("pack header") }
        guard index.count >= 8 + 1024, index.prefix(8) == Data([0xFF, 0x74, 0x4F, 0x63, 0, 0, 0, 2]) else {
            throw GitReadError.unsupported("pack index v1")
        }
        let indexBytes = index.count, packBytes = pack.count
        (fanout, offsets) = try index.withUnsafeBytes { raw -> ([Int], [Int]) in
            let fanout = (0..<256).map { Int(Self.be32(raw, 8 + $0 * 4)) }
            let n = fanout[255]
            guard zip(fanout, fanout.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw GitReadError.corrupt("pack index fanout") }
            let table = 8 + 1024 + n * 24
            let largeTable = table + n * 4
            guard largeTable + 40 <= indexBytes else { throw GitReadError.corrupt("pack index size") }
            let largeCount = (indexBytes - 40 - largeTable) / 8
            let offsets = try (0..<n).map { i -> Int in
                let small = Self.be32(raw, table + i * 4)
                var offset = Int(small)
                if small & 0x8000_0000 != 0 {
                    let slot = Int(small & 0x7FFF_FFFF)
                    guard slot < largeCount else { throw GitReadError.corrupt("pack index offset") }
                    let at = largeTable + slot * 8
                    offset = Int(clamping: UInt64(Self.be32(raw, at)) << 32 | UInt64(Self.be32(raw, at + 4)))
                }
                guard offset >= 12, offset < packBytes - 20 else { throw GitReadError.corrupt("pack index offset") }
                return offset
            }
            return (fanout, offsets)
        }
        count = fanout[255]
        sortedOffsets = offsets.sorted()
    }

    static func be32(_ raw: UnsafeRawBufferPointer, _ at: Int) -> UInt32 {
        UInt32(raw[at]) << 24 | UInt32(raw[at + 1]) << 16 | UInt32(raw[at + 2]) << 8 | UInt32(raw[at + 3])
    }

    /// Where the object starts in the pack, if this pack has it.
    func offset(of id: GitObjectID) -> Int? {
        index.withUnsafeBytes { raw -> Int? in
            let first = id.firstByte
            var low = first == 0 ? 0 : fanout[first - 1]
            var high = fanout[first]
            let ids = 8 + 1024
            while low < high {
                let mid = (low + high) / 2
                let candidate = GitObjectID(raw: raw, at: ids + mid * 20)
                if candidate == id { return offsets[mid] }
                if candidate < id { low = mid + 1 } else { high = mid }
            }
            return nil
        }
    }

    /// The end of the compressed entry starting at `offset`.
    func end(after offset: Int) -> Int {
        var low = 0, high = sortedOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if sortedOffsets[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low < sortedOffsets.count ? sortedOffsets[low] : pack.count - 20
    }

    struct EntryHeader {
        let type: Int
        let size: Int
        let dataStart: Int
        let baseOffset: Int?
        let baseID: GitObjectID?
    }

    func header(at offset: Int) throws -> EntryHeader {
        try pack.withUnsafeBytes { raw -> EntryHeader in
            var p = offset
            func next() throws -> UInt8 {
                guard p < raw.count - 20 else { throw GitReadError.corrupt("pack entry") }
                defer { p += 1 }
                return raw[p]
            }
            var byte = try next()
            let type = Int(byte >> 4 & 7)
            var size = Int(byte & 0x0F), shift = 4
            while byte & 0x80 != 0 {
                byte = try next()
                guard shift <= 46 else { throw GitReadError.corrupt("object too large") }
                size |= Int(byte & 0x7F) << shift
                shift += 7
            }
            guard size <= GitRepository.maxObjectBytes else { throw GitReadError.corrupt("object too large") }
            var baseOffset: Int?, baseID: GitObjectID?
            if type == 6 {
                // Git's own encoding: each continuation adds one before shifting, so every
                // distance has exactly one spelling.
                byte = try next()
                var distance = Int(byte & 0x7F)
                while byte & 0x80 != 0 {
                    byte = try next()
                    // No pack is larger than this; stop before the arithmetic could overflow.
                    guard distance < 1 << 48 else { throw GitReadError.corrupt("delta base offset") }
                    distance = ((distance + 1) << 7) | Int(byte & 0x7F)
                }
                guard distance > 0, distance <= offset else { throw GitReadError.corrupt("delta base offset") }
                baseOffset = offset - distance
            } else if type == 7 {
                guard p + 20 <= raw.count - 20 else { throw GitReadError.corrupt("delta base id") }
                baseID = GitObjectID(raw: raw, at: p)
                p += 20
            }
            return EntryHeader(type: type, size: size, dataStart: p, baseOffset: baseOffset, baseID: baseID)
        }
    }
}

public final class GitRepository {
    public let gitDirectory: URL
    public let commonDirectory: URL
    let config: GitConfig
    private let objectDirectories: [URL]
    /// An `alternates` entry points at an object store that is gone or cannot be read.
    public let hasUnreadableAlternates: Bool
    private let packs: [GitPack]
    private var cache: [CacheKey: (GitObjectKind, Data)] = [:]
    private var cacheBytes = 0
    private static let cacheLimit = 64 << 20
    /// No object is inflated beyond this. Sizes come from the files themselves, so a
    /// damaged pack must not be able to ask for an impossible allocation.
    static let maxObjectBytes = 512 << 20

    private struct CacheKey: Hashable { let pack: ObjectIdentifier; let offset: Int }

    public init(gitDirectory: URL, commonDirectory: URL) throws {
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
        config = GitConfig(url: commonDirectory.appendingPathComponent("config"))
        if config.value("extensions", "objectformat")?.lowercased() == "sha256" { throw GitReadError.unsupported("sha256") }
        let fm = FileManager.default
        if config.value("extensions", "refstorage")?.lowercased() == "reftable"
            || fm.fileExists(atPath: commonDirectory.appendingPathComponent("reftable").path) {
            throw GitReadError.unsupported("reftable")
        }
        let objects = commonDirectory.appendingPathComponent("objects")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: objects.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GitReadError.corrupt("no objects folder")
        }
        var directories = [objects]
        var missingAlternates = false
        if let alternates = try? String(contentsOf: objects.appendingPathComponent("info/alternates"), encoding: .utf8) {
            for line in alternates.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.isEmpty {
                let path = String(line)
                let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : objects.appendingPathComponent(path)).canonical
                // A real alternate is another repository's object store. Anything else is
                // not followed, so a repository cannot point the reader at arbitrary folders.
                guard url.lastPathComponent == "objects", url != objects.canonical else { continue }
                // Gone, or outside what the sandbox may read: part of the history is missing.
                if fm.isReadableFile(atPath: url.path), (try? fm.contentsOfDirectory(atPath: url.path)) != nil {
                    directories.append(url)
                } else {
                    missingAlternates = true
                }
            }
        }
        objectDirectories = directories
        hasUnreadableAlternates = missingAlternates
        var found: [GitPack] = []
        for directory in directories {
            let packDirectory = directory.appendingPathComponent("pack")
            let names = (try? fm.contentsOfDirectory(atPath: packDirectory.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".idx") {
                let pack = packDirectory.appendingPathComponent(String(name.dropLast(4)) + ".pack")
                guard fm.fileExists(atPath: pack.path) else { continue }
                found.append(try GitPack(pack: pack, index: packDirectory.appendingPathComponent(name)))
            }
        }
        packs = found
    }

    // MARK: - Refs

    /// Branches, tags, remote-tracking branches, the stash and `HEAD` (plus the `HEAD` of
    /// each extra worktree), with loose refs taking precedence over `packed-refs`.
    public func refs() throws -> [(name: String, id: GitObjectID)] {
        Self.refs(gitDirectory: gitDirectory, commonDirectory: commonDirectory)
    }

    /// The refs of a repository without opening its object database, for a cheap
    /// "has anything changed since last time" check.
    static func refs(gitDirectory: URL, commonDirectory: URL) -> [(name: String, id: GitObjectID)] {
        var byName: [String: GitObjectID] = [:]
        var symbolic: [String: String] = [:]
        if let packed = try? String(contentsOf: commonDirectory.appendingPathComponent("packed-refs"), encoding: .utf8) {
            for line in packed.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.hasPrefix("^") {
                let parts = line.split(separator: " ", maxSplits: 1)
                if parts.count == 2, let id = GitObjectID(hex: String(parts[0])) { byName[String(parts[1])] = id }
            }
        }
        let fm = FileManager.default
        for prefix in ["refs/heads", "refs/tags", "refs/remotes", "refs/stash"] {
            let base = commonDirectory.appendingPathComponent(prefix)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: base.path, isDirectory: &isDirectory) else { continue }
            let files = isDirectory.boolValue
                ? ((fm.enumerator(atPath: base.path)?.allObjects as? [String]) ?? []).map { prefix + "/" + $0 }
                : [prefix]
            for name in files {
                guard let text = try? String(contentsOf: commonDirectory.appendingPathComponent(name), encoding: .utf8) else { continue }
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("ref: ") { symbolic[name] = String(value.dropFirst(5)) }
                else if let id = GitObjectID(hex: value) { byName[name] = id }
            }
        }
        func resolve(_ value: String) -> GitObjectID? {
            if value.hasPrefix("ref: ") {
                let target = String(value.dropFirst(5))
                return byName[target] ?? symbolic[target].flatMap { byName[$0] }
            }
            return GitObjectID(hex: value)
        }
        for (name, target) in symbolic { if let id = byName[target] { byName[name] = id } }
        var heads: [(String, URL)] = [("HEAD", gitDirectory.appendingPathComponent("HEAD"))]
        let worktrees = commonDirectory.appendingPathComponent("worktrees")
        for name in ((try? fm.contentsOfDirectory(atPath: worktrees.path)) ?? []).sorted() {
            heads.append(("worktrees/\(name)/HEAD", worktrees.appendingPathComponent(name).appendingPathComponent("HEAD")))
        }
        for (name, url) in heads {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let id = resolve(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                byName[name] = id
            }
        }
        return byName.sorted { $0.key < $1.key }.map { (name: $0.key, id: $0.value) }
    }

    /// Every commit a ref below `underRefPrefix` has pointed at, from its reflog. For
    /// remote-tracking refs this includes commits that were pushed and later force-pushed away.
    public func reflogOldValues(underRefPrefix prefix: String) -> [GitObjectID] {
        let base = commonDirectory.appendingPathComponent("logs").appendingPathComponent(prefix)
        let files = (FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String]) ?? []
        var out: [GitObjectID] = []
        var seen = Set<GitObjectID>()
        for file in files.sorted() {
            guard let text = try? String(contentsOf: base.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2 else { continue }
                for part in parts.prefix(2) {
                    if let id = GitObjectID(hex: String(part)), !id.isZero, seen.insert(id).inserted { out.append(id) }
                }
            }
        }
        return out
    }

    /// Remote name to URL, from the repository's config.
    public func remoteURLs() -> [String: String] { config.values("remote", "url") }

    /// Remote name to push URL, for remotes that push somewhere other than they fetch from.
    public func remotePushURLs() -> [String: String] { config.values("remote", "pushurl") }

    /// Whether the object database holds anything at all. A repository with objects but
    /// no readable refs is damaged, not empty.
    public var hasObjects: Bool {
        if packs.contains(where: { $0.count > 0 }) { return true }
        let fm = FileManager.default
        return objectDirectories.contains { directory in
            ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).contains { name in
                name.count == 2 && name.allSatisfy(\.isHexDigit) && !((try? fm.contentsOfDirectory(atPath: directory.appendingPathComponent(name).path)) ?? []).isEmpty
            }
        }
    }

    /// Commits whose parents are absent because this is a shallow clone.
    public lazy var shallowCommits: Set<GitObjectID> = {
        let text = (try? String(contentsOf: commonDirectory.appendingPathComponent("shallow"), encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).compactMap { GitObjectID(hex: String($0)) })
    }()

    // MARK: - Objects

    public func object(_ id: GitObjectID) throws -> (kind: GitObjectKind, data: Data) {
        for pack in packs {
            if let offset = pack.offset(of: id) { return try packed(pack, at: offset, depth: 0) }
        }
        if let loose = try loose(id) { return loose }
        throw GitReadError.missingObject(id.hex)
    }

    /// The object's size without inflating all of it.
    public func objectSize(_ id: GitObjectID) throws -> Int {
        for pack in packs {
            guard let offset = pack.offset(of: id) else { continue }
            let header = try pack.header(at: offset)
            guard header.type == 6 || header.type == 7 else { return header.size }
            // A delta starts with two sizes: its base's, then the result's.
            let prefix = try Self.inflatePrefix(pack.pack, from: header.dataStart, to: pack.end(after: offset), count: 32)
            var p = 0
            _ = try Self.varint(prefix, &p)
            return try Self.varint(prefix, &p)
        }
        for url in looseURLs(id) {
            guard let raw = try? Data(contentsOf: url) else { continue }
            let prefix = try Self.inflatePrefix(raw, from: 0, to: raw.count, count: 64)
            guard let nul = prefix.firstIndex(of: 0), let space = prefix[..<nul].firstIndex(of: 0x20),
                  let size = Int(String(decoding: prefix[prefix.index(after: space)..<nul], as: UTF8.self)) else {
                throw GitReadError.corrupt("loose object header")
            }
            return size
        }
        throw GitReadError.missingObject(id.hex)
    }

    /// The commit `id` names, peeling annotated tags.
    public func commit(_ id: GitObjectID) throws -> GitCommit {
        var current = id
        for _ in 0..<16 {
            let (kind, data) = try object(current)
            switch kind {
            case .commit:
                return try Self.parseCommit(data)
            case .tag:
                guard let target = Self.headerLines(data).first(where: { $0.hasPrefix("object ") }).flatMap({ GitObjectID(hex: String($0.dropFirst(7))) }) else {
                    throw GitReadError.corrupt("tag")
                }
                current = target
            case .tree, .blob:
                throw GitReadError.corrupt("not a commit")
            }
        }
        throw GitReadError.corrupt("tag chain")
    }

    public func tree(_ id: GitObjectID) throws -> [GitTreeEntry] {
        let (kind, data) = try object(id)
        guard kind == .tree else { throw GitReadError.corrupt("not a tree") }
        return try data.withUnsafeBytes { raw -> [GitTreeEntry] in
            var out: [GitTreeEntry] = []
            var p = 0
            while p < raw.count {
                guard let space = (p..<raw.count).first(where: { raw[$0] == 0x20 }),
                      let nul = (space..<raw.count).first(where: { raw[$0] == 0 }), nul + 21 <= raw.count else {
                    throw GitReadError.corrupt("tree entry")
                }
                let mode = String(decoding: UnsafeRawBufferPointer(rebasing: raw[p..<space]), as: UTF8.self)
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(space + 1)..<nul]), as: UTF8.self)
                let entryID = GitObjectID(raw: raw, at: nul + 1)
                out.append(GitTreeEntry(name: name, id: entryID, isTree: mode == "40000", isFile: mode.hasPrefix("100")))
                p = nul + 21
            }
            return out
        }
    }

    // MARK: - Internals

    /// Reads a packed object, resolving its chain of deltas in a loop rather than by
    /// recursion: git allows chains thousands long, and a scan runs on a small-stack thread.
    private func packed(_ pack: GitPack, at offset: Int, depth _: Int) throws -> (GitObjectKind, Data) {
        var chain: [(pack: GitPack, offset: Int, header: GitPack.EntryHeader)] = []
        var current = (pack: pack, offset: offset)
        var base: (GitObjectKind, Data)
        while true {
            if let hit = cache[CacheKey(pack: ObjectIdentifier(current.pack), offset: current.offset)] { base = hit; break }
            guard chain.count < 10_000 else { throw GitReadError.corrupt("delta chain") }
            let header = try current.pack.header(at: current.offset)
            switch header.type {
            case 1...4:
                let raw = try Self.inflate(current.pack.pack, from: header.dataStart, to: current.pack.end(after: current.offset), size: header.size)
                base = ([GitObjectKind.commit, .tree, .blob, .tag][header.type - 1], raw)
                remember(base, pack: current.pack, offset: current.offset)
            case 6:
                chain.append((current.pack, current.offset, header))
                current = (current.pack, header.baseOffset!)
                continue
            case 7:
                chain.append((current.pack, current.offset, header))
                let baseID = header.baseID!
                if let inPack = packs.lazy.compactMap({ p in p.offset(of: baseID).map { (p, $0) } }).first {
                    current = (inPack.0, inPack.1)
                    continue
                }
                guard let loose = try loose(baseID) else { throw GitReadError.missingObject(baseID.hex) }
                base = loose
            default:
                throw GitReadError.corrupt("pack entry type \(header.type)")
            }
            break
        }
        for link in chain.reversed() {
            let delta = try Self.inflate(link.pack.pack, from: link.header.dataStart, to: link.pack.end(after: link.offset), size: link.header.size)
            base = (base.0, try Self.applyDelta(delta, to: base.1))
            remember(base, pack: link.pack, offset: link.offset)
        }
        return base
    }

    /// Delta bases are read again and again while walking history; keep the small ones.
    private func remember(_ object: (GitObjectKind, Data), pack: GitPack, offset: Int) {
        guard object.1.count < 4 << 20 else { return }
        if cacheBytes + object.1.count > Self.cacheLimit { cache.removeAll(); cacheBytes = 0 }
        cache[CacheKey(pack: ObjectIdentifier(pack), offset: offset)] = object
        cacheBytes += object.1.count
    }

    private func looseURLs(_ id: GitObjectID) -> [URL] {
        let hex = id.hex
        return objectDirectories.map { $0.appendingPathComponent(String(hex.prefix(2))).appendingPathComponent(String(hex.dropFirst(2))) }
    }

    private func loose(_ id: GitObjectID) throws -> (GitObjectKind, Data)? {
        for url in looseURLs(id) {
            guard let raw = try? Data(contentsOf: url) else { continue }
            guard raw.count > 2, let full = try? (Data(raw.dropFirst(2)) as NSData).decompressed(using: .zlib) as Data,
                  let nul = full.firstIndex(of: 0), let space = full[..<nul].firstIndex(of: 0x20) else {
                throw GitReadError.corrupt("loose object \(id.hex)")
            }
            let kind: GitObjectKind
            switch String(decoding: full[full.startIndex..<space], as: UTF8.self) {
            case "commit": kind = .commit
            case "tree": kind = .tree
            case "blob": kind = .blob
            case "tag": kind = .tag
            default: throw GitReadError.corrupt("loose object type")
            }
            return (kind, Data(full[full.index(after: nul)...]))
        }
        return nil
    }

    /// Inflates a zlib stream whose inflated size is known. Bytes after the stream are ignored.
    static func inflate(_ data: Data, from start: Int, to end: Int, size: Int) throws -> Data {
        guard start + 2 <= end, end <= data.count else { throw GitReadError.corrupt("compressed entry bounds") }
        guard size >= 0, size <= maxObjectBytes else { throw GitReadError.corrupt("object too large") }
        if size == 0 { return Data() }
        var out = Data(count: size + 1)
        let written = data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                                          src.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start + 2), end - start - 2,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw GitReadError.corrupt("inflated size") }
        out.removeLast()
        return out
    }

    /// The first `count` bytes of a zlib stream, without inflating the rest.
    static func inflatePrefix(_ data: Data, from start: Int, to end: Int, count: Int) throws -> Data {
        guard start + 2 <= end, end <= data.count else { throw GitReadError.corrupt("compressed entry bounds") }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GitReadError.corrupt("inflate")
        }
        defer { compression_stream_destroy(stream) }
        var out = [UInt8](repeating: 0, count: count)
        let produced = data.withUnsafeBytes { src -> Int in
            out.withUnsafeMutableBufferPointer { dst -> Int in
                stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!.advanced(by: start + 2)
                stream.pointee.src_size = end - start - 2
                stream.pointee.dst_ptr = dst.baseAddress!
                stream.pointee.dst_size = count
                while stream.pointee.dst_size > 0 {
                    let status = compression_stream_process(stream, 0)
                    if status != COMPRESSION_STATUS_OK || stream.pointee.src_size == 0 { break }
                }
                return count - stream.pointee.dst_size
            }
        }
        return Data(out.prefix(produced))
    }

    static func varint(_ data: Data, _ p: inout Int) throws -> Int {
        var result = 0, shift = 0
        while true {
            guard p < data.count, shift < 63 else { throw GitReadError.corrupt("varint") }
            let byte = data[data.startIndex + p]
            p += 1
            result |= Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { return result }
        }
    }

    static func applyDelta(_ delta: Data, to base: Data) throws -> Data {
        var p = 0
        guard try varint(delta, &p) == base.count else { throw GitReadError.corrupt("delta base size") }
        let size = try varint(delta, &p)
        guard size <= maxObjectBytes else { throw GitReadError.corrupt("object too large") }
        var out = [UInt8]()
        out.reserveCapacity(size)
        try delta.withUnsafeBytes { d in
            try base.withUnsafeBytes { b in
                while p < d.count {
                    let op = d[p]
                    p += 1
                    if op & 0x80 != 0 {
                        var offset = 0, length = 0
                        for i in 0..<4 where op & (1 << i) != 0 {
                            guard p < d.count else { throw GitReadError.corrupt("delta copy") }
                            offset |= Int(d[p]) << (8 * i); p += 1
                        }
                        for i in 0..<3 where op & (1 << (4 + i)) != 0 {
                            guard p < d.count else { throw GitReadError.corrupt("delta copy") }
                            length |= Int(d[p]) << (8 * i); p += 1
                        }
                        if length == 0 { length = 0x10000 }
                        guard offset + length <= b.count else { throw GitReadError.corrupt("delta copy range") }
                        // The declared size bounds memory: never grow past it, then check.
                        guard out.count + length <= size else { throw GitReadError.corrupt("delta overflows its size") }
                        out.append(contentsOf: UnsafeRawBufferPointer(rebasing: b[offset..<(offset + length)]))
                    } else if op != 0 {
                        let length = Int(op)
                        guard p + length <= d.count else { throw GitReadError.corrupt("delta insert") }
                        guard out.count + length <= size else { throw GitReadError.corrupt("delta overflows its size") }
                        out.append(contentsOf: UnsafeRawBufferPointer(rebasing: d[p..<(p + length)]))
                        p += length
                    } else {
                        throw GitReadError.corrupt("delta opcode")
                    }
                }
            }
        }
        guard out.count == size else { throw GitReadError.corrupt("delta result size") }
        return Data(out)
    }

    static func headerLines(_ data: Data) -> [Substring] {
        let end = data.range(of: Data([0x0A, 0x0A])).map { $0.lowerBound } ?? data.endIndex
        return String(decoding: data[data.startIndex..<end], as: UTF8.self).split(separator: "\n")
    }

    static func parseCommit(_ data: Data) throws -> GitCommit {
        var tree: GitObjectID?
        var parents: [GitObjectID] = []
        var author = "", committer = ""
        func email(_ line: Substring) -> String {
            guard let open = line.firstIndex(of: "<"), let close = line[open...].firstIndex(of: ">") else { return "" }
            return line[line.index(after: open)..<close].lowercased()
        }
        for line in headerLines(data) {
            if line.hasPrefix("tree ") { tree = GitObjectID(hex: String(line.dropFirst(5))) }
            else if line.hasPrefix("parent ") { if let id = GitObjectID(hex: String(line.dropFirst(7))) { parents.append(id) } }
            else if line.hasPrefix("author ") { author = email(line) }
            else if line.hasPrefix("committer ") { committer = email(line) }
        }
        guard let tree else { throw GitReadError.corrupt("commit without tree") }
        return GitCommit(tree: tree, parents: parents, authorEmail: author, committerEmail: committer)
    }
}
