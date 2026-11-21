import CryptoKit
import Foundation

/// What we remember about a file between scans.
struct FileState: Codable, Equatable {
    var size: UInt64
    /// Seconds since 1970, kept as a number so it survives a save and load exactly.
    var modified: Double
    /// Where the next scan of an append-only file should start.
    var offset: UInt64
    var line: Int
    /// Changes when a file is deleted and recreated under the same name.
    var inode: UInt64
    /// Hash of the bytes just before `offset` and at the start of the file. If these
    /// differ next time, the file was rewritten and "only read the new tail" is unsafe.
    var anchor: String
}

/// The scanner's memory between runs, stamped with the rules it was produced by.
struct ScanState: Codable {
    var ruleset: Int
    var files: [String: FileState]
}

/// What happened when the user asked to remove leaked copies from disk.
public struct RemovalReport: Sendable {
    public enum SkipReason: Sendable, Equatable {
        /// A config or .env file that uses the key. Removing it there would break something.
        case inUse
        /// A database, which cannot be edited safely as text.
        case database
        /// Changed moments ago, so an agent may still be writing to it.
        case recentlyModified
        case notFound
        case unreadable
    }

    public struct RemovedFile: Sendable, Equatable { public let path: String; public let copies: Int }
    public struct SkippedFile: Sendable, Equatable { public let path: String; public let reason: SkipReason }

    public var removed: [RemovedFile] = []
    public var skipped: [SkippedFile] = []
    public var copiesRemoved: Int { removed.reduce(0) { $0 + $1.copies } }
}

public struct ScanReport: Sendable {
    public var filesScanned = 0
    /// Unchanged since the last scan, so not read again.
    public var filesSkipped = 0
    /// Could not be read this time. Their earlier findings are kept.
    public var filesUnreadable = 0
    public var cancelled = false
    /// Findings that were not known before this scan.
    public var newFindings: [Finding] = []
}

/// Decides how much of each file needs reading.
///
/// Agent transcripts only ever grow, and they can reach gigabytes. Re-reading all of
/// them on every launch would be slow and wasteful, so each file is in one of three
/// states: unchanged (skip, keep its findings), grown (read only the new tail), or
/// rewritten (read it all again).
///
/// The rule for every shortcut here: when in doubt, read the whole file, and never
/// treat "could not read" as "clean". A scanner that fails quietly is worse than none.
public final class ScanCoordinator {
    public let scanner: SecretScanner
    public let store: FindingStore
    private let stateURL: URL
    private var states: [String: FileState] = [:]

    private enum Outcome {
        case skipped([Finding])
        case scanned([Finding], FileState)
        /// Exists but could not be read. Carries the findings we already had.
        case unreadable([Finding])
        case gone
    }

    public init(scanner: SecretScanner, store: FindingStore, stateURL: URL) {
        self.scanner = scanner
        self.store = store
        self.stateURL = stateURL
        // Progress saved under older rules is discarded, so every file is read again and
        // new rules reach files that have not changed. Findings and the user's decisions
        // are kept separately and are not affected.
        if let data = try? Data(contentsOf: stateURL), let saved = try? Crypto.decoder.decode(ScanState.self, from: data),
           saved.ruleset == SecretRule.rulesetVersion {
            states = saved.files
        }
    }

    /// Forget what was read before, so the next scan reads every file from the start.
    public func resetState() {
        states = [:]
        saveState()
    }

    /// Forget one file. Call this after changing a file ourselves, so it is re-read in full.
    public func forget(_ file: URL) {
        states[file.canonical.path] = nil
        saveState()
    }

    @discardableResult
    public func runFullScan(sources: [ScanSource], now: Date = Date(),
                            progress: ((_ label: String, _ filesDone: Int) -> Void)? = nil,
                            isCancelled: () -> Bool = { false }) -> ScanReport {
        var report = ScanReport()
        let knownBefore = Set(store.findings.map(\.id))
        let previousByPath = Dictionary(grouping: store.findings, by: \.path)
        var all: [Finding] = []
        // Built on the side and committed only when the scan completes. A cancelled scan
        // must not leave files marked "already read" whose findings were never saved.
        var newStates: [String: FileState] = [:]
        var visited = Set<String>()
        var done = 0

        for source in sources {
            for (rawFile, effective) in scanner.files(for: source) {
                if isCancelled() {
                    report.cancelled = true
                    return report
                }
                let file = rawFile.canonical
                guard visited.insert(file.path).inserted else { continue }
                let previous = previousByPath[file.path] ?? []
                switch examine(file, source: effective, previous: previous, known: states[file.path], now: now) {
                case .skipped(let findings):
                    all.append(contentsOf: findings)
                    newStates[file.path] = states[file.path]
                    report.filesSkipped += 1
                case .scanned(let findings, let state):
                    all.append(contentsOf: findings)
                    newStates[file.path] = state
                    report.filesScanned += 1
                case .unreadable(let findings):
                    all.append(contentsOf: findings)
                    newStates[file.path] = states[file.path]
                    report.filesUnreadable += 1
                case .gone:
                    break
                }
                done += 1
                if done % 20 == 0 { progress?(source.label, done) }
            }
        }
        states = newStates
        saveState()
        store.replaceAll(with: all)
        report.newFindings = store.findings.filter { !knownBefore.contains($0.id) }
        progress?("Done", done)
        return report
    }

    /// Called by the live watch when one file changed. Returns findings not seen before.
    public func fileChanged(_ rawFile: URL, sources: [ScanSource], now: Date = Date()) -> [Finding] {
        guard let source = scanner.source(for: rawFile, in: sources) else { return [] }
        let file = rawFile.canonical
        let previous = store.findings.filter { $0.path == file.path }
        let known = Set(previous.map(\.id))
        switch examine(file, source: source, previous: previous, known: states[file.path], now: now) {
        case .skipped, .unreadable:
            return []
        case .gone:
            states[file.path] = nil
            saveState()
            if !previous.isEmpty { store.replace(path: file.path, with: []) }
            return []
        case .scanned(let findings, let state):
            states[file.path] = state
            saveState()
            store.replace(path: file.path, with: findings)
            return findings.filter { !known.contains($0.id) }
        }
    }

    // MARK: - Removing leaked copies

    /// Removes the given findings' copies from disk, one rewrite per file.
    ///
    /// Only records (transcripts, shell history) are touched. Files that use the key are
    /// left alone and reported. Each finding whose copy was removed stays listed until the
    /// user rotates the key: the copy is gone, the leak is not.
    @discardableResult
    public func removeLocalCopies(of findings: [Finding], sources: [ScanSource], now: Date = Date()) -> RemovalReport {
        var report = RemovalReport()
        let scrubber = Scrubber(scanner: scanner)
        for (path, group) in Dictionary(grouping: findings, by: \.path).sorted(by: { $0.key < $1.key }) {
            guard let first = group.first else { continue }
            guard first.kind.isRecord else {
                report.skipped.append(.init(path: path, reason: .inUse))
                continue
            }
            do {
                let counts = try scrubber.scrub(fingerprints: Set(group.map(\.fingerprint)), path: path, isEnvFile: false, now: now)
                for finding in group where counts[finding.fingerprint] != nil { store.markLocalCopyRemoved(finding.id, at: now) }
                report.removed.append(.init(path: path, copies: counts.values.reduce(0, +)))
                // We just rewrote the file ourselves, so read all of it again.
                let url = URL(fileURLWithPath: path)
                forget(url)
                _ = fileChanged(url, sources: sources, now: now)
            } catch let error as ScrubError {
                let reason: RemovalReport.SkipReason
                switch error {
                case .unsupportedFile: reason = .database
                case .recentlyModified: reason = .recentlyModified
                case .notFound: reason = .notFound
                case .unreadable: reason = .unreadable
                }
                report.skipped.append(.init(path: path, reason: reason))
            } catch {
                report.skipped.append(.init(path: path, reason: .unreadable))
            }
        }
        return report
    }

    // MARK: - Internals

    /// Reads as much of `file` as needed. Does not touch `states` or the store.
    private func examine(_ file: URL, source: ScanSource, previous allPrevious: [Finding], known: FileState?, now: Date) -> Outcome {
        let fm = FileManager.default
        // Findings whose copy was removed are no longer in the file. Whether they stay
        // listed is the store's decision (until rotated), not something to carry forward here.
        let previous = allPrevious.filter { $0.localCopyRemovedAt == nil }
        guard let attributes = try? fm.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return fm.fileExists(atPath: file.path) ? .unreadable(allPrevious) : .gone
        }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        if let known, known.size == size, known.modified == modified, known.inode == inode {
            return .skipped(previous)
        }

        // Reading only the new tail is safe only for files that are genuinely append-only
        // (agent transcripts), and only after proving this is still the same file with the
        // same content up to where we stopped. Shell history, configs and .env files get
        // rewritten, so they are always read in full.
        if let known, source.kind == .agentTranscript, size > known.size, known.offset <= size, known.inode == inode,
           let anchor = Self.anchor(of: file, upTo: known.offset), anchor == known.anchor {
            guard let tail = try? scanner.scan(file: file, source: source, fromOffset: known.offset, startLine: known.line, now: now),
                  let newAnchor = Self.anchor(of: file, upTo: tail.endOffset) else { return .unreadable(previous) }
            return .scanned(Self.merge(previous, with: tail.findings),
                            FileState(size: size, modified: modified, offset: tail.endOffset, line: tail.endLine, inode: inode, anchor: newAnchor))
        }

        guard let full = try? scanner.scan(file: file, source: source, now: now),
              let anchor = Self.anchor(of: file, upTo: full.endOffset) else { return .unreadable(previous) }
        return .scanned(full.findings, FileState(size: size, modified: modified, offset: full.endOffset, line: full.endLine, inode: inode, anchor: anchor))
    }

    /// Hash of the first and last 512 bytes of the region `[0, offset)`.
    private static func anchor(of file: URL, upTo offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let window: UInt64 = 512
        do {
            let head = try handle.read(upToCount: Int(min(window, offset))) ?? Data()
            try handle.seek(toOffset: offset > window ? offset - window : 0)
            let tail = try handle.read(upToCount: Int(min(window, offset))) ?? Data()
            var hasher = SHA256()
            hasher.update(data: head)
            hasher.update(data: tail)
            return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }

    private static func merge(_ existing: [Finding], with tail: [Finding]) -> [Finding] {
        var out = existing
        for finding in tail {
            if let index = out.firstIndex(where: { $0.id == finding.id }) {
                out[index].count += finding.count
                out[index].lastSeen = finding.lastSeen
            } else {
                out.append(finding)
            }
        }
        return out
    }

    private func saveState() {
        let state = ScanState(ruleset: SecretRule.rulesetVersion, files: states)
        if let data = try? Crypto.encoder.encode(state) { try? SecureFile.write(data, to: stateURL) }
    }
}

extension URL {
    /// One spelling per file. macOS reaches the same file as `/var/...` and `/private/var/...`;
    /// findings and scan state are keyed by path, so the spelling has to be stable.
    var canonical: URL { resolvingSymlinksInPath().standardizedFileURL }
}
