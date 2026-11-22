import XCTest
@testable import AgentSafeCore

final class CoordinatorHistoryTests: XCTestCase {
    var data: URL!
    let salt = Data([5])

    override func setUp() { data = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: data) }

    func coordinator() -> ScanCoordinator {
        ScanCoordinator(scanner: SecretScanner(fingerprint: { Fingerprint.of($0, salt: self.salt) }),
                        store: FindingStore(url: data.appendingPathComponent("findings.json")),
                        stateURL: data.appendingPathComponent("scan-state.json"))
    }

    func history(_ c: ScanCoordinator) -> [Finding] { c.store.findings.filter { $0.kind == .gitHistory } }
    func print(_ value: String) -> String { Fingerprint.of(value, salt: salt) }

    func makeRepository(_ fx: GitFixture, _ name: String = "a") -> URL {
        let repo = fx.makeRepository(name, at: fx.home.appendingPathComponent("projects"))
        fx.commit([".env": "STRIPE_SECRET_KEY=\(Fake.stripeLive)\n"], message: "env", in: repo)
        return repo
    }

    func testFirstScanFindsHistoryAndSecondSkipsIt() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        _ = makeRepository(fx)
        let first = coordinator()
        let report1 = first.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(report1.repositoriesScanned, 1)
        XCTAssertEqual(history(first).map(\.fingerprint), [print(Fake.stripeLive)])
        let second = coordinator()
        let report2 = second.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(report2.repositoriesSkipped, 1)
        XCTAssertEqual(report2.repositoriesScanned, 0)
        XCTAssertEqual(history(second).map(\.id), history(first).map(\.id))
    }

    func testNewCommitRescansRepository() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = makeRepository(fx)
        let c = coordinator()
        c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        fx.commit([".env": "ANTHROPIC_API_KEY=\(Fake.anthropic)\n"], message: "new key", in: repo)
        let report = c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(report.repositoriesScanned, 1)
        XCTAssertEqual(Set(history(c).map(\.fingerprint)), [print(Fake.stripeLive), print(Fake.anthropic)])
    }

    func testUnreadableRepositoryKeepsItsFindingsAndIsListed() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = makeRepository(fx)
        let c = coordinator()
        c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        let before = history(c).map(\.id)
        // A new branch changes the tips, so the repository is read again, and now it cannot be.
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.copyItem(at: git.appendingPathComponent("refs/heads/main"), to: git.appendingPathComponent("refs/heads/other"))
        let config = try String(contentsOf: git.appendingPathComponent("config"), encoding: .utf8)
        try (config + "[extensions]\n\tobjectformat = sha256\n").write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let report = c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(history(c).map(\.id), before)
        XCTAssertEqual(report.repositoriesUnreadable, [repo.canonical.path])
    }

    func testUnreadableOnFirstSightIsListedNotClean() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let b = fx.home.appendingPathComponent("projects/b")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        fx.git("init", "-q", "--object-format=sha256", in: b)
        let c = coordinator()
        let report = c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(report.repositoriesUnreadable, [b.canonical.path])
        XCTAssertTrue(history(c).isEmpty)
        XCTAssertEqual(c.runFullScan(sources: SourceCatalog.standard(home: fx.home)).repositoriesUnreadable, [b.canonical.path],
                       "still listed on the next scan, not remembered as read")
    }

    func testCancelledScanCommitsNoHistory() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        _ = makeRepository(fx)
        var cancel = false
        let c = coordinator()
        let report = c.runFullScan(sources: SourceCatalog.standard(home: fx.home),
                                   progress: { label, _ in if label == "Git history" { cancel = true } }, isCancelled: { cancel })
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(c.store.findings.isEmpty)
        XCTAssertEqual(coordinator().runFullScan(sources: SourceCatalog.standard(home: fx.home)).repositoriesScanned, 1,
                       "nothing was remembered as read")
    }

    func testPushedKeyStaysAfterItsRepositoryIsDeleted() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = makeRepository(fx)
        let remote = fx.root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        fx.git("init", "-q", "--bare", in: remote)
        fx.git("remote", "add", "origin", remote.path, in: repo)
        fx.git("push", "-q", "origin", "main", in: repo)
        fx.git("remote", "set-url", "origin", "git@github.com:me/app.git", in: repo)
        let c = coordinator()
        c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(history(c).first?.git?.pushedTo, "github.com/me/app")
        try FileManager.default.removeItem(at: repo)
        c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(history(c).map(\.status), [.open], "deleting the clone does not un-push the key")
        XCTAssertFalse(c.store.findings.contains { $0.kind == .envFile }, "the .env file itself is gone")
    }

    func testPushedStaysPushedAfterTheRemoteIsRemoved() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = makeRepository(fx)
        let remote = fx.root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        fx.git("init", "-q", "--bare", in: remote)
        fx.git("remote", "add", "origin", remote.path, in: repo)
        fx.git("push", "-q", "origin", "main", in: repo)
        fx.git("remote", "set-url", "origin", "git@github.com:me/app.git", in: repo)
        let c = coordinator()
        c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(history(c).first?.git?.pushedTo, "github.com/me/app")
        // Removing the remote (or pruning a merged branch) deletes the evidence, not the push.
        fx.git("remote", "remove", "origin", in: repo)
        let report = c.runFullScan(sources: SourceCatalog.standard(home: fx.home))
        XCTAssertEqual(report.repositoriesScanned, 1)
        XCTAssertEqual(history(c).first?.git?.pushedTo, "github.com/me/app")
    }

    func testStateFrom030StillLoads() throws {
        let json = #"{"ruleset":\#(SecretRule.rulesetVersion),"files":{}}"#
        let state = try Crypto.decoder.decode(ScanState.self, from: Data(json.utf8))
        XCTAssertNil(state.repositories)
        XCTAssertEqual(state.files.count, 0)
    }
}
