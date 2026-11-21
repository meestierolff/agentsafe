import CryptoKit
import Foundation

// MARK: - Encrypted backup

public enum BackupError: Error, Equatable {
    case wrongPassword
    case notABackup
}

/// One key as it travels in a backup: metadata plus the value, all inside the encrypted part.
public struct BackupEntry: Codable, Equatable, Sendable {
    public var name: String
    public var service: String
    public var envName: String?
    public var note: String
    public var createdAt: Date
    public var lastRotatedAt: Date
    public var expiresAt: Date?
    public var rotateAfterDays: Int?
    public var rotationURL: String?
    public var value: String
}

/// There is no cloud, so the backup is a single file the user keeps wherever they like.
/// Nothing in it is readable without the backup password, including key names.
public enum Backup {
    struct Envelope: Codable {
        var format = "agentsafe-backup"
        var version = 1
        var salt: Data
        var iterations: Int
        var sealed: Data
    }

    public static let fileExtension = "agentsafe-backup"

    public static func export(_ entries: [(item: VaultItem, value: String)], password: String,
                              iterations: Int = Vault.defaultKDFIterations) throws -> Data {
        let payload = entries.map {
            BackupEntry(name: $0.item.name, service: $0.item.service, envName: $0.item.envName, note: $0.item.note,
                        createdAt: $0.item.createdAt, lastRotatedAt: $0.item.lastRotatedAt, expiresAt: $0.item.expiresAt,
                        rotateAfterDays: $0.item.rotateAfterDays, rotationURL: $0.item.rotationURL, value: $0.value)
        }
        let salt = Crypto.randomBytes(16)
        let key = Crypto.pbkdf2(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(try Crypto.encoder.encode(payload), using: key).combined!
        return try Crypto.encoder.encode(Envelope(salt: salt, iterations: iterations, sealed: sealed))
    }

    public static func read(_ data: Data, password: String) throws -> [BackupEntry] {
        guard let envelope = try? Crypto.decoder.decode(Envelope.self, from: data), envelope.format == "agentsafe-backup" else {
            throw BackupError.notABackup
        }
        let key = Crypto.pbkdf2(password: password, salt: envelope.salt, iterations: envelope.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: envelope.sealed),
              let plain = try? AES.GCM.open(box, using: key),
              let entries = try? Crypto.decoder.decode([BackupEntry].self, from: plain) else { throw BackupError.wrongPassword }
        return entries
    }
}

// MARK: - Licence

public enum LicenseError: Error, Equatable {
    case malformed
    case badSignature
}

public struct License: Codable, Equatable, Sendable {
    public let id: String
    public let email: String?
    /// Issued-at, seconds since 1970.
    public let iat: Int
    public let sku: String

    public init(id: String, email: String?, iat: Int, sku: String) {
        self.id = id; self.email = email; self.iat = iat; self.sku = sku
    }
}

/// Checks a licence without talking to a server.
///
/// The website signs `AS1.<payload>` with a private key only it holds. The app ships the
/// matching public key, which can verify signatures but cannot create them. That is why
/// the app needs no network access to know a licence is genuine.
public enum LicenseVerifier {
    public static let prefix = "AS1"

    public static func verify(_ raw: String, publicKey: Data) throws -> License {
        let compact = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == prefix,
              let payload = decodeBase64URL(parts[1]),
              let signature = decodeBase64URL(parts[2]) else { throw LicenseError.malformed }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: signed) else { throw LicenseError.badSignature }
        guard let license = try? JSONDecoder().decode(License.self, from: payload) else { throw LicenseError.malformed }
        return license
    }

    static func decodeBase64URL(_ s: String) -> Data? {
        var base64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Hardening Claude Code

public enum HardeningError: Error, Equatable {
    /// The existing settings file is not a JSON object. We refuse to replace what we cannot read.
    case unreadableSettings
}

public struct HardeningRule: Equatable, Sendable {
    public let rule: String
    public let explanation: String
}

public struct HardeningPlan: Equatable, Sendable {
    public let added: [String]
    public let alreadyPresent: [String]
    /// The full settings file to write.
    public let result: Data
}

/// Adds deny rules to `~/.claude/settings.json`.
///
/// What this covers, per the Claude Code permission docs: Claude's own file tools, and
/// shell commands it can recognise as file reads (`cat`, `head`, `tail`, `sed`). What it
/// does not cover: a script that opens the file itself, or `grep -r` run from the folder.
/// It is a seatbelt, not a lock, and the UI says so.
public enum ClaudeHardening {
    /// `//` anchors at the filesystem root, so these apply in every project. A blanket
    /// `.env.*` rule is avoided on purpose: it would also block `.env.example`, which
    /// agents legitimately read.
    public static let rules: [HardeningRule] = [
        .init(rule: "Read(//**/.env)", explanation: ".env files in any project"),
        .init(rule: "Read(//**/.env.local)", explanation: ".env.local files"),
        .init(rule: "Read(//**/.env.*.local)", explanation: ".env.development.local and similar"),
        .init(rule: "Read(//**/.env.production)", explanation: "Production env files"),
        .init(rule: "Read(//**/.env.development)", explanation: "Development env files"),
        .init(rule: "Read(//**/.env.staging)", explanation: "Staging env files"),
        .init(rule: "Read(~/.aws/credentials)", explanation: "AWS access keys"),
        .init(rule: "Read(~/.ssh/**)", explanation: "SSH keys"),
        .init(rule: "Read(//**/*.pem)", explanation: "Private key files"),
        .init(rule: "Read(~/.npmrc)", explanation: "npm publish token"),
        .init(rule: "Read(~/.netrc)", explanation: "Saved logins for command-line tools"),
        .init(rule: "Read(~/.docker/config.json)", explanation: "Docker registry logins"),
    ]

    public static func plan(existing: Data?) throws -> HardeningPlan {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw HardeningError.unreadableSettings
            }
            root = parsed
        }
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        var deny = permissions["deny"] as? [String] ?? []
        var added: [String] = []
        var present: [String] = []
        for rule in rules.map(\.rule) {
            if deny.contains(rule) { present.append(rule) } else { deny.append(rule); added.append(rule) }
        }
        permissions["deny"] = deny
        root["permissions"] = permissions
        let result = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return HardeningPlan(added: added, alreadyPresent: present, result: result)
    }
}

// MARK: - Rotation links

/// Turns what a user typed as "the page where I manage this key" into a link that is
/// safe to open. Only `https` is accepted: the app opens this in the browser on a click,
/// so file paths, scripts and unencrypted pages are refused.
public enum RotationLink {
    public static func url(from text: String?) -> URL? {
        guard var candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty,
              !candidate.contains(" ") else { return nil }
        // "console.example.com/keys" is how people paste addresses. Anything that names
        // another scheme is refused; a bare address is taken as https.
        if !candidate.contains("://") {
            guard !candidate.contains(":"), candidate.contains(".") else { return nil }
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }
}

// MARK: - Key health

public enum KeyStatus: Equatable, Sendable {
    case healthy(daysLeft: Int)
    /// Reaching its recommended rotation age.
    case dueSoon(daysLeft: Int)
    /// Past its recommended rotation age.
    case overdue(daysOver: Int)
    /// The provider's hard expiry is close.
    case expiring(daysLeft: Int)
    case expired(daysAgo: Int)
    /// A copy of this key was found outside the safe.
    case leaked

    public var needsAttention: Bool {
        if case .healthy = self { return false }
        return true
    }
}

/// How often a key should be replaced even when nothing went wrong.
public struct RotationPolicy: Equatable, Sendable {
    public var defaultDays: Int
    /// Start warning this many days before a key is due or expires.
    public var warnDays: Int

    public init(defaultDays: Int = 90, warnDays: Int = 14) {
        self.defaultDays = defaultDays
        self.warnDays = warnDays
    }

    /// Recommended maximum age for a key from this provider.
    ///
    /// This is the one piece of product judgement in the file: shorter means safer but
    /// more nagging, and a tool that nags gets ignored. Right now every provider gets
    /// `defaultDays`. Tune per provider here (for example, shorter for keys that can
    /// spend money, longer for read-only ones).
    public func recommendedDays(for service: String) -> Int {
        defaultDays
    }
}

public struct HealthSummary: Equatable, Sendable {
    public var total = 0
    public var leaked = 0
    /// Overdue or expired: act now.
    public var needRotation = 0
    /// Due soon or expiring soon: act this month.
    public var expiring = 0

    public var allClear: Bool { leaked == 0 && needRotation == 0 && expiring == 0 }
}

public enum KeyHealth {
    public static func status(of item: VaultItem, leaked: Bool, policy: RotationPolicy, now: Date = Date()) -> KeyStatus {
        if leaked { return .leaked }
        let day: TimeInterval = 86_400
        if let expires = item.expiresAt {
            let left = Int((expires.timeIntervalSince(now) / day).rounded(.down))
            if left < 0 { return .expired(daysAgo: -left) }
            if left <= policy.warnDays { return .expiring(daysLeft: left) }
        }
        let limit = item.rotateAfterDays ?? policy.recommendedDays(for: item.service)
        let age = Int((now.timeIntervalSince(item.lastRotatedAt) / day).rounded(.down))
        let left = limit - age
        if left < 0 { return .overdue(daysOver: -left) }
        if left <= policy.warnDays { return .dueSoon(daysLeft: left) }
        return .healthy(daysLeft: left)
    }

    public static func summary(items: [VaultItem], leakedFingerprints: Set<String>, policy: RotationPolicy, now: Date = Date()) -> HealthSummary {
        var summary = HealthSummary(total: items.count)
        for item in items {
            switch status(of: item, leaked: leakedFingerprints.contains(item.fingerprint), policy: policy, now: now) {
            case .leaked: summary.leaked += 1
            case .overdue, .expired: summary.needRotation += 1
            case .dueSoon, .expiring: summary.expiring += 1
            case .healthy: break
            }
        }
        return summary
    }
}
