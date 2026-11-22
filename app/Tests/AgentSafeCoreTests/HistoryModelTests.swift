import XCTest
@testable import AgentSafeCore

/// The shape 0.3.0 reads `findings.json` with. Used to prove a downgrade still loads.
private struct Finding030: Decodable {
    enum Kind030: String, Decodable { case agentTranscript, agentConfig, shellHistory, envFile, credentialsFile }
    let id: String
    let kind: Kind030
    let status: String
}

final class HistoryModelTests: XCTestCase {
    var dir: URL!
    var findingsURL: URL { dir.appendingPathComponent("findings.json") }

    override func setUp() { dir = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func finding(_ fingerprint: String, path: String, kind: SourceKind, git: GitLocation? = nil) -> Finding {
        Finding(id: SecretScanner.findingID(fingerprint: fingerprint, path: path), ruleID: "stripe", service: "Stripe", name: nil,
                preview: "sk_live_…abcd", fingerprint: fingerprint, path: path, line: 1, count: 1, kind: kind,
                sourceLabel: kind == .gitHistory ? "Git history" : "Env file", firstSeen: Date(), lastSeen: Date(), status: .open, git: git)
    }

    func history(_ fingerprint: String, repo: String = "/r", path: String = ".env", pushedTo: String? = nil) -> Finding {
        finding(fingerprint, path: Finding.gitPath(commonDirectory: repo + "/.git", pathInRepository: path), kind: .gitHistory,
                git: GitLocation(repository: repo, pathInRepository: path, pushedTo: pushedTo, inHead: false, committedByUser: true))
    }

    func testDecodesFindingsSavedBy030() throws {
        let json = """
        [{"id":"a1","ruleID":"anthropic","service":"Anthropic","preview":"sk-ant-…QwAA","fingerprint":"f1","path":"/h/.claude/projects/p/a.jsonl",
          "line":3,"count":1,"kind":"agentTranscript","sourceLabel":"Claude Code transcripts","firstSeen":"2026-11-20T10:00:00Z",
          "lastSeen":"2026-11-20T10:00:00Z","status":"rotated"},
         {"id":"b2","ruleID":"env-assignment","service":"API key","name":"SECRET","preview":"q9Xy…f","fingerprint":"f2","path":"/h/p/.env",
          "line":1,"count":1,"kind":"envFile","sourceLabel":"Env file","firstSeen":"2026-11-20T10:00:00Z","lastSeen":"2026-11-20T10:00:00Z","status":"open"}]
        """
        try Data(json.utf8).write(to: findingsURL)
        let store = FindingStore(url: findingsURL)
        XCTAssertEqual(store.findings.count, 2)
        XCTAssertEqual(store.findings.first { $0.id == "a1" }?.status, .rotated)
        XCTAssertNil(store.findings.first { $0.id == "a1" }?.git)
    }

    func testHistoryFindingsAreSavedApartFromFindingsJSON() throws {
        let store = FindingStore(url: findingsURL)
        store.replaceAll(with: [finding("f1", path: "/h/p/.env", kind: .envFile), history("f2")])
        let legacy = try Crypto.decoder.decode([Finding030].self, from: Data(contentsOf: findingsURL))
        XCTAssertEqual(legacy.map(\.id), [SecretScanner.findingID(fingerprint: "f1", path: "/h/p/.env")])
        let historyFile = try Crypto.decoder.decode([Finding].self, from: Data(contentsOf: store.historyURL))
        XCTAssertEqual(historyFile.count, 1)
        XCTAssertEqual(store.historyURL.lastPathComponent, "git-findings.json")
        XCTAssertEqual(Set(FindingStore(url: findingsURL).findings.map(\.fingerprint)), ["f1", "f2"])
    }

    func testOneUnreadableEntryKeepsTheRest() throws {
        let good = try String(decoding: Crypto.encoder.encode(finding("f1", path: "/h/p/.env", kind: .envFile)), as: UTF8.self)
        let future = good.replacingOccurrences(of: "\"envFile\"", with: "\"fromTheFuture\"").replacingOccurrences(of: "\"f1\"", with: "\"f9\"")
        try Data("[\(future),\(good)]".utf8).write(to: findingsURL)
        let store = FindingStore(url: findingsURL)
        XCTAssertEqual(store.findings.map(\.fingerprint), ["f1"])
    }

    func testNewCopyOfRotatedKeyArrivesRotated() {
        let store = FindingStore(url: findingsURL)
        let transcript = finding("f1", path: "/h/t.jsonl", kind: .agentTranscript)
        store.replaceAll(with: [transcript])
        store.setStatus(.rotated, forFingerprint: "f1")
        store.replaceAll(with: [transcript, history("f1")])
        XCTAssertEqual(store.findings.first { $0.kind == .gitHistory }?.status, .rotated)
    }

    func testNewCopyOfPartlyRotatedKeyStaysOpen() {
        let store = FindingStore(url: findingsURL)
        let a = finding("f1", path: "/h/a.jsonl", kind: .agentTranscript)
        let b = finding("f1", path: "/h/b.jsonl", kind: .agentTranscript)
        store.replaceAll(with: [a, b])
        store.setStatus(.rotated, for: a.id)
        store.replaceAll(with: [a, b, history("f1")])
        XCTAssertEqual(store.findings.first { $0.kind == .gitHistory }?.status, .open)
    }

    func testLiveWatchEventDoesNotRemoveHistoryFindings() {
        let store = FindingStore(url: findingsURL)
        store.replaceAll(with: [finding("f1", path: "/r/.env", kind: .envFile), history("f1")])
        store.replace(path: "/r/.env", with: [])
        XCTAssertEqual(store.findings.map(\.kind), [.gitHistory])
        XCTAssertEqual(store.findings.first?.path, "git:/r/.git:.env")
    }

    func testHistoryFindingCannotBeScrubbed() {
        XCTAssertFalse(history("f1").canScrub)
        XCTAssertFalse(SourceKind.gitHistory.isRecord)
        XCTAssertTrue(SourceKind.gitHistory.isLeak)
    }
}
