import XCTest
@testable import AgentSafeCore

/// Compares the history walk with `git` itself on every repository in this Mac's home
/// folder, and times it. Runs only when asked (`AGENTSAFE_GIT_DIFF=1`): it reads real
/// repositories. It prints folder names and counts only, never contents or keys.
final class GitDifferentialTests: XCTestCase {
    func gitObjects(_ location: GitRepositoryLocation) -> [(id: String, path: String)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--git-dir=\(location.gitDirectory.path)", "rev-list", "--objects", "--missing=allow-any",
                             "--branches", "--tags", "--remotes", "HEAD"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_NO_LAZY_FETCH"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
    }

    func testReaderMatchesGitOnThisMac() throws {
        guard ProcessInfo.processInfo.environment["AGENTSAFE_GIT_DIFF"] == "1" else {
            throw XCTSkip("Set AGENTSAFE_GIT_DIFF=1 to compare the history walk with git on this Mac.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let salt = Crypto.randomBytes(16)
        let scanner = SecretScanner(fingerprint: { Fingerprint.of($0, salt: salt) })
        let projects = try XCTUnwrap(SourceCatalog.standard(home: home).first { $0.id == "projects" })
        var seen = Set<String>()
        let locations = (scanner.filesAndRepositories(for: projects).repositories + GitRepositoryLocator.dotfilesCandidates(home: home))
            .filter { seen.insert($0.commonDirectory.path).inserted }
        let history = GitHistoryScanner(scanner: scanner)

        var scanSeconds = 0.0, missingTotal = 0, unreadable = 0, partly = 0, skippedByGit = 0, keys = 0, pushed = 0
        for location in locations {
            let name = URL(fileURLWithPath: location.displayPath).lastPathComponent
            let started = Date()
            guard let result = history.scan(location, userEmails: [], now: Date(), isCancelled: { false }) else { continue }
            let seconds = Date().timeIntervalSince(started)
            scanSeconds += seconds
            keys += Set(result.findings.map(\.fingerprint)).count
            pushed += Set(result.findings.filter { $0.git?.pushedTo != nil }.map(\.fingerprint)).count
            switch result.outcome {
            case .unreadable(let why): unreadable += 1; print("UNREADABLE\t\(name)\t\(why)"); continue
            case .partlyRead(let why): partly += 1; print("PARTLY READ\t\(name)\t\(why)")
            case .complete: break
            }
            guard let objects = gitObjects(location) else { skippedByGit += 1; print("git failed\t\(name)"); continue }
            let theirs = Set(objects.filter { object in
                let parts = object.path.split(separator: "/").map(String.init)
                return SourceCatalog.gitKeyFileGroup(forPath: object.path) != nil
                    && !parts.dropLast().contains { SourceCatalog.gitTreeSkippedDirectories.contains($0) }
            }.map(\.id))
            let ours = Set(try history.collectVersions(location).map(\.hex))
            let missing = theirs.subtracting(ours)
            missingTotal += missing.count
            if !theirs.isEmpty || !missing.isEmpty {
                print(String(format: "%@\ttheirs %d\tours %d\tmissing %d\t%.2fs", name, theirs.count, ours.count, missing.count, seconds))
            }
            for id in missing.prefix(3) { print("  missing \(id)") }
        }
        let hashStarted = Date()
        for location in locations { _ = GitHistoryScanner.tipsHash(location) }
        let hashSeconds = Date().timeIntervalSince(hashStarted)
        print(String(format: "TOTAL\t%d repositories\tscan %.1fs\ttipsHash %.2fs\tunreadable %d\tpartly %d\tgit failed %d\tmissing %d\tkeys %d (%d pushed)",
                     locations.count, scanSeconds, hashSeconds, unreadable, partly, skippedByGit, missingTotal, keys, pushed))
        XCTAssertEqual(missingTotal, 0, "every key-file version git lists must be found by the walk")
    }
}
