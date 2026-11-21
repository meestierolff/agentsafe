import AgentSafeCore
import AppKit
import CryptoKit
import SwiftUI

/// Proves, from inside the signed app, the claims the product makes about itself.
enum SelfTest {
    static func run() {
        print("sandboxed: \(Paths.isSandboxed)")
        print("data directory: \(Paths.display(Paths.defaultDataDirectory.path))")
        print("secure enclave: \(SecureEnclave.isAvailable)")
        let home = Paths.realHome.appendingPathComponent(".zsh_history").path
        print("home readable without a grant: \(FileManager.default.isReadableFile(atPath: home))")
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { print("network: blocked (\((error as NSError).code))") }
            else { print("network: REACHABLE \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)
    }
}

/// Runs the real scanner over this Mac and prints totals only: no paths, no previews,
/// no values. For checking speed and false-positive rates during development.
enum ScanSummary {
    static func run() {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("agentsafe-summary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let salt = Crypto.randomBytes(16)
        let coordinator = ScanCoordinator(
            scanner: SecretScanner(fingerprint: { Fingerprint.of($0, salt: salt) }),
            store: FindingStore(url: scratch.appendingPathComponent("findings.json")),
            stateURL: scratch.appendingPathComponent("state.json"))
        let started = Date()
        let report = coordinator.runFullScan(sources: SourceCatalog.standard(home: Paths.realHome))
        let seconds = Date().timeIntervalSince(started)
        let findings = coordinator.store.findings
        print(String(format: "files read: %d, unreadable: %d, time: %.1fs", report.filesScanned, report.filesUnreadable, seconds))
        print("distinct secrets: \(Set(findings.map(\.fingerprint)).count), places: \(findings.count)")
        for (label, group) in Dictionary(grouping: findings, by: \.sourceLabel).sorted(by: { $0.key < $1.key }) {
            print("  source \(label): \(Set(group.map(\.fingerprint)).count) secrets in \(group.count) files")
        }
        for (rule, group) in Dictionary(grouping: findings, by: \.ruleID).sorted(by: { $0.key < $1.key }) {
            print("  rule \(rule): \(Set(group.map(\.fingerprint)).count) secrets")
        }
    }
}

/// Renders the main screens to PNG files with made-up data, so the look can be reviewed
/// (and screenshots made) without touching anyone's real keys.
@MainActor
enum Snapshot {
    static func run(outputDirectory: URL) {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("agentsafe-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let model = demoModel(in: scratch.appendingPathComponent("full"))
        let geometry = NotchGeometry(notch: CGSize(width: 185, height: 32), hasHardwareNotch: true)
        let controller = NotchController(model: model)

        render(NotchStage(geometry: geometry, expanded: false) { NotchCollapsedView(model: model, geometry: geometry) },
               size: CGSize(width: 640, height: 90), to: outputDirectory.appendingPathComponent("notch-collapsed.png"))

        render(NotchStage(geometry: geometry, expanded: true) { NotchExpandedView(model: model, controller: controller) },
               size: CGSize(width: 640, height: 440), to: outputDirectory.appendingPathComponent("notch-open.png"))

        model.alert = LeakAlert(title: "Anthropic key leaked", detail: "Found in Claude Code transcripts. It is your Anthropic production. Rotate it.")
        render(NotchStage(geometry: geometry, expanded: true) { NotchExpandedView(model: model, controller: controller) },
               size: CGSize(width: 640, height: 480), to: outputDirectory.appendingPathComponent("notch-alert.png"))
        model.alert = nil

        for tab in SafeTab.allCases {
            model.selectedTab = tab
            let name = tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            render(SafeRootView(model: model), size: CGSize(width: 940, height: 680), to: outputDirectory.appendingPathComponent("safe-\(name).png"))
        }

        renderStatusIcons(to: outputDirectory.appendingPathComponent("status-icons.png"))

        // The prompt a command sees when it asks for keys.
        if let first = model.items.first(where: { $0.envName == "OPENAI_API_KEY" }), let second = model.items.first(where: { $0.envName == "STRIPE_SECRET_KEY" }) {
            var plan = RunPlan()
            plan.matched = [RunPlan.Match(envName: "OPENAI_API_KEY", item: first), RunPlan.Match(envName: "STRIPE_SECRET_KEY", item: second)]
            let request = RunRequest(id: UUID().uuidString, createdAt: Date(), names: ["OPENAI_API_KEY", "STRIPE_SECRET_KEY"],
                                     directory: Paths.realHome.path + "/projects/shop", command: ["npm", "run", "dev"], publicKey: Data())
            render(RunApprovalView(model: model, pending: PendingRun(request: request, plan: plan)), size: CGSize(width: 520, height: 400),
                   to: outputDirectory.appendingPathComponent("run-approval.png"))
        }

        // The same leak list as a free user sees it, after reaching for a licensed action.
        model.selectedTab = .leaks
        model.loadDemo(findings: model.findings, license: nil)
        model.licencePrompt = true
        render(SafeRootView(model: model), size: CGSize(width: 940, height: 680), to: outputDirectory.appendingPathComponent("safe-leaks-free.png"))

        render(SafeGlyph().padding(96).background(Color.clear), size: CGSize(width: 1024, height: 1024),
               to: outputDirectory.appendingPathComponent("icon-1024.png"), scale: 1)

        let empty = AppModel(dataDirectory: scratch.appendingPathComponent("empty"), isDemo: true)
        render(SafeRootView(model: empty), size: CGSize(width: 900, height: 640), to: outputDirectory.appendingPathComponent("safe-setup.png"))
        print("snapshots written to \(outputDirectory.path)")
    }

    static func demoModel(in directory: URL) -> AppModel {
        let model = AppModel(dataDirectory: directory, isDemo: true)
        model.loadDemo(findings: [], license: License(id: "demo", email: nil, iat: 0, sku: "agentsafe-mac"))
        try? model.createSafe(password: "demo master password", useTouchID: false)
        let day: TimeInterval = 86_400
        // Made-up values in real formats. None of these are working keys.
        func noise(_ count: Int, _ seed: UInt64) -> String {
            let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            var state = seed &* 2862933555777941757 &+ 3037000493
            return String((0..<count).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return chars[Int((state >> 33) % UInt64(chars.count))]
            })
        }
        let keys: [(String, String, String, Double, Double?)] = [
            ("Anthropic production", "sk-" + "ant-api03-" + noise(90, 11), "ANTHROPIC_API_KEY", 12, nil),
            ("OpenAI side project", "sk-" + "proj-" + noise(56, 12), "OPENAI_API_KEY", 131, nil),
            ("GitHub deploy token", "gh" + "p_" + noise(36, 13), "GITHUB_TOKEN", 40, 9),
            ("Stripe live", "sk_" + "live_" + noise(30, 14), "STRIPE_SECRET_KEY", 81, nil),
            ("X bearer token", String(repeating: "A", count: 22) + noise(10, 15) + "%2B" + noise(6, 16) + "%3D" + noise(48, 17), "X_BEARER_TOKEN", 3, nil),
            ("Scrape Creators", noise(31, 18), "SCRAPE_CREATORS_API_KEY", 25, nil),
        ]
        for (name, value, env, age, expiresIn) in keys {
            let service = model.inspect(value)?.service ?? "API key"
            if let item = try? model.addKey(name: name, value: value, service: service, envName: env, expiresAt: expiresIn.map { Date().addingTimeInterval($0 * day) }) {
                model.update(item.id) { $0.lastRotatedAt = Date().addingTimeInterval(-age * day) }
            }
        }
        let salt = model.settings.installSalt
        func finding(_ value: String, _ service: String, _ path: String, _ line: Int, _ count: Int, _ kind: SourceKind, _ label: String, _ status: FindingStatus = .open, name: String? = nil) -> Finding {
            let print = Fingerprint.of(value, salt: salt)
            let rule = SecretRule.builtIn.first { $0.service == service }?.id ?? "env-assignment"
            return Finding(id: "\(print)-\(path)", ruleID: rule, service: service, name: name, preview: Redactor.preview(value), fingerprint: print,
                           path: Paths.realHome.path + path, line: line, count: count, kind: kind, sourceLabel: label,
                           firstSeen: Date(), lastSeen: Date(), status: status)
        }
        let anthropic = keys[0].1
        let resend = "re_" + noise(8, 19) + "_" + noise(24, 20)
        model.loadDemo(findings: [
            finding(anthropic, "Anthropic", "/.claude/projects/-Users-you-shop/4f2a91c0.jsonl", 212, 3, .agentTranscript, "Claude Code transcripts"),
            finding(anthropic, "Anthropic", "/projects/shop/.env", 4, 1, .envFile, "Env file", name: "ANTHROPIC_API_KEY"),
            finding(anthropic, "Anthropic", "/Library/Application Support/Cursor/User/globalStorage/state.vscdb", 1, 2, .agentTranscript, "Cursor chat history"),
            finding(resend, "Resend", "/.zsh_history", 1880, 1, .shellHistory, "Shell history (zsh)"),
            Finding(id: "demo-stripe-live", ruleID: "stripe", service: "Stripe", name: nil, preview: "sk_live_…C39H", fingerprint: "demo-stripe-live",
                    path: Paths.realHome.path + "/.codex/sessions/2026/11/rollout-18.jsonl", line: 44, count: 2, kind: .agentTranscript,
                    sourceLabel: "Codex transcripts", firstSeen: Date(), lastSeen: Date(), status: .open),
            Finding(id: "demo-stripe-test", ruleID: "stripe", service: "Stripe", name: nil, preview: "sk_test_…9fQ2", fingerprint: "demo-stripe-test",
                    path: Paths.realHome.path + "/.claude/projects/-Users-you-shop/4f2a91c0.jsonl", line: 90, count: 1, kind: .agentTranscript,
                    sourceLabel: "Claude Code transcripts", firstSeen: Date(), lastSeen: Date(), status: .open),
            finding("gh" + "p_" + noise(36, 21), "GitHub", "/.claude.json", 57, 1, .agentConfig, "Claude Code MCP config", .rotated),
            finding(noise(40, 22), "API key", "/projects/shop/.env", 9, 1, .envFile, "Env file", name: "SESSION_SECRET"),
            finding("sk_" + "live_" + noise(30, 23), "Stripe", "/projects/old-saas/.env.production", 2, 1, .envFile, "Env file", name: "STRIPE_SECRET_KEY"),
            finding(noise(36, 24), "API key", "/projects/old-saas/.env.production", 5, 1, .envFile, "Env file", name: "SENDGRID_API_KEY"),
        ], license: License(id: "demo", email: nil, iat: 0, sku: "agentsafe-mac"))
        return model
    }

    /// The three states of the menu bar icon, on a dark and a light menu bar, enlarged.
    static func renderStatusIcons(to url: URL) {
        let scale: CGFloat = 6
        let cell = NSSize(width: 44, height: 30)
        let tones = StatusIcon.Tone.allCases
        let size = NSSize(width: cell.width * CGFloat(tones.count), height: cell.height * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size  // set before making the context, so one point covers `scale` pixels
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (row, appearance) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let y = CGFloat(1 - row) * cell.height
                (row == 0 ? NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.52, alpha: 1) : NSColor(calibratedWhite: 0.90, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell.height).fill()
                for (column, tone) in tones.enumerated() {
                    let origin = NSPoint(x: CGFloat(column) * cell.width + (cell.width - StatusIcon.size.width) / 2, y: y + (cell.height - StatusIcon.size.height) / 2)
                    StatusIcon.image(tone).draw(in: NSRect(origin: origin, size: StatusIcon.size))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Draws a view the way it appears on screen, including AppKit-backed controls.
    static func render<V: View>(_ view: V, size: CGSize, to url: URL, scale: CGFloat? = nil) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))  // let SwiftUI settle
        window.isOpaque = false
        window.backgroundColor = .clear
        let pixelScale = scale ?? 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * pixelScale), pixelsHigh: Int(size.height * pixelScale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// A fake strip of menu bar with a notch in it, as a backdrop for notch screenshots.
struct NotchStage<Content: View>: View {
    var geometry: NotchGeometry
    var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let size = expanded ? geometry.expanded : geometry.collapsed
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.52), Color(red: 0.42, green: 0.62, blue: 0.80)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.white.opacity(0.28)).frame(height: geometry.notch.height).frame(maxHeight: .infinity, alignment: .top)
            ZStack(alignment: .top) {
                NotchShape(bottomRadius: expanded ? 22 : 10).fill(.black)
                if expanded {
                    content.padding(.top, geometry.notch.height + 2).padding([.horizontal, .bottom], 10)
                } else {
                    content
                }
            }
            .frame(width: size.width).fixedSize(horizontal: false, vertical: true)
        }
    }
}
