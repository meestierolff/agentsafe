import Foundation

/// Fake credentials, assembled at runtime so no secret-shaped literal sits in the repo
/// (GitHub push protection would otherwise reject the commit).
enum Fake {
    static func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

    /// Deterministic random-looking characters, so fixtures look like real keys (real
    /// keys end in noise, and the detector rejects repetitive filler) but never change.
    static func noise(_ count: Int, seed: UInt64, alphabet: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") -> String {
        let chars = Array(alphabet)
        var state = seed &* 2862933555777941757 &+ 3037000493
        return String((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return chars[Int((state >> 33) % UInt64(chars.count))]
        })
    }

    static let anthropic = "sk-" + "ant-" + "api03-" + noise(88, seed: 1) + "QwAA"
    static let openAIProject = "sk-" + "proj-" + noise(56, seed: 2)
    static let openRouter = "sk-" + "or-v1-" + noise(64, seed: 3, alphabet: "0123456789abcdef")
    static let github = "gh" + "p_" + noise(36, seed: 4)
    static let awsKeyID = "AK" + "IA" + noise(16, seed: 5, alphabet: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    static let stripeLive = "sk_" + "live_" + noise(30, seed: 6)
    static let google = "AI" + "za" + noise(35, seed: 7)
    static let slack = "xox" + "b-" + "1234567890-" + noise(24, seed: 8)
    static let postgresURL = "postgres" + "://admin:" + noise(16, seed: 9) + "@ep-cool-lake-12345.eu-central-1.aws.neon.tech:5432/app"
    /// Random-looking value with no known prefix, like a small provider would issue.
    static let unknownProviderSecret = "q9Xy7Lm2" + "Rt4Vb8Nc" + "1Zp6Wd3K" + "s5Hg0Jf"
    static let xBearer = rep("A", 21) + "MLheAAAAAAA0" + "%2B" + "uSeid" + "%2B" + "ULvsea4JtiGRiSDSJSI" + "%3D" + "EUifiRBkKG5E2XzMDjRfl76ZC9Ub0wnz4XsNiRVBChTYbJcE3F"
    static let privateKeyHeader = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"

    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("agentsafe-tests-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
