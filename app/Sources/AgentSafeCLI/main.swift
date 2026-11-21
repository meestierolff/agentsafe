import AgentSafeCore
import CryptoKit
import Foundation

// agentsafe: start a command with keys from the AgentSafe app, so a project needs no
// .env file with real values in it.
//
//   agentsafe run -- npm run dev          keys listed in ./agentsafe.keys
//   agentsafe run --keys A,B -- <command> keys named on the command line
//   agentsafe init                        write agentsafe.keys from the names in ./.env
//
// This program never prints a key and never stores one. It asks the app, the app asks
// you (Touch ID), and the reply is decrypted in memory and handed to the command.

let version = "0.3.0"

enum Exit: Int32 {
    case usage = 2
    case noAnswer = 3
    case refused = 4
    case cannotRun = 127
}

func fail(_ code: Exit, _ message: String) -> Never {
    FileHandle.standardError.write(Data(("agentsafe: " + message + "\n").utf8))
    exit(code.rawValue)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let usage = """
Usage:
  agentsafe run [--keys NAME,NAME] [--timeout SECONDS] -- <command> [arguments]
  agentsafe init [--from FILE]
  agentsafe version

run    Starts <command> with the named keys as environment variables. Without --keys,
       the names come from a file called agentsafe.keys in this folder or a parent.
       AgentSafe asks for Touch ID before anything is released.
init   Writes agentsafe.keys from the variable names in .env. Names only, never values.

Each key must first be switched on for this in AgentSafe ("Commands may use this key").
"""

/// The user's home folder, or a stand-in when testing.
let home: URL = {
    if let override = ProcessInfo.processInfo.environment["AGENTSAFE_HOME"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
}()

let isTestRun = ProcessInfo.processInfo.environment["AGENTSAFE_HOME"] != nil
let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()

/// Looks for the project's key list in this folder, then each parent.
func findKeyList() -> URL? {
    var folder = workingDirectory
    for _ in 0..<32 {
        let candidate = folder.appendingPathComponent(RunHandoff.keyListFileName)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let parent = folder.deletingLastPathComponent()
        if parent.path == folder.path { break }
        folder = parent
    }
    return nil
}

// MARK: - init

func runInit(_ arguments: [String]) -> Never {
    var source = ".env"
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--from", index + 1 < arguments.count { source = arguments[index + 1]; index += 2 } else { fail(.usage, "unknown option \(arguments[index])\n\n\(usage)") }
    }
    let target = workingDirectory.appendingPathComponent(RunHandoff.keyListFileName)
    guard !FileManager.default.fileExists(atPath: target.path) else {
        fail(.usage, "\(RunHandoff.keyListFileName) already exists here. Edit it, or remove it first.")
    }
    guard let text = try? String(contentsOf: workingDirectory.appendingPathComponent(source), encoding: .utf8) else {
        fail(.usage, "could not read \(source) in this folder.")
    }
    let names = RunHandoff.secretVariableNames(inEnvFile: text)
    guard !names.isEmpty else { fail(.usage, "found no secret-looking variables in \(source).") }
    let body = """
    # Keys this project needs from AgentSafe. Names only: never put a value in this file.
    # A line can be NAME, or NAME = name of the key in your safe.
    # Start the project with:  agentsafe run -- <your usual command>

    """ + names.joined(separator: "\n") + "\n"
    do {
        try body.write(to: target, atomically: true, encoding: .utf8)
    } catch {
        fail(.usage, "could not write \(RunHandoff.keyListFileName): \(error.localizedDescription)")
    }
    print("Wrote \(RunHandoff.keyListFileName) with \(names.count) \(names.count == 1 ? "name" : "names"):")
    for name in names { print("  \(name)") }
    print("Next, for the person at the Mac (not for an AI agent): store each key in AgentSafe under that variable name and switch on \"Commands may use this key\". Once the project starts with agentsafe run, remove the values from \(source).")
    exit(0)
}

// MARK: - run

func runCommand(_ arguments: [String]) -> Never {
    var named: [String]?
    var timeout: TimeInterval = 120
    var command: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" { command = Array(arguments[(index + 1)...]); break }
        if argument == "--keys", index + 1 < arguments.count {
            named = arguments[index + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            index += 2
        } else if argument == "--timeout", index + 1 < arguments.count, let seconds = TimeInterval(arguments[index + 1]), seconds > 0 {
            timeout = seconds
            index += 2
        } else {
            fail(.usage, "unknown option \(argument)\n\n\(usage)")
        }
    }
    guard !command.isEmpty else { fail(.usage, "nothing to run. Put the command after \"--\".\n\n\(usage)") }

    var names: [String] = []
    var keyNames: [String: String] = [:]
    if let named {
        names = named
    } else if let file = findKeyList(), let text = try? String(contentsOf: file, encoding: .utf8) {
        let suspicious = RunHandoff.secretLookingLines(in: text)
        if !suspicious.isEmpty {
            note("agentsafe: warning: \(file.lastPathComponent) line \(suspicious.map(String.init).joined(separator: ", ")) looks like a real key. That file is for names only; remove the value and rotate that key.")
        }
        for reference in RunHandoff.parseKeyList(text) {
            names.append(reference.envName)
            if let keyName = reference.keyName { keyNames[reference.envName] = keyName }
        }
    } else {
        fail(.usage, "no keys named. Use --keys NAME,NAME or create \(RunHandoff.keyListFileName) (try: agentsafe init).")
    }

    let privateKey = P256.KeyAgreement.PrivateKey()
    let request = RunRequest(id: UUID().uuidString, createdAt: Date(), names: names, directory: workingDirectory.path, command: command,
                             publicKey: privateKey.publicKey.rawRepresentation, keyNames: keyNames.isEmpty ? nil : keyNames)
    do {
        try RunHandoff.validate(request)
    } catch {
        fail(.usage, "those are not usable variable names: \(names.joined(separator: ", ")). Use names like OPENAI_API_KEY; system variables such as PATH cannot be set this way.")
    }

    let fm = FileManager.default
    let requestFile = RunHandoff.requestsFolder(home: home).appendingPathComponent("\(request.id).json")
    let responseFile = RunHandoff.responsesFolder(home: home).appendingPathComponent("\(request.id).json")
    let seenFile = RunHandoff.seenMarker(for: request.id, home: home)
    func cleanUp() {
        try? fm.removeItem(at: requestFile)
        try? fm.removeItem(at: responseFile)
        try? fm.removeItem(at: seenFile)
    }
    do {
        for folder in [RunHandoff.requestsFolder(home: home), RunHandoff.responsesFolder(home: home)] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try SecureFile.write(try RunHandoff.encoder.encode(request), to: requestFile)
    } catch {
        fail(.cannotRun, "could not write the request in \(RunHandoff.folder(home: home).path): \(error.localizedDescription)")
    }

    if !isTestRun {
        // Make sure the app is running. `-g` keeps it in the background; it brings up its own prompt.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-g", "-b", "live.agentsafe.mac"]
        opener.standardError = FileHandle.nullDevice
        try? opener.run()
    }
    note("agentsafe: sent a request for \(names.count) \(names.count == 1 ? "key" : "keys") to AgentSafe…")

    let deadline = Date().addingTimeInterval(timeout)
    var response: RunResponse?
    var announced = false
    while Date() < deadline {
        if !announced, fm.fileExists(atPath: seenFile.path) {
            announced = true
            note("agentsafe: AgentSafe is asking for your approval (Touch ID)…")
        }
        if let data = try? Data(contentsOf: responseFile), let decoded = try? RunHandoff.decoder.decode(RunResponse.self, from: data) {
            response = decoded
            break
        }
        Thread.sleep(forTimeInterval: 0.15)
    }
    guard let response else {
        cleanUp()
        fail(.noAnswer, announced
             ? "AgentSafe did not answer within \(Int(timeout)) seconds: the request was shown but not approved."
             : "AgentSafe did not answer within \(Int(timeout)) seconds. Check that the app is running and has been allowed to read your home folder.")
    }
    cleanUp()

    let environment: [String: String]
    do {
        environment = try RunHandoff.open(response, for: request, privateKey: privateKey)
    } catch RunError.denied(let message), RunError.failed(let message) {
        fail(.refused, message)
    } catch {
        fail(.refused, "the reply from AgentSafe could not be read.")
    }

    for (name, value) in environment { setenv(name, value, 1) }
    // Replace this process with the command, so nothing of ours lingers holding the keys.
    var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
    argv.append(nil)
    execvp(command[0], &argv)
    fail(.cannotRun, "could not start \(command[0]): \(String(cString: strerror(errno)))")
}

// MARK: - entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "run": runCommand(Array(arguments.dropFirst()))
case "init": runInit(Array(arguments.dropFirst()))
case "version", "--version": print("agentsafe \(version)"); exit(0)
case "help", "--help", "-h": print(usage); exit(0)
default: fail(.usage, (arguments.first.map { "unknown command \($0)" } ?? "no command given") + "\n\n\(usage)")
}
