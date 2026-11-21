import CryptoKit
import XCTest
@testable import AgentSafeCore

final class RunHandoffTests: XCTestCase {
    var dir: URL!
    let password = "correct horse battery staple"

    override func setUp() { dir = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeVault() throws -> Vault { try Vault.create(at: dir.appendingPathComponent("safe.json"), password: password, kdfIterations: 1_000) }

    func request(_ names: [String], key: P256.KeyAgreement.PrivateKey = .init(), command: [String] = ["npm", "run", "dev"],
                 createdAt: Date = Date()) -> RunRequest {
        RunRequest(id: UUID().uuidString, createdAt: createdAt, names: names, directory: "/Users/me/shop", command: command,
                   publicKey: key.publicKey.rawRepresentation)
    }

    // MARK: - Which keys a project asks for

    func testKeyListFileNamesVariablesAndOptionallyTheKeyToUse() {
        let text = """
        # keys this project needs
        OPENAI_API_KEY
        STRIPE_SECRET_KEY = Stripe live

          DATABASE_URL=Neon production   # trailing note
        """
        XCTAssertEqual(RunHandoff.parseKeyList(text), [
            KeyReference(envName: "OPENAI_API_KEY", keyName: nil),
            KeyReference(envName: "STRIPE_SECRET_KEY", keyName: "Stripe live"),
            KeyReference(envName: "DATABASE_URL", keyName: "Neon production"),
        ])
    }

    func testKeyListNeverAcceptsAValueThatLooksLikeASecret() {
        // Someone will paste a real .env here. The file is for names, so a pasted secret is refused, not used.
        let text = "OPENAI_API_KEY=" + Fake.openAIProject + "\nGOOD_NAME\n"
        XCTAssertEqual(RunHandoff.parseKeyList(text), [KeyReference(envName: "GOOD_NAME", keyName: nil)])
        XCTAssertEqual(RunHandoff.secretLookingLines(in: text), [1])
    }

    // MARK: - Finding the keys in the safe

    func testKeysAreFoundByVariableNameOrByTheNameGiven() throws {
        let vault = try makeVault()
        let openai = try vault.add(name: "OpenAI side project", value: Fake.openAIProject, service: "OpenAI", envName: "OPENAI_API_KEY")
        let stripe = try vault.add(name: "Stripe live", value: Fake.stripeLive, service: "Stripe")
        try vault.update(openai.id) { $0.allowRun = true }
        try vault.update(stripe.id) { $0.allowRun = true }
        let plan = vault.resolve([KeyReference(envName: "OPENAI_API_KEY", keyName: nil), KeyReference(envName: "STRIPE_SECRET_KEY", keyName: "stripe LIVE")])
        XCTAssertEqual(plan.matched.map(\.envName), ["OPENAI_API_KEY", "STRIPE_SECRET_KEY"])
        XCTAssertEqual(plan.matched.map(\.item.id), [openai.id, stripe.id])
        XCTAssertTrue(plan.missing.isEmpty)
        XCTAssertTrue(plan.notAllowed.isEmpty)
    }

    func testAKeyMustBeSwitchedOnBeforeAnyCommandCanAskForIt() throws {
        // Off by default: adding the helper must not make every key in the safe requestable.
        let vault = try makeVault()
        try vault.add(name: "Stripe live", value: Fake.stripeLive, service: "Stripe", envName: "STRIPE_SECRET_KEY")
        let plan = vault.resolve([KeyReference(envName: "STRIPE_SECRET_KEY", keyName: nil), KeyReference(envName: "NOT_THERE", keyName: nil)])
        XCTAssertTrue(plan.matched.isEmpty)
        XCTAssertEqual(plan.notAllowed.map(\.envName), ["STRIPE_SECRET_KEY"])
        XCTAssertEqual(plan.missing, ["NOT_THERE"])
        XCTAssertFalse(plan.canProceed)
    }

    // MARK: - The handoff itself

    func testApprovedKeysReachOnlyTheProcessThatAsked() throws {
        let vault = try makeVault()
        let item = try vault.add(name: "OpenAI", value: Fake.openAIProject, service: "OpenAI", envName: "OPENAI_API_KEY")
        try vault.update(item.id) { $0.allowRun = true }
        let asker = P256.KeyAgreement.PrivateKey()
        let req = request(["OPENAI_API_KEY"], key: asker)

        let response = try RunHandoff.approve(req, plan: vault.resolve(req.references), vault: vault, using: .password(password))
        XCTAssertEqual(response.status, .approved)
        let onDisk = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(onDisk.contains(Fake.openAIProject), "the reply file must not contain the key in the clear")
        XCTAssertEqual(try RunHandoff.open(response, for: req, privateKey: asker), ["OPENAI_API_KEY": Fake.openAIProject])

        // Anyone else who reads the reply file gets nothing out of it.
        XCTAssertThrowsError(try RunHandoff.open(response, for: req, privateKey: P256.KeyAgreement.PrivateKey()))
        // And a reply cannot be replayed against a different request.
        XCTAssertThrowsError(try RunHandoff.open(response, for: request(["OPENAI_API_KEY"], key: asker), privateKey: asker))
    }

    func testNothingIsReleasedWhenAnyRequestedKeyIsMissingOrSwitchedOff() throws {
        let vault = try makeVault()
        try vault.add(name: "OpenAI", value: Fake.openAIProject, service: "OpenAI", envName: "OPENAI_API_KEY")
        let req = request(["OPENAI_API_KEY"])
        XCTAssertThrowsError(try RunHandoff.approve(req, plan: vault.resolve(req.references), vault: vault, using: .password(password))) {
            XCTAssertEqual($0 as? RunError, .notReady)
        }
    }

    func testMalformedOrStaleRequestsAreRefused() {
        XCTAssertNoThrow(try RunHandoff.validate(request(["OPENAI_API_KEY"])))
        XCTAssertThrowsError(try RunHandoff.validate(request([]))) { XCTAssertEqual($0 as? RunError, .invalidRequest) }
        XCTAssertThrowsError(try RunHandoff.validate(request(["BAD NAME"]))) { XCTAssertEqual($0 as? RunError, .invalidRequest) }
        XCTAssertThrowsError(try RunHandoff.validate(request(["PATH"]))) { XCTAssertEqual($0 as? RunError, .invalidRequest) }
        XCTAssertThrowsError(try RunHandoff.validate(request(["A"], command: []))) { XCTAssertEqual($0 as? RunError, .invalidRequest) }
        XCTAssertThrowsError(try RunHandoff.validate(request(["A"], createdAt: Date().addingTimeInterval(-600)))) { XCTAssertEqual($0 as? RunError, .expired) }
        var bad = request(["A"]); bad.id = "../../etc/passwd"
        XCTAssertThrowsError(try RunHandoff.validate(bad)) { XCTAssertEqual($0 as? RunError, .invalidRequest) }
    }

    func testDeniedReplyCarriesNoKeys() throws {
        let req = request(["OPENAI_API_KEY"])
        let response = RunHandoff.deny(req, message: "Denied in AgentSafe.")
        XCTAssertEqual(response.status, .denied)
        XCTAssertNil(response.sealed)
        XCTAssertThrowsError(try RunHandoff.open(response, for: req, privateKey: P256.KeyAgreement.PrivateKey())) {
            XCTAssertEqual($0 as? RunError, .denied("Denied in AgentSafe."))
        }
    }

    func testSafeWrittenBeforeTheAgentSwitchExistedStillOpensWithItOff() throws {
        let vault = try makeVault()
        try vault.add(name: "GitHub", value: Fake.github, service: "GitHub")
        XCTAssertFalse(try String(contentsOf: dir.appendingPathComponent("safe.json"), encoding: .utf8).contains("allowRun"))
        XCTAssertNil(try Vault.open(at: dir.appendingPathComponent("safe.json")).items.first?.allowRun)
    }
}
