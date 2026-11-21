import XCTest
@testable import AgentSafeCore

final class ScannerTests: XCTestCase {
    var home: URL!
    let salt = Data([7, 7, 7])
    lazy var scanner = SecretScanner(fingerprint: { Fingerprint.of($0, salt: self.salt) })

    override func setUp() { home = Fake.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func write(_ relative: String, _ text: String) -> URL {
        let url = home.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func transcriptLine(_ secret: String) -> String {
        #"{"type":"tool_result","content":"read .env -> KEY="# + secret + #"\n"}"#
    }

    func testFindsKeyInClaudeTranscriptWithLineNumberAndNoPlaintext() throws {
        write(".claude/projects/-Users-me-app/s1.jsonl", "{\"type\":\"user\"}\n" + transcriptLine(Fake.anthropic) + "\n")
        let findings = scanner.scanAll(SourceCatalog.standard(home: home))
        XCTAssertEqual(findings.count, 1)
        let f = try XCTUnwrap(findings.first)
        XCTAssertEqual(f.service, "Anthropic")
        XCTAssertEqual(f.line, 2)
        XCTAssertEqual(f.kind, .agentTranscript)
        XCTAssertEqual(f.preview, Redactor.preview(Fake.anthropic))
        let stored = String(data: try JSONEncoder().encode(findings), encoding: .utf8)!
        XCTAssertFalse(stored.contains(Fake.anthropic), "a finding must never carry the secret itself")
    }

    func testRepeatedKeyInOneFileIsOneFindingWithACount() {
        write(".codex/sessions/2026/a.jsonl", [transcriptLine(Fake.github), transcriptLine(Fake.github), transcriptLine(Fake.github)].joined(separator: "\n"))
        let findings = scanner.scanAll(SourceCatalog.standard(home: home))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.count, 3)
        XCTAssertEqual(findings.first?.line, 1)
    }

    func testFindsSecretsAcrossEverySourceKind() {
        write(".claude/projects/p/s.jsonl", transcriptLine(Fake.anthropic))
        write(".claude.json", #"{"mcpServers":{"x":{"env":{"GITHUB_TOKEN":""# + Fake.github + #""}}}}"#)
        write(".zsh_history", ": 1700000000:0;curl -H 'Authorization: Bearer " + Fake.openAIProject + "' https://api.example.com\n")
        write("projects/shop/.env", "STRIPE_SECRET_KEY=" + Fake.stripeLive + "\nSCRAPER_API_KEY=" + Fake.unknownProviderSecret + "\nPORT=3000\n")
        write("projects/shop/.claude/settings.local.json", #"{"permissions":{"allow":["Bash(PGPASSWORD=x psql "# + Fake.postgresURL + #")"]}}"#)
        let findings = scanner.scanAll(SourceCatalog.standard(home: home))
        XCTAssertEqual(Set(findings.map(\.kind)), [.agentTranscript, .agentConfig, .shellHistory, .envFile])
        XCTAssertEqual(findings.count, 6)
        XCTAssertEqual(findings.first { $0.service == "API key" && $0.kind == .envFile }?.name, "SCRAPER_API_KEY")
    }

    func testSkipsExampleEnvFilesAndDependencyFolders() {
        write("projects/shop/.env.example", "STRIPE_SECRET_KEY=" + Fake.stripeLive + "\n")
        write("projects/shop/node_modules/pkg/.env", "STRIPE_SECRET_KEY=" + Fake.stripeLive + "\n")
        write("Library/Caches/thing/.env", "STRIPE_SECRET_KEY=" + Fake.stripeLive + "\n")
        XCTAssertTrue(scanner.scanAll(SourceCatalog.standard(home: home)).isEmpty)
    }

    func testFindsKeySplitAcrossReadChunks() throws {
        // A long single line forces the reader to stitch chunks together.
        let padding = String(repeating: ".", count: 70_000)  // not a letter: a key must not be glued to a word
        let url = write(".claude/projects/p/big.jsonl", padding + Fake.slack + padding + "\n" + transcriptLine(Fake.google))
        let small = SecretScanner(fingerprint: { Fingerprint.of($0, salt: self.salt) }, chunkSize: 4_096)
        let result = try small.scan(file: url, source: SourceCatalog.standard(home: home)[0])
        XCTAssertEqual(Set(result.findings.map(\.service)), ["Slack", "Google"])
        XCTAssertEqual(result.findings.first { $0.service == "Google" }?.line, 2)
    }

    func testIncrementalScanOnlyReadsAppendedBytes() throws {
        let url = write(".claude/projects/p/live.jsonl", transcriptLine(Fake.anthropic) + "\n")
        let source = SourceCatalog.standard(home: home)[0]
        let first = try scanner.scan(file: url, source: source)
        XCTAssertEqual(first.findings.count, 1)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write((transcriptLine(Fake.github) + "\n").data(using: .utf8)!)
        try handle.close()
        let second = try scanner.scan(file: url, source: source, fromOffset: first.endOffset, startLine: first.endLine)
        XCTAssertEqual(second.findings.map(\.service), ["GitHub"])
        XCTAssertEqual(second.findings.first?.line, 2)
    }

    func testFindingStoreKeepsStatusAcrossRescansAndDropsFixedOnes() throws {
        let url = write(".claude/projects/p/s.jsonl", transcriptLine(Fake.anthropic) + "\n" + transcriptLine(Fake.github))
        let sources = SourceCatalog.standard(home: home)
        let store = FindingStore(url: home.appendingPathComponent("findings.json"))
        store.replaceAll(with: scanner.scanAll(sources))
        let anthropic = try XCTUnwrap(store.findings.first { $0.service == "Anthropic" })
        store.setStatus(.rotated, for: anthropic.id)
        try transcriptLine(Fake.anthropic).write(to: url, atomically: true, encoding: .utf8)
        store.replaceAll(with: scanner.scanAll(sources))
        XCTAssertEqual(store.findings.map(\.service), ["Anthropic"])
        XCTAssertEqual(store.findings.first?.status, .rotated)
        XCTAssertEqual(FindingStore(url: home.appendingPathComponent("findings.json")).findings.count, 1)
        XCTAssertEqual(store.openCount, 0)
    }

    // MARK: - Scrubbing

    func testScrubReplacesOnlyTheTargetKeyAndKeepsJSONValid() throws {
        let url = write(".claude/projects/p/s.jsonl", transcriptLine(Fake.anthropic) + "\n" + transcriptLine(Fake.github) + "\n")
        let finding = try XCTUnwrap(scanner.scanAll(SourceCatalog.standard(home: home)).first { $0.service == "Anthropic" })
        let old = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let replaced = try Scrubber(scanner: scanner).scrub(finding)
        XCTAssertEqual(replaced, 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(Fake.anthropic))
        XCTAssertTrue(text.contains(Fake.github))
        XCTAssertTrue(text.contains(Redactor.placeholder))
        for line in text.split(separator: "\n") {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testScrubRefusesFilesAnAgentMayStillBeWriting() throws {
        write(".claude/projects/p/s.jsonl", transcriptLine(Fake.anthropic) + "\n")
        let finding = try XCTUnwrap(scanner.scanAll(SourceCatalog.standard(home: home)).first)
        XCTAssertThrowsError(try Scrubber(scanner: scanner).scrub(finding)) { error in
            XCTAssertEqual(error as? ScrubError, .recentlyModified)
        }
    }

    func testScrubRefusesDatabases() throws {
        let url = write("Library/Application Support/Cursor/User/globalStorage/state.vscdb", "SQLite format 3\u{0}" + Fake.github)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: url.path)
        let finding = try XCTUnwrap(scanner.scanAll(SourceCatalog.standard(home: home)).first)
        XCTAssertEqual(finding.canScrub, false)
        XCTAssertThrowsError(try Scrubber(scanner: scanner).scrub(finding)) { error in
            XCTAssertEqual(error as? ScrubError, .unsupportedFile)
        }
    }

    func testOnlyCopiesThatShouldNotExistCountAsLeaks() {
        // A key in a transcript, a shell history or an agent config is a leak.
        // A key in a .env file is where developers keep keys: exposed, but not leaked.
        XCTAssertEqual(SourceKind.allCases.filter(\.isLeak), [.agentTranscript, .agentConfig, .shellHistory])
    }
}
