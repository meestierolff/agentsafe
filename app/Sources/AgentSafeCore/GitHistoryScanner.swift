import CryptoKit
import Foundation

/// Where one git repository lives on disk. All URLs are canonical.
public struct GitRepositoryLocation: Hashable, Sendable {
    /// `nil` for a bare repository.
    public let workingDirectory: URL?
    /// The folder holding this checkout's `HEAD` (differs from `commonDirectory` in a worktree).
    public let gitDirectory: URL
    /// The folder holding the objects and refs. Worktrees of one repository share it.
    public let commonDirectory: URL

    /// What to show the user: the working folder, or the git folder when bare.
    public var displayPath: String { (workingDirectory ?? gitDirectory).path }
}

public enum GitRepositoryLocator {
    /// A `.git` entry found in a folder: a directory, or a file holding `gitdir: <path>`
    /// (worktrees and submodules), followed through `commondir` when present.
    public static func resolve(dotGit: URL) -> GitRepositoryLocation? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = dotGit.canonical
        } else {
            guard let text = smallText(dotGit),
                  let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectory = (path.hasPrefix("/") ? URL(fileURLWithPath: path)
                            : dotGit.deletingLastPathComponent().appendingPathComponent(path)).canonical
        }
        guard fm.fileExists(atPath: gitDirectory.appendingPathComponent("HEAD").path) else { return nil }
        return GitRepositoryLocation(workingDirectory: dotGit.deletingLastPathComponent().canonical,
                                     gitDirectory: gitDirectory, commonDirectory: commonDirectory(of: gitDirectory))
    }

    /// A bare repository: a folder with `HEAD`, `objects/` and `refs/` directly inside.
    public static func bare(at url: URL) -> GitRepositoryLocation? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.appendingPathComponent("HEAD").path),
              fm.fileExists(atPath: url.appendingPathComponent("objects").path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.fileExists(atPath: url.appendingPathComponent("refs").path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let gitDirectory = url.canonical
        return GitRepositoryLocation(workingDirectory: nil, gitDirectory: gitDirectory, commonDirectory: commonDirectory(of: gitDirectory))
    }

    /// Dotfiles repositories live in hidden folders the project walk never enters, and they
    /// are where a committed `.zsh_history` or `.npmrc` usually is.
    public static func dotfilesCandidates(home: URL) -> [GitRepositoryLocation] {
        var out: [GitRepositoryLocation] = []
        for folder in [".dotfiles", ".config", ".local/share/chezmoi"] {
            let base = home.appendingPathComponent(folder)
            if let found = resolve(dotGit: base.appendingPathComponent(".git")) { out.append(found) }
            let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for child in children.sorted(by: { $0.path < $1.path })
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let found = resolve(dotGit: child.appendingPathComponent(".git")) { out.append(found) }
            }
        }
        for folder in [".cfg", ".dotfiles.git", ".dotfiles"] {
            if let found = bare(at: home.appendingPathComponent(folder)) { out.append(found) }
        }
        return out
    }

    /// Pointer files (`.git` as a file, `commondir`) hold one short line. Anything bigger
    /// than 4 KB is not one of them and is not read into memory.
    static func smallText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func commonDirectory(of gitDirectory: URL) -> URL {
        guard let text = smallText(gitDirectory.appendingPathComponent("commondir")) else { return gitDirectory }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return gitDirectory }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDirectory.appendingPathComponent(path)).canonical
    }
}

/// What reading one repository's history produced.
public struct GitRepositoryScan: Sendable {
    public enum Outcome: Equatable, Sendable {
        case complete
        /// Some objects could not be read (a partial clone, a missing alternate). What was
        /// found is real; keys in the missing part may be missed.
        case partlyRead(String)
        /// Nothing could be read (an unsupported format, a damaged repository).
        case unreadable(String)
    }

    public let outcome: Outcome
    public let findings: [Finding]
    /// `nil` when the refs could not be read; the repository is then read again next time.
    public let tipsHash: String?
    /// File versions skipped because they are larger than the limit.
    public let versionsTooLarge: Int
}

/// Finds keys in every past version of key-holding files in one repository, and tells
/// versions that were pushed from ones only in local commits.
///
/// Each commit is compared with its first parent, the way `git log` lists changes, so every
/// version is attributed to the commits that introduced it: that is what "pushed" and "by
/// the user" are decided on. Unchanged subtrees are skipped by ID, so a commit costs only
/// the folders it touched.
public struct GitHistoryScanner {
    public let scanner: SecretScanner
    public let maxVersionBytes: Int

    public init(scanner: SecretScanner, maxVersionBytes: Int = 50_000_000) {
        self.scanner = scanner
        self.maxVersionBytes = maxVersionBytes
    }

    struct VersionAtPath: Hashable, Comparable {
        let path: String
        let id: GitObjectID
        static func < (a: VersionAtPath, b: VersionAtPath) -> Bool { (a.path, a.id) < (b.path, b.id) }
    }

    struct Introduction {
        var pushedTo: String?
        var committedByUser: Bool
    }

    struct Collection {
        var versions: [VersionAtPath: Introduction] = [:]
        var headVersions: [String: GitObjectID] = [:]
        var problem: String?
    }

    /// Returns `nil` only when cancelled.
    public func scan(_ location: GitRepositoryLocation, userEmails: Set<String>, now: Date, isCancelled: () -> Bool) -> GitRepositoryScan? {
        let repo: GitRepository
        do {
            repo = try GitRepository(gitDirectory: location.gitDirectory, commonDirectory: location.commonDirectory)
        } catch {
            return GitRepositoryScan(outcome: .unreadable(Self.reason(error)), findings: [], tipsHash: nil, versionsTooLarge: 0)
        }
        let hash = Self.tipsHash(location)
        guard var collection = collect(repo, userEmails: userEmails, isCancelled: isCancelled) else { return nil }

        struct Key: Hashable { let fingerprint: String; let path: String }
        var byKey: [Key: Finding] = [:]
        var order: [Key] = []
        var tooLarge = 0
        for (index, version) in collection.versions.keys.sorted().enumerated() {
            if index % 100 == 0, isCancelled() { return nil }
            guard let introduction = collection.versions[version],
                  let group = SourceCatalog.gitKeyFileGroup(forPath: version.path) else { continue }
            do {
                guard try repo.objectSize(version.id) <= maxVersionBytes else { tooLarge += 1; continue }
                let data = try repo.object(version.id).data
                let path = Finding.gitPath(commonDirectory: location.commonDirectory.path, pathInRepository: version.path)
                let inHead = collection.headVersions[version.path] == version.id
                for var found in scanner.scan(data: data, path: path, kind: .gitHistory, sourceLabel: "Git history", envRules: group.envRules, now: now) {
                    let key = Key(fingerprint: found.fingerprint, path: version.path)
                    if var existing = byKey[key], let git = existing.git {
                        existing.count += 1
                        if existing.name == nil { existing.name = found.name }
                        existing.git = GitLocation(repository: git.repository, pathInRepository: git.pathInRepository,
                                                   pushedTo: git.pushedTo ?? introduction.pushedTo, inHead: git.inHead || inHead,
                                                   committedByUser: git.committedByUser || introduction.committedByUser)
                        byKey[key] = existing
                    } else {
                        found.count = 1
                        found.git = GitLocation(repository: location.displayPath, pathInRepository: version.path,
                                                pushedTo: introduction.pushedTo, inHead: inHead, committedByUser: introduction.committedByUser)
                        byKey[key] = found
                        order.append(key)
                    }
                }
            } catch {
                collection.problem = collection.problem ?? Self.reason(error)
            }
        }
        let outcome: GitRepositoryScan.Outcome = collection.problem.map { .partlyRead($0) } ?? .complete
        return GitRepositoryScan(outcome: outcome, findings: order.compactMap { byKey[$0] }, tipsHash: hash, versionsTooLarge: tooLarge)
    }

    /// The IDs of every key-file version the walk collects. Used to check the walk against `git`.
    func collectVersions(_ location: GitRepositoryLocation) throws -> Set<GitObjectID> {
        let repo = try GitRepository(gitDirectory: location.gitDirectory, commonDirectory: location.commonDirectory)
        return Set((collect(repo, userEmails: [], isCancelled: { false })?.versions.keys.map(\.id)) ?? [])
    }

    // MARK: - The walk

    private func collect(_ repo: GitRepository, userEmails: Set<String>, isCancelled: () -> Bool) -> Collection? {
        var collection = Collection()
        let refs = (try? repo.refs()) ?? []
        if repo.hasUnreadableAlternates { collection.problem = "alternates could not be read" }
        // Objects but no refs: the refs are damaged. Saying "nothing found" would be a lie.
        if refs.isEmpty, repo.hasObjects { collection.problem = collection.problem ?? "refs could not be read" }
        var remoteNames: [String: String] = [:]
        let fetchURLs = repo.remoteURLs(), pushURLs = repo.remotePushURLs()
        for name in Set(fetchURLs.keys).union(pushURLs.keys) {
            // Pushes go to the push URL when there is one; that is where the key went.
            if let display = pushURLs[name].flatMap(Self.displayRemote) ?? fetchURLs[name].flatMap(Self.displayRemote) {
                remoteNames[name] = display
            }
        }
        // Remote-tracking refs of remotes that are folders on this Mac count as local.
        func isPushedRef(_ name: String) -> Bool { remoteNames.keys.contains { name.hasPrefix("refs/remotes/\($0)/") } }

        var commits: [GitObjectID: GitCommit] = [:]
        var pushedBy: [GitObjectID: String] = [:]
        var order: [GitObjectID] = []
        var visited = 0

        /// The commit a ref names, peeling tags; `nil` for a tag on a tree or a blob.
        /// Throws when the object is missing or damaged.
        func peel(_ id: GitObjectID) throws -> GitObjectID? {
            var current = id
            for _ in 0..<16 {
                let object = try repo.object(current)
                switch object.kind {
                case .commit: return current
                case .tag:
                    guard let target = GitRepository.headerLines(object.data).first(where: { $0.hasPrefix("object ") })
                        .flatMap({ GitObjectID(hex: String($0.dropFirst(7))) }) else { return nil }
                    current = target
                case .tree, .blob: return nil
                }
            }
            return nil
        }

        /// Walks every commit reachable from the tips that has not been seen yet. A ref that
        /// cannot be read is reported: its history is missing. An old reflog entry whose
        /// commit was garbage collected is normal, and is skipped silently.
        func walk(refs refTips: [GitObjectID], reflog reflogTips: [GitObjectID] = [], remote: String?) -> Bool {
            var stack: [GitObjectID] = []
            for tip in refTips {
                do { if let commit = try peel(tip) { stack.append(commit) } } catch {
                    collection.problem = collection.problem ?? Self.reason(error)
                }
            }
            for tip in reflogTips { if let commit = try? peel(tip) { stack.append(commit) } }
            while let id = stack.popLast() {
                if commits[id] != nil { continue }
                let commit: GitCommit
                do { commit = try repo.commit(id) } catch {
                    collection.problem = collection.problem ?? Self.reason(error)
                    continue
                }
                commits[id] = commit
                order.append(id)
                if let remote { pushedBy[id] = remote }
                visited += 1
                if visited % 200 == 0, isCancelled() { return false }
                if repo.shallowCommits.contains(id) { continue }
                for parent in commit.parents where commits[parent] == nil { stack.append(parent) }
            }
            return true
        }

        for name in remoteNames.keys.sorted() {
            let tips = refs.filter { $0.name.hasPrefix("refs/remotes/\(name)/") }.map(\.id)
            guard walk(refs: tips, reflog: repo.reflogOldValues(underRefPrefix: "refs/remotes/\(name)"), remote: remoteNames[name]) else { return nil }
        }
        guard walk(refs: refs.filter { !isPushedRef($0.name) }.map(\.id), remote: nil) else { return nil }

        var trees = TreeCache(repo: repo)
        for (index, id) in order.enumerated() {
            if index % 200 == 0, isCancelled() { return nil }
            guard let commit = commits[id] else { continue }
            // A first parent that was not read (the edge of a shallow clone) counts as empty.
            let base = commit.parents.first.flatMap { commits[$0]?.tree }
            let byUser = userEmails.contains(commit.authorEmail) || userEmails.contains(commit.committerEmail)
            let remote = pushedBy[id]
            do {
                var found: [(path: String, version: GitObjectID)] = []
                try diff(commit.tree, against: base, prefix: "", trees: &trees) { found.append(($0, $1)) }
                // A merge "introduces" everything its other parents changed. It only makes a
                // version the merger's when the version matches none of its parents.
                let otherParents = commit.parents.dropFirst().compactMap { commits[$0]?.tree }
                for (path, version) in found {
                    var madeHere = true
                    for parent in otherParents where madeHere {
                        if try Self.version(at: path, in: parent, trees: &trees) == version { madeHere = false }
                    }
                    let key = VersionAtPath(path: path, id: version)
                    var introduction = collection.versions[key] ?? Introduction(pushedTo: nil, committedByUser: false)
                    if introduction.pushedTo == nil { introduction.pushedTo = remote }
                    introduction.committedByUser = introduction.committedByUser || (byUser && madeHere)
                    collection.versions[key] = introduction
                }
            } catch {
                collection.problem = collection.problem ?? Self.reason(error)
            }
        }

        if let head = refs.first(where: { $0.name == "HEAD" }).flatMap({ try? peel($0.id) }),
           let tree = commits[head]?.tree ?? (try? repo.commit(head))?.tree {
            try? diff(tree, against: nil, prefix: "", trees: &trees) { path, version in collection.headVersions[path] = version }
        }
        return collection
    }

    /// Calls `found` for every key-holding file in `tree` that is new or changed compared
    /// with `base`, skipping subtrees whose ID did not change.
    private func diff(_ tree: GitObjectID, against base: GitObjectID?, prefix: String, depth: Int = 0, trees: inout TreeCache,
                      found: (String, GitObjectID) -> Void) throws {
        // Object IDs are not verified, so a damaged repository can hold a tree that lists itself.
        guard depth < 256 else { throw GitReadError.corrupt("tree too deep") }
        let entries = try trees.entries(tree)
        let old = try base.map { try trees.entries($0) } ?? [:]
        for (name, entry) in entries {
            let previous = old[name]
            if let previous, previous.id == entry.id { continue }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if entry.isTree {
                guard !SourceCatalog.gitTreeSkippedDirectories.contains(name) else { continue }
                try diff(entry.id, against: previous?.isTree == true ? previous?.id : nil, prefix: path, depth: depth + 1, trees: &trees, found: found)
            } else if entry.isFile, SourceCatalog.gitKeyFileGroup(forPath: path) != nil {
                found(path, entry.id)
            }
        }
    }

    /// The file version at `path` in `tree`, if there is one.
    private static func version(at path: String, in tree: GitObjectID, trees: inout TreeCache) throws -> GitObjectID? {
        var current = tree
        let parts = path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            guard let entry = try trees.entries(current)[part] else { return nil }
            if index == parts.count - 1 { return entry.isFile ? entry.id : nil }
            guard entry.isTree else { return nil }
            current = entry.id
        }
        return nil
    }

    /// Parsed trees by ID. A commit and its parent share most of their trees.
    private struct TreeCache {
        let repo: GitRepository
        var parsed: [GitObjectID: [String: GitTreeEntry]] = [:]

        mutating func entries(_ id: GitObjectID) throws -> [String: GitTreeEntry] {
            if let hit = parsed[id] { return hit }
            let entries = Dictionary(try repo.tree(id).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            if parsed.count >= 20_000 { parsed.removeAll(keepingCapacity: true) }
            parsed[id] = entries
            return entries
        }
    }

    // MARK: - Helpers

    static func reason(_ error: Error) -> String {
        switch error as? GitReadError {
        case .unsupported(let what): return what
        case .missingObject: return "missing objects"
        case .corrupt(let what): return "damaged (\(what))"
        case nil: return "could not be read"
        }
    }

    /// Changes whenever a branch, tag or remote-tracking branch moves, or a remote reflog
    /// grows. Reads refs only, not the object database, so an unchanged repository costs
    /// a few file reads.
    public static func tipsHash(_ location: GitRepositoryLocation) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.gitDirectory.appendingPathComponent("HEAD").path) else { return nil }
        var hasher = SHA256()
        for ref in GitRepository.refs(gitDirectory: location.gitDirectory, commonDirectory: location.commonDirectory) {
            hasher.update(data: Data("\(ref.name) \(ref.id.hex)\n".utf8))
        }
        func stamp(_ url: URL, as label: String) {
            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            hasher.update(data: Data("\(label) \(size) \(modified)\n".utf8))
        }
        let logs = location.commonDirectory.appendingPathComponent("logs/refs/remotes")
        for file in ((fm.enumerator(atPath: logs.path)?.allObjects as? [String]) ?? []).sorted() {
            stamp(logs.appendingPathComponent(file), as: file)
        }
        // Deepening a shallow clone or adding an alternate makes more history readable
        // without moving any ref.
        stamp(location.commonDirectory.appendingPathComponent("shallow"), as: "shallow")
        stamp(location.commonDirectory.appendingPathComponent("objects/info/alternates"), as: "alternates")
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The user's git emails, lowercased: the global config, the repository's own, and every
    /// file they include. `includeIf` conditions are not evaluated: a work email set for one
    /// folder is still the user's, and a few extra addresses are harmless here.
    public static func userEmails(home: URL, location: GitRepositoryLocation) -> Set<String> {
        var queue = [home.appendingPathComponent(".gitconfig"), home.appendingPathComponent(".config/git/config"),
                     location.commonDirectory.appendingPathComponent("config")]
        var seen = Set<String>()
        var emails = Set<String>()
        while !queue.isEmpty, seen.count < 32 {
            let file = queue.removeFirst().standardizedFileURL
            guard seen.insert(file.path).inserted else { continue }
            let config = GitConfig(url: file)
            emails.formUnion(config.allValues("user", "email").map { $0.lowercased() }.filter { !$0.isEmpty })
            for path in config.allValues("include", "path") + config.allValues("includeif", "path") {
                if path.hasPrefix("~/") { queue.append(home.appendingPathComponent(String(path.dropFirst(2)))) }
                else if path.hasPrefix("/") { queue.append(URL(fileURLWithPath: path)) }
                else { queue.append(file.deletingLastPathComponent().appendingPathComponent(path)) }
            }
        }
        return emails
    }

    /// `github.com/owner/repo` for a remote URL, without scheme, credentials, port or
    /// `.git`. `nil` for a remote that is a folder on this Mac: pushing there exposes nothing.
    public static func displayRemote(_ url: String) -> String? {
        var rest = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty || rest.hasPrefix("file://") || rest.hasPrefix("/") || rest.hasPrefix(".") || rest.hasPrefix("~") { return nil }
        var host: Substring
        var path: Substring
        if let scheme = rest.range(of: "://") {
            rest = String(rest[scheme.upperBound...])
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            host = rest[..<slash]
            path = rest[slash...].drop { $0 == "/" }
        } else if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains("/") {
            // `[user[:password]@]host:path`. Credentials go first, wherever their own colon is.
            let firstSlash = rest.firstIndex(of: "/") ?? rest.endIndex
            if let at = rest[..<firstSlash].lastIndex(of: "@") {
                rest = String(rest[rest.index(after: at)...])
                guard let hostEnd = rest.firstIndex(of: ":") else { return nil }
                host = rest[..<hostEnd]
                path = rest[rest.index(after: hostEnd)...].drop { $0 == "/" }
                return Self.joined(host, path)
            }
            host = rest[..<colon]
            path = rest[rest.index(after: colon)...].drop { $0 == "/" }
        } else {
            return nil
        }
        return Self.joined(host, path)
    }

    private static func joined(_ rawHost: Substring, _ path: Substring) -> String? {
        var host = rawHost
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let port = host.lastIndex(of: ":") { host = host[..<port] }
        var cleaned = String(path)
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        if cleaned.hasSuffix(".git") { cleaned.removeLast(4) }
        guard !host.isEmpty else { return nil }
        return cleaned.isEmpty ? String(host) : "\(host)/\(cleaned)"
    }
}
