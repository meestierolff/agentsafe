import Foundation

/// How bad it is if this kind of key gets out. Rated by what the key can do,
/// not by who issued it.
public enum KeySeverity: Int, Comparable, Codable, Sendable, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    public static func < (a: KeySeverity, b: KeySeverity) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .critical: return "Critical"
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

/// Whether a key works on real data or only in a provider's test environment.
/// Stated only when the key's own format proves it. A variable called `TEST_KEY`
/// proves nothing, so names are never used for this.
public enum KeyEnvironment: String, Codable, Sendable {
    case production
    case sandbox
    case unknown
}

/// What a person needs to know about a key at a glance.
public struct KeyProfile: Equatable, Sendable {
    /// One or two plain sentences: what this is and what someone holding it can do.
    public let summary: String
    public let environment: KeyEnvironment
    public let severity: KeySeverity
}

public enum KeyCatalog {
    public static let unknown = KeyProfile(
        summary: "A secret AgentSafe does not recognise. Check the variable name and the file to see what it unlocks.",
        environment: .unknown, severity: .medium)

    /// Profile for a finding. Works from the rule that matched and the visible start of
    /// the key, so it needs neither the key itself nor anything stored with the finding.
    public static func profile(ruleID: String, preview: String) -> KeyProfile {
        func make(_ summary: String, _ severity: KeySeverity, _ environment: KeyEnvironment = .unknown) -> KeyProfile {
            KeyProfile(summary: summary, environment: environment, severity: severity)
        }
        switch ruleID {
        case "stripe":
            if preview.hasPrefix("sk_live_") {
                return make("Stripe live secret key. Full access to the Stripe account: it can create charges and refunds and read customer data.", .critical, .production)
            }
            if preview.hasPrefix("rk_live_") {
                return make("Stripe live restricted key. It can do whatever it was scoped for, on real data. Check its permissions in the Stripe dashboard.", .high, .production)
            }
            if preview.hasPrefix("sk_test_") || preview.hasPrefix("rk_test_") {
                return make("Stripe test key. It only works on test data, so no real money or customers are involved.", .low, .sandbox)
            }
            return make("Stripe webhook signing secret. Someone holding it can forge payment events to your server.", .medium)
        case "anthropic":
            return make("Anthropic API key. Anyone holding it can run Claude models on your bill.", .high)
        case "openai":
            return make("OpenAI API key. Anyone holding it can run models on your bill and, depending on the key, read stored files.", .high)
        case "openrouter":
            return make("OpenRouter API key. It spends your OpenRouter credits on any model.", .high)
        case "xai":
            return make("xAI API key. It runs Grok models on your bill.", .high)
        case "groq":
            return make("Groq API key. It runs models on your Groq account.", .high)
        case "replicate":
            return make("Replicate API token. It runs models and bills your account.", .high)
        case "huggingface":
            return make("Hugging Face token. It uses your account's paid inference, and with write scope it can change your models and datasets.", .high)
        case "google":
            return make("Google API key. What it can do depends on which APIs it is enabled for: some uses are public by design (Maps, Firebase in a web page), others such as Gemini spend money.", .medium)
        case "github":
            return make("GitHub access token. It can read your repositories and, depending on its scopes, push code to them.", .critical)
        case "gitlab":
            return make("GitLab access token. It can read your projects and, depending on its scopes, push code to them.", .critical)
        case "npm":
            return make("npm access token. It can publish packages under your name, which reaches everyone who installs them.", .critical)
        case "aws":
            return make("AWS access key ID. This is the identifier half of an AWS credential; it is only dangerous together with its secret key, which is often in the same file.", .medium)
        case "database-url":
            return make("Database address with its password. Anyone holding it can read and change everything in that database.", .critical)
        case "private-key":
            return make("The contents of a private key. Whatever it unlocks, such as SSH logins, signing or TLS, is open to anyone holding it.", .critical)
        case "supabase":
            return make("Supabase secret. Depending on the kind, it manages your projects or reads and writes all data, bypassing row-level security.", .critical)
        case "neon":
            return make("Neon API key. It can create, read and delete your Neon databases.", .critical)
        case "digitalocean":
            return make("DigitalOcean API token. It controls your servers and other resources.", .critical)
        case "sendgrid":
            return make("SendGrid API key. It can send email as your domain, which is what phishers want.", .high)
        case "brevo":
            return make("Brevo API key. It can send email and SMS from your account and read your contact lists.", .high)
        case "resend":
            return make("Resend API key. It can send email as your domain.", .high)
        case "slack":
            return make("Slack token. It can read and post messages as the app or person it belongs to.", .high)
        case "telegram":
            return make("Telegram bot token. It gives full control of that bot, including reading messages sent to it.", .high)
        case "slack-webhook":
            return make("Slack incoming webhook. Anyone holding the link can post messages into that channel.", .medium)
        case "discord-webhook":
            return make("Discord webhook. Anyone holding the link can post messages into that channel.", .medium)
        case "linear":
            return make("Linear API key. It can read and change your team's issues.", .medium)
        case "notion":
            return make("Notion integration token. It can read and edit the pages shared with that integration.", .medium)
        case "firecrawl":
            return make("Firecrawl API key. It spends your scraping credits.", .medium)
        case "x-bearer":
            return make("X app bearer token. It reads public data on your app's quota; it cannot post.", .medium)
        case "generic-sk":
            return make("An API key in the common \"sk-\" format. Many AI providers use it, so check the variable name to see which service it is for.", .medium)
        case "env-assignment":
            return make("A secret from a .env file that AgentSafe has no specific rule for. The variable name says what it unlocks.", .medium)
        default:
            return unknown
        }
    }

    /// Profile for a key in the safe, which is stored with its service name.
    public static func profile(service: String, preview: String) -> KeyProfile {
        guard let rule = SecretRule.builtIn.first(where: { $0.service == service }) else { return unknown }
        return profile(ruleID: rule.id, preview: preview)
    }
}

/// Where the panel sits on screen.
public enum Placement: String, Codable, Sendable, CaseIterable {
    /// Beside the other icons at the right of the menu bar.
    case menuBar
    /// Over the MacBook's notch.
    case notch
}

/// Settings and small state that survive a relaunch. Contains nothing secret.
///
/// Every field except the salt is read with a default, so a file written by an older
/// version always loads. Failing to load would be costly: the app would start with a new
/// salt and forget the licence and the folder grant.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Random per install. Makes fingerprints useless to anyone who copies the findings file.
    public var installSalt: Data
    public var licenseKey: String?
    public var homeBookmark: Data?
    public var watchEnabled = true
    public var clipboardWatch = false
    public var lastScan: Date?
    public var hasCompletedSetup = false
    /// When the last "keys need rotating" notification went out.
    public var lastReminder: Date?
    public var placement: Placement = .menuBar
    /// Open the panel when the pointer rests on it, instead of on a click.
    public var openOnHover = false

    public init(installSalt: Data) { self.installSalt = installSalt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installSalt = try c.decode(Data.self, forKey: .installSalt)
        licenseKey = try c.decodeIfPresent(String.self, forKey: .licenseKey)
        homeBookmark = try c.decodeIfPresent(Data.self, forKey: .homeBookmark)
        watchEnabled = try c.decodeIfPresent(Bool.self, forKey: .watchEnabled) ?? true
        clipboardWatch = try c.decodeIfPresent(Bool.self, forKey: .clipboardWatch) ?? false
        lastScan = try c.decodeIfPresent(Date.self, forKey: .lastScan)
        hasCompletedSetup = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? false
        lastReminder = try c.decodeIfPresent(Date.self, forKey: .lastReminder)
        // An unknown value (from a newer version) falls back to the default instead of failing.
        placement = (try? c.decodeIfPresent(Placement.self, forKey: .placement)) ?? .menuBar
        openOnHover = try c.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? false
    }
}
