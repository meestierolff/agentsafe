import XCTest
@testable import AgentSafeCore

final class GitLocatorTests: XCTestCase {
    func repositories(home: URL) -> [GitRepositoryLocation] {
        let scanner = SecretScanner(fingerprint: { $0 })
        let projects = SourceCatalog.standard(home: home).first { $0.id == "projects" }!
        return scanner.filesAndRepositories(for: projects).repositories
    }

    func testFindsRepositoriesDuringTheProjectWalk() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let projects = fx.home.appendingPathComponent("projects")
        let a = fx.makeRepository("a", at: projects)
        _ = fx.makeRepository("x", at: a.appendingPathComponent("node_modules"))
        let found = repositories(home: fx.home)
        XCTAssertEqual(found.map(\.workingDirectory), [a.canonical])
        XCTAssertEqual(found.first?.commonDirectory, a.appendingPathComponent(".git").canonical)
    }

    func testHomeItselfCanBeARepository() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        fx.git("init", "-q", in: fx.home)
        XCTAssertEqual(repositories(home: fx.home).map(\.workingDirectory), [fx.home.canonical])
    }

    func testWorktreeSharesItsCommonDirectory() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        fx.commit(["a.txt": "1\n"], message: "one", in: a)
        fx.git("worktree", "add", "-q", fx.root.appendingPathComponent("wt").path, in: a)
        let location = try XCTUnwrap(GitRepositoryLocator.resolve(dotGit: fx.root.appendingPathComponent("wt/.git")))
        XCTAssertEqual(location.commonDirectory, a.appendingPathComponent(".git").canonical)
        XCTAssertEqual(location.workingDirectory, fx.root.appendingPathComponent("wt").canonical)
        XCTAssertNotEqual(location.gitDirectory, location.commonDirectory)
    }

    func testSubmoduleGitFileIsFollowed() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let lib = fx.makeRepository("lib")
        fx.commit(["lib.txt": "1\n"], message: "lib", in: lib)
        let a = fx.makeRepository("a")
        fx.commit(["a.txt": "1\n"], message: "one", in: a)
        fx.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", lib.path, "sub", in: a)
        let location = try XCTUnwrap(GitRepositoryLocator.resolve(dotGit: a.appendingPathComponent("sub/.git")))
        XCTAssertTrue(location.commonDirectory.path.hasPrefix(a.appendingPathComponent(".git/modules").canonical.path), location.commonDirectory.path)
    }

    func testOversizedGitFileIsNotRead() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let a = fx.makeRepository("a")
        let wt = fx.root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        // A pointer file is a single short line. One padded to megabytes is not read at all.
        let padding = String(repeating: "#", count: 2_000_000) + "\n"
        try (padding + "gitdir: " + a.appendingPathComponent(".git").path + "\n").write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNil(GitRepositoryLocator.resolve(dotGit: wt.appendingPathComponent(".git")))
        try ("gitdir: " + a.appendingPathComponent(".git").path + "\n").write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(GitRepositoryLocator.resolve(dotGit: wt.appendingPathComponent(".git")))
    }

    func testFindsBareDotfilesRepositoryAndDotConfigRepository() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let cfg = fx.home.appendingPathComponent(".cfg")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        fx.git("init", "-q", "--bare", in: cfg)
        let nvim = fx.makeRepository("nvim", at: fx.home.appendingPathComponent(".config"))
        let found = GitRepositoryLocator.dotfilesCandidates(home: fx.home)
        XCTAssertTrue(found.contains { $0.commonDirectory == cfg.canonical && $0.workingDirectory == nil })
        XCTAssertTrue(found.contains { $0.workingDirectory == nvim.canonical })
        XCTAssertTrue(repositories(home: fx.home).isEmpty, "the project walk itself still skips hidden folders")
    }
}
