import XCTest
@testable import AgentSafeCore

final class VaultTests: XCTestCase {
    var dir: URL!
    var file: URL { dir.appendingPathComponent("vault.json") }
    let password = "correct horse battery staple"

    override func setUp() { dir = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeVault() throws -> Vault {
        try Vault.create(at: file, password: password, kdfIterations: 1_000)
    }

    func testAddingAKeyNeedsNoUnlockAndStoresNoPlaintext() throws {
        let vault = try makeVault()
        let item = try vault.add(name: "Anthropic prod", value: Fake.anthropic, service: "Anthropic")
        XCTAssertEqual(item.preview, Redactor.preview(Fake.anthropic))
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(Fake.anthropic))
        XCTAssertFalse(onDisk.contains(String(Fake.anthropic.dropFirst(10).prefix(20))))
    }

    func testRevealWithMasterPasswordReturnsTheValue() throws {
        let vault = try makeVault()
        let item = try vault.add(name: "GitHub", value: Fake.github, service: "GitHub")
        let reopened = try Vault.open(at: file)
        XCTAssertEqual(try reopened.reveal(item.id, using: .password(password)), Fake.github)
    }

    func testWrongPasswordIsRejected() throws {
        let vault = try makeVault()
        let item = try vault.add(name: "GitHub", value: Fake.github, service: "GitHub")
        XCTAssertThrowsError(try vault.reveal(item.id, using: .password("wrong password"))) { error in
            XCTAssertEqual(error as? VaultError, .wrongPassword)
        }
    }

    func testVaultFileIsOwnerOnly() throws {
        _ = try makeVault()
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testFingerprintMatchesALeakedCopyOfAStoredKey() throws {
        let vault = try makeVault()
        let item = try vault.add(name: "Stripe", value: Fake.stripeLive, service: "Stripe")
        XCTAssertEqual(vault.item(matchingFingerprint: vault.fingerprint(of: Fake.stripeLive))?.id, item.id)
        XCTAssertNil(vault.item(matchingFingerprint: vault.fingerprint(of: Fake.github)))
    }

    func testAddingTheSameValueTwiceIsRefused() throws {
        let vault = try makeVault()
        _ = try vault.add(name: "A", value: Fake.github, service: "GitHub")
        XCTAssertThrowsError(try vault.add(name: "B", value: Fake.github, service: "GitHub")) { error in
            XCTAssertEqual(error as? VaultError, .duplicate)
        }
    }

    func testReplacingAValueRecordsTheRotation() throws {
        let vault = try makeVault()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try vault.add(name: "OpenAI", value: Fake.openAIProject, service: "OpenAI", now: old)
        let newValue = Fake.openAIProject + "NEW1"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try vault.replaceValue(of: item.id, with: newValue, now: now)
        let updated = try XCTUnwrap(vault.items.first)
        XCTAssertEqual(updated.lastRotatedAt, now)
        XCTAssertEqual(updated.createdAt, old)
        XCTAssertEqual(try vault.reveal(item.id, using: .password(password)), newValue)
    }

    func testDeleteRemovesItemFromDisk() throws {
        let vault = try makeVault()
        let item = try vault.add(name: "Slack", value: Fake.slack, service: "Slack")
        try vault.delete(item.id)
        XCTAssertTrue(try Vault.open(at: file).items.isEmpty)
    }

    func testChangingThePasswordKeepsEveryKeyReadable() throws {
        let vault = try makeVault()
        let item = try vault.add(name: "GitHub", value: Fake.github, service: "GitHub")
        try vault.changePassword(from: password, to: "a brand new passphrase", kdfIterations: 1_000)
        XCTAssertEqual(try vault.reveal(item.id, using: .password("a brand new passphrase")), Fake.github)
        XCTAssertThrowsError(try vault.reveal(item.id, using: .password(password)))
    }

    func testShortPasswordIsRefusedAtSetup() {
        XCTAssertThrowsError(try Vault.create(at: file, password: "short", kdfIterations: 1_000)) { error in
            XCTAssertEqual(error as? VaultError, .passwordTooShort)
        }
    }

    /// Uses the real Secure Enclave, with the fingerprint requirement switched off so the
    /// test can run unattended. Skipped on Macs without one.
    func testEnclaveUnlockRevealsWithoutThePassword() throws {
        let enclave = SecureEnclaveKeyProvider(requireUserPresence: false)
        try XCTSkipUnless(enclave.isAvailable, "No Secure Enclave on this machine")
        let vault = try makeVault()
        let item = try vault.add(name: "Anthropic", value: Fake.anthropic, service: "Anthropic")
        XCTAssertFalse(vault.hasEnclaveUnlock)
        try vault.enableEnclaveUnlock(password: password, enclave: enclave)
        let reopened = try Vault.open(at: file)
        XCTAssertTrue(reopened.hasEnclaveUnlock)
        XCTAssertEqual(try reopened.reveal(item.id, using: .enclave(enclave, reason: "test")), Fake.anthropic)
    }
}
