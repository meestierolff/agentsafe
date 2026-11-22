import Foundation

/// The order keys should be rotated in.
public enum RotationOrder {
    /// A key's severity, raised one level when it was pushed, up to Critical: anyone with
    /// access to that repository has it. A Low key (a test key) stays Low.
    public static func priority(severity: KeySeverity, pushed: Bool) -> Int {
        guard pushed, severity != .low else { return severity.rawValue }
        return min(severity.rawValue + 1, KeySeverity.critical.rawValue)
    }
}

/// The findings the app shows. History copies only another person committed are left out:
/// only whoever made a key can rotate it, and cloned projects often hold sample keys.
public struct ListedFindings: Sendable {
    public let findings: [Finding]
    /// Open keys left out because they are only in other people's commits.
    public let hiddenOthersKeyCount: Int

    /// A history copy is listed when the user committed it, or when the same key is also
    /// somewhere else AgentSafe knows: another kind of file, or the safe. The tracked file
    /// itself does not count: a cloned project's committed `.env` is in its working folder
    /// too, and that says nothing about whose key it is.
    public static func filter(_ all: [Finding], vaultFingerprints: Set<String>) -> ListedFindings {
        let trackedFiles = Set(all.compactMap { finding -> String? in
            guard let git = finding.git, git.inHead else { return nil }
            return finding.fingerprint + "|" + git.repository + "/" + git.pathInRepository
        })
        let elsewhere = Set(all.filter { $0.kind != .gitHistory && !trackedFiles.contains($0.fingerprint + "|" + $0.path) }.map(\.fingerprint))
            .union(vaultFingerprints)
        var listed: [Finding] = []
        var hidden = Set<String>()
        for finding in all {
            if finding.kind != .gitHistory || finding.git?.committedByUser == true || elsewhere.contains(finding.fingerprint) {
                listed.append(finding)
            } else if finding.status == .open {
                hidden.insert(finding.fingerprint)
            }
        }
        return ListedFindings(findings: listed, hiddenOthersKeyCount: hidden.count)
    }
}

/// One key on the rotation checklist, with every listed copy of it.
public struct ChecklistEntry: Identifiable, Sendable {
    public let fingerprint: String
    public let findings: [Finding]
    /// The worst severity across its copies.
    public let severity: KeySeverity
    /// A history copy of it was pushed.
    public let pushed: Bool
    public let isOpen: Bool
    public let priority: Int
    public var id: String { fingerprint }

    public var envFileCopies: Int { findings.filter { $0.kind == .envFile }.count }
    public var configCopies: Int { findings.filter { $0.kind == .agentConfig }.count }
    public var inHistory: Bool { findings.contains { $0.kind == .gitHistory } }
    /// A history copy's file is still committed in the current branch.
    public var stillCommitted: Bool { findings.contains { $0.git?.inHead == true } }

    /// The keys that leaked (at least one copy that should not exist), open ones first,
    /// in rotation order: priority, then severity, then number of places, then service.
    public static func entries(listed: [Finding], profile: (Finding) -> KeyProfile) -> [ChecklistEntry] {
        let entries = Dictionary(grouping: listed, by: \.fingerprint).compactMap { fingerprint, copies -> ChecklistEntry? in
            guard copies.contains(where: { $0.kind.isLeak }) else { return nil }
            let severity = copies.map { profile($0).severity }.max() ?? .medium
            let pushed = copies.contains { $0.git?.pushedTo != nil }
            let sorted = copies.sorted { ($0.kind.isLeak ? 0 : 1, $0.path) < ($1.kind.isLeak ? 0 : 1, $1.path) }
            return ChecklistEntry(fingerprint: fingerprint, findings: sorted, severity: severity, pushed: pushed,
                                  isOpen: copies.contains { $0.kind.isLeak && $0.status == .open },
                                  priority: RotationOrder.priority(severity: severity, pushed: pushed))
        }
        return entries.sorted {
            ($0.isOpen ? 0 : 1, -$0.priority, -$0.severity.rawValue, -$0.findings.count, $0.findings[0].service, $0.fingerprint)
                < ($1.isOpen ? 0 : 1, -$1.priority, -$1.severity.rawValue, -$1.findings.count, $1.findings[0].service, $1.fingerprint)
        }
    }
}

/// Where the keys on the checklist are, counted once per key per row. Rows can overlap
/// (a key can be in a .env file and in history), so they need not add up to the total.
public struct LeakBreakdown: Equatable, Sendable {
    public let total: Int
    public let inEnvFile: Int
    public let inGitHistory: Int
    public let pushed: Int
    /// Deleted from every file, still in commits.
    public let onlyInGitHistory: Int
    /// In no .env file and no commit: only in transcripts, configs and shell history.
    public let onlyInRecordsAndConfigs: Int

    public init(total: Int, inEnvFile: Int, inGitHistory: Int, pushed: Int, onlyInGitHistory: Int, onlyInRecordsAndConfigs: Int) {
        self.total = total; self.inEnvFile = inEnvFile; self.inGitHistory = inGitHistory; self.pushed = pushed
        self.onlyInGitHistory = onlyInGitHistory; self.onlyInRecordsAndConfigs = onlyInRecordsAndConfigs
    }

    public static func compute(_ entries: [ChecklistEntry]) -> LeakBreakdown {
        let open = entries.filter(\.isOpen)
        func count(_ test: (ChecklistEntry) -> Bool) -> Int { open.filter(test).count }
        return LeakBreakdown(
            total: open.count,
            inEnvFile: count { $0.envFileCopies > 0 },
            inGitHistory: count(\.inHistory),
            pushed: count(\.pushed),
            onlyInGitHistory: count { $0.findings.allSatisfy { $0.kind == .gitHistory } },
            onlyInRecordsAndConfigs: count { $0.envFileCopies == 0 && !$0.inHistory })
    }

    /// One line to paste into a post. Counts and fixed words only: no names, previews,
    /// paths or repositories.
    public var summary: String {
        "AgentSafe found \(total) leaked \(total == 1 ? "key" : "keys") on my Mac: \(inEnvFile) also in .env files, "
            + "\(inGitHistory) in git history (\(pushed) pushed), \(onlyInGitHistory) only in git history."
    }
}
