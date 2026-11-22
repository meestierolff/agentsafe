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
    /// An earlier version of a key-holding file, kept in a git repository's history.
    case gitHistory

    /// A pure record of what happened (a transcript, a command history). Nothing reads a
    /// key back out of these, so removing it is safe. A config or .env file is different:
    /// something uses the key there, and replacing it would break that. Git history is
    /// never rewritten by AgentSafe: that needs a force-push and breaks other clones.
    public var isRecord: Bool {
        switch self {
        case .agentTranscript, .shellHistory: return true
        case .agentConfig, .envFile, .credentialsFile, .gitHistory: return false
        }
    }

    /// A copy that should not exist at all (an agent or a shell wrote it down, or it was
    /// committed), as opposed to a file whose job is to hold keys.
    public var isLeak: Bool {
        switch self {
        case .agentTranscript, .agentConfig, .shellHistory, .gitHistory: return true
        case .envFile, .credentialsFile: return false
        }
    }
}

/// Where in a git repository's history a key was found.
public struct GitLocation: Codable, Equatable, Sendable {
    /// The repository's working folder, or its git folder when it is bare.
    public let repository: String
    public let pathInRepository: String
    /// The remote a commit holding the key was pushed to, as host and path
    /// (`github.com/owner/repo`). `nil` when it is only in local commits.
    public let pushedTo: String?
    /// The file is still committed in the current branch, not only in history.
    public let inHead: Bool
    /// A commit by the user (their git email as author or committer) introduced it.
    public let committedByUser: Bool

    public init(repository: String, pathInRepository: String, pushedTo: String?, inHead: Bool, committedByUser: Bool) {
        self.repository = repository; self.pathInRepository = pathInRepository; self.pushedTo = pushedTo
        self.inHead = inHead; self.committedByUser = committedByUser
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

    /// Folders the history scan never descends into. Not `skippedDirectories`: that list
    /// holds `Library`, which would hide `Library/Application Support/Claude/...` in a
    /// dotfiles repository.
    public static let gitTreeSkippedDirectories: Set<String> = [
        "node_modules", "vendor", "Pods", "bower_components", "site-packages", "__pycache__", "DerivedData",
    ]

    /// Whether a path in a git repository is a file that holds keys, and which kind.
    /// Only these are read from history; source files are not.
    public static func gitKeyFileGroup(forPath path: String) -> GitKeyFileGroup? {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        let parent = parts.count >= 2 ? parts[parts.count - 2] : ""
        if isSecretEnvFileName(name) || name == ".dev.vars" { return .envFile }
        // Transcripts and prompt history, as written under ~/.claude and ~/.codex: these turn
        // up in dotfiles repositories that track those folders.
        func follows(_ first: String, _ second: String) -> Bool {
            zip(parts, parts.dropFirst()).contains { $0 == first && $1 == second }
        }
        if name.hasSuffix(".jsonl"), follows(".claude", "projects") || follows(".codex", "sessions") { return .agentLog }
        if name == "history.jsonl", parent == ".claude" || parent == ".codex" { return .agentLog }
        switch name {
        case ".mcp.json", ".claude.json", "claude_desktop_config.json": return .agentConfig
        case "mcp.json" where parent == ".cursor": return .agentConfig
        case "mcp_config.json" where parent == "windsurf": return .agentConfig
        case "settings.json" where parent == ".claude", "settings.local.json" where parent == ".claude": return .agentConfig
        case "config.toml" where parent == ".codex": return .agentConfig
        case ".aider.chat.history.md": return .agentLog
        case ".zsh_history", ".bash_history", "fish_history": return .shellHistory
        case ".npmrc", ".pypirc", ".netrc", ".git-credentials", "id_rsa", "id_ecdsa", "id_ed25519": return .credentials
        case "credentials" where parent == ".aws": return .credentials
        default: break
        }
        if let specstory = parts.firstIndex(of: ".specstory"), specstory + 2 < parts.count, parts[specstory + 1] == "history" { return .agentLog }
        return nil
    }
}

/// The kinds of key-holding files read from git history.
public enum GitKeyFileGroup: Sendable {
    case envFile, agentConfig, agentLog, shellHistory, credentials

    /// .env files also get the `NAME=value` heuristic; the others only known key shapes.
    public var envRules: Bool { self == .envFile }
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
    /// Set for `.gitHistory` findings. Their `path` is synthetic (see `gitPath`).
    public var git: GitLocation?

    public init(id: String, ruleID: String, service: String, name: String?, preview: String, fingerprint: String, path: String,
                line: Int, count: Int, kind: SourceKind, sourceLabel: String, firstSeen: Date, lastSeen: Date, status: FindingStatus,
                git: GitLocation? = nil) {
        self.id = id; self.ruleID = ruleID; self.service = service; self.name = name; self.preview = preview
        self.fingerprint = fingerprint; self.path = path; self.line = line; self.count = count; self.kind = kind
        self.sourceLabel = sourceLabel; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.status = status
        self.git = git
    }

    /// The `path` of a history finding. Never a real file, so nothing that acts on files
    /// (the live watch, the scrubber) can touch it, and its ID cannot collide with the
    /// finding for the working-tree file of the same name.
    public static func gitPath(commonDirectory: String, pathInRepository: String) -> String {
        "git:\(commonDirectory):\(pathInRepository)"
    }

    /// Databases cannot be edited safely as text, and history is never rewritten here;
    /// the only fix for those is to rotate the key.
    public var canScrub: Bool {
        kind != .gitHistory && !["vscdb", "db", "sqlite", "sqlite3"].contains((path as NSString).pathExtension.lowercased())
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
        let collector = Collector(path: file.path, kind: source.kind, sourceLabel: source.label, now: now, fingerprint: fingerprint)
        let reader = try LineBlockReader(url: file, offset: fromOffset, chunkSize: chunkSize, maxBytes: maxFileBytes)
        var line = startLine
        try reader.forEachBlock { part in
            line += scanBlock(part, firstLine: line, envRules: source.kind == .envFile, into: collector)
        }
        return FileScanResult(findings: collector.findings, endOffset: reader.endOffset, endLine: line)
    }

    /// Scans contents held in memory, such as one version of a file from git history.
    /// `path` is used exactly as given, for the findings' path and IDs. `envRules` adds the
    /// `NAME=value` heuristic used for .env files.
    public func scan(data: Data, path: String, kind: SourceKind, sourceLabel: String, envRules: Bool, now: Date = Date()) -> [Finding] {
        let collector = Collector(path: path, kind: kind, sourceLabel: sourceLabel, now: now, fingerprint: fingerprint)
        _ = scanBlock(LineBlockReader.Block(data: data, overlapPrefix: 0, truncated: false), firstLine: 0, envRules: envRules, into: collector)
        return collector.findings
    }

    /// One finding per secret in one file, counting repeats.
    private final class Collector {
        let path: String, kind: SourceKind, sourceLabel: String, now: Date
        let fingerprint: (String) -> String
        private var hits: [String: Finding] = [:]
        private var order: [String] = []

        init(path: String, kind: SourceKind, sourceLabel: String, now: Date, fingerprint: @escaping (String) -> String) {
            self.path = path; self.kind = kind; self.sourceLabel = sourceLabel; self.now = now; self.fingerprint = fingerprint
        }

        var findings: [Finding] { order.compactMap { hits[$0] } }

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
                id: SecretScanner.findingID(fingerprint: print, path: path),
                ruleID: ruleID, service: service, name: name, preview: Redactor.preview(value), fingerprint: print,
                path: path, line: line, count: 1, kind: kind, sourceLabel: sourceLabel,
                firstSeen: now, lastSeen: now, status: .open)
        }
    }

    /// Records the secrets in one block and returns how many lines it held.
    private func scanBlock(_ part: LineBlockReader.Block, firstLine line: Int, envRules: Bool, into collector: Collector) -> Int {
        let block = part.data
        if envRules {
            // .env files are small, and need the NAME=value heuristic as well as the shape rules.
            let text = String(decoding: block, as: UTF8.self)
            let matches = detector.matches(in: text)
            let assignments = detector.envAssignments(in: text)
            let lines = LineIndex(text)
            for match in matches {
                let name = assignments.first { $0.value.contains(match.value) || match.value.contains($0.value) }?.name
                collector.record(ruleID: match.rule.id, service: match.rule.service, name: name, value: match.value,
                                 line: line + lines.lineNumber(atUTF16Offset: match.offset))
            }
            for assignment in assignments where !matches.contains(where: { $0.value.contains(assignment.value) || assignment.value.contains($0.value) }) {
                let offset = (text as NSString).range(of: assignment.value).location
                collector.record(ruleID: "env-assignment", service: "API key", name: assignment.name, value: assignment.value,
                                 line: line + lines.lineNumber(atUTF16Offset: offset == NSNotFound ? 0 : offset))
            }
            return lines.count
        }
        let result = detector.scan(block)
        for match in result.matches {
            let end = match.byteOffset + match.value.utf8.count
            // Already counted at the end of the previous block.
            if part.overlapPrefix > 0, end <= part.overlapPrefix { continue }
            // Touches the cut: probably half a key. The next block has it whole.
            if part.truncated, end >= block.count { continue }
            collector.record(ruleID: match.rule.id, service: match.rule.service, name: nil, value: match.value, line: line + match.line)
        }
        return result.newlines
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

    func files(for source: ScanSource) -> [(URL, ScanSource)] { filesAndRepositories(for: source).files }

    /// The files of a source and, for the project walk, every git repository it passes,
    /// found in the same walk so the home folder is only walked once.
    func filesAndRepositories(for source: ScanSource) -> (files: [(URL, ScanSource)], repositories: [GitRepositoryLocation]) {
        if case .projects(let maxDepth) = source.matcher {
            var out: [(URL, ScanSource)] = []
            var repositories: [GitRepositoryLocation] = []
            walkProjects(source.root, depth: 0, maxDepth: maxDepth, base: source, into: &out, repositories: &repositories)
            return (out, repositories)
        }
        return (matchedFiles(for: source), [])
    }

    private func matchedFiles(for source: ScanSource) -> [(URL, ScanSource)] {
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
        case .projects:
            return filesAndRepositories(for: source).files
        }
    }

    private func walkProjects(_ dir: URL, depth: Int, maxDepth: Int, base: ScanSource, into out: inout [(URL, ScanSource)],
                              repositories: inout [GitRepositoryLocation]) {
        let fm = FileManager.default
        // Per-project agent files live in hidden folders we otherwise do not descend into.
        for relative in [".claude/settings.local.json", ".claude/settings.json", ".cursor/mcp.json", ".mcp.json", ".aider.chat.history.md"] {
            let url = dir.appendingPathComponent(relative)
            if fm.isReadableFile(atPath: url.path), let source = Self.projectSource(for: url, base: base) { out.append((url, source)) }
        }
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            if name == ".git" {
                if let repository = GitRepositoryLocator.resolve(dotGit: entry) { repositories.append(repository) }
                continue
            }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                if depth < maxDepth, !name.hasPrefix("."), !SourceCatalog.skippedDirectories.contains(name) {
                    walkProjects(entry, depth: depth + 1, maxDepth: maxDepth, base: base, into: &out, repositories: &repositories)
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
    /// The copy is gone from disk but the key has not been replaced yet. A pushed history
    /// copy counts too: deleting the clone or rewriting history does not un-push it.
    var awaitsRotation: Bool {
        guard status == .open else { return false }
        return localCopyRemovedAt != nil || (kind == .gitHistory && git?.pushedTo != nil)
    }
}

/// Decodes one entry of a list without failing the whole list. A finding written by a
/// newer version (an unknown kind) is skipped instead of emptying the store.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Findings on disk, redacted. Keeps what the user decided ("I rotated this") across rescans.
///
/// History findings are kept in their own file (`git-findings.json`), so an older version
/// that does not know the `.gitHistory` kind never sees one, and going back to it loses
/// none of the decisions it knew about.
public final class FindingStore {
    public let url: URL
    public var historyURL: URL { url.deletingLastPathComponent().appendingPathComponent("git-findings.json") }
    public private(set) var findings: [Finding] = []

    public init(url: URL) {
        self.url = url
        findings = Self.load(url) + Self.load(historyURL)
    }

    private static func load(_ url: URL) -> [Finding] {
        guard let data = try? Data(contentsOf: url), let saved = try? Crypto.decoder.decode([Lossy<Finding>].self, from: data) else { return [] }
        return saved.compactMap(\.value)
    }

    public var openCount: Int { findings.filter { $0.status == .open }.count }

    /// After a full scan: anything no longer found is gone; anything still there keeps its history.
    public func replaceAll(with fresh: [Finding]) {
        let previous = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let decided = decidedStatusByFingerprint()
        let freshIDs = Set(fresh.map(\.id))
        findings = fresh.map { carry(previous[$0.id], into: $0, decided: decided) } + findings.filter { $0.awaitsRotation && !freshIDs.contains($0.id) }
        save()
    }

    /// For each key, the status every known copy shares, when that is a decision (rotated
    /// or ignored). A decision belongs to the key: the UI marks every copy at once, and a
    /// rotated key is dead wherever its old value turns up.
    private func decidedStatusByFingerprint() -> [String: FindingStatus] {
        var out: [String: FindingStatus?] = [:]
        for finding in findings {
            if let seen = out[finding.fingerprint] {
                if seen != finding.status { out[finding.fingerprint] = .some(nil) }
            } else {
                out[finding.fingerprint] = finding.status
            }
        }
        return out.compactMapValues { status in status.flatMap { $0 == .open ? nil : $0 } }
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
        let decided = decidedStatusByFingerprint()
        let freshIDs = Set(fresh.map(\.id))
        findings.removeAll { $0.path == path }
        findings.append(contentsOf: fresh.map { carry(previous[$0.id], into: $0, decided: decided) })
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

    private func carry(_ old: Finding?, into new: Finding, decided: [String: FindingStatus]) -> Finding {
        guard let old else {
            var arrived = new
            if let status = decided[new.fingerprint] { arrived.status = status }
            return arrived
        }
        var merged = new
        merged.status = old.status
        merged.firstSeen = old.firstSeen
        // Once seen as pushed, always pushed: removing the remote or pruning a merged branch
        // deletes the evidence on this Mac, not the copy on the server.
        if let pushed = old.git?.pushedTo, let git = merged.git, git.pushedTo == nil {
            merged.git = GitLocation(repository: git.repository, pathInRepository: git.pathInRepository, pushedTo: pushed,
                                     inHead: git.inHead, committedByUser: git.committedByUser)
        }
        // Found in the file again, so any earlier removal no longer describes it.
        merged.localCopyRemovedAt = nil
        return merged
    }

    private func save() {
        let history = findings.filter { $0.kind == .gitHistory }
        let rest = findings.filter { $0.kind != .gitHistory }
        if let data = try? Crypto.encoder.encode(rest) { try? SecureFile.write(data, to: url) }
        if let data = try? Crypto.encoder.encode(history) { try? SecureFile.write(data, to: historyURL) }
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
