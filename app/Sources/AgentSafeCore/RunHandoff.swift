import CryptoKit
import Foundation

// `agentsafe run -- <command>` starts a command with keys from the safe as environment
// variables, so projects need no .env file with real values in it.
//
// The app is sandboxed and the command-line helper is not, so they cannot talk directly.
// They meet in a folder in the user's home:
//
//   1. The helper writes a request: which variables, for which command, plus a public key
//      it made for this one request.
//   2. The app shows the request. Nothing is released without Touch ID.
//   3. The app writes a reply encrypted to that public key. Only the process that asked
//      holds the matching private key, in memory, so the file is useless to anything else.
//
// What this does not do: the command that receives the keys can read them. And any
// process running as the user can write a request, so the command shown in the prompt is
// only what the requester claims. That is why each key has to be switched on for this
// before it can be requested at all, and why the prompt names every key.

/// One line of a project's key list: a variable, and optionally which key in the safe fills it.
public struct KeyReference: Equatable, Sendable {
    public let envName: String
    /// Name of the key in the safe. `nil` means "the key whose variable name is `envName`".
    public let keyName: String?

    public init(envName: String, keyName: String?) {
        self.envName = envName
        self.keyName = keyName
    }
}

public struct RunRequest: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var names: [String]
    /// Where the command was started. Shown in the prompt.
    public var directory: String
    /// The command and its arguments, as claimed by the requester. Shown in the prompt.
    public var command: [String]
    /// Made for this request only. The reply is encrypted to it.
    public var publicKey: Data
    /// For variables whose key in the safe has a different name.
    public var keyNames: [String: String]?

    public init(id: String, createdAt: Date, names: [String], directory: String, command: [String], publicKey: Data,
                keyNames: [String: String]? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.names = names
        self.directory = directory
        self.command = command
        self.publicKey = publicKey
        self.keyNames = keyNames
    }

    public var references: [KeyReference] { names.map { KeyReference(envName: $0, keyName: keyNames?[$0]) } }
}

public struct RunResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case approved, denied, error }

    public var id: String
    public var status: Status
    public var message: String?
    var ephemeralPublicKey: Data?
    var sealed: Data?
}

public enum RunError: Error, Equatable {
    case invalidRequest
    /// Written too long ago. A stale request must not pop a prompt at a random moment.
    case expired
    /// A requested key is missing from the safe or not switched on for commands.
    case notReady
    case denied(String)
    case failed(String)
    case badReply
}

/// Which of the requested keys can be released, and why the others cannot.
public struct RunPlan: Sendable {
    public struct Match: Sendable {
        public let envName: String
        public let item: VaultItem

        public init(envName: String, item: VaultItem) {
            self.envName = envName
            self.item = item
        }
    }

    public init() {}

    public var matched: [Match] = []
    /// No key in the safe for this variable.
    public var missing: [String] = []
    /// In the safe, but not switched on for commands.
    public var notAllowed: [Match] = []

    public var canProceed: Bool { !matched.isEmpty && missing.isEmpty && notAllowed.isEmpty }
}

public enum RunHandoff {
    /// The meeting folder in the user's home.
    public static let folderName = ".agentsafe"
    /// The file in a project that lists which variables it needs. Names only, never values.
    public static let keyListFileName = "agentsafe.keys"
    public static let maxAge: TimeInterval = 180

    public static func folder(home: URL) -> URL { home.appendingPathComponent(folderName, isDirectory: true) }
    public static func requestsFolder(home: URL) -> URL { folder(home: home).appendingPathComponent("requests", isDirectory: true) }
    public static func responsesFolder(home: URL) -> URL { folder(home: home).appendingPathComponent("responses", isDirectory: true) }

    /// A small file the app leaves to say "I have your request and am asking the user".
    /// It tells the helper that the app is running and can see the meeting folder.
    public static func seenMarker(for id: String, home: URL) -> URL {
        responsesFolder(home: home).appendingPathComponent("\(id).seen")
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Key list file

    /// Reads a project's key list. Each line is `NAME` or `NAME = name of the key in the safe`.
    /// A line whose right-hand side looks like an actual secret is skipped: this file is
    /// meant to be committed, and someone will paste a real .env into it one day.
    public static func parseKeyList(_ text: String) -> [KeyReference] {
        parsedLines(text).compactMap { $0.looksLikeSecret ? nil : $0.reference }
    }

    /// 1-based numbers of the lines that hold what looks like a real secret.
    public static func secretLookingLines(in text: String) -> [Int] {
        parsedLines(text).filter(\.looksLikeSecret).map(\.number)
    }

    private struct ParsedLine {
        let number: Int
        let reference: KeyReference
        let looksLikeSecret: Bool
    }

    private static func parsedLines(_ text: String) -> [ParsedLine] {
        let detector = SecretDetector()
        var out: [ParsedLine] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw
            if let comment = line.range(of: " #") { line = String(line[..<comment.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = parts[0].replacingOccurrences(of: "export ", with: "")
            guard isValidName(name) else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) : ""
            let secret = !value.isEmpty && (detector.identify(value) != nil || SecretDetector.looksRandom(value))
            out.append(ParsedLine(number: index + 1, reference: KeyReference(envName: name, keyName: value.isEmpty ? nil : value), looksLikeSecret: secret))
        }
        return out
    }

    /// Names of the variables in a .env file that hold secrets. Returns names only; used by
    /// `agentsafe init`, which must never print or copy a value.
    public static func secretVariableNames(inEnvFile text: String) -> [String] {
        let detector = SecretDetector()
        var names: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals]).replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            guard isValidName(name), !names.contains(name) else { continue }
            let isSecret = !detector.envAssignments(in: line).isEmpty || !detector.matches(in: line).isEmpty
            if isSecret { names.append(name) }
        }
        return names
    }

    // MARK: - Checking a request

    /// Variables a command must never be handed by this route: they change how programs load code.
    private static let reservedNames: Set<String> = ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "PWD", "IFS", "ENV", "BASH_ENV"]

    static func isValidName(_ name: String) -> Bool {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,127}$", options: .regularExpression) != nil else { return false }
        let upper = name.uppercased()
        return !reservedNames.contains(upper) && !upper.hasPrefix("DYLD_") && !upper.hasPrefix("LD_")
    }

    public static func validate(_ request: RunRequest, now: Date = Date()) throws {
        // The id becomes a file name, so it must not be able to climb out of the folder.
        guard request.id.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil,
              !request.names.isEmpty, request.names.count <= 50, Set(request.names).count == request.names.count,
              request.names.allSatisfy(isValidName),
              !request.command.isEmpty,
              (try? P256.KeyAgreement.PublicKey(rawRepresentation: request.publicKey)) != nil else { throw RunError.invalidRequest }
        guard abs(now.timeIntervalSince(request.createdAt)) <= maxAge else { throw RunError.expired }
    }

    // MARK: - Replying

    /// Releases the requested keys, encrypted so that only the requester can read them.
    /// Refuses unless every requested key is present and switched on.
    public static func approve(_ request: RunRequest, plan: RunPlan, vault: Vault, using method: UnlockMethod) throws -> RunResponse {
        try validate(request)
        guard plan.canProceed else { throw RunError.notReady }
        let values = try vault.reveal(ids: plan.matched.map(\.item.id), using: method)
        var environment: [String: String] = [:]
        for match in plan.matched { environment[match.envName] = values[match.item.id] }

        let requester = try P256.KeyAgreement.PublicKey(rawRepresentation: request.publicKey)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let key = Crypto.deriveKey(try ephemeral.sharedSecretFromKeyAgreement(with: requester),
                                   salt: ephemeral.publicKey.rawRepresentation, info: "agentsafe-run-v1")
        // Tied to this request's id, so a reply cannot be replayed against another request.
        let sealed = try AES.GCM.seal(try JSONEncoder().encode(environment), using: key, authenticating: Data(request.id.utf8))
        return RunResponse(id: request.id, status: .approved, message: nil,
                           ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, sealed: sealed.combined)
    }

    public static func deny(_ request: RunRequest, message: String) -> RunResponse {
        RunResponse(id: request.id, status: .denied, message: message, ephemeralPublicKey: nil, sealed: nil)
    }

    public static func failure(_ request: RunRequest, message: String) -> RunResponse {
        RunResponse(id: request.id, status: .error, message: message, ephemeralPublicKey: nil, sealed: nil)
    }

    /// The requester's side: turn the reply into environment variables.
    public static func open(_ response: RunResponse, for request: RunRequest, privateKey: P256.KeyAgreement.PrivateKey) throws -> [String: String] {
        switch response.status {
        case .denied: throw RunError.denied(response.message ?? "Denied.")
        case .error: throw RunError.failed(response.message ?? "AgentSafe could not release the keys.")
        case .approved: break
        }
        guard response.id == request.id, let publicKey = response.ephemeralPublicKey, let sealed = response.sealed,
              let appKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: publicKey),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: appKey),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: Crypto.deriveKey(shared, salt: publicKey, info: "agentsafe-run-v1"),
                                            authenticating: Data(request.id.utf8)),
              let environment = try? JSONDecoder().decode([String: String].self, from: plain) else { throw RunError.badReply }
        return environment
    }
}
