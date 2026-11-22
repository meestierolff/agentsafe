import Foundation
import XCTest

/// Builds real git repositories in a temporary folder with `/usr/bin/git`, isolated from
/// the user's own git configuration. Tests that use it are skipped where git cannot run.
final class GitFixture {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }

    init() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git is not installed") }
        root = Fake.tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        guard run(["--version"], in: root).status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw XCTSkip("git does not run here")
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func environment(author: String = "me@example.com", committer: String = "me@example.com") -> [String: String] {
        var env = [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "PATH": "/usr/bin:/bin", "LANG": "C",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": author, "GIT_COMMITTER_NAME": "Me", "GIT_COMMITTER_EMAIL": committer,
        ]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { env["DEVELOPER_DIR"] = developer }
        return env
    }

    func run(_ args: [String], in dir: URL, author: String = "me@example.com", committer: String = "me@example.com") -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = environment(author: author, committer: committer)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// Runs git and returns its output as raw bytes. A failing command fails the test.
    @discardableResult
    func gitData(_ args: String..., in dir: URL, author: String = "me@example.com", file: StaticString = #filePath, line: UInt = #line) -> Data {
        let result = run(args, in: dir, author: author)
        if result.status != 0 { XCTFail("git \(args.joined(separator: " ")) exited \(result.status)", file: file, line: line) }
        return result.output
    }

    @discardableResult
    func git(_ args: String..., in dir: URL, author: String = "me@example.com", committer: String = "me@example.com", file: StaticString = #filePath, line: UInt = #line) -> String {
        let result = run(args, in: dir, author: author, committer: committer)
        if result.status != 0 { XCTFail("git \(args.joined(separator: " ")) exited \(result.status)", file: file, line: line) }
        return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new repository at `root/<name>` (or at an absolute path) on branch `main`.
    func makeRepository(_ name: String, at parent: URL? = nil) -> URL {
        let dir = (parent ?? root).appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: dir)
        return dir
    }

    /// Writes the files (a `nil` value deletes one), stages everything and commits.
    func commit(_ files: [String: String?], message: String, in dir: URL, author: String = "me@example.com", committer: String = "me@example.com") {
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            if let contents {
                try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try! contents.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        git("add", "-A", in: dir)
        git("commit", "-q", "-m", message, in: dir, author: author, committer: committer)
    }

    func head(_ dir: URL) -> String { git("rev-parse", "HEAD", in: dir) }
}
