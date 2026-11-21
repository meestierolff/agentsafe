import XCTest
@testable import AgentSafeCore

final class SettingsTests: XCTestCase {
    /// The exact shape of the settings file written by version 0.1.0. A user who already
    /// has a safe, a licence and a folder grant must not lose them to an update.
    func testSettingsFileFromTheFirstReleaseStillLoads() throws {
        let old = #"{"installSalt":"AQIDBAUGBwgJCgsMDQ4PEA==","licenseKey":"AS1.abc.def","homeBookmark":"Ym9va21hcms=","watchEnabled":false,"clipboardWatch":true,"lastScan":774000000,"hasCompletedSetup":true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.installSalt, Data((1...16).map { UInt8($0) }))
        XCTAssertEqual(settings.licenseKey, "AS1.abc.def")
        XCTAssertEqual(settings.homeBookmark, Data("bookmark".utf8))
        XCTAssertFalse(settings.watchEnabled)
        XCTAssertTrue(settings.clipboardWatch)
        XCTAssertTrue(settings.hasCompletedSetup)
        XCTAssertEqual(settings.placement, .menuBar, "new options take their defaults")
        XCTAssertFalse(settings.openOnHover)
    }

    func testSettingsWithOnlyASaltLoadWithDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"installSalt":"AQID"}"#.utf8))
        XCTAssertTrue(settings.watchEnabled)
        XCTAssertNil(settings.licenseKey)
    }

    func testSettingsRoundTripKeepsNewOptions() throws {
        var settings = AppSettings(installSalt: Data([9]))
        settings.placement = .notch
        settings.openOnHover = true
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.placement, .notch)
        XCTAssertTrue(back.openOnHover)
    }
}

final class KeyCatalogTests: XCTestCase {
    func profile(_ rule: String, _ preview: String) -> KeyProfile { KeyCatalog.profile(ruleID: rule, preview: preview) }

    func testStripeLiveAndTestKeysAreToldApart() {
        let live = profile("stripe", "sk_live_…C39H")
        XCTAssertEqual(live.environment, .production)
        XCTAssertEqual(live.severity, .critical)
        let test = profile("stripe", "sk_test_…C39H")
        XCTAssertEqual(test.environment, .sandbox)
        XCTAssertEqual(test.severity, .low)
        XCTAssertEqual(profile("stripe", "rk_live_…C39H").severity, .high, "a restricted key is limited by its scopes")
        XCTAssertEqual(profile("stripe", "whsec_…C39H").severity, .medium)
        XCTAssertNotEqual(live.summary, test.summary)
    }

    func testSeverityFollowsWhatTheKeyCanDoNotWhoIssuedIt() {
        XCTAssertEqual(profile("database-url", "post…/app").severity, .critical)
        XCTAssertEqual(profile("private-key", "----…----").severity, .critical)
        XCTAssertEqual(profile("anthropic", "sk-ant-…QwAA").severity, .high)
        XCTAssertEqual(profile("aws", "AKIA…MPLQ").severity, .medium, "an access key ID is only half a credential")
        XCTAssertEqual(profile("env-assignment", "q9Xy…0Jf").severity, .medium)
    }

    func testEnvironmentIsOnlyStatedWhereTheFormatProvesIt() {
        for rule in ["anthropic", "openai", "github", "database-url", "env-assignment", "brevo"] {
            XCTAssertEqual(profile(rule, "abcd…wxyz").environment, .unknown, rule)
        }
    }

    func testEveryBuiltInRuleHasADescription() {
        for rule in SecretRule.builtIn {
            let p = profile(rule.id, "abcd…wxyz")
            XCTAssertFalse(p.summary.isEmpty, rule.id)
            XCTAssertNotEqual(p.summary, KeyCatalog.unknown.summary, "\(rule.id) falls back to the generic text")
        }
    }

    func testSeveritySortsHighestFirst() {
        XCTAssertEqual([KeySeverity.low, .critical, .medium, .high].sorted(by: >), [.critical, .high, .medium, .low])
    }

    func testStoredKeysGetAProfileFromTheirServiceName() {
        XCTAssertEqual(KeyCatalog.profile(service: "Stripe", preview: "sk_test_…C39H").environment, .sandbox)
        XCTAssertEqual(KeyCatalog.profile(service: "Something else", preview: "abcd…wxyz"), KeyCatalog.unknown)
    }

    func testStripeTestKeysAreDetected() {
        let key = "sk_" + "test_" + Fake.noise(30, seed: 51)
        let hits = SecretDetector().scan(Data(("STRIPE=" + key).utf8)).matches
        XCTAssertEqual(hits.map(\.value), [key])
        XCTAssertEqual(hits.first?.rule.id, "stripe")
    }
}

final class RemovalTests: XCTestCase {
    var home: URL!
    var data: URL!
    let salt = Data([5, 5])
    var sources: [ScanSource] { SourceCatalog.standard(home: home) }

    override func setUp() { home = Fake.tempDir(); data = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: data) }

    func coordinator() -> ScanCoordinator {
        ScanCoordinator(scanner: SecretScanner(fingerprint: { Fingerprint.of($0, salt: self.salt) }),
                        store: FindingStore(url: data.appendingPathComponent("findings.json")),
                        stateURL: data.appendingPathComponent("scan-state.json"))
    }

    func line(_ secret: String) -> String { #"{"content":"KEY="# + secret + #""}"# + "\n" }

    @discardableResult
    func write(_ relative: String, _ text: String, age: TimeInterval = 600) -> URL {
        let url = home.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func testOnlyRecordsAreSafeToScrub() {
        // Transcripts and shell history are records. A config or .env file is in use:
        // replacing the key there would break whatever reads it.
        XCTAssertEqual(SourceKind.allCases.filter(\.isRecord), [.agentTranscript, .shellHistory])
    }

    func testBulkRemovalScrubsRecordsAndLeavesFilesThatUseTheKey() throws {
        let transcript = write(".claude/projects/p/a.jsonl", line(Fake.anthropic) + line(Fake.github))
        let history = write(".zsh_history", ": 1:0;curl -H 'x-api-key: " + Fake.anthropic + "' https://api.example.org\n")
        let config = write(".claude.json", #"{"mcpServers":{"x":{"env":{"K":""# + Fake.anthropic + #""}}}}"#)
        let env = write("projects/shop/.env", "ANTHROPIC_API_KEY=" + Fake.anthropic + "\n")
        let c = coordinator()
        c.runFullScan(sources: sources)

        let report = c.removeLocalCopies(of: c.store.findings, sources: sources)
        XCTAssertEqual(report.copiesRemoved, 3)
        XCTAssertEqual(Set(report.removed.map(\.path)), [transcript.canonical.path, history.canonical.path])
        XCTAssertEqual(report.skipped.filter { $0.reason == .inUse }.count, 2)
        XCTAssertFalse(try String(contentsOf: transcript, encoding: .utf8).contains(Fake.anthropic))
        XCTAssertFalse(try String(contentsOf: history, encoding: .utf8).contains(Fake.anthropic))
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains(Fake.anthropic), "an MCP config still needs its key")
        XCTAssertTrue(try String(contentsOf: env, encoding: .utf8).contains(Fake.anthropic), "a .env file still needs its key")
    }

    func testBulkRemovalReportsWhatItCouldNotTouch() throws {
        write(".claude/projects/p/live.jsonl", line(Fake.anthropic), age: 5)   // an agent is still writing here
        write("Library/Application Support/Cursor/User/globalStorage/state.vscdb", "SQLite format 3\u{0}" + Fake.anthropic)
        let c = coordinator()
        c.runFullScan(sources: sources)
        let report = c.removeLocalCopies(of: c.store.findings, sources: sources)
        XCTAssertEqual(report.copiesRemoved, 0)
        XCTAssertEqual(Set(report.skipped.map(\.reason)), [.recentlyModified, .database])
    }

    func testALeakStaysListedAfterItsLastCopyIsRemoved() throws {
        // Removing the file copy does not un-leak the key. It still has to be rotated,
        // so the finding must not quietly disappear.
        write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let c = coordinator()
        c.runFullScan(sources: sources)
        c.removeLocalCopies(of: c.store.findings, sources: sources)

        var remaining = try XCTUnwrap(c.store.findings.first)
        XCTAssertEqual(c.store.findings.count, 1)
        XCTAssertEqual(remaining.status, .open)
        XCTAssertNotNil(remaining.localCopyRemovedAt)

        c.runFullScan(sources: sources)   // a later scan no longer sees it in the file
        remaining = try XCTUnwrap(c.store.findings.first)
        XCTAssertEqual(remaining.status, .open, "still needs rotating")

        c.store.setStatus(.rotated, forFingerprint: remaining.fingerprint)
        c.runFullScan(sources: sources)
        XCTAssertTrue(c.store.findings.isEmpty, "rotated and gone from disk: nothing left to say")
    }

    func testNewRulesReachFilesThatHaveNotChanged() throws {
        write(".claude/projects/p/a.jsonl", line(Fake.anthropic))
        let first = coordinator()
        first.runFullScan(sources: sources)
        first.store.setStatus(.ignored, forFingerprint: first.store.findings[0].fingerprint)

        // The same state on disk, as an older version of the rules would have left it.
        let stateURL = data.appendingPathComponent("scan-state.json")
        var state = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        state["ruleset"] = 1
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)

        let report = coordinator().runFullScan(sources: sources)
        XCTAssertEqual(report.filesSkipped, 0, "an unchanged file must be read again when the rules changed")
        XCTAssertEqual(report.filesScanned, 1)
        XCTAssertEqual(FindingStore(url: data.appendingPathComponent("findings.json")).findings.first?.status, .ignored, "the user's decision survives")
    }

    func testRemovalKeepsTheFilesOriginalDate() throws {
        // Agents list sessions by date. Rewriting hundreds of transcripts must not make
        // them all look like they were used today.
        let url = write(".claude/projects/p/a.jsonl", line(Fake.anthropic), age: 86_400 * 9)
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let c = coordinator()
        c.runFullScan(sources: sources)
        XCTAssertEqual(c.removeLocalCopies(of: c.store.findings, sources: sources).copiesRemoved, 1)
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        XCTAssertEqual(after.timeIntervalSince1970, before.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(Fake.anthropic))
    }
}

final class SafeFileTests: XCTestCase {
    var dir: URL!
    var file: URL { dir.appendingPathComponent("safe.json") }
    let password = "correct horse battery staple"

    override func setUp() { dir = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testCreatingASafeNeverReplacesAnExistingFile() throws {
        // The file may be a real safe we merely failed to read. Writing a new, empty
        // one over it would destroy every key in it.
        let vault = try Vault.create(at: file, password: password, kdfIterations: 1_000)
        try vault.add(name: "GitHub", value: Fake.github, service: "GitHub")
        XCTAssertThrowsError(try Vault.create(at: file, password: "another password!", kdfIterations: 1_000)) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists)
        }
        try "not json at all".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Vault.create(at: file, password: password, kdfIterations: 1_000)) {
            XCTAssertEqual($0 as? VaultError, .alreadyExists)
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json at all", "the unreadable file is left exactly as it was")
    }

    func testSafeWrittenBeforeRotationLinksExistedStillOpens() throws {
        let vault = try Vault.create(at: file, password: password, kdfIterations: 1_000)
        let item = try vault.add(name: "GitHub", value: Fake.github, service: "GitHub")
        // A key without a link is stored exactly as the previous version stored it.
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("rotationURL"))
        let reopened = try Vault.open(at: file)
        XCTAssertNil(reopened.items.first?.rotationURL)
        XCTAssertEqual(try reopened.reveal(item.id, using: .password(password)), Fake.github)
    }

    func testRotationLinkIsKeptAcrossSaveBackupAndRestore() throws {
        let vault = try Vault.create(at: file, password: password, kdfIterations: 1_000)
        let item = try vault.add(name: "Stripe", value: Fake.stripeLive, service: "Stripe", rotationURL: "https://dashboard.stripe.com/acct_123/apikeys")
        XCTAssertEqual(try Vault.open(at: file).items.first?.rotationURL, "https://dashboard.stripe.com/acct_123/apikeys")
        try vault.update(item.id) { $0.rotationURL = "https://dashboard.stripe.com/acct_456/apikeys" }

        let backup = try Backup.export(vault.revealAll(using: .password(password)), password: "backup password", iterations: 1_000)
        let fresh = try Vault.create(at: dir.appendingPathComponent("other.json"), password: password, kdfIterations: 1_000)
        try fresh.restore(Backup.read(backup, password: "backup password"))
        XCTAssertEqual(fresh.items.first?.rotationURL, "https://dashboard.stripe.com/acct_456/apikeys")
    }

    func testBackupWrittenBeforeRotationLinksExistedStillRestores() throws {
        // The payload shape of a 0.2 backup: no rotationURL field at all.
        let entry = #"[{"name":"GitHub","service":"GitHub","note":"","createdAt":"2026-11-21T10:00:00Z","lastRotatedAt":"2026-11-21T10:00:00Z","value":"abc"}]"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([BackupEntry].self, from: Data(entry.utf8))
        XCTAssertEqual(entries.first?.name, "GitHub")
        XCTAssertNil(entries.first?.rotationURL)
    }

    func testOnlySecureWebLinksAreAcceptedAsRotationLinks() {
        XCTAssertEqual(RotationLink.url(from: " https://platform.openai.com/api-keys ")?.host, "platform.openai.com")
        XCTAssertEqual(RotationLink.url(from: "console.anthropic.com/settings/keys")?.absoluteString, "https://console.anthropic.com/settings/keys",
                       "a bare address is taken as https")
        for bad in ["http://example.org/keys", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.org", "", "   ", "https://", "not a link"] {
            XCTAssertNil(RotationLink.url(from: bad), bad)
        }
    }
}
