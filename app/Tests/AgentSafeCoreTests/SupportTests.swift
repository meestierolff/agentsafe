import XCTest
@testable import AgentSafeCore

final class BackupTests: XCTestCase {
    func testBackupRoundTripRestoresValuesAndDates() throws {
        let dir = Fake.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir.appendingPathComponent("v.json"), password: "master password 1", kdfIterations: 1_000)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try vault.add(name: "Anthropic", value: Fake.anthropic, service: "Anthropic", envName: "ANTHROPIC_API_KEY", now: created)
        try vault.update(item.id) { $0.rotateAfterDays = 30 }
        let data = try Backup.export(vault.revealAll(using: .password("master password 1")), password: "backup password", iterations: 1_000)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(Fake.anthropic))

        let fresh = try Vault.create(at: dir.appendingPathComponent("v2.json"), password: "another password", kdfIterations: 1_000)
        let summary = try fresh.restore(Backup.read(data, password: "backup password"))
        XCTAssertEqual(summary.added, 1)
        let restored = try XCTUnwrap(fresh.items.first)
        XCTAssertEqual(restored.createdAt, created)
        XCTAssertEqual(restored.envName, "ANTHROPIC_API_KEY")
        XCTAssertEqual(restored.rotateAfterDays, 30)
        XCTAssertEqual(try fresh.reveal(restored.id, using: .password("another password")), Fake.anthropic)
        XCTAssertEqual(try fresh.restore(Backup.read(data, password: "backup password")).skipped, 1, "restoring twice must not duplicate")
    }

    func testBackupWithWrongPasswordIsRejected() throws {
        let data = try Backup.export([], password: "backup password", iterations: 1_000)
        XCTAssertThrowsError(try Backup.read(data, password: "nope nope nope")) { XCTAssertEqual($0 as? BackupError, .wrongPassword) }
        XCTAssertThrowsError(try Backup.read(Data("hello".utf8), password: "x")) { XCTAssertEqual($0 as? BackupError, .notABackup) }
    }
}

final class LicenseTests: XCTestCase {
    // From shared/license-test-vector.json, signed by the website's code with the TEST key.
    let publicKey = Data(base64Encoded: "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=")!
    let license = "AS1.eyJpZCI6ImxpY190ZXN0XzAwMDEiLCJlbWFpbCI6ImJ1eWVyQGV4YW1wbGUuY29tIiwiaWF0IjoxNzk1MDAwMDAwLCJza3UiOiJhZ2VudHNhZmUtbWFjIn0.1Jow6qFVvJMtmMAnr3aZNpp-j2zGhSRgZm1xX0_hhcADifvwqCYZssFEki69jo_J5ODtuupRNCCM-9OXYLweAQ"

    func testAcceptsALicenceSignedByTheWebsite() throws {
        let l = try LicenseVerifier.verify(license, publicKey: publicKey)
        XCTAssertEqual(l.id, "lic_test_0001")
        XCTAssertEqual(l.email, "buyer@example.com")
        XCTAssertEqual(l.sku, "agentsafe-mac")
    }

    func testAcceptsLicencePastedWithWhitespaceAndLineBreaks() throws {
        let messy = "  " + license.prefix(40) + "\n" + license.dropFirst(40) + "  \n"
        XCTAssertNoThrow(try LicenseVerifier.verify(messy, publicKey: publicKey))
    }

    func testRejectsTamperedPayloadWrongKeyAndGarbage() {
        var parts = license.split(separator: ".").map(String.init)
        parts[1] = Data(#"{"id":"lic_free","iat":1,"sku":"agentsafe-mac"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try LicenseVerifier.verify(parts.joined(separator: "."), publicKey: publicKey)) { XCTAssertEqual($0 as? LicenseError, .badSignature) }
        XCTAssertThrowsError(try LicenseVerifier.verify(license, publicKey: Data(repeating: 9, count: 32))) { XCTAssertEqual($0 as? LicenseError, .badSignature) }
        XCTAssertThrowsError(try LicenseVerifier.verify("not a licence", publicKey: publicKey)) { XCTAssertEqual($0 as? LicenseError, .malformed) }
    }
}

final class HardeningTests: XCTestCase {
    func testAddsDenyRulesAndKeepsEverythingElse() throws {
        let existing = Data(#"{"model":"opus","permissions":{"allow":["Bash(npm test *)"],"deny":["Read(./secrets/**)"]},"hooks":{"Stop":[]}}"#.utf8)
        let plan = try ClaudeHardening.plan(existing: existing)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.result) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "opus")
        XCTAssertNotNil(json["hooks"])
        let permissions = try XCTUnwrap(json["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(npm test *)"])
        let deny = try XCTUnwrap(permissions["deny"] as? [String])
        XCTAssertEqual(deny.first, "Read(./secrets/**)", "existing rules stay first and untouched")
        XCTAssertTrue(deny.contains("Read(//**/.env)"))
        XCTAssertTrue(deny.contains("Read(~/.ssh/**)"))
        XCTAssertEqual(plan.added.count, ClaudeHardening.rules.count)
    }

    func testRunningTwiceAddsNothing() throws {
        let once = try ClaudeHardening.plan(existing: nil)
        let twice = try ClaudeHardening.plan(existing: once.result)
        XCTAssertTrue(twice.added.isEmpty)
        XCTAssertEqual(twice.alreadyPresent.count, ClaudeHardening.rules.count)
    }

    func testExampleEnvFilesStayReadable() {
        let rules = ClaudeHardening.rules.map(\.rule)
        XCTAssertFalse(rules.contains("Read(//**/.env.*)"), "a blanket .env.* rule would also block .env.example")
        XCTAssertTrue(rules.contains("Read(//**/.env.local)"))
    }

    func testRefusesToOverwriteASettingsFileItCannotParse() {
        XCTAssertThrowsError(try ClaudeHardening.plan(existing: Data("{ broken".utf8))) { XCTAssertEqual($0 as? HardeningError, .unreadableSettings) }
        XCTAssertThrowsError(try ClaudeHardening.plan(existing: Data("[1,2]".utf8))) { XCTAssertEqual($0 as? HardeningError, .unreadableSettings) }
    }
}

final class KeyHealthTests: XCTestCase {
    let policy = RotationPolicy()
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func item(ageDays: Double, expiresInDays: Double? = nil, rotateAfter: Int? = nil, service: String = "OpenAI") throws -> VaultItem {
        let dir = Fake.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let vault = try Vault.create(at: dir.appendingPathComponent("v.json"), password: "master password 1", kdfIterations: 1_000)
        let created = now.addingTimeInterval(-ageDays * day)
        let item = try vault.add(name: "k", value: Fake.openAIProject, service: service, expiresAt: expiresInDays.map { now.addingTimeInterval($0 * day) }, now: created)
        try vault.update(item.id) { $0.rotateAfterDays = rotateAfter }
        return vault.items[0]
    }

    func testFreshKeyIsHealthy() throws {
        XCTAssertEqual(KeyHealth.status(of: try item(ageDays: 3), leaked: false, policy: policy, now: now), .healthy(daysLeft: 87))
    }

    func testKeyNearItsRotationAgeIsDueSoonThenOverdue() throws {
        XCTAssertEqual(KeyHealth.status(of: try item(ageDays: 80), leaked: false, policy: policy, now: now), .dueSoon(daysLeft: 10))
        XCTAssertEqual(KeyHealth.status(of: try item(ageDays: 100), leaked: false, policy: policy, now: now), .overdue(daysOver: 10))
    }

    func testHardExpiryWinsOverAge() throws {
        XCTAssertEqual(KeyHealth.status(of: try item(ageDays: 3, expiresInDays: 5), leaked: false, policy: policy, now: now), .expiring(daysLeft: 5))
        XCTAssertEqual(KeyHealth.status(of: try item(ageDays: 3, expiresInDays: -2), leaked: false, policy: policy, now: now), .expired(daysAgo: 2))
    }

    func testLeakedBeatsEverything() throws {
        XCTAssertEqual(KeyHealth.status(of: try item(ageDays: 1), leaked: true, policy: policy, now: now), .leaked)
    }

    func testPerKeyRotationOverridesThePolicy() throws {
        XCTAssertEqual(KeyHealth.status(of: try item(ageDays: 40, rotateAfter: 30), leaked: false, policy: policy, now: now), .overdue(daysOver: 10))
    }

    func testSummaryCountsWhatNeedsAttention() throws {
        let items = [try item(ageDays: 3), try item(ageDays: 100), try item(ageDays: 3, expiresInDays: 5)]
        let summary = KeyHealth.summary(items: items, leakedFingerprints: [], policy: policy, now: now)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.needRotation, 1)
        XCTAssertEqual(summary.expiring, 1)
    }
}
