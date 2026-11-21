import CryptoKit
import Foundation

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    /// Conversation logs an agent writes to disk.
    case agentTranscript
    /// Agent settings and MCP configs, which often carry tokens in an `env` block.
    case agentConfig
    case shellHistory
    case envFile
    /// Files that hold credentials by design (`~/.aws/credentials`, `~/.npmrc`).
    case credentialsFile

    /// A pure record of what happened (a transcript, a command history). Nothing reads a
    /// key back out of these, so removing it is safe. A config or .env file is different:
    /// something uses the key there, and replacing it would break that.
    public var isRecord: Bool {
        switch self {
        case .agentTranscript, .shellHistory: return true
        case .agentConfig, .envFile, .credentialsFile: return false
        }
    }

    /// A copy that should not exist at all (an agent or a shell wrote it down), as
    /// opposed to a file whose job is to hold keys.
    public var isLeak: Bool {
        switch self {
        case .agentTranscript, .agentConfig, .shellHistory: return true
        case .envFile, .credentialsFile: return false
        }
    }
}

/// One place on disk where secrets tend to end up.
public struct ScanSource: Sendable {
    enum Matcher: Sendable {
        /// `root` is the file itself.
        case file
        /// Every file below `root` with one of these extensions or exact names.
        case tree(extensions: Set<String>, names: Set<String>)
        /// Walk project folders below `root` looking for .env files and per-project agent configs.
        case projects(maxDepth: Int)
    }

    public let id: String
    public let label: String
    public let kind: SourceKind
    public let root: URL
    let matcher: Matcher
}

public enum SourceCatalog {
    /// Folders that are never worth walking when looking for project files.
    static let skippedDirectories: Set<String> = [
        "node_modules", "Library", "Applications", "Pictures", "Movies", "Music", "Public",
        "vendor", "venv", "env", "Pods", "DerivedData", "build", "dist", "out", "target", "coverage",
        "site-packages", "bower_components", "__pycache__",
    ]

    static let envFileSuffixesToSkip = [".example", ".sample", ".template", ".dist", ".defaults", ".schema"]

    /// Known locations, most important first. Paths that do not exist are simply skipped.
    public static func standard(home: URL) -> [ScanSource] {
        func at(_ path: String) -> URL { home.appendingPathComponent(path) }
        let appSupport = "Library/Application Support"
        return [
            .init(id: "claude-transcripts", label: "Claude Code transcripts", kind: .agentTranscript,
                  root: at(".claude/projects"), matcher: .tree(extensions: ["jsonl"], names: [])),
            .init(id: "claude-history", label: "Claude Code prompt history", kind: .agentTranscript,
                  root: at(".claude/history.jsonl"), matcher: .file),
            .init(id: "codex-transcripts", label: "Codex transcripts", kind: .agentTranscript,
                  root: at(".codex/sessions"), matcher: .tree(extensions: ["jsonl", "json"], names: [])),
            .init(id: "codex-history", label: "Codex prompt history", kind: .agentTranscript,
                  root: at(".codex/history.jsonl"), matcher: .file),
            .init(id: "cursor-history", label: "Cursor chat history", kind: .agentTranscript,
                  root: at("\(appSupport)/Cursor/User"), matcher: .tree(extensions: [], names: ["state.vscdb"])),
            .init(id: "windsurf-history", label: "Windsurf chat history", kind: .agentTranscript,
                  root: at("\(appSupport)/Windsurf/User"), matcher: .tree(extensions: [], names: ["state.vscdb"])),
            .init(id: "gemini-history", label: "Gemini CLI history", kind: .agentTranscript,
                  root: at(".gemini/tmp"), matcher: .tree(extensions: ["json", "jsonl"], names: [])),
            .init(id: "opencode-history", label: "OpenCode history", kind: .agentTranscript,
                  root: at(".local/share/opencode"), matcher: .tree(extensions: ["json", "jsonl"], names: [])),

            .init(id: "claude-settings", label: "Claude Code settings", kind: .agentConfig,
                  root: at(".claude/settings.json"), matcher: .file),
            .init(id: "claude-settings-local", label: "Claude Code settings", kind: .agentConfig,
                  root: at(".claude/settings.local.json"), matcher: .file),
            .init(id: "claude-config", label: "Claude Code MCP config", kind: .agentConfig,
                  root: at(".claude.json"), matcher: .file),
            .init(id: "claude-desktop", label: "Claude Desktop MCP config", kind: .agentConfig,
                  root: at("\(appSupport)/Claude/claude_desktop_config.json"), matcher: .file),
            .init(id: "cursor-mcp", label: "Cursor MCP config", kind: .agentConfig,
                  root: at(".cursor/mcp.json"), matcher: .file),
            .init(id: "codex-config", label: "Codex config", kind: .agentConfig,
                  root: at(".codex/config.toml"), matcher: .file),
            .init(id: "windsurf-mcp", label: "Windsurf MCP config", kind: .agentConfig,
                  root: at(".codeium/windsurf/mcp_config.json"), matcher: .file),

            .init(id: "zsh-history", label: "Shell history (zsh)", kind: .shellHistory,
                  root: at(".zsh_history"), matcher: .file),
            .init(id: "bash-history", label: "Shell history (bash)", kind: .shellHistory,
                  root: at(".bash_history"), matcher: .file),
            .init(id: "fish-history", label: "Shell history (fish)", kind: .shellHistory,
                  root: at(".local/share/fish/fish_history"), matcher: .file),

            .init(id: "projects", label: "Project files", kind: .envFile,
                  root: home, matcher: .projects(maxDepth: 6)),
        ]
    }

    /// Roots worth watching for live changes: the places agents write to while they work.
    public static func watchRoots(home: URL) -> [URL] {
        [".claude", ".codex", ".cursor", ".gemini"].map { home.appendingPathComponent($0) }
    }

    static func isSecretEnvFileName(_ name: String) -> Bool {
        guard name == ".env" || name.hasPrefix(".env.") else { return false }
        return !envFileSuffixesToSkip.contains { name.hasSuffix($0) }
    }
}

public enum FindingStatus: String, Codable, Sendable {
    case open
    /// The user replaced the key at the provider. The leaked copy is now harmless.
    case rotated
    case ignored
}

/// A secret seen somewhere it should not be. Carries a preview and a fingerprint, never the value.
public struct Finding: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let ruleID: String
    public let service: String
    /// Variable name when the secret came from a `NAME=value` line.
    public var name: String?
    public let preview: String
    public let fingerprint: String
    public let path: String
    /// First line the secret appears on.
    public let line: Int
    /// How many times it appears in this file.
    public var count: Int
    public let kind: SourceKind
    public let sourceLabel: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var status: FindingStatus
    /// Set when the copy in this file was removed. The finding is kept until the user
    /// rotates the key, because removing a copy does not un-leak it.
    public var localCopyRemovedAt: Date?

    public init(id: String, ruleID: String, service: String, name: String?, preview: String, fingerprint: String, path: String,
                line: Int, count: Int, kind: SourceKind, sourceLabel: String, firstSeen: Date, lastSeen: Date, status: FindingStatus) {
        self.id = id; self.ruleID = ruleID; self.service = service; self.name = name; self.preview = preview
        self.fingerprint = fingerprint; self.path = path; self.line = line; self.count = count; self.kind = kind
        self.sourceLabel = sourceLabel; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.status = status
    }

    /// Databases cannot be edited safely as text; the only fix for those is to rotate the key.
    public var canScrub: Bool {
        !["vscdb", "db", "sqlite", "sqlite3"].contains((path as NSString).pathExtension.lowercased())
    }
}

public struct FileScanResult: Sendable {
    public let findings: [Finding]
    /// Byte offset to resume from next time, for files that only ever grow.
    public let endOffset: UInt64
    /// Number of complete lines read so far.
    public let endLine: Int
}

public final class SecretScanner: @unchecked Sendable {
    public let detector: SecretDetector
    private let fingerprint: (String) -> String
    private let chunkSize: Int
    /// Files larger than this are skipped rather than stalling a scan.
    public var maxFileBytes: UInt64 = 2_000_000_000

    public init(detector: SecretDetector = SecretDetector(), fingerprint: @escaping (String) -> String, chunkSize: Int = 1 << 20) {
        self.detector = detector
        self.fingerprint = fingerprint
        self.chunkSize = chunkSize
    }

    // MARK: - Whole-machine scan

    public func scanAll(_ sources: [ScanSource], now: Date = Date(),
                        progress: ((_ label: String, _ filesDone: Int) -> Void)? = nil,
                        isCancelled: () -> Bool = { false }) -> [Finding] {
        var seen = Set<String>()
        var out: [Finding] = []
        var done = 0
        for source in sources {
            for (file, effective) in files(for: source) {
                if isCancelled() { return out }
                guard seen.insert(file.path).inserted else { continue }
                if let result = try? scan(file: file, source: effective, now: now) {
                    out.append(contentsOf: result.findings)
                }
                done += 1
                if done % 25 == 0 { progress?(source.label, done) }
            }
        }
        progress?("Done", done)
        return out
    }

    /// The source a changed file belongs to, if any. Used by the live watch.
    ///
    /// A file can be reached by more than one spelling (through a symlinked project
    /// folder, or `/var` versus `/private/var`). Both the path as given and its resolved
    /// form are tried against both forms of each root, so neither spelling is missed.
    public func source(for rawFile: URL, in sources: [ScanSource]) -> ScanSource? {
        let filePaths = Set([rawFile.standardizedFileURL.path, rawFile.canonical.path])
        let name = rawFile.lastPathComponent
        func rootPaths(_ source: ScanSource) -> Set<String> { [source.root.standardizedFileURL.path, source.root.canonical.path] }
        func isInside(_ source: ScanSource) -> Bool {
            rootPaths(source).contains { root in filePaths.contains { $0.hasPrefix(root + "/") } }
        }
        for source in sources {
            switch source.matcher {
            case .file:
                if !rootPaths(source).isDisjoint(with: filePaths) { return source }
            case .tree(let extensions, let names):
                guard isInside(source) else { continue }
                if names.contains(name) || extensions.contains(rawFile.pathExtension.lowercased()) { return source }
            case .projects:
                guard isInside(source) else { continue }
                if let project = Self.projectSource(for: rawFile, base: source) { return project }
            }
        }
        return nil
    }

    // MARK: - One file

    public func scan(file rawFile: URL, source: ScanSource, fromOffset: UInt64 = 0, startLine: Int = 0, now: Date = Date()) throws -> FileScanResult {
        let file = rawFile.canonical
        var hits: [String: Finding] = [:]
        var order: [String] = []

        func record(ruleID: String, service: String, name: String?, value: String, line: Int) {
            let print = fingerprint(value)
            if var existing = hits[print] {
                existing.count += 1
                if existing.name == nil { existing.name = name }
                hits[print] = existing
                return
            }
            order.append(print)
            hits[print] = Finding(
                id: Self.findingID(fingerprint: print, path: file.path),
                ruleID: ruleID, service: service, name: name, preview: Redactor.preview(value), fingerprint: print,
                path: file.path, line: line, count: 1, kind: source.kind, sourceLabel: source.label,
                firstSeen: now, lastSeen: now, status: .open)
        }

        let isEnvFile = source.kind == .envFile
        let reader = try LineBlockReader(url: file, offset: fromOffset, chunkSize: chunkSize, maxBytes: maxFileBytes)
        var line = startLine
        try reader.forEachBlock { part in
            let block = part.data
            if isEnvFile {
                // .env files are small, and need the NAME=value heuristic as well as the shape rules.
                let text = String(decoding: block, as: UTF8.self)
                let matches = detector.matches(in: text)
                let assignments = detector.envAssignments(in: text)
                let lines = LineIndex(text)
                for match in matches {
                    let name = assignments.first { $0.value.contains(match.value) || match.value.contains($0.value) }?.name
                    record(ruleID: match.rule.id, service: match.rule.service, name: name, value: match.value,
                           line: line + lines.lineNumber(atUTF16Offset: match.offset))
                }
                for assignment in assignments where !matches.contains(where: { $0.value.contains(assignment.value) || assignment.value.contains($0.value) }) {
                    let offset = (text as NSString).range(of: assignment.value).location
                    record(ruleID: "env-assignment", service: "API key", name: assignment.name, value: assignment.value,
                           line: line + lines.lineNumber(atUTF16Offset: offset == NSNotFound ? 0 : offset))
                }
                line += lines.count
                return
            }
            let result = detector.scan(block)
            for match in result.matches {
                let end = match.byteOffset + match.value.utf8.count
                // Already counted at the end of the previous block.
                if part.overlapPrefix > 0, end <= part.overlapPrefix { continue }
                // Touches the cut: probably half a key. The next block has it whole.
                if part.truncated, end >= block.count { continue }
                record(ruleID: match.rule.id, service: match.rule.service, name: nil, value: match.value, line: line + match.line)
            }
            line += result.newlines
        }
        return FileScanResult(findings: order.compactMap { hits[$0] }, endOffset: reader.endOffset, endLine: line)
    }

    /// Values in `block` whose fingerprint is one of `targets`, with the fingerprint each
    /// belongs to. Used by the scrubber to locate what to remove.
    func values(in block: Data, matching targets: Set<String>, includeEnvAssignments: Bool) -> [String: String] {
        var out: [String: String] = [:]
        for match in detector.scan(block).matches {
            let print = fingerprint(match.value)
            if targets.contains(print) { out[match.value] = print }
        }
        if includeEnvAssignments {
            for assignment in detector.envAssignments(in: String(decoding: block, as: UTF8.self)) {
                let print = fingerprint(assignment.value)
                if targets.contains(print) { out[assignment.value] = print }
            }
        }
        return out
    }

    // MARK: - File discovery

    func files(for source: ScanSource) -> [(URL, ScanSource)] {
        let fm = FileManager.default
        switch source.matcher {
        case .file:
            return fm.isReadableFile(atPath: source.root.path) ? [(source.root, source)] : []
        case .tree(let extensions, let names):
            guard let walker = fm.enumerator(at: source.root, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsPackageDescendants]) else { return [] }
            var out: [(URL, ScanSource)] = []
            for case let url as URL in walker {
                if names.contains(url.lastPathComponent) || extensions.contains(url.pathExtension.lowercased()) {
                    if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append((url, source)) }
                }
            }
            return out
        case .projects(let maxDepth):
            var out: [(URL, ScanSource)] = []
            walkProjects(source.root, depth: 0, maxDepth: maxDepth, base: source, into: &out)
            return out
        }
    }

    private func walkProjects(_ dir: URL, depth: Int, maxDepth: Int, base: ScanSource, into out: inout [(URL, ScanSource)]) {
        let fm = FileManager.default
        // Per-project agent files live in hidden folders we otherwise do not descend into.
        for relative in [".claude/settings.local.json", ".claude/settings.json", ".cursor/mcp.json", ".mcp.json", ".aider.chat.history.md"] {
            let url = dir.appendingPathComponent(relative)
            if fm.isReadableFile(atPath: url.path), let source = Self.projectSource(for: url, base: base) { out.append((url, source)) }
        }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                if depth < maxDepth, !name.hasPrefix("."), !SourceCatalog.skippedDirectories.contains(name) {
                    walkProjects(entry, depth: depth + 1, maxDepth: maxDepth, base: base, into: &out)
                }
            } else if SourceCatalog.isSecretEnvFileName(name), let source = Self.projectSource(for: entry, base: base) {
                out.append((entry, source))
            }
        }
    }

    /// Classifies a file found inside a project folder.
    static func projectSource(for file: URL, base: ScanSource) -> ScanSource? {
        let name = file.lastPathComponent
        let parent = file.deletingLastPathComponent().lastPathComponent
        if SourceCatalog.isSecretEnvFileName(name) {
            return ScanSource(id: "env-file", label: "Env file", kind: .envFile, root: file, matcher: .file)
        }
        if name == ".aider.chat.history.md" {
            return ScanSource(id: "aider-history", label: "Aider chat history", kind: .agentTranscript, root: file, matcher: .file)
        }
        if name == ".mcp.json" || (parent == ".cursor" && name == "mcp.json") {
            return ScanSource(id: "project-mcp", label: "Project MCP config", kind: .agentConfig, root: file, matcher: .file)
        }
        if parent == ".claude", name == "settings.local.json" || name == "settings.json" {
            return ScanSource(id: "project-claude-settings", label: "Claude Code project settings", kind: .agentConfig, root: file, matcher: .file)
        }
        return nil
    }

    static func findingID(fingerprint: String, path: String) -> String {
        SHA256.hash(data: Data((fingerprint + "|" + path).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Reading large files

/// Reads a file in chunks and hands back blocks that end on a line boundary, so a
/// multi-gigabyte transcript never has to fit in memory and no key is cut in half.
final class LineBlockReader {
    private let handle: FileHandle
    private let chunkSize: Int
    private let maxBytes: UInt64
    private(set) var endOffset: UInt64

    init(url: URL, offset: UInt64, chunkSize: Int, maxBytes: UInt64) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = chunkSize
        self.maxBytes = maxBytes
        endOffset = offset
        try handle.seek(toOffset: offset)
    }

    deinit { try? handle.close() }

    /// One block of the file. `overlapPrefix` bytes at the start were already delivered at
    /// the end of the previous block; `truncated` means the block stops mid-line.
    struct Block {
        let data: Data
        let overlapPrefix: Int
        let truncated: Bool
    }

    /// Number of bytes repeated between two blocks when a single line is too long to hold.
    /// Longer than any key we detect, so a key cut by one block is whole in the next.
    static let overlap = 512

    /// - Parameter allowOverlap: pass `false` when the blocks will be written back out
    ///   (scrubbing), where repeating bytes would corrupt the file.
    func forEachBlock(allowOverlap: Bool = true, _ body: (Block) throws -> Void) throws {
        var pending = Data()
        var delivered = 0  // bytes at the start of `pending` already handed out as overlap
        var read: UInt64 = 0
        while read < maxBytes, let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            read += UInt64(chunk.count)
            pending.append(chunk)
            if let newline = pending.lastIndex(of: 0x0A) {
                let cut = pending.index(after: newline)
                try body(Block(data: pending.subdata(in: pending.startIndex..<cut), overlapPrefix: delivered, truncated: false))
                pending = pending.subdata(in: cut..<pending.endIndex)
                delivered = 0
            } else if allowOverlap, pending.count > 8 * chunkSize {
                // One enormous line (a database blob, a minified file). Hand it out now and
                // repeat its tail at the start of the next block.
                try body(Block(data: pending, overlapPrefix: delivered, truncated: true))
                pending = pending.suffix(Self.overlap)
                pending = Data(pending)
                delivered = pending.count
            }
        }
        if pending.count > delivered { try body(Block(data: pending, overlapPrefix: delivered, truncated: false)) }
        endOffset += read
    }
}

/// Maps a UTF-16 offset in a block of text to a 1-based line number within that block.
struct LineIndex {
    private let newlineOffsets: [Int]

    init(_ text: String) {
        var offsets: [Int] = []
        var i = 0
        for unit in text.utf16 {
            if unit == 0x0A { offsets.append(i) }
            i += 1
        }
        newlineOffsets = offsets
    }

    /// Number of line breaks in the text.
    var count: Int { newlineOffsets.count }

    func lineNumber(atUTF16Offset offset: Int) -> Int {
        var low = 0, high = newlineOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if newlineOffsets[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low + 1
    }
}

// MARK: - Remembering findings

extension Finding {
    /// The copy is gone from disk but the key has not been replaced yet.
    var awaitsRotation: Bool { localCopyRemovedAt != nil && status == .open }
}

/// Findings on disk, redacted. Keeps what the user decided ("I rotated this") across rescans.
public final class FindingStore {
    public let url: URL
    public private(set) var findings: [Finding] = []

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? Crypto.decoder.decode([Finding].self, from: data) {
            findings = saved
        }
    }

    public var openCount: Int { findings.filter { $0.status == .open }.count }

    /// After a full scan: anything no longer found is gone; anything still there keeps its history.
    public func replaceAll(with fresh: [Finding]) {
        let previous = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let freshIDs = Set(fresh.map(\.id))
        findings = fresh.map { carry(previous[$0.id], into: $0) } + findings.filter { $0.awaitsRotation && !freshIDs.contains($0.id) }
        save()
    }

    /// Records that the copy in a file was removed, and keeps the finding until it is rotated.
    public func markLocalCopyRemoved(_ id: String, at date: Date = Date()) {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[index].localCopyRemovedAt = date
        save()
    }

    /// Swap the findings for one file, keeping the user's decisions on those that remain.
    public func replace(path: String, with fresh: [Finding]) {
        let old = findings.filter { $0.path == path }
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let freshIDs = Set(fresh.map(\.id))
        findings.removeAll { $0.path == path }
        findings.append(contentsOf: fresh.map { carry(previous[$0.id], into: $0) })
        findings.append(contentsOf: old.filter { $0.awaitsRotation && !freshIDs.contains($0.id) })
        save()
    }

    public func setStatus(_ status: FindingStatus, for id: String) {
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[index].status = status
        save()
    }

    /// Mark every copy of one secret at once, wherever it was found.
    public func setStatus(_ status: FindingStatus, forFingerprint fingerprint: String) {
        for index in findings.indices where findings[index].fingerprint == fingerprint { findings[index].status = status }
        save()
    }

    public func remove(_ id: String) {
        findings.removeAll { $0.id == id }
        save()
    }

    private func carry(_ old: Finding?, into new: Finding) -> Finding {
        guard let old else { return new }
        var merged = new
        merged.status = old.status
        merged.firstSeen = old.firstSeen
        // Found in the file again, so any earlier removal no longer describes it.
        merged.localCopyRemovedAt = nil
        return merged
    }

    private func save() {
        if let data = try? Crypto.encoder.encode(findings) { try? SecureFile.write(data, to: url) }
    }
}

// MARK: - Removing a leaked copy

public enum ScrubError: Error, Equatable {
    /// Databases and other binary formats. Editing them as text would corrupt them.
    case unsupportedFile
    /// Changed moments ago, so an agent may still be appending to it.
    case recentlyModified
    case notFound
    case unreadable
}

/// Replaces a leaked secret inside a text file with a placeholder.
///
/// This only removes the local copy. A key that reached a transcript was already sent
/// to the model provider, so the real fix is always to rotate it.
public struct Scrubber {
    let scanner: SecretScanner
    public var minimumAge: TimeInterval = 120

    public init(scanner: SecretScanner) { self.scanner = scanner }

    /// Returns how many occurrences were replaced.
    @discardableResult
    public func scrub(_ finding: Finding, now: Date = Date()) throws -> Int {
        guard finding.canScrub else { throw ScrubError.unsupportedFile }
        let counts = try scrub(fingerprints: [finding.fingerprint], path: finding.path, isEnvFile: finding.kind == .envFile, now: now)
        return counts[finding.fingerprint] ?? 0
    }

    /// Removes several secrets from one file in a single rewrite, and returns how many
    /// occurrences of each were replaced. One pass matters: a second rewrite would be
    /// refused, because the first one makes the file look "changed moments ago".
    @discardableResult
    public func scrub(fingerprints: Set<String>, path: String, isEnvFile: Bool, now: Date = Date()) throws -> [String: Int] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard !["vscdb", "db", "sqlite", "sqlite3"].contains(url.pathExtension.lowercased()) else { throw ScrubError.unsupportedFile }
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { throw ScrubError.unreadable }
        guard now.timeIntervalSince(modified) >= minimumAge else { throw ScrubError.recentlyModified }

        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).agentsafe-\(UUID().uuidString).tmp")
        let permissions = attributes[.posixPermissions] ?? NSNumber(value: 0o600)
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: permissions]) else { throw ScrubError.unreadable }
        var replaced: [String: Int] = [:]
        do {
            let output = try FileHandle(forWritingTo: temp)
            defer { try? output.close() }
            let placeholder = Data(Redactor.placeholder.utf8)
            let reader = try LineBlockReader(url: url, offset: 0, chunkSize: 1 << 20, maxBytes: .max)
            try reader.forEachBlock(allowOverlap: false) { part in
                let values = scanner.values(in: part.data, matching: fingerprints, includeEnvAssignments: isEnvFile)
                var data = part.data
                // Replace at the byte level so every other byte of the file stays exactly as it was.
                for (value, print) in values {
                    let needle = Data(value.utf8)
                    var searchStart = data.startIndex
                    while let range = data.range(of: needle, in: searchStart..<data.endIndex) {
                        data.replaceSubrange(range, with: placeholder)
                        searchStart = data.index(range.lowerBound, offsetBy: placeholder.count)
                        replaced[print, default: 0] += 1
                    }
                }
                try output.write(contentsOf: data)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw ScrubError.unreadable
        }
        guard !replaced.isEmpty else {
            try? fm.removeItem(at: temp)
            throw ScrubError.notFound
        }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw ScrubError.unreadable
        }
        // Keep the file's original date, so agents that list sessions by date do not show
        // every cleaned transcript as "used just now".
        try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return replaced
    }
}
