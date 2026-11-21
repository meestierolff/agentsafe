import CryptoKit
import XCTest
@testable import AgentSafeCore

/// Runs the real `agentsafe` binary, with this test standing in for the app.
final class CommandLineTests: XCTestCase {
    var home: URL!
    var project: URL!
    let password = "correct horse battery staple"

    override func setUp() {
        home = Fake.tempDir()
        project = home.appendingPathComponent("project")
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    var binary: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agentsafe-cli") }

    func makeVault(allow: Bool = true) throws -> Vault {
        let vault = try Vault.create(at: home.appendingPathComponent("safe.json"), password: password, kdfIterations: 1_000)
        let item = try vault.add(name: "OpenAI", value: Fake.openAIProject, service: "OpenAI", envName: "OPENAI_API_KEY")
        if allow { try vault.update(item.id) { $0.allowRun = true } }
        return vault
    }

    struct Outcome { let status: Int32; let out: String; let err: String }

    /// Starts the helper and answers its request the way the app would.
    func run(_ arguments: [String], respond: ((RunRequest) throws -> RunResponse)?) throws -> Outcome {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = project
        process.environment = ["AGENTSAFE_HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        if let respond {
            let requests = RunHandoff.requestsFolder(home: home)
            let deadline = Date().addingTimeInterval(10)
            var answered = false
            while !answered, Date() < deadline, process.isRunning {
                if let file = (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "json" }),
                   let request = try? RunHandoff.decoder.decode(RunRequest.self, from: Data(contentsOf: file)) {
                    // The app first says it has the request, then answers once the user decides.
                    try Data().write(to: RunHandoff.seenMarker(for: request.id, home: home))
                    Thread.sleep(forTimeInterval: 0.4)
                    let response = try respond(request)
                    let target = RunHandoff.responsesFolder(home: home).appendingPathComponent("\(request.id).json")
                    try SecureFile.write(try RunHandoff.encoder.encode(response), to: target)
                    answered = true
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            XCTAssertTrue(answered, "the helper never wrote a request")
        }
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus,
                       out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func leftovers() -> [String] {
        [RunHandoff.requestsFolder(home: home), RunHandoff.responsesFolder(home: home)].flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
    }

    func testApprovedCommandRunsWithTheKeyInItsEnvironment() throws {
        let vault = try makeVault()
        let result = try run(["run", "--keys", "OPENAI_API_KEY", "--", "/usr/bin/env"]) { request in
            XCTAssertEqual(request.command, ["/usr/bin/env"])
            XCTAssertEqual(request.directory, self.project.resolvingSymlinksInPath().path)
            return try RunHandoff.approve(request, plan: vault.resolve(request.references), vault: vault, using: .password(self.password))
        }
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("OPENAI_API_KEY=" + Fake.openAIProject))
        XCTAssertFalse(result.err.contains(Fake.openAIProject), "the helper itself never prints a key")
        XCTAssertTrue(result.err.contains("AgentSafe is asking for your approval"), result.err)
        XCTAssertEqual(leftovers(), [], "request and reply files are removed afterwards")
    }

    func testTheProjectsKeyListIsUsedWhenNoKeysAreNamed() throws {
        let vault = try makeVault()
        try "# what this project needs\nOPENAI_API_KEY\n".write(to: project.appendingPathComponent("agentsafe.keys"), atomically: true, encoding: .utf8)
        let nested = project.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let result = try run(["run", "--", "/bin/sh", "-c", "echo got-${#OPENAI_API_KEY}-chars"]) { request in
            XCTAssertEqual(request.names, ["OPENAI_API_KEY"])
            return try RunHandoff.approve(request, plan: vault.resolve(request.references), vault: vault, using: .password(self.password))
        }
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), "got-\(Fake.openAIProject.count)-chars")
    }

    func testDeniedRequestDoesNotRunTheCommand() throws {
        let marker = home.appendingPathComponent("ran.txt")
        let result = try run(["run", "--keys", "OPENAI_API_KEY", "--", "/usr/bin/touch", marker.path]) { request in
            RunHandoff.deny(request, message: "Denied in AgentSafe.")
        }
        XCTAssertEqual(result.status, 4)
        XCTAssertTrue(result.err.contains("Denied in AgentSafe."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(leftovers(), [])
    }

    func testGivesUpWithAClearMessageWhenTheAppNeverAnswers() throws {
        let result = try run(["run", "--keys", "OPENAI_API_KEY", "--timeout", "1", "--", "/usr/bin/true"], respond: nil)
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.err.contains("AgentSafe did not answer"), result.err)
        XCTAssertEqual(leftovers(), [], "an unanswered request is withdrawn")
    }

    func testUsageErrorsNeverReachTheApp() throws {
        for arguments in [["run"], ["run", "--keys", "A"], ["run", "--", "/usr/bin/true"], ["run", "--keys", "PATH", "--", "/usr/bin/true"], ["nonsense"]] {
            let result = try run(arguments, respond: nil)
            XCTAssertEqual(result.status, 2, arguments.joined(separator: " "))
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testInitListsSecretVariableNamesFromAnEnvFileWithoutItsValues() throws {
        try ("PORT=3000\nOPENAI_API_KEY=" + Fake.openAIProject + "\nNEXT_PUBLIC_URL=https://example.org\nSESSION_SECRET=" + Fake.unknownProviderSecret + "\nDATABASE_URL=" + Fake.postgresURL + "\n")
            .write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let result = try run(["init"], respond: nil)
        XCTAssertEqual(result.status, 0, result.err)
        let written = try String(contentsOf: project.appendingPathComponent("agentsafe.keys"), encoding: .utf8)
        XCTAssertEqual(RunHandoff.parseKeyList(written).map(\.envName), ["OPENAI_API_KEY", "SESSION_SECRET", "DATABASE_URL"])
        for text in [written, result.out, result.err] {
            XCTAssertFalse(text.contains(Fake.openAIProject))
            XCTAssertFalse(text.contains(Fake.unknownProviderSecret))
            XCTAssertFalse(text.contains(Fake.postgresURL))
        }
        // Running it again must not clobber a list someone has edited.
        XCTAssertEqual(try run(["init"], respond: nil).status, 2)
    }
}
