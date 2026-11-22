import XCTest
@testable import AgentSafeCore

final class GitHistoryTests: XCTestCase {
    let salt = Data([1])
    func print(_ value: String) -> String { Fingerprint.of(value, salt: salt) }

    func scan(_ repo: URL, emails: Set<String> = ["me@example.com"], maxVersionBytes: Int = 50_000_000) throws -> GitRepositoryScan {
        let location = try XCTUnwrap(GitRepositoryLocator.resolve(dotGit: repo.appendingPathComponent(".git")))
        let history = GitHistoryScanner(scanner: SecretScanner(fingerprint: { Fingerprint.of($0, salt: self.salt) }), maxVersionBytes: maxVersionBytes)
        return try XCTUnwrap(history.scan(location, userEmails: emails, now: Date(), isCancelled: { false }))
    }

    func finding(_ scan: GitRepositoryScan, _ value: String) -> Finding? { scan.findings.first { $0.fingerprint == print(value) } }

    /// Pushes `main` to a bare repository on disk, then points `origin` at GitHub, so the
    /// remote-tracking refs exist and the remote reads as a real host.
    func pushToGitHub(_ fx: GitFixture, _ repo: URL, keepLocalURL: Bool = false) throws {
        let remote = fx.root.appendingPathComponent("remote-\(repo.lastPathComponent).git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        fx.git("init", "-q", "--bare", in: remote)
        fx.git("remote", "add", "origin", remote.path, in: repo)
        fx.git("push", "-q", "-u", "origin", "main", in: repo)
        if !keepLocalURL { fx.git("remote", "set-url", "origin", "git@github.com:me/app.git", in: repo) }
    }

    func env(_ key: String) -> String { "STRIPE_SECRET_KEY=\(key)\n" }

    func testFindsKeyInDeletedEnvFile() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([".env": env(Fake.stripeLive), "README.md": "app\n"], message: "add env", in: a)
        fx.commit([".env": nil], message: "remove env", in: a)
        let result = try scan(a)
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.findings.count, 1)
        let f = try XCTUnwrap(finding(result, Fake.stripeLive))
        XCTAssertEqual(f.kind, .gitHistory)
        XCTAssertEqual(f.sourceLabel, "Git history")
        XCTAssertEqual(f.git?.pathInRepository, ".env")
        XCTAssertEqual(f.git?.inHead, false)
        XCTAssertEqual(f.git?.repository, a.canonical.path)
        XCTAssertEqual(f.path, "git:\(a.appendingPathComponent(".git").canonical.path):.env")
    }

    func testPushedBranchIsPushedAndLocalBranchIsNot() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([".env": env(Fake.stripeLive)], message: "pushed", in: a)
        try pushToGitHub(fx, a)
        fx.git("checkout", "-q", "-b", "local", in: a)
        fx.commit([".env.local": "ANTHROPIC_API_KEY=\(Fake.anthropic)\n"], message: "local only", in: a)
        let result = try scan(a)
        XCTAssertEqual(finding(result, Fake.stripeLive)?.git?.pushedTo, "github.com/me/app")
        XCTAssertNotNil(finding(result, Fake.anthropic))
        XCTAssertNil(finding(result, Fake.anthropic)?.git?.pushedTo)
    }

    func testForcePushedKeyStillCountsAsPushed() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit(["a.txt": "1\n"], message: "one", in: a)
        fx.commit([".env": env(Fake.stripeLive)], message: "oops", in: a)
        try pushToGitHub(fx, a, keepLocalURL: true)
        fx.git("reset", "-q", "--hard", "HEAD~1", in: a)
        fx.git("push", "-q", "--force", "origin", "main", in: a)
        fx.git("remote", "set-url", "origin", "git@github.com:me/app.git", in: a)
        XCTAssertEqual(finding(try scan(a), Fake.stripeLive)?.git?.pushedTo, "github.com/me/app")
    }

    func testRemoteThatIsAFolderOnThisMacIsNotPushed() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([".env": env(Fake.stripeLive)], message: "pushed to a folder", in: a)
        try pushToGitHub(fx, a, keepLocalURL: true)
        let f = try XCTUnwrap(finding(try scan(a), Fake.stripeLive))
        XCTAssertNil(f.git?.pushedTo)
    }

    func testStillCommittedFileIsInHead() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([".env": env(Fake.stripeLive)], message: "add env", in: a)
        XCTAssertEqual(finding(try scan(a), Fake.stripeLive)?.git?.inHead, true)
    }

    func testCommittedByUserComesFromAuthorEmail() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let theirs = fx.makeRepository("theirs")
        fx.commit([".env": env(Fake.stripeLive)], message: "upstream", in: theirs, author: "other@example.com", committer: "other@example.com")
        XCTAssertEqual(finding(try scan(theirs), Fake.stripeLive)?.git?.committedByUser, false)
        let mine = fx.makeRepository("mine")
        fx.commit([".env": env(Fake.stripeLive)], message: "mine", in: mine, author: "Me@Example.com")
        XCTAssertEqual(finding(try scan(mine), Fake.stripeLive)?.git?.committedByUser, true)
    }

    func testKeyInShellHistoryAndMcpConfigIsFound() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([
            ".zsh_history": ": 1700000000:0;export ANTHROPIC_API_KEY=\(Fake.anthropic)\n",
            ".cursor/mcp.json": #"{"mcpServers":{"gh":{"env":{"GITHUB_TOKEN":""# + Fake.github + #""}}}}"#,
            "src/config.ts": "export const key = \"\(Fake.openAIProject)\"\n",
        ], message: "dotfiles", in: a)
        let result = try scan(a)
        XCTAssertEqual(Set(result.findings.compactMap(\.git?.pathInRepository)), [".zsh_history", ".cursor/mcp.json"])
        XCTAssertNil(finding(result, Fake.openAIProject), "source files are not part of the history scan")
    }

    func testSkipsNodeModulesAndTooLargeVersions() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        let padding = String(repeating: "# filler line\n", count: 150)
        fx.commit(["node_modules/x/.env": env(Fake.stripeLive), ".env": padding + "ANTHROPIC_API_KEY=\(Fake.anthropic)\n"], message: "c", in: a)
        let normal = try scan(a)
        XCTAssertEqual(normal.findings.compactMap(\.git?.pathInRepository), [".env"])
        let small = try scan(a, maxVersionBytes: 1_000)
        XCTAssertTrue(small.findings.isEmpty)
        XCTAssertEqual(small.versionsTooLarge, 1)
    }

    func testSHA256RepositoryIsUnreadable() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let b = fx.root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        fx.git("init", "-q", "--object-format=sha256", in: b)
        XCTAssertEqual(try scan(b).outcome, .unreadable("sha256"))
    }

    func testShallowCloneIsReadAsFarAsItGoes() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let source = fx.makeRepository("source")
        fx.commit([".env": "ANTHROPIC_API_KEY=\(Fake.anthropic)\n"], message: "old key", in: source)
        fx.commit([".env": env(Fake.stripeLive)], message: "new key", in: source)
        fx.git("clone", "-q", "--depth", "1", "file://" + source.path, fx.root.appendingPathComponent("shallow").path, in: fx.root)
        let result = try scan(fx.root.appendingPathComponent("shallow"))
        XCTAssertEqual(result.outcome, .complete)
        XCTAssertNotNil(finding(result, Fake.stripeLive))
        XCTAssertNil(finding(result, Fake.anthropic))
    }

    func testDisplayRemote() {
        XCTAssertEqual(GitHistoryScanner.displayRemote("git@github.com:me/app.git"), "github.com/me/app")
        XCTAssertEqual(GitHistoryScanner.displayRemote("https://me:ghp_x@github.com/me/app.git"), "github.com/me/app")
        XCTAssertEqual(GitHistoryScanner.displayRemote("ssh://git@gitlab.com:22/a/b.git"), "gitlab.com/a/b")
        XCTAssertEqual(GitHistoryScanner.displayRemote("me:ghp_secret@github.com:me/app.git"), "github.com/me/app")
        XCTAssertEqual(GitHistoryScanner.displayRemote("https://github.com/me/app"), "github.com/me/app")
        XCTAssertNil(GitHistoryScanner.displayRemote("/Users/me/remote.git"))
        XCTAssertNil(GitHistoryScanner.displayRemote("file:///tmp/r"))
    }

    func testUnreadableRefsAreNotReportedClean() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([".env": env(Fake.stripeLive)], message: "add env", in: a)
        try "not a ref\n".write(to: a.appendingPathComponent(".git/refs/heads/main"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try scan(a).outcome, .partlyRead("refs could not be read"))
    }

    func testDeepeningAShallowCloneChangesTheTipsHash() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let source = fx.makeRepository("source")
        fx.commit(["a.txt": "1\n"], message: "one", in: source)
        fx.commit(["a.txt": "2\n"], message: "two", in: source)
        let shallow = fx.root.appendingPathComponent("shallow")
        fx.git("clone", "-q", "--depth", "1", "file://" + source.path, shallow.path, in: fx.root)
        let location = try XCTUnwrap(GitRepositoryLocator.resolve(dotGit: shallow.appendingPathComponent(".git")))
        let before = GitHistoryScanner.tipsHash(location)
        fx.git("fetch", "-q", "--unshallow", in: shallow)
        XCTAssertNotEqual(GitHistoryScanner.tipsHash(location), before)
    }

    func testPushURLCountsAsPushed() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([".env": env(Fake.stripeLive)], message: "pushed", in: a)
        try pushToGitHub(fx, a, keepLocalURL: true)
        fx.git("remote", "set-url", "--push", "origin", "git@github.com:me/app.git", in: a)
        XCTAssertEqual(finding(try scan(a), Fake.stripeLive)?.git?.pushedTo, "github.com/me/app")
    }

    func testKeyFileNamesMatchTheLiveScan() {
        for path in [".claude.json", "dot/.codeium/windsurf/mcp_config.json", ".claude/projects/-Users-me/abc.jsonl",
                     ".codex/sessions/2026/11/rollout.jsonl", ".claude/history.jsonl", ".codex/history.jsonl"] {
            XCTAssertNotNil(SourceCatalog.gitKeyFileGroup(forPath: path), path)
        }
        for path in ["src/settings.json", "data/rows.jsonl", "mcp_config.json", "docs/.env.example"] {
            XCTAssertNil(SourceCatalog.gitKeyFileGroup(forPath: path), path)
        }
    }

    // MARK: - Review fixes

    func writeLoose(_ git: URL, _ hex: String, _ type: String, _ body: Data) throws {
        let full = Data("\(type) \(body.count)\0".utf8) + body
        let deflated = try (full as NSData).compressed(using: .zlib) as Data
        let dir = git.appendingPathComponent("objects/\(hex.prefix(2))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (Data([0x78, 0x9C]) + deflated).write(to: dir.appendingPathComponent(String(hex.dropFirst(2))))
    }

    func testTreeThatContainsItselfDoesNotHang() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        let git = a.appendingPathComponent(".git")
        // Object IDs are not verified, so a damaged repository can hold a tree listing itself.
        let tree = String(repeating: "ab", count: 20), commit = String(repeating: "cd", count: 20)
        var body = Data("40000 loop\0".utf8)
        body.append(contentsOf: stride(from: 0, to: 40, by: 2).map { UInt8(tree.dropFirst($0).prefix(2), radix: 16)! })
        try writeLoose(git, tree, "tree", body)
        try writeLoose(git, commit, "commit", Data("tree \(tree)\nauthor A <a@b> 0 +0000\ncommitter A <a@b> 0 +0000\n\nloop\n".utf8))
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try (commit + "\n").write(to: git.appendingPathComponent("refs/heads/main"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try scan(a).outcome, .partlyRead("damaged (tree too deep)"))
    }

    func testMissingBranchTipIsNotReportedClean() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit([".env": env(Fake.stripeLive)], message: "add env", in: a)
        let head = fx.head(a)
        try FileManager.default.removeItem(at: a.appendingPathComponent(".git/objects/\(head.prefix(2))/\(head.dropFirst(2))"))
        XCTAssertEqual(try scan(a).outcome, .partlyRead("missing objects"))
    }

    func testSharedCloneWithoutItsAlternateIsNotClean() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let source = fx.makeRepository("source")
        fx.commit([".env": env(Fake.stripeLive)], message: "add env", in: source)
        let clone = fx.root.appendingPathComponent("clone")
        fx.git("clone", "-q", "--shared", source.path, clone.path, in: fx.root)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try scan(clone).outcome, .partlyRead("alternates could not be read"))
    }

    func testMergingSomeoneElsesBranchDoesNotMakeTheirKeyYours() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit(["README.md": "app\n"], message: "start", in: a)
        fx.git("checkout", "-q", "-b", "upstream", in: a)
        fx.commit(["examples/.env": env(Fake.stripeLive)], message: "sample", in: a, author: "other@example.com", committer: "other@example.com")
        fx.git("checkout", "-q", "main", in: a)
        fx.commit(["notes.md": "mine\n"], message: "mine", in: a)
        fx.git("merge", "-q", "--no-ff", "upstream", "-m", "merge upstream", in: a)
        XCTAssertEqual(finding(try scan(a), Fake.stripeLive)?.git?.committedByUser, false)
    }

    func testUserEmailsFollowIncludes() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let config = "[user]\n\temail = me@example.com\n[includeIf \"gitdir:~/work/\"]\n\tpath = ~/.gitconfig-work\n[include]\n\tpath = .gitconfig-extra\n"
        try config.write(to: fx.home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        try "[user]\n\temail = Me@Work.example\n".write(to: fx.home.appendingPathComponent(".gitconfig-work"), atomically: true, encoding: .utf8)
        try "[user]\n\temail = side@example.org\n".write(to: fx.home.appendingPathComponent(".gitconfig-extra"), atomically: true, encoding: .utf8)
        let a = fx.makeRepository("a")
        let location = try XCTUnwrap(GitRepositoryLocator.resolve(dotGit: a.appendingPathComponent(".git")))
        XCTAssertEqual(GitHistoryScanner.userEmails(home: fx.home, location: location), ["me@example.com", "me@work.example", "side@example.org"])
    }

    func testTipsHashChangesAfterCommitAndFetch() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit(["a.txt": "1\n"], message: "one", in: a)
        let location = try XCTUnwrap(GitRepositoryLocator.resolve(dotGit: a.appendingPathComponent(".git")))
        let first = try XCTUnwrap(GitHistoryScanner.tipsHash(location))
        XCTAssertEqual(GitHistoryScanner.tipsHash(location), first)
        fx.commit(["a.txt": "2\n"], message: "two", in: a)
        XCTAssertNotEqual(GitHistoryScanner.tipsHash(location), first)
    }

    func testUserEmailsComeFromGlobalAndRepositoryConfig() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        try "[user]\n\tname = Me\n\temail = Me@Example.com\n".write(to: fx.home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let a = fx.makeRepository("a")
        fx.git("config", "user.email", "work@corp.example", in: a)
        let location = try XCTUnwrap(GitRepositoryLocator.resolve(dotGit: a.appendingPathComponent(".git")))
        XCTAssertEqual(GitHistoryScanner.userEmails(home: fx.home, location: location), ["me@example.com", "work@corp.example"])
    }
}
