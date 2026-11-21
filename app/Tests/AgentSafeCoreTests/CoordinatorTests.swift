import XCTest
@testable import AgentSafeCore

final class CoordinatorTests: XCTestCase {
    var home: URL!
    var data: URL!
    let salt = Data([4, 2])
    var sources: [ScanSource] { SourceCatalog.standard(home: home) }

    override func setUp() { home = Fake.tempDir(); data = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: data) }

    func makeCoordinator() -> ScanCoordinator {
        ScanCoordinator(scanner: SecretScanner(fingerprint: { Fingerprint.of($0, salt: self.salt) }),
                        store: FindingStore(url: data.appendingPathComponent("findings.json")),
                        stateURL: data.appendingPathComponent("scan-state.json"))
    }

    func line(_ secret: String) -> String { #"{"content":"KEY="# + secret + #""}"# + "\n" }

    @discardableResult
    func write(_ relative: String, _ text: String, append: Bool = false) -> URL {
        let url = home.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(text.data(using: .utf8)!); try! handle.close()
        } else {
            try! text.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func testSecondScanSkipsUnchangedFilesAndKeepsTheirFindings() {
        write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let first = makeCoordinator()
        let report1 = first.runFullScan(sources: sources)
        XCTAssertEqual(report1.newFindings.count, 1)
        XCTAssertEqual(report1.filesSkipped, 0)

        let second = makeCoordinator()  // a fresh launch, state read from disk
        let report2 = second.runFullScan(sources: sources)
        XCTAssertEqual(report2.filesSkipped, 1)
        XCTAssertTrue(report2.newFindings.isEmpty)
        XCTAssertEqual(second.store.findings.count, 1)
    }

    func testGrowingTranscriptIsReadFromWhereItLeftOff() {
        write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        write(".claude/projects/p/a.jsonl", line(Fake.anthropic) + line(Fake.github), append: true)
        let report = coordinator.runFullScan(sources: sources)
        XCTAssertEqual(report.newFindings.map(\.service), ["GitHub"])
        XCTAssertEqual(report.newFindings.first?.line, 3)
        XCTAssertEqual(coordinator.store.findings.first { $0.service == "Anthropic" }?.count, 2)
    }

    func testFindingsDisappearWhenTheFileIsDeleted() {
        let url = write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        try! FileManager.default.removeItem(at: url)
        _ = coordinator.runFullScan(sources: sources)
        XCTAssertTrue(coordinator.store.findings.isEmpty)
    }

    func testLiveChangeReportsOnlyTheNewLeak() {
        let url = write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        write(".claude/projects/p/a.jsonl", line(Fake.stripeLive), append: true)
        XCTAssertEqual(coordinator.fileChanged(url, sources: sources).map(\.service), ["Stripe"])
        XCTAssertTrue(coordinator.fileChanged(url, sources: sources).isEmpty, "nothing new the second time")
        XCTAssertEqual(coordinator.store.findings.count, 2)
    }

    func testLiveChangeInAnUnwatchedFileIsIgnored() {
        let url = write("notes/todo.txt", line(Fake.anthropic))
        XCTAssertTrue(makeCoordinator().fileChanged(url, sources: sources).isEmpty)
    }

    func testRewrittenConfigIsRescannedFromTheStart() {
        let url = write(".claude.json", #"{"env":{"A":""# + Fake.github + #""}}"#)
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-50)], ofItemAtPath: url.path)
        write(".claude.json", #"{"env":{"A":"removed"},"padding":"................................................................"}"#)
        _ = coordinator.runFullScan(sources: sources)
        XCTAssertTrue(coordinator.store.findings.isEmpty, "the key is gone from the file, so the finding must go too")
    }

    func testVaultCreatedWithInstallSaltSharesFingerprintsWithTheScanner() throws {
        let vault = try Vault.create(at: data.appendingPathComponent("v.json"), password: "master password 1", kdfIterations: 1_000, salt: salt)
        XCTAssertEqual(vault.fingerprint(of: Fake.github), Fingerprint.of(Fake.github, salt: salt))
    }

    // MARK: - Failure modes that must not hide a leak

    func testCancelledScanDoesNotMakeTheNextScanSkipFiles() {
        write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        write(".claude/projects/p/b.jsonl", line(Fake.github))
        let coordinator = makeCoordinator()
        var calls = 0
        _ = coordinator.runFullScan(sources: sources, isCancelled: { calls += 1; return calls > 1 })
        XCTAssertTrue(coordinator.store.findings.isEmpty, "a cancelled scan commits nothing")
        let report = coordinator.runFullScan(sources: sources)
        XCTAssertEqual(Set(report.newFindings.map(\.service)), ["Anthropic", "GitHub"])
        XCTAssertEqual(report.filesSkipped, 0)
    }

    func testTranscriptRewrittenToALargerFileIsReadFromTheStart() {
        let url = write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        // Same path, different content, bigger: looks like "it grew" unless we check.
        try! FileManager.default.removeItem(at: url)
        write(".claude/projects/p/a.jsonl", #"{"content":"nothing here, just a much longer line of ordinary text to make the file larger than before............................................................................"}"# + "\n" + line(Fake.github))
        _ = coordinator.runFullScan(sources: sources)
        XCTAssertEqual(coordinator.store.findings.map(\.service), ["GitHub"])
        XCTAssertEqual(coordinator.store.findings.first?.line, 2)
    }

    func testUnreadableFileKeepsItsFindingsUntilItIsActuallyGone() throws {
        let url = write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        write(".claude/projects/p/a.jsonl", line(Fake.github), append: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        _ = coordinator.runFullScan(sources: sources)
        XCTAssertEqual(coordinator.store.findings.map(\.service), ["Anthropic"], "could not read is not the same as clean")
        XCTAssertTrue(coordinator.fileChanged(url, sources: sources).isEmpty)
        XCTAssertEqual(coordinator.store.findings.count, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        _ = coordinator.runFullScan(sources: sources)
        XCTAssertEqual(Set(coordinator.store.findings.map(\.service)), ["Anthropic", "GitHub"], "readable again: the missed tail is picked up")
    }

    func testShellHistoryIsAlwaysReadInFull() {
        // zsh rewrites its history file (dedupe, trimming), so "it only grows" does not hold.
        let url = write(".zsh_history", ": 1:0;echo " + Fake.github + "\n")
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: url.path)
        write(".zsh_history", ": 1:0;echo hello world this is a longer but harmless history file now........\n: 2:0;ls\n")
        _ = coordinator.runFullScan(sources: sources)
        XCTAssertTrue(coordinator.store.findings.isEmpty)
    }

    func testLiveChangeInsideASymlinkedProjectIsSeen() throws {
        let outside = Fake.tempDir(); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("projects/linked"), withDestinationURL: outside)
        try ("STRIPE_SECRET_KEY=" + Fake.stripeLive + "\n").write(to: outside.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let viaLink = home.appendingPathComponent("projects/linked/.env")
        XCTAssertEqual(makeCoordinator().fileChanged(viaLink, sources: sources).map(\.service), ["Stripe"])
    }

    func testForgettingAFileForcesAFullReread() {
        let url = write(".claude/projects/p/a.jsonl", line(Fake.anthropic) + line(Fake.github))
        let coordinator = makeCoordinator()
        _ = coordinator.runFullScan(sources: sources)
        // Simulate an in-place edit that removes the first key but keeps size and timestamps plausible.
        let padded = String(repeating: " ", count: line(Fake.anthropic).count - 1) + "\n" + line(Fake.github) + line(Fake.slack)
        try! padded.write(to: url, atomically: false, encoding: .utf8)
        coordinator.forget(url)
        _ = coordinator.fileChanged(url, sources: sources)
        XCTAssertEqual(Set(coordinator.store.findings.map(\.service)), ["GitHub", "Slack"])
    }
}
