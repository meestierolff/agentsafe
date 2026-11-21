import XCTest
@testable import AgentSafeCore

final class DetectorTests: XCTestCase {
    let detector = SecretDetector()

    func testFindsAnthropicKeyInsideJSONTranscriptLine() {
        let line = #"{"type":"tool_result","content":"ANTHROPIC_API_KEY="# + Fake.anthropic + #"\nPORT=3000"}"#
        let hits = detector.matches(in: line)
        XCTAssertEqual(hits.map(\.value), [Fake.anthropic])
        XCTAssertEqual(hits.first?.rule.service, "Anthropic")
    }

    func testIdentifiesEachProviderByShape() {
        let cases: [(String, String)] = [
            (Fake.openAIProject, "OpenAI"), (Fake.openRouter, "OpenRouter"), (Fake.github, "GitHub"),
            (Fake.awsKeyID, "AWS"), (Fake.stripeLive, "Stripe"), (Fake.google, "Google"), (Fake.slack, "Slack"),
        ]
        for (value, service) in cases {
            XCTAssertEqual(detector.identify(value)?.service, service, "expected \(service)")
        }
    }

    func testOpenRouterKeyIsNotReportedAsOpenAI() {
        let hits = detector.matches(in: "key: " + Fake.openRouter)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.rule.service, "OpenRouter")
    }

    func testFindsDatabasePasswordAndPrivateKeyBlock() {
        let text = "DATABASE_URL=" + Fake.postgresURL + "\n" + Fake.privateKeyHeader + "\nabc"
        let services = Set(detector.matches(in: text).map(\.rule.id))
        XCTAssertEqual(services, ["database-url", "private-key"])
    }

    func testOrdinaryTextAndPlaceholdersProduceNoFindings() {
        let text = """
        The sk-learn library and risk-based checks are fine.
        OPENAI_API_KEY=your-key-here
        export API_KEY=<paste here>
        url: https://example.com/a/b?c=d
        """
        XCTAssertTrue(detector.matches(in: text).isEmpty)
        XCTAssertTrue(detector.envAssignments(in: text).isEmpty)
    }

    func testEnvAssignmentsCatchUnknownProvidersButSkipConfigValues() {
        let secret = Fake.unknownProviderSecret
        let text = "PORT=3000\nNODE_ENV=production\nSCRAPER_API_KEY=" + secret + "\nNEXT_PUBLIC_URL=https://example.com\nMY_SERVICE_TOKEN=\"" + secret + "\"\n"
        let found = detector.envAssignments(in: text)
        XCTAssertEqual(found.map(\.name), ["SCRAPER_API_KEY", "MY_SERVICE_TOKEN"])
        XCTAssertEqual(found.map(\.value), [secret, secret])
    }

    func testPreviewNeverContainsTheMiddleOfTheSecret() {
        let p = Redactor.preview(Fake.anthropic)
        XCTAssertTrue(p.hasPrefix("sk-ant-"))
        XCTAssertTrue(p.contains("…"))
        XCTAssertLessThanOrEqual(p.count, 16)
        XCTAssertFalse(p.contains(String(Fake.anthropic.dropFirst(12).prefix(12))))
        XCTAssertEqual(Redactor.preview("short"), "•••••")
    }

    func testFingerprintIsStablePerSaltAndDiffersAcrossSalts() {
        let a = Fingerprint.of(Fake.github, salt: Data([1, 2, 3]))
        XCTAssertEqual(a, Fingerprint.of(Fake.github, salt: Data([1, 2, 3])))
        XCTAssertNotEqual(a, Fingerprint.of(Fake.github, salt: Data([9])))
        XCTAssertFalse(a.contains(Fake.github))
    }

    // MARK: - Fast path over raw bytes (what the scanner uses on gigabytes of transcripts)

    func testByteScanFindsTheSameKeysWithLineNumbers() {
        let text = "{\"a\":1}\n" + #"{"content":"KEY="# + Fake.anthropic + #"\n"}"# + "\nplain line\n" + "token " + Fake.github + " and " + Fake.stripeLive + "\n"
        let result = detector.scan(Data(text.utf8))
        XCTAssertEqual(result.matches.map(\.value), [Fake.anthropic, Fake.github, Fake.stripeLive])
        XCTAssertEqual(result.matches.map(\.line), [2, 4, 4])
        XCTAssertEqual(result.newlines, 4)
        XCTAssertEqual(result.matches.map(\.value), detector.matches(in: text).map(\.value), "fast path and reference path must agree")
    }

    func testByteScanAgreesWithReferenceOnEveryFixture() {
        let all = [Fake.anthropic, Fake.openAIProject, Fake.openRouter, Fake.github, Fake.awsKeyID, Fake.stripeLive,
                   Fake.google, Fake.slack, Fake.postgresURL, Fake.xBearer, Fake.privateKeyHeader]
        let text = all.enumerated().map { "line \($0.offset): \"\($0.element)\" trailing words like task-list and risk-based" }.joined(separator: "\n")
        XCTAssertEqual(detector.scan(Data(text.utf8)).matches.map(\.value), detector.matches(in: text).map(\.value))
        XCTAssertEqual(detector.matches(in: text).count, all.count)
    }

    func testKeyLongerThanTheFirstWindowIsNotTruncated() {
        let long = "sk-" + "ant-" + String((0..<1500).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })
        let hits = detector.scan(Data(("x " + long + " y").utf8)).matches
        XCTAssertEqual(hits.map(\.value), [long])
    }

    func testPlaceholderKeysAreNotReported() {
        // The AWS line is Amazon's own documentation example, assembled so the literal is not in the repo.
        let text = """
        ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        OPENAI_API_KEY=sk-proj-0000000000000000000000000000000000000000000000
        AWS_ACCESS_KEY_ID=\("AK" + "IA")IOSFODNN7EXAMPLE
        """
        XCTAssertTrue(detector.matches(in: text).isEmpty)
        XCTAssertTrue(detector.scan(Data(text.utf8)).matches.isEmpty)
    }

    func testBase64ImageDataIsNotMistakenForAnXToken() {
        let blob = "data:image/png;base64,iVBORw0KGgo" + Fake.rep("A", 60) + Fake.rep("QUJDREVGR0hJSktMTU5PUA", 8)
        XCTAssertTrue(detector.scan(Data(blob.utf8)).matches.isEmpty)
        XCTAssertEqual(detector.identify(Fake.xBearer)?.service, "X (Twitter)")
    }

    // MARK: - Noise that a real machine is full of

    func testLocalAndPlaceholderDatabaseURLsAreIgnored() {
        let scheme = "postgres" + "://"
        let noisy = [
            scheme + "postgres:postgres@localhost:5432/dev",
            scheme + "user:password@127.0.0.1:5432/app",
            scheme + "app:devpassword123@db:5432/app",
            scheme + "user:password@host.example.com:5432/app",
            scheme + "USER:PASSWORD@HOST:5432/DATABASE",
            scheme + "admin:${DB_PASSWORD}@prod.internal.net:5432/app",
            scheme + "admin:<password>@prod.internal.net/app",
            "redis" + "://default:changeme@cache.internal.net:6379",
        ]
        for url in noisy {
            XCTAssertTrue(detector.matches(in: "DATABASE_URL=" + url).isEmpty, "should ignore \(url)")
        }
        XCTAssertEqual(detector.matches(in: "DATABASE_URL=" + Fake.postgresURL).map(\.rule.id), ["database-url"])
    }

    func testEnvAssignmentsSkipPublicKeysURLsAndPaths() {
        let secret = Fake.unknownProviderSecret
        let text = """
        STRIPE_PUBLISHABLE_KEY=\(secret)
        JWT_PUBLIC_KEY=\(secret)
        SERVICE_TOKEN_URL=https://auth.internal.net/oauth/token/issue
        GOOGLE_APPLICATION_CREDENTIALS=/Users/me/keys/service-account.json
        SSH_KEY_PATH=~/.ssh/id_ed25519_deploy
        SESSION_SECRET=\(secret)
        """
        XCTAssertEqual(detector.envAssignments(in: text).map(\.name), ["SESSION_SECRET"])
    }

    // MARK: - Filters must only skip on positive evidence of a placeholder

    func testRealDatabasePasswordsSurviveTheNoiseFilter() {
        let scheme = "postgres" + "://"
        let real = [
            scheme + "admin:" + Fake.noise(14, seed: 31) + "@prod-db:5432/app",                 // internal host without a dot
            scheme + "admin:" + "Zx$9" + Fake.noise(10, seed: 32) + "@db.internal.net/app",     // "$" inside a real password
            scheme + "svc:" + Fake.noise(12, seed: 33) + "@db.internal.net/app?contact=ops@corp.net",  // "@" later in the URL
            scheme + "admin:" + "MyPassword" + "Q7xK2m" + "@db.internal.net/app",
            scheme + "admin:" + "Secret#2024" + "@db.internal.net/app",                          // weak, but real and in use
            scheme + "admin:" + "password123" + "@db.internal.net/app", // contains the word, is not the word
        ]
        for url in real {
            XCTAssertEqual(detector.matches(in: "DATABASE_URL=" + url).map(\.rule.id), ["database-url"], "should report \(url.prefix(24))…")
        }
    }

    func testSecretsThatLookLikePathsOrSitUnderOddNamesAreStillFound() {
        let slashSecret = "/" + Fake.noise(20, seed: 35) + "/" + Fake.noise(20, seed: 36) + "+" + Fake.noise(6, seed: 37) + "=="
        let text = """
        SIGNING_SECRET=\(slashSecret)
        REPUBLIC_API_KEY=\(Fake.unknownProviderSecret)
        CALLBACK_SECRET_URL=https://hooks.internal.net/in?token=\(Fake.noise(32, seed: 38))
        """
        XCTAssertEqual(detector.envAssignments(in: text).map(\.name), ["SIGNING_SECRET", "REPUBLIC_API_KEY", "CALLBACK_SECRET_URL"])
    }

    func testWebhookURLsAreSecrets() {
        let slack = "https://hooks.slack" + ".com/services/T" + Fake.noise(9, seed: 39, alphabet: "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789")
            + "/B" + Fake.noise(10, seed: 40, alphabet: "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789") + "/" + Fake.noise(24, seed: 41)
        let discord = "https://discord" + ".com/api/webhooks/123456789012345678/" + Fake.noise(68, seed: 42)
        XCTAssertEqual(detector.matches(in: "notify: " + slack + "\nalso " + discord).map(\.rule.id), ["slack-webhook", "discord-webhook"])
        XCTAssertEqual(detector.scan(Data(("notify: " + slack + "\nalso " + discord).utf8)).matches.map(\.rule.id), ["slack-webhook", "discord-webhook"])
    }
}
