import XCTest
@testable import AgentSafeCore

final class GitRepositoryTests: XCTestCase {
    func open(_ repo: URL) throws -> GitRepository {
        let dotGit = repo.appendingPathComponent(".git")
        return try GitRepository(gitDirectory: dotGit, commonDirectory: dotGit)
    }

    /// Every object git lists must come back byte for byte as `git cat-file` prints it.
    func assertEveryObjectMatchesGit(_ fx: GitFixture, _ repo: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let reader = try open(repo)
        let ids = fx.git("rev-list", "--objects", "--all", in: repo).split(separator: "\n").map { String($0.prefix(40)) }
        XCTAssertFalse(ids.isEmpty, file: file, line: line)
        for hex in ids {
            let type = fx.git("cat-file", "-t", hex, in: repo)
            let expected = fx.gitData("cat-file", type, hex, in: repo)
            let id = try XCTUnwrap(GitObjectID(hex: hex), file: file, line: line)
            let object = try reader.object(id)
            XCTAssertEqual("\(object.kind)", type, file: file, line: line)
            XCTAssertEqual(object.data, expected, "object \(hex)", file: file, line: line)
            XCTAssertEqual(try reader.objectSize(id), expected.count, file: file, line: line)
            XCTAssertEqual(id.hex, hex, file: file, line: line)
        }
    }

    /// A 20 KB text file committed six times, one line changed each time, so packing
    /// stores most versions as deltas of each other.
    func commitGrowingHistory(_ fx: GitFixture, _ repo: URL) {
        var lines = (0..<400).map { "line \($0) " + Fake.noise(40, seed: UInt64($0)) }
        for round in 0..<6 {
            lines[round * 50] = "changed in round \(round) " + Fake.noise(30, seed: UInt64(1000 + round))
            fx.commit(["big.txt": lines.joined(separator: "\n"), ".env": "ROUND=\(round)\n"], message: "round \(round)", in: repo)
        }
    }

    func testLooseObjectsMatchGitCatFile() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = fx.makeRepository("a")
        fx.commit([".env": "KEY=1\n", "src/README.md": "hi\n"], message: "one", in: repo)
        fx.commit([".env": "KEY=2\n", "empty.txt": ""], message: "two", in: repo)
        try assertEveryObjectMatchesGit(fx, repo)
    }

    func testPackedObjectsWithDeltaChainsMatchGitCatFile() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = fx.makeRepository("a")
        commitGrowingHistory(fx, repo)
        fx.git("gc", "-q", "--aggressive", in: repo)
        fx.git("prune", in: repo)
        XCTAssertTrue(fx.git("count-objects", "-v", in: repo).contains("count: 0"), "everything should be packed")
        let packDir = repo.appendingPathComponent(".git/objects/pack")
        let index = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: packDir.path).first { $0.hasSuffix(".idx") })
        let verify = fx.git("verify-pack", "-v", packDir.appendingPathComponent(index).path, in: repo)
        XCTAssertNotNil(verify.range(of: #"chain length = ([2-9]|\d\d+)"#, options: .regularExpression), "expected a delta chain")
        try assertEveryObjectMatchesGit(fx, repo)
    }

    func testRefDeltaPackMatchesGitCatFile() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = fx.makeRepository("a")
        commitGrowingHistory(fx, repo)
        // Without offset deltas, every delta names its base by object ID.
        fx.git("-c", "repack.useDeltaBaseOffset=false", "repack", "-q", "-a", "-d", "-f", in: repo)
        fx.git("prune", in: repo)
        try assertEveryObjectMatchesGit(fx, repo)
    }

    func testRefsReadFromPackedRefsAndLooseRefs() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = fx.makeRepository("a")
        fx.commit(["a.txt": "1\n"], message: "one", in: repo)
        fx.git("tag", "-a", "v1", "-m", "release", in: repo)
        fx.git("branch", "feature", in: repo)
        fx.git("pack-refs", "--all", in: repo)
        fx.commit(["a.txt": "2\n"], message: "two", in: repo)
        fx.git("branch", "late", in: repo)
        let reader = try open(repo)
        let refs = Dictionary(try reader.refs().map { ($0.name, $0.id.hex) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(refs["HEAD"], fx.head(repo))
        XCTAssertEqual(refs["refs/heads/main"], fx.head(repo), "the loose ref wins over the packed one")
        XCTAssertEqual(refs["refs/heads/late"], fx.head(repo))
        XCTAssertEqual(refs["refs/heads/feature"], fx.git("rev-parse", "feature", in: repo))
        let tag = try XCTUnwrap(refs["refs/tags/v1"].flatMap(GitObjectID.init(hex:)))
        XCTAssertEqual(tag.hex, fx.git("rev-parse", "v1", in: repo), "the tag object itself")
        let tagged = try XCTUnwrap(GitObjectID(hex: fx.git("rev-parse", "v1^{commit}", in: repo)))
        XCTAssertEqual(try reader.commit(tag).tree, try reader.commit(tagged).tree)
    }

    func testRejectsSHA256Repository() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = fx.root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        fx.git("init", "-q", "--object-format=sha256", in: repo)
        XCTAssertThrowsError(try open(repo)) { XCTAssertEqual($0 as? GitReadError, .unsupported("sha256")) }
    }

    func testRemoteReflogKeepsForcePushedCommit() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let remote = fx.root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        fx.git("init", "-q", "--bare", in: remote)
        let repo = fx.makeRepository("a")
        fx.commit(["a.txt": "1\n"], message: "one", in: repo)
        fx.commit([".env": "KEY=pushed\n"], message: "two", in: repo)
        let pushed = fx.head(repo)
        fx.git("remote", "add", "origin", remote.path, in: repo)
        fx.git("push", "-q", "-u", "origin", "main", in: repo)
        fx.git("reset", "-q", "--hard", "HEAD~1", in: repo)
        fx.git("push", "-q", "--force", "origin", "main", in: repo)
        let reader = try open(repo)
        let remoteTips = try reader.refs().filter { $0.name.hasPrefix("refs/remotes/") }.map(\.id.hex)
        XCTAssertFalse(remoteTips.contains(pushed), "the remote branch no longer has it")
        XCTAssertTrue(reader.reflogOldValues(underRefPrefix: "refs/remotes").map(\.hex).contains(pushed))
        XCTAssertEqual(reader.remoteURLs()["origin"], remote.path)
    }

    // MARK: - Malformed files: a damaged or crafted .git must make the reader throw, never crash.

    /// A pack with one entry at offset 12 whose header bytes are `header`, and a matching index.
    func craftedPack(header: [UInt8], fanoutOverride: (index: Int, value: UInt32)? = nil) throws -> (pack: URL, index: URL) {
        let dir = Fake.tempDir()
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let pack = Array("PACK".utf8) + be32(2) + be32(1) + header + [UInt8](repeating: 0x78, count: 30) + [UInt8](repeating: 0, count: 20)
        var fanout = [UInt32](repeating: 1, count: 256)
        if let o = fanoutOverride { fanout[o.index] = o.value }
        let index = [0xFF, 0x74, 0x4F, 0x63] + be32(2) + fanout.flatMap(be32) + [UInt8](repeating: 0, count: 20) + be32(0) + be32(12)
            + [UInt8](repeating: 0, count: 40)
        let packURL = dir.appendingPathComponent("p.pack"), indexURL = dir.appendingPathComponent("p.idx")
        try Data(pack).write(to: packURL)
        try Data(index).write(to: indexURL)
        return (packURL, indexURL)
    }

    func testRejectsAbsurdObjectSizeInPackHeader() throws {
        // Type blob, then size continuation bytes adding up to far more than any real object.
        let files = try craftedPack(header: [0xBF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        let pack = try GitPack(pack: files.pack, index: files.index)
        XCTAssertThrowsError(try pack.header(at: 12)) { XCTAssertEqual($0 as? GitReadError, .corrupt("object too large")) }
    }

    func testRejectsIndexWithBrokenFanout() throws {
        let files = try craftedPack(header: [0x35], fanoutOverride: (index: 0x10, value: 9))
        XCTAssertThrowsError(try GitPack(pack: files.pack, index: files.index)) { XCTAssertEqual($0 as? GitReadError, .corrupt("pack index fanout")) }
    }

    func testRejectsIndexOffsetOutsideThePack() throws {
        var files = try craftedPack(header: [0x35])
        var index = try Data(contentsOf: files.index)
        let offsetAt = 8 + 1024 + 20 + 4
        index.replaceSubrange(offsetAt..<(offsetAt + 4), with: [0x00, 0x10, 0x00, 0x00])
        try index.write(to: files.index)
        XCTAssertThrowsError(try GitPack(pack: files.pack, index: files.index)) { XCTAssertEqual($0 as? GitReadError, .corrupt("pack index offset")) }
        files = try craftedPack(header: [0x35])
        index = try Data(contentsOf: files.index)
        index.replaceSubrange(offsetAt..<(offsetAt + 4), with: [0x80, 0x00, 0x00, 0x05])  // points into a large-offset table that is not there
        try index.write(to: files.index)
        XCTAssertThrowsError(try GitPack(pack: files.pack, index: files.index)) { XCTAssertEqual($0 as? GitReadError, .corrupt("pack index offset")) }
    }

    func testRejectsDeltaLargerThanTheLimit() {
        // Base size 0, then a result size of 600 MB.
        let delta = Data([0x00, 0x80, 0x80, 0x80, 0xAC, 0x02])
        XCTAssertThrowsError(try GitRepository.applyDelta(delta, to: Data())) { XCTAssertEqual($0 as? GitReadError, .corrupt("object too large")) }
    }

    func testDeltaBaseDistanceCannotOverflow() throws {
        // An offset delta whose distance bytes never end within any sane range.
        let files = try craftedPack(header: [0x6A] + [UInt8](repeating: 0xFE, count: 8) + [0xFF, 0x00])
        let pack = try GitPack(pack: files.pack, index: files.index)
        XCTAssertThrowsError(try pack.header(at: 12)) { XCTAssertEqual($0 as? GitReadError, .corrupt("delta base offset")) }
    }

    func testDeltaCannotGrowPastItsDeclaredSize() {
        // Base of 10 bytes, result declared as 10 bytes, then 1,000 copies of the whole base.
        let copyAll: [UInt8] = [0x90, 10]  // copy, size byte present: 10 bytes from offset 0
        let delta = Data([10, 10] + Array(repeating: copyAll, count: 1_000).flatMap { $0 })
        XCTAssertThrowsError(try GitRepository.applyDelta(delta, to: Data(repeating: 7, count: 10))) {
            XCTAssertEqual($0 as? GitReadError, .corrupt("delta overflows its size"))
        }
    }

    func testAlternatesMustPointAtAnObjectsFolder() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let other = fx.makeRepository("other")
        fx.commit(["x.txt": "only in other\n"], message: "x", in: other)
        let blob = try XCTUnwrap(GitObjectID(hex: fx.git("rev-parse", "HEAD:x.txt", in: other)))
        let a = fx.makeRepository("a")
        let alternates = a.appendingPathComponent(".git/objects/info/alternates")
        try FileManager.default.createDirectory(at: alternates.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (other.appendingPathComponent(".git/objects").path + "\n").write(to: alternates, atomically: true, encoding: .utf8)
        XCTAssertEqual(try open(a).object(blob).kind, .blob, "a real alternate is followed")
        let elsewhere = fx.root.appendingPathComponent("not-git")
        try FileManager.default.copyItem(at: other.appendingPathComponent(".git/objects"), to: elsewhere)
        try (elsewhere.path + "\n").write(to: alternates, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try open(a).object(blob)) { XCTAssertEqual($0 as? GitReadError, .missingObject(blob.hex)) }
    }

    func testCommitHasAuthorAndCommitterEmails() throws {
        let fx = try GitFixture(); defer { fx.cleanup() }
        let repo = fx.makeRepository("a")
        fx.commit(["a.txt": "1\n"], message: "one", in: repo, author: "Other@Example.com")
        let commit = try open(repo).commit(try XCTUnwrap(GitObjectID(hex: fx.head(repo))))
        XCTAssertEqual(commit.authorEmail, "other@example.com")
        XCTAssertEqual(commit.committerEmail, "me@example.com")
        XCTAssertTrue(commit.parents.isEmpty)
    }
}
