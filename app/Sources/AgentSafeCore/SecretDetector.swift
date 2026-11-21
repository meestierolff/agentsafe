import CryptoKit
import Foundation

/// One recognisable credential format.
public struct SecretRule: Equatable, Sendable {
    public let id: String
    /// Human name of the provider, shown in the UI ("OpenAI", "GitHub").
    public let service: String
    /// Regular expression body. Must not contain capturing groups.
    public let pattern: String
    /// Where the user goes to revoke and re-issue this kind of key.
    public let rotationURL: String?
    /// Literal text every match begins with. Lets the scanner skip the 99.9% of a
    /// transcript that cannot contain this kind of key without running a regex over it.
    public let anchors: [String]
    /// Literal text that appears somewhere inside a match rather than at its start.
    public let innerAnchors: [String]

    public init(id: String, service: String, pattern: String, rotationURL: String? = nil,
                anchors: [String] = [], innerAnchors: [String] = []) {
        self.id = id
        self.service = service
        self.pattern = pattern
        self.rotationURL = rotationURL
        self.anchors = anchors
        self.innerAnchors = innerAnchors
    }
}

/// A match found by the byte-level scan.
public struct ByteMatch: Equatable, Sendable {
    public let rule: SecretRule
    public let value: String
    /// Offset of the match in the scanned bytes.
    public let byteOffset: Int
    /// 1-based line within the scanned bytes.
    public let line: Int
}

public struct ByteScanResult: Sendable {
    public let matches: [ByteMatch]
    /// Number of line breaks in the scanned bytes.
    public let newlines: Int
}

public struct SecretMatch: Equatable, Sendable {
    public let rule: SecretRule
    public let value: String
    /// UTF-16 offset of the match inside the scanned text.
    public let offset: Int
}

public struct EnvAssignment: Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Finds credentials in text by their shape. High precision on purpose: a scanner
/// that cries wolf gets switched off.
public struct SecretDetector: Sendable {
    public let rules: [SecretRule]
    private let combined: NSRegularExpression
    private let envLine: NSRegularExpression
    private let anchorIndex: AnchorIndex

    public init(rules: [SecretRule] = SecretRule.builtIn) {
        self.rules = rules
        // One alternation, one pass over the text. Each rule is its own capture group,
        // so the group that matched tells us which rule fired. Order matters: specific
        // prefixes (sk-ant-, sk-or-) come before the generic "sk-" rule.
        let body = rules.map { "(\($0.pattern))" }.joined(separator: "|")
        // The lookbehind stops "risk-based" or "task_id" from matching a key prefix.
        self.combined = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])(?:\(body))")
        self.anchorIndex = AnchorIndex(rules: rules)
        self.envLine = try! NSRegularExpression(
            pattern: #"^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(.*)$"#,
            options: [.anchorsMatchLines])
    }

    public func matches(in text: String) -> [SecretMatch] {
        let ns = text as NSString
        var out: [SecretMatch] = []
        combined.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result else { return }
            for (i, rule) in rules.enumerated() {
                let r = result.range(at: i + 1)
                if r.location != NSNotFound {
                    let value = ns.substring(with: r)
                    if Self.isPlausible(value, rule: rule) {
                        out.append(SecretMatch(rule: rule, value: value, offset: r.location))
                    }
                    break
                }
            }
        }
        return out
    }

    /// The fast path. Finds the same keys as `matches(in:)`, but first walks the raw
    /// bytes once looking for the short literal every key format starts with ("sk-ant-",
    /// "ghp_", …) and only runs the regular expression on a small window around each hit.
    /// On gigabytes of transcripts this is the difference between seconds and many minutes.
    public func scan(_ data: Data) -> ByteScanResult {
        let (hits, newlineOffsets) = anchorIndex.hits(in: data)
        guard !hits.isEmpty else { return ByteScanResult(matches: [], newlines: newlineOffsets.count) }

        var out: [ByteMatch] = []
        var consumedUpTo = 0  // bytes already covered by an accepted match or a scanned window
        var index = 0
        while index < hits.count {
            let hit = hits[index]
            index += 1
            if hit < consumedUpTo { continue }
            let start = max(0, hit - Self.windowLead)
            var length = Self.windowLength
            while true {
                let end = min(data.count, start + length)
                let window = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
                let text = String(decoding: window, as: UTF8.self)
                let found = matches(in: text)
                // A match that touches the end of the window may have been cut short. Look again, wider.
                let touchesEnd = found.contains { $0.offset + ($0.value as NSString).length >= (text as NSString).length }
                if touchesEnd, end < data.count, length < Self.maxWindowLength {
                    length *= 4
                    continue
                }
                for match in found {
                    let byteOffset = start + String(text.utf16.prefix(match.offset))!.utf8.count
                    guard byteOffset + match.value.utf8.count > consumedUpTo else { continue }
                    out.append(ByteMatch(rule: match.rule, value: match.value, byteOffset: byteOffset,
                                         line: Self.line(of: byteOffset, in: newlineOffsets)))
                    consumedUpTo = byteOffset + match.value.utf8.count
                }
                consumedUpTo = max(consumedUpTo, min(end, hit + 1))
                break
            }
        }
        return ByteScanResult(matches: out, newlines: newlineOffsets.count)
    }

    private static let windowLead = 16
    private static let windowLength = 768
    private static let maxWindowLength = 49_152

    private static func line(of offset: Int, in newlineOffsets: [Int]) -> Int {
        var low = 0, high = newlineOffsets.count
        while low < high {
            let mid = (low + high) / 2
            if newlineOffsets[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low + 1
    }

    /// Filters out documentation examples and filler such as `sk-ant-xxxxxxxx`.
    static func isPlausible(_ value: String, rule: SecretRule) -> Bool {
        if rule.id == "private-key" { return true }
        if rule.id == "database-url" { return isRealDatabaseURL(value) }
        if value.range(of: "example", options: .caseInsensitive) != nil { return false }
        // A real key ends in random characters. Filler ends in the same one repeated.
        return Set(value.suffix(20)).count >= 6
    }

    /// Which provider does this single value look like? Used when a key is pasted into the safe.
    public func identify(_ value: String) -> SecretRule? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = matches(in: trimmed).first, m.offset == 0, m.value.count == trimmed.count else { return nil }
        return m.rule
    }

    /// `NAME=value` lines whose name says "secret" and whose value looks random.
    /// Catches providers we have no shape rule for. Only meant for .env-style files.
    public func envAssignments(in text: String) -> [EnvAssignment] {
        let ns = text as NSString
        var out: [EnvAssignment] = []
        envLine.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result else { return }
            let name = ns.substring(with: result.range(at: 1))
            let value = Self.cleanEnvValue(ns.substring(with: result.range(at: 2)))
            if Self.nameSuggestsSecret(name), Self.looksRandom(value) {
                out.append(EnvAssignment(name: name, value: value))
            }
        }
        return out
    }

    // MARK: - Heuristics

    private static let placeholderPasswords: Set<String> = [
        "password", "passwd", "pass", "pwd", "postgres", "mysql", "mongo", "redis", "root", "admin", "user", "secret",
        "changeme", "example", "test", "testing", "docker", "development", "localdev", "supersecret",
        "devpassword", "dbpassword", "mypassword", "yourpassword",
    ]

    /// Host names that mean "a database on this machine or in this docker-compose file".
    private static let localHosts: Set<String> = [
        "localhost", "db", "database", "postgres", "postgresql", "mysql", "mariadb", "mongo", "mongodb", "redis",
        "cache", "host", "hostname", "host.docker.internal", "0.0.0.0", "::1",
    ]

    /// Drops connection strings that are plainly tutorial or local-development filler,
    /// such as `postgres://postgres:postgres@localhost`. Every tutorial and every
    /// docker-compose file has one, and reporting them would bury the findings that matter.
    ///
    /// The rule is to skip only on positive evidence of a placeholder. Anything else is
    /// reported, because wrongly hiding a production password is the worse mistake.
    static func isRealDatabaseURL(_ value: String) -> Bool {
        guard let schemeEnd = value.range(of: "://") else { return false }
        let rest = value[schemeEnd.upperBound...]
        // The first "@" ends the credentials. (The pattern does not allow "@" in a password;
        // a later one, in a query string for example, belongs to something else.)
        guard let at = rest.firstIndex(of: "@") else { return false }
        let credentials = rest[..<at]
        guard let colon = credentials.firstIndex(of: ":") else { return false }
        let password = String(credentials[credentials.index(after: colon)...])
        let host = String(rest[rest.index(after: at)...].prefix { $0 != ":" && $0 != "/" && $0 != "?" })

        let lowerHost = host.lowercased()
        if localHosts.contains(lowerHost) || lowerHost.hasPrefix("127.") { return false }
        // HOST, DB_HOST: an unfilled template.
        if host == host.uppercased(), host.rangeOfCharacter(from: .letters) != nil { return false }
        for suffix in ["example.com", "example.org", "example.net", ".example", ".local", ".test", ".invalid"] where lowerHost.hasSuffix(suffix) {
            return false
        }

        let lowerPassword = password.lowercased()
        // Exact match only. "secret" is filler; "Secret#2024" is a weak password that is
        // really in use, and a weak password on a remote database is exactly worth reporting.
        if placeholderPasswords.contains(lowerPassword) { return false }
        if lowerPassword.hasPrefix("your") { return false }
        // Whole-token placeholders: ${VAR}, $VAR, <password>, {{password}}, [password], ******.
        // A "$" or "*" inside an otherwise ordinary password is just a strong password.
        if password.hasPrefix("${") || password.hasPrefix("$(") || password.hasPrefix("{{") { return false }
        if password.hasPrefix("<"), password.hasSuffix(">") { return false }
        if password.hasPrefix("["), password.hasSuffix("]") { return false }
        if password.hasPrefix("$"), password.dropFirst().allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) { return false }
        if Set(lowerPassword).isSubset(of: ["*", "x", "•"]) { return false }
        return true
    }

    static func cleanEnvValue(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        if let first = v.first, first == "\"" || first == "'" {
            v.removeFirst()
            if let end = v.firstIndex(of: first) { v = String(v[..<end]) }
        } else if let hash = v.range(of: " #") {
            v = String(v[..<hash.lowerBound])
        }
        return v.trimmingCharacters(in: .whitespaces)
    }

    static func nameSuggestsSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        // Values meant for the browser are public by design.
        for publicPrefix in ["NEXT_PUBLIC_", "VITE_", "PUBLIC_", "EXPO_PUBLIC_", "REACT_APP_"] where upper.hasPrefix(publicPrefix) {
            return false
        }
        // "Publishable" and public keys are meant to be shared. Compared as whole words,
        // so REPUBLIC_API_KEY is not mistaken for one.
        let words = Set(upper.split(separator: "_").map(String.init))
        if !words.isDisjoint(with: ["PUBLIC", "PUBLISHABLE", "PUB"]) { return false }
        // Names that describe where a secret lives or how it behaves, not the secret itself.
        for suffix in ["_PATH", "_FILE", "_DIR", "_NAME", "_ID", "_ENDPOINT", "_REGION", "_TTL", "_EXPIRY",
                       "_EXPIRES_IN", "_ALGORITHM", "_HEADER", "_PREFIX", "_LENGTH", "_TYPE"] where upper.hasSuffix(suffix) {
            return false
        }
        return ["KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "PWD", "CREDENTIAL"].contains { upper.contains($0) }
    }

    private static let credentialInURL = try! NSRegularExpression(
        pattern: #"://[^/\s:@]+:[^/\s@]+@|[?&](?:token|key|secret|sig|signature|password|auth|access_token|api_key|apikey)="#,
        options: [.caseInsensitive])

    /// Folders a value must start with to be treated as a file path. A leading "/" alone
    /// proves nothing: base64 secrets can start with one.
    private static let pathRoots = ["/users/", "/home/", "/var/", "/etc/", "/tmp/", "/opt/", "/usr/", "/app/", "/run/",
                                    "/mnt/", "/srv/", "/volumes/", "/private/", "/bin/", "/lib/", "/data/", "/workspace/"]

    static func looksRandom(_ value: String) -> Bool {
        guard value.count >= 16, !value.contains(" ") else { return false }
        let lower = value.lowercased()
        // A link is configuration, unless it carries a credential.
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return credentialInURL.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
        }
        // File paths are configuration. "~" and "." cannot begin a base64 or hex secret.
        for prefix in ["~/", "./", "../"] + pathRoots where lower.hasPrefix(prefix) { return false }
        for placeholder in ["your", "xxxx", "changeme", "example", "placeholder", "<", "${", "todo", "replace"] where lower.contains(placeholder) {
            return false
        }
        return shannonEntropy(value) >= 3.0
    }

    static func shannonEntropy(_ s: String) -> Double {
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }
}

public extension SecretRule {
    /// Raise this whenever the rules below change what they match. The scanner compares it
    /// with the number saved beside its progress, and reads every file again when they
    /// differ. Without that, files that have not changed would never see a new rule.
    static let rulesetVersion = 2

    /// Formats with a distinctive prefix or structure. Each one was chosen because a
    /// match is almost never a false positive.
    static let builtIn: [SecretRule] = [
        .init(id: "anthropic", service: "Anthropic", pattern: #"sk-ant-[A-Za-z0-9_\-]{32,}"#,
              rotationURL: "https://console.anthropic.com/settings/keys",
              anchors: ["sk-ant-"]),
        .init(id: "openrouter", service: "OpenRouter", pattern: #"sk-or-v1-[a-f0-9]{64}"#,
              rotationURL: "https://openrouter.ai/settings/keys",
              anchors: ["sk-or-v1-"]),
        .init(id: "openai", service: "OpenAI",
              pattern: #"sk-(?:proj|svcacct|admin)-[A-Za-z0-9_\-]{40,}|sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}"#,
              rotationURL: "https://platform.openai.com/api-keys",
              anchors: ["sk-proj-", "sk-svcacct-", "sk-admin-", "sk-"], innerAnchors: ["T3BlbkFJ"]),
        .init(id: "github", service: "GitHub", pattern: #"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,}"#,
              rotationURL: "https://github.com/settings/tokens",
              anchors: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]),
        .init(id: "gitlab", service: "GitLab", pattern: #"glpat-[A-Za-z0-9_\-]{20,}"#,
              rotationURL: "https://gitlab.com/-/user_settings/personal_access_tokens",
              anchors: ["glpat-"]),
        .init(id: "aws", service: "AWS", pattern: #"(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"#,
              rotationURL: "https://console.aws.amazon.com/iam/home#/security_credentials",
              anchors: ["AKIA", "ASIA"]),
        .init(id: "stripe", service: "Stripe", pattern: #"[sr]k_(?:live|test)_[A-Za-z0-9]{20,}|whsec_[A-Za-z0-9]{24,}"#,
              rotationURL: "https://dashboard.stripe.com/apikeys",
              anchors: ["sk_live_", "rk_live_", "sk_test_", "rk_test_", "whsec_"]),
        .init(id: "google", service: "Google", pattern: #"AIza[0-9A-Za-z_\-]{35}"#,
              rotationURL: "https://console.cloud.google.com/apis/credentials",
              anchors: ["AIza"]),
        .init(id: "slack", service: "Slack", pattern: #"xox[abprs]-[A-Za-z0-9\-]{10,}"#,
              rotationURL: "https://api.slack.com/apps",
              anchors: ["xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-"]),
        .init(id: "huggingface", service: "Hugging Face", pattern: #"hf_[A-Za-z0-9]{34,}"#,
              rotationURL: "https://huggingface.co/settings/tokens",
              anchors: ["hf_"]),
        .init(id: "replicate", service: "Replicate", pattern: #"r8_[A-Za-z0-9]{37,}"#,
              rotationURL: "https://replicate.com/account/api-tokens",
              anchors: ["r8_"]),
        .init(id: "groq", service: "Groq", pattern: #"gsk_[A-Za-z0-9]{40,}"#,
              rotationURL: "https://console.groq.com/keys",
              anchors: ["gsk_"]),
        .init(id: "xai", service: "xAI", pattern: #"xai-[A-Za-z0-9]{60,}"#,
              rotationURL: "https://console.x.ai",
              anchors: ["xai-"]),
        .init(id: "npm", service: "npm", pattern: #"npm_[A-Za-z0-9]{36}"#,
              rotationURL: "https://www.npmjs.com/settings/~/tokens",
              anchors: ["npm_"]),
        .init(id: "sendgrid", service: "SendGrid", pattern: #"SG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}"#,
              rotationURL: "https://app.sendgrid.com/settings/api_keys",
              anchors: ["SG."]),
        .init(id: "brevo", service: "Brevo", pattern: #"xkeysib-[a-f0-9]{64}-[A-Za-z0-9]{16}"#,
              rotationURL: "https://app.brevo.com/settings/keys/api",
              anchors: ["xkeysib-"]),
        .init(id: "resend", service: "Resend", pattern: #"re_[A-Za-z0-9]{8,}_[A-Za-z0-9]{20,}"#,
              rotationURL: "https://resend.com/api-keys",
              anchors: ["re_"]),
        .init(id: "supabase", service: "Supabase", pattern: #"sbp_[a-f0-9]{40}|sb_secret_[A-Za-z0-9_\-]{20,}"#,
              rotationURL: "https://supabase.com/dashboard/account/tokens",
              anchors: ["sbp_", "sb_secret_"]),
        .init(id: "neon", service: "Neon", pattern: #"napi_[a-z0-9]{40,}"#,
              rotationURL: "https://console.neon.tech/app/settings/api-keys",
              anchors: ["napi_"]),
        .init(id: "digitalocean", service: "DigitalOcean", pattern: #"dop_v1_[a-f0-9]{64}"#,
              rotationURL: "https://cloud.digitalocean.com/account/api/tokens",
              anchors: ["dop_v1_"]),
        .init(id: "linear", service: "Linear", pattern: #"lin_api_[A-Za-z0-9]{40}"#,
              rotationURL: "https://linear.app/settings/api",
              anchors: ["lin_api_"]),
        .init(id: "notion", service: "Notion", pattern: #"ntn_[A-Za-z0-9]{40,}"#,
              rotationURL: "https://www.notion.so/my-integrations",
              anchors: ["ntn_"]),
        .init(id: "firecrawl", service: "Firecrawl", pattern: #"fc-[a-f0-9]{32}(?![a-f0-9])"#,
              rotationURL: "https://www.firecrawl.dev/app/api-keys",
              anchors: ["fc-"]),
        .init(id: "telegram", service: "Telegram bot", pattern: #"\d{8,10}:AA[A-Za-z0-9_\-]{33}"#,
              rotationURL: "https://t.me/BotFather",
              innerAnchors: [":AA"]),
        .init(id: "x-bearer", service: "X (Twitter)", pattern: #"A{20,}[A-Za-z0-9]{1,40}%(?:2B|2F|3D)[A-Za-z0-9%]{30,}"#,
              rotationURL: "https://developer.x.com/en/portal/dashboard",
              anchors: ["AAAAAAAAAAAAAAAAAAAA"]),
        .init(id: "database-url", service: "Database password",
              pattern: #"(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|rediss?)://[^\s:/@"']+:[^\s@"'/]{6,}@[^\s"'\\]+"#,
              anchors: ["postgres://", "postgresql://", "mysql://", "mongodb://", "mongodb+srv://", "redis://", "rediss://"]),
        .init(id: "private-key", service: "Private key",
              pattern: #"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----"#,
              innerAnchors: ["PRIVATE KEY-----"]),
        // A webhook URL is a password in the shape of a link: anyone who has it can post.
        .init(id: "slack-webhook", service: "Slack webhook",
              pattern: #"https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]{20,}"#,
              rotationURL: "https://api.slack.com/apps",
              anchors: ["https://hooks.slack.com/services/"]),
        .init(id: "discord-webhook", service: "Discord webhook",
              pattern: #"https://discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_\-]{40,}"#,
              anchors: ["https://discord.com/api/webhooks/", "https://discordapp.com/api/webhooks/"]),
        // Many providers (DeepSeek, Moonshot, …) reuse the "sk-" convention. Keep this last.
        .init(id: "generic-sk", service: "API key", pattern: #"sk-[A-Za-z0-9_\-]{32,}"#,
              anchors: ["sk-"]),
    ]
}

/// Turns a secret into something safe to show and store.
public enum Redactor {
    /// "sk-ant-…QwAA": enough to recognise the key, useless to an attacker.
    public static func preview(_ value: String) -> String {
        guard value.count >= 16 else { return String(repeating: "•", count: min(value.count, 8)) }
        let head = value.prefix(8)
        let prefix: Substring
        if let cut = head.lastIndex(where: { $0 == "-" || $0 == "_" }) {
            prefix = head[...cut]
        } else {
            prefix = head.prefix(4)
        }
        return "\(prefix)…\(value.suffix(4))"
    }

    public static let placeholder = "[REDACTED-BY-AGENTSAFE]"
}

/// A salted hash that lets us say "this leaked value is the key you stored"
/// without keeping either value readable.
public enum Fingerprint {
    public static func of(_ value: String, salt: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(value.utf8))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Finds every place a key *could* start, in one pass over the bytes.
struct AnchorIndex: Sendable {
    private struct Anchor: Sendable {
        let bytes: [UInt8]
        /// Must not be glued to a preceding letter, digit or underscore ("risk-" is not "sk-").
        let needsBoundary: Bool
    }

    /// `table[b0 << 8 | b1]` is 0, or 1 + the index of the bucket of anchors starting with those two bytes.
    private let table: [UInt16]
    private let buckets: [[Anchor]]

    init(rules: [SecretRule]) {
        var byPrefix: [Int: [Anchor]] = [:]
        var seen = Set<String>()
        for rule in rules {
            for (text, boundary) in rule.anchors.map({ ($0, true) }) + rule.innerAnchors.map({ ($0, false) }) {
                let bytes = Array(text.utf8)
                guard bytes.count >= 2, seen.insert("\(boundary)|\(text)").inserted else { continue }
                byPrefix[Int(bytes[0]) << 8 | Int(bytes[1]), default: []].append(Anchor(bytes: bytes, needsBoundary: boundary))
            }
        }
        var table = [UInt16](repeating: 0, count: 65_536)
        var buckets: [[Anchor]] = []
        for (prefix, anchors) in byPrefix {
            buckets.append(anchors)
            table[prefix] = UInt16(buckets.count)
        }
        self.table = table
        self.buckets = buckets
    }

    /// Offsets where an anchor starts, in order, plus the offset of every line break.
    func hits(in data: Data) -> (hits: [Int], newlines: [Int]) {
        var hits: [Int] = []
        var newlines: [Int] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count > 0 else { return }
            table.withUnsafeBufferPointer { table in
                var i = 0
                while i < count {
                    let b0 = bytes[i]
                    if b0 == 0x0A { newlines.append(i) }
                    if i + 1 < count {
                        let slot = table[Int(b0) << 8 | Int(bytes[i + 1])]
                        if slot != 0 {
                            for anchor in buckets[Int(slot) - 1] where i + anchor.bytes.count <= count {
                                if anchor.needsBoundary, i > 0, Self.isWordByte(bytes[i - 1]) { continue }
                                var same = true
                                var k = 2
                                while k < anchor.bytes.count {
                                    if bytes[i + k] != anchor.bytes[k] { same = false; break }
                                    k += 1
                                }
                                if same { hits.append(i); break }
                            }
                        }
                    }
                    i += 1
                }
            }
        }
        return (hits, newlines)
    }

    @inline(__always)
    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F
    }
}
