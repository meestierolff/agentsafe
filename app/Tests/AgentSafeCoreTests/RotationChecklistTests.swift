import XCTest
@testable import AgentSafeCore

final class RotationChecklistTests: XCTestCase {
    func copy(_ fingerprint: String, _ kind: SourceKind, rule: String = "openai", preview: String = "sk-proj-…abcd", service: String = "OpenAI",
              path: String? = nil, pushedTo: String? = nil, byUser: Bool = true, inHead: Bool = false, status: FindingStatus = .open) -> Finding {
        let place = path ?? "/h/\(fingerprint)/\(kind.rawValue)"
        let git = kind == .gitHistory
            ? GitLocation(repository: "/h/repo", pathInRepository: ".env", pushedTo: pushedTo, inHead: inHead, committedByUser: byUser) : nil
        return Finding(id: SecretScanner.findingID(fingerprint: fingerprint, path: place), ruleID: rule, service: service, name: nil, preview: preview,
                       fingerprint: fingerprint, path: place, line: 1, count: 1, kind: kind, sourceLabel: kind.rawValue,
                       firstSeen: Date(), lastSeen: Date(), status: status, git: git)
    }

    func entries(_ findings: [Finding]) -> [ChecklistEntry] {
        ChecklistEntry.entries(listed: findings) { KeyCatalog.profile(ruleID: $0.ruleID, preview: $0.preview) }
    }

    func testPushedKeyMovesUpOneLevel() {
        XCTAssertEqual(RotationOrder.priority(severity: .high, pushed: true), 3)
        XCTAssertEqual(RotationOrder.priority(severity: .critical, pushed: true), 3)
        XCTAssertEqual(RotationOrder.priority(severity: .low, pushed: true), 0)
        XCTAssertEqual(RotationOrder.priority(severity: .medium, pushed: false), 1)
    }

    func testLocalCriticalBeatsPushedHighOnTie() {
        let pushedHigh = copy("openai", .gitHistory, pushedTo: "github.com/me/app")
        let localCritical = copy("stripe", .agentTranscript, rule: "stripe", preview: "sk_live_…abcd", service: "Stripe")
        let order = entries([pushedHigh, localCritical])
        XCTAssertEqual(order.map(\.fingerprint), ["stripe", "openai"])
        XCTAssertEqual(order.map(\.priority), [3, 3])
    }

    func testPushedHighBeatsLocalHigh() {
        let localHigh = copy("a-local", .agentTranscript)
        let pushedHigh = copy("z-pushed", .gitHistory, pushedTo: "github.com/me/app")
        XCTAssertEqual(entries([localHigh, pushedHigh]).map(\.fingerprint), ["z-pushed", "a-local"])
        XCTAssertEqual(entries([localHigh, pushedHigh]).first?.pushed, true)
    }

    func testHiddenWhenCommittedOnlyBySomeoneElse() {
        let listed = ListedFindings.filter([copy("theirs", .gitHistory, byUser: false)], vaultFingerprints: [])
        XCTAssertTrue(listed.findings.isEmpty)
        XCTAssertEqual(listed.hiddenOthersKeyCount, 1)
    }

    func testListedWhenAlsoInEnvFileOrSafe() {
        let theirs = copy("k", .gitHistory, byUser: false)
        XCTAssertEqual(ListedFindings.filter([theirs, copy("k", .envFile)], vaultFingerprints: []).findings.count, 2)
        XCTAssertEqual(ListedFindings.filter([theirs], vaultFingerprints: ["k"]).findings.count, 1)
        XCTAssertEqual(ListedFindings.filter([theirs], vaultFingerprints: ["k"]).hiddenOthersKeyCount, 0)
    }

    func testUpstreamEnvFileInTheSameCloneDoesNotListTheirKey() {
        // A cloned project that tracks its .env has the same key in the working tree.
        let theirs = copy("k", .gitHistory, byUser: false, inHead: true)  // /h/repo, .env still tracked
        let sameClone = copy("k", .envFile, path: "/h/repo/.env")
        let listed = ListedFindings.filter([theirs, sameClone], vaultFingerprints: [])
        XCTAssertEqual(listed.findings.map(\.kind), [.envFile])
        XCTAssertEqual(listed.hiddenOthersKeyCount, 1)
        let elsewhere = copy("k", .envFile, path: "/h/my-app/.env")
        XCTAssertEqual(ListedFindings.filter([theirs, elsewhere], vaultFingerprints: []).findings.count, 2)
        // A teammate committed a key the user keeps in their own, untracked .env in that repository.
        let teammate = copy("k", .gitHistory, byUser: false, inHead: false)
        XCTAssertEqual(ListedFindings.filter([teammate, sameClone], vaultFingerprints: []).findings.count, 2)
    }

    func testBreakdownCountsEachKeyOncePerRow() {
        let findings = [
            copy("k1", .agentTranscript), copy("k1", .envFile), copy("k1", .gitHistory, pushedTo: "github.com/me/app"),
            copy("k1", .gitHistory, path: "git:/h/repo/.git:.env.local", pushedTo: "github.com/me/app"),
            copy("k2", .gitHistory),
            copy("k3", .agentTranscript), copy("k3", .shellHistory),
            copy("k4", .agentTranscript, status: .rotated),
        ]
        let breakdown = LeakBreakdown.compute(entries(findings))
        XCTAssertEqual(breakdown, LeakBreakdown(total: 3, inEnvFile: 1, inGitHistory: 2, pushed: 1, onlyInGitHistory: 1, onlyInRecordsAndConfigs: 1))
        XCTAssertEqual(entries(findings).last?.fingerprint, "k4", "done keys come last")
        XCTAssertEqual(entries(findings).first { $0.fingerprint == "k1" }?.envFileCopies, 1)
    }

    func testEnvOnlyKeyIsNotOnTheChecklist() {
        XCTAssertTrue(entries([copy("k", .envFile)]).isEmpty, "a key only in .env files is not leaked")
    }

    func testStillCommittedComesFromHistoryCopies() {
        XCTAssertTrue(entries([copy("k", .gitHistory, inHead: true)])[0].stillCommitted)
        XCTAssertFalse(entries([copy("k", .gitHistory)])[0].stillCommitted)
        XCTAssertTrue(entries([copy("k", .gitHistory)])[0].inHistory)
    }

    func testSummaryHoldsOnlyCounts() {
        let summary = LeakBreakdown(total: 68, inEnvFile: 12, inGitHistory: 9, pushed: 6, onlyInGitHistory: 4, onlyInRecordsAndConfigs: 51).summary
        XCTAssertEqual(summary, "AgentSafe found 68 leaked keys on my Mac: 12 also in .env files, 9 in git history (6 pushed), 4 only in git history.")
        let one = LeakBreakdown(total: 1, inEnvFile: 0, inGitHistory: 1, pushed: 1, onlyInGitHistory: 1, onlyInRecordsAndConfigs: 0).summary
        XCTAssertNotNil(one.range(of: #"^AgentSafe found \d+ leaked keys? on my Mac: \d+ also in \.env files, \d+ in git history \(\d+ pushed\), \d+ only in git history\.$"#,
                                  options: .regularExpression))
        XCTAssertTrue(one.hasPrefix("AgentSafe found 1 leaked key on my Mac"))
    }
}
