import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication

public enum VaultError: Error, Equatable {
    case wrongPassword
    case passwordTooShort
    case duplicate
    case notFound
    case corrupt
    case enclaveUnavailable
    case enclaveNotEnabled
    case authenticationFailed
    /// A file is already where the new safe would go. It is never replaced.
    case alreadyExists
}

/// A value sealed to the vault's public key. Anyone can create one; only the vault's
/// private key can open it.
public struct SealedValue: Codable, Equatable, Sendable {
    var ephemeralPublicKey: Data
    var ciphertext: Data
}

public struct VaultItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var service: String
    /// Name to use when copying as `NAME=value`, e.g. `OPENAI_API_KEY`.
    public var envName: String?
    public var note: String
    public let createdAt: Date
    /// When the current value was put in. Equals `createdAt` until the first rotation.
    public var lastRotatedAt: Date
    /// Hard expiry set by the provider, if the user knows it.
    public var expiresAt: Date?
    /// Overrides the default "rotate every N days" for this key. `nil` means use the policy.
    public var rotateAfterDays: Int?
    /// The page where this key is managed, so "Rotate" can go straight there.
    /// `nil` means use the provider's usual page.
    public var rotationURL: String?
    /// Whether `agentsafe run` may hand this key to a command. Off unless the user turns
    /// it on for this key: installing the helper must not make every key requestable.
    public var allowRun: Bool?
    public internal(set) var fingerprint: String
    public internal(set) var preview: String
    var sealed: SealedValue
}

/// The single secret that opens every item, wrapped (encrypted) under the master password.
struct PasswordWrap: Codable, Equatable {
    var salt: Data
    var iterations: Int
    var sealed: Data
}

/// The same secret, wrapped under a key that lives inside the Secure Enclave.
struct EnclaveWrap: Codable, Equatable {
    var keyBlob: Data
    var ephemeralPublicKey: Data
    var sealed: Data
}

struct VaultFile: Codable, Equatable {
    var version = 1
    var salt: Data
    var publicKey: Data
    var passwordWrap: PasswordWrap
    var enclaveWrap: EnclaveWrap?
    var items: [VaultItem]
}

public enum UnlockMethod {
    case password(String)
    case enclave(EnclaveKeyProviding, reason: String)
}

/// The safe. Design in one line: a mail slot.
///
/// Dropping a key in needs no unlock, because items are sealed to a public key that sits
/// in the file. Taking a key out needs the private key, which only exists wrapped: once
/// under the master password, and optionally once under a Secure Enclave key that macOS
/// releases only after Touch ID. The private key is never written to disk in the clear
/// and is not kept in memory between reveals.
public final class Vault {
    public static let minimumPasswordLength = 10
    public static let defaultKDFIterations = 600_000

    public let url: URL
    private var file: VaultFile

    public var items: [VaultItem] { file.items }
    public var hasEnclaveUnlock: Bool { file.enclaveWrap != nil }

    private init(url: URL, file: VaultFile) {
        self.url = url
        self.file = file
    }

    // MARK: - Create / open

    public static func exists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// - Parameter salt: pass the install's scanner salt so that a key in the safe and a
    ///   leaked copy found by the scanner get the same fingerprint.
    public static func create(at url: URL, password: String, kdfIterations: Int = defaultKDFIterations, salt: Data? = nil) throws -> Vault {
        guard password.count >= minimumPasswordLength else { throw VaultError.passwordTooShort }
        // Whatever is at this path may be a safe we could not read. Never write over it.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw VaultError.alreadyExists }
        let privateKey = P256.KeyAgreement.PrivateKey()
        let file = VaultFile(
            salt: salt ?? Crypto.randomBytes(16),
            publicKey: privateKey.publicKey.rawRepresentation,
            passwordWrap: try Crypto.wrap(privateKey.rawRepresentation, password: password, iterations: kdfIterations),
            enclaveWrap: nil,
            items: [])
        let vault = Vault(url: url, file: file)
        try vault.save()
        return vault
    }

    public static func open(at url: URL) throws -> Vault {
        guard let data = try? Data(contentsOf: url),
              let file = try? Crypto.decoder.decode(VaultFile.self, from: data) else { throw VaultError.corrupt }
        return Vault(url: url, file: file)
    }

    // MARK: - Writing (no unlock needed)

    @discardableResult
    public func add(name: String, value: String, service: String, envName: String? = nil, note: String = "",
                    expiresAt: Date? = nil, rotationURL: String? = nil, now: Date = Date()) throws -> VaultItem {
        let print = fingerprint(of: value)
        guard item(matchingFingerprint: print) == nil else { throw VaultError.duplicate }
        let id = UUID()
        let item = VaultItem(
            id: id, name: name, service: service, envName: envName, note: note,
            createdAt: now, lastRotatedAt: now, expiresAt: expiresAt, rotateAfterDays: nil, rotationURL: rotationURL,
            fingerprint: print, preview: Redactor.preview(value),
            sealed: try seal(value, for: id))
        file.items.append(item)
        try save()
        return item
    }

    /// Rotation: same entry, new value, clock restarted.
    public func replaceValue(of id: UUID, with newValue: String, now: Date = Date()) throws {
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { throw VaultError.notFound }
        file.items[index].sealed = try seal(newValue, for: id)
        file.items[index].fingerprint = fingerprint(of: newValue)
        file.items[index].preview = Redactor.preview(newValue)
        file.items[index].lastRotatedAt = now
        try save()
    }

    public func update(_ id: UUID, _ change: (inout VaultItem) -> Void) throws {
        guard let index = file.items.firstIndex(where: { $0.id == id }) else { throw VaultError.notFound }
        var copy = file.items[index]
        change(&copy)
        // The cryptographic fields are not editable through this path.
        copy.sealed = file.items[index].sealed
        copy.fingerprint = file.items[index].fingerprint
        copy.preview = file.items[index].preview
        file.items[index] = copy
        try save()
    }

    public func delete(_ id: UUID) throws {
        guard file.items.contains(where: { $0.id == id }) else { throw VaultError.notFound }
        file.items.removeAll { $0.id == id }
        try save()
    }

    /// Puts backup entries into this safe. Keys already present (same value) are skipped.
    @discardableResult
    public func restore(_ entries: [BackupEntry]) throws -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        for entry in entries {
            let print = fingerprint(of: entry.value)
            if item(matchingFingerprint: print) != nil { skipped += 1; continue }
            let id = UUID()
            file.items.append(VaultItem(
                id: id, name: entry.name, service: entry.service, envName: entry.envName, note: entry.note,
                createdAt: entry.createdAt, lastRotatedAt: entry.lastRotatedAt, expiresAt: entry.expiresAt,
                rotateAfterDays: entry.rotateAfterDays, rotationURL: entry.rotationURL,
                fingerprint: print, preview: Redactor.preview(entry.value),
                sealed: try seal(entry.value, for: id)))
            added += 1
        }
        try save()
        return (added, skipped)
    }

    // MARK: - Reading (unlock needed)

    public func reveal(_ id: UUID, using method: UnlockMethod) throws -> String {
        guard let item = file.items.first(where: { $0.id == id }) else { throw VaultError.notFound }
        let privateKey = try unlock(method)
        return try open(item.sealed, for: id, with: privateKey)
    }

    /// Every value at once. Used for the encrypted backup.
    public func revealAll(using method: UnlockMethod) throws -> [(item: VaultItem, value: String)] {
        let privateKey = try unlock(method)
        return try file.items.map { ($0, try open($0.sealed, for: $0.id, with: privateKey)) }
    }

    /// Several values with a single unlock. Used when a command needs more than one key.
    public func reveal(ids: [UUID], using method: UnlockMethod) throws -> [UUID: String] {
        let wanted = try ids.map { id -> VaultItem in
            guard let item = file.items.first(where: { $0.id == id }) else { throw VaultError.notFound }
            return item
        }
        let privateKey = try unlock(method)
        var out: [UUID: String] = [:]
        for item in wanted { out[item.id] = try open(item.sealed, for: item.id, with: privateKey) }
        return out
    }

    /// Works out which stored keys a command is asking for. Needs no unlock: it only reads names.
    public func resolve(_ references: [KeyReference]) -> RunPlan {
        var plan = RunPlan()
        for reference in references {
            let item: VaultItem?
            if let name = reference.keyName {
                item = file.items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            } else {
                item = file.items.first { $0.envName == reference.envName }
                    ?? file.items.first { $0.name.caseInsensitiveCompare(reference.envName) == .orderedSame }
            }
            guard let item else { plan.missing.append(reference.envName); continue }
            let match = RunPlan.Match(envName: reference.envName, item: item)
            if item.allowRun == true { plan.matched.append(match) } else { plan.notAllowed.append(match) }
        }
        return plan
    }

    public func verify(password: String) -> Bool { (try? unlock(.password(password))) != nil }

    // MARK: - Matching leaks

    public func fingerprint(of value: String) -> String { Fingerprint.of(value, salt: file.salt) }

    public func item(matchingFingerprint print: String) -> VaultItem? {
        file.items.first { $0.fingerprint == print }
    }

    // MARK: - Unlock methods

    public func enableEnclaveUnlock(password: String, enclave: EnclaveKeyProviding) throws {
        guard enclave.isAvailable else { throw VaultError.enclaveUnavailable }
        let privateKey = try unlock(.password(password))
        let created = try enclave.createKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let enclavePublic = try P256.KeyAgreement.PublicKey(rawRepresentation: created.publicKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclavePublic)
        let key = Crypto.deriveKey(shared, salt: ephemeral.publicKey.rawRepresentation, info: "agentsafe-enclave-wrap-v1")
        let sealed = try AES.GCM.seal(privateKey.rawRepresentation, using: key).combined!
        file.enclaveWrap = EnclaveWrap(keyBlob: created.blob, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, sealed: sealed)
        try save()
    }

    public func disableEnclaveUnlock() throws {
        file.enclaveWrap = nil
        try save()
    }

    public func changePassword(from old: String, to new: String, kdfIterations: Int = defaultKDFIterations) throws {
        guard new.count >= Self.minimumPasswordLength else { throw VaultError.passwordTooShort }
        let privateKey = try unlock(.password(old))
        file.passwordWrap = try Crypto.wrap(privateKey.rawRepresentation, password: new, iterations: kdfIterations)
        try save()
    }

    // MARK: - Internals

    private func unlock(_ method: UnlockMethod) throws -> P256.KeyAgreement.PrivateKey {
        switch method {
        case .password(let password):
            let key = Crypto.pbkdf2(password: password, salt: file.passwordWrap.salt, iterations: file.passwordWrap.iterations)
            guard let box = try? AES.GCM.SealedBox(combined: file.passwordWrap.sealed),
                  let raw = try? AES.GCM.open(box, using: key) else { throw VaultError.wrongPassword }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        case .enclave(let enclave, let reason):
            guard let wrap = file.enclaveWrap else { throw VaultError.enclaveNotEnabled }
            let shared: SharedSecret
            do {
                shared = try enclave.sharedSecret(blob: wrap.keyBlob, peerPublicKey: wrap.ephemeralPublicKey, reason: reason)
            } catch {
                throw VaultError.authenticationFailed
            }
            let key = Crypto.deriveKey(shared, salt: wrap.ephemeralPublicKey, info: "agentsafe-enclave-wrap-v1")
            guard let box = try? AES.GCM.SealedBox(combined: wrap.sealed),
                  let raw = try? AES.GCM.open(box, using: key) else { throw VaultError.corrupt }
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
    }

    private func seal(_ value: String, for id: UUID) throws -> SealedValue {
        let vaultPublic = try P256.KeyAgreement.PublicKey(rawRepresentation: file.publicKey)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: vaultPublic)
        let key = Crypto.deriveKey(shared, salt: ephemeral.publicKey.rawRepresentation, info: "agentsafe-item-v1")
        // Binding the ciphertext to the item id means a sealed value cannot be moved
        // onto another entry by editing the file.
        let box = try AES.GCM.seal(Data(value.utf8), using: key, authenticating: Data(id.uuidString.utf8))
        return SealedValue(ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, ciphertext: box.combined!)
    }

    private func open(_ sealed: SealedValue, for id: UUID, with privateKey: P256.KeyAgreement.PrivateKey) throws -> String {
        let ephemeralPublic = try P256.KeyAgreement.PublicKey(rawRepresentation: sealed.ephemeralPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let key = Crypto.deriveKey(shared, salt: sealed.ephemeralPublicKey, info: "agentsafe-item-v1")
        guard let box = try? AES.GCM.SealedBox(combined: sealed.ciphertext),
              let data = try? AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8)),
              let value = String(data: data, encoding: .utf8) else { throw VaultError.corrupt }
        return value
    }

    private func save() throws {
        try SecureFile.write(try Crypto.encoder.encode(file), to: url)
    }
}

// MARK: - Secure Enclave

public protocol EnclaveKeyProviding {
    var isAvailable: Bool { get }
    /// Creates a key inside the Secure Enclave. `blob` is an opaque handle that only this Mac's enclave can use.
    func createKey() throws -> (blob: Data, publicKey: Data)
    /// Runs a key agreement inside the enclave. This is the step macOS gates behind Touch ID.
    func sharedSecret(blob: Data, peerPublicKey: Data, reason: String) throws -> SharedSecret
}

public struct SecureEnclaveKeyProvider: EnclaveKeyProviding {
    /// `false` only in tests, so they can run without a finger on the sensor.
    public let requireUserPresence: Bool

    public init(requireUserPresence: Bool = true) {
        self.requireUserPresence = requireUserPresence
    }

    public var isAvailable: Bool { SecureEnclave.isAvailable }

    public func createKey() throws -> (blob: Data, publicKey: Data) {
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        // `.userPresence` = Touch ID, or the Mac's login password when no sensor is
        // available (lid closed, external keyboard). An agent can provide neither.
        if requireUserPresence { flags.insert(.userPresence) }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else {
            throw VaultError.enclaveUnavailable
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        return (key.dataRepresentation, key.publicKey.rawRepresentation)
    }

    public func sharedSecret(blob: Data, peerPublicKey: Data, reason: String) throws -> SharedSecret {
        let context = LAContext()
        context.localizedReason = reason
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        return try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey))
    }
}

// MARK: - Primitives

public enum Crypto {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Slow on purpose: every password guess costs an attacker this many hash rounds.
    static func pbkdf2(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        salt.withUnsafeBytes { saltPtr in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, derived.count)
        }
        return SymmetricKey(data: derived)
    }

    static func wrap(_ secret: Data, password: String, iterations: Int) throws -> PasswordWrap {
        let salt = randomBytes(16)
        let key = pbkdf2(password: password, salt: salt, iterations: iterations)
        return PasswordWrap(salt: salt, iterations: iterations, sealed: try AES.GCM.seal(secret, using: key).combined!)
    }

    static func deriveKey(_ shared: SharedSecret, salt: Data, info: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(info.utf8), outputByteCount: 32)
    }
}

/// Writes a file so that it is never half-written and never readable by other users.
public enum SecureFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temp.path, url.path) != 0 {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
