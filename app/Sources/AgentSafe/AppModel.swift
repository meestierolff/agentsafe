import AgentSafeCore
import AppKit
import Combine
import Foundation

enum ScanActivity: Equatable {
    case idle
    case running(label: String, files: Int)
}

struct LeakAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
}

struct CaptureCandidate: Equatable {
    var value: String
    var service: String
    var suggestedName: String
    var suggestedEnvName: String?
}

/// A command that is waiting for keys, with what the safe can and cannot give it.
struct PendingRun: Identifiable {
    let request: RunRequest
    let plan: RunPlan
    var id: String { request.id }

    var commandLine: String { request.command.joined(separator: " ") }
}

struct PasswordRequest: Identifiable {
    let id = UUID()
    let reason: String
    let reply: (String?) -> Void
}

enum AppError: LocalizedError {
    case needsLicence
    case noSafe
    case message(String)

    var errorDescription: String? {
        switch self {
        case .needsLicence: return "The free version holds \(AppModel.freeKeyLimit) keys. A licence removes the limit."
        case .noSafe: return "Create your safe first."
        case .message(let text): return text
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let freeKeyLimit = 3
    /// Public half of the licence signing key. It can check licences but cannot create them.
    static let licensePublicKey = Data(base64Encoded: "rpkBPaYO3oha03jsg0faMfhkowwre01wmKmzNyFFmI4=")!

    // What the views render.
    @Published private(set) var items: [VaultItem] = []
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var hasSafe = false
    /// A safe file exists but could not be read. Shown as its own state: offering to
    /// "set up a safe" here would invite the user to replace their keys with nothing.
    @Published private(set) var safeUnreadable = false
    @Published private(set) var touchIDEnabled = false
    @Published private(set) var license: License?
    @Published private(set) var hasFolderAccess = false
    @Published private(set) var activity: ScanActivity = .idle
    @Published private(set) var revealed: [UUID: String] = [:]
    @Published var settings: AppSettings
    @Published var alert: LeakAlert?
    @Published var toast: String?
    @Published var candidate: CaptureCandidate?
    @Published var passwordRequest: PasswordRequest?
    @Published var selectedTab: SafeTab = .keys
    /// Shown after "Remove local copies": what was removed and what was left alone.
    @Published var lastRemoval: RemovalReport?
    @Published private(set) var isRemoving = false
    /// Set when a free user reaches for a licensed action, to explain what a licence adds.
    @Published var licencePrompt = false
    /// A command asking for keys through `agentsafe run`. Shown as its own prompt.
    @Published private(set) var pendingRun: PendingRun?

    let policy = RotationPolicy()
    let detector = SecretDetector()
    let dataDirectory: URL
    let isDemo: Bool

    private var vault: Vault?
    private let coordinator: ScanCoordinator
    private let access = FolderAccess()
    private var watcher: FileWatcher?
    private var clipboardTimer: Timer?
    private var reminderTimer: Timer?
    private var runWatcher: FileWatcher?
    private var lastClipboardChange = 0
    /// Every read and write of findings happens on this queue, so scans never race the UI.
    private let scanQueue = DispatchQueue(label: "live.agentsafe.scan", qos: .utility)
    private let scanCancelled = Flag()

    var onOpenSafe: (() -> Void)?
    var onPlacementChange: (() -> Void)?

    // MARK: - Setup

    init(dataDirectory: URL = Paths.defaultDataDirectory, isDemo: Bool = false) {
        self.dataDirectory = dataDirectory
        self.isDemo = isDemo
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let settingsURL = dataDirectory.appendingPathComponent("settings.json")
        let loaded: AppSettings
        if let data = try? Data(contentsOf: settingsURL) {
            if let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
                loaded = saved
            } else {
                // Never write over a settings file we could not read: it holds the licence and
                // the folder grant. Set it aside so it can be recovered, then start fresh.
                let aside = dataDirectory.appendingPathComponent("settings.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: settingsURL, to: aside)
                loaded = AppSettings(installSalt: Crypto.randomBytes(16))
            }
        } else {
            loaded = AppSettings(installSalt: Crypto.randomBytes(16))
        }
        settings = loaded

        let salt = loaded.installSalt
        let scanner = SecretScanner(fingerprint: { Fingerprint.of($0, salt: salt) })
        coordinator = ScanCoordinator(
            scanner: scanner,
            store: FindingStore(url: dataDirectory.appendingPathComponent("findings.json")),
            stateURL: dataDirectory.appendingPathComponent("scan-state.json"))
        let vaultURL = dataDirectory.appendingPathComponent("safe.json")
        if Vault.exists(at: vaultURL) {
            if let opened = try? Vault.open(at: vaultURL) {
                vault = opened
                refreshVault()
            } else {
                safeUnreadable = true
            }
        }
        findings = coordinator.store.findings
        if let key = settings.licenseKey { license = try? LicenseVerifier.verify(key, publicKey: Self.licensePublicKey) }
        saveSettings()
    }

    /// Called once the app has finished launching. Not used in demo mode.
    func start() {
        if let refreshed = access.restore(from: settings.homeBookmark) { settings.homeBookmark = refreshed; saveSettings() }
        hasFolderAccess = access.isGranted
        Notifier.requestPermission()
        restartWatching()
        restartRunBroker()
        restartClipboardWatch()
        // Look at key ages shortly after launch, then a few times a day.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.remindIfDue() }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.remindIfDue() }
        }
        // Catch up on anything agents wrote while the app was closed.
        if hasFolderAccess, settings.hasCompletedSetup { scanNow() }
    }

    var sources: [ScanSource] { SourceCatalog.standard(home: Paths.realHome) }
    var isLicensed: Bool { license != nil }
    var canAddKey: Bool { isLicensed || items.count < Self.freeKeyLimit }
    var isScanning: Bool { activity != .idle }

    // MARK: - Derived state

    var openFindings: [Finding] { findings.filter { $0.status == .open } }

    /// Copies that should not exist: in agent transcripts, agent configs and shell history.
    var leakFindings: [Finding] { openFindings.filter { $0.kind.isLeak } }

    /// Keys sitting in plaintext .env files. Normal for developers, readable by any agent.
    var exposedFindings: [Finding] { openFindings.filter { !$0.kind.isLeak } }

    /// Secrets, not files: one key leaked into five transcripts counts once.
    var openLeakCount: Int { leakedFingerprints.count }

    var leakedFingerprints: Set<String> { Set(leakFindings.map(\.fingerprint)) }

    /// How many .env files hold a copy of this key. Shown on the key, so a key that is
    /// "safe in the safe" but also lying in project folders is not mistaken for protected.
    func envFileCopies(of item: VaultItem) -> Int {
        exposedFindings.filter { $0.fingerprint == item.fingerprint }.count
    }

    /// Secrets that are only in .env files (not also leaked).
    var exposedCount: Int { Set(exposedFindings.map(\.fingerprint)).subtracting(leakedFingerprints).count }

    var summary: HealthSummary {
        KeyHealth.summary(items: items, leakedFingerprints: leakedFingerprints, policy: policy)
    }

    var attentionCount: Int { summary.needRotation + summary.expiring }

    func status(of item: VaultItem) -> KeyStatus {
        KeyHealth.status(of: item, leaked: leakedFingerprints.contains(item.fingerprint), policy: policy)
    }

    func profile(of finding: Finding) -> KeyProfile { KeyCatalog.profile(ruleID: finding.ruleID, preview: finding.preview) }

    func profile(of item: VaultItem) -> KeyProfile { KeyCatalog.profile(service: item.service, preview: item.preview) }

    /// Leaked keys by severity, for the one-line summary above the list.
    var leakSeverityCounts: [(severity: KeySeverity, count: Int)] {
        var worst: [String: KeySeverity] = [:]
        for finding in leakFindings { worst[finding.fingerprint] = max(worst[finding.fingerprint] ?? .low, profile(of: finding).severity) }
        return KeySeverity.allCases.sorted(by: >).compactMap { level in
            let count = worst.values.filter { $0 == level }.count
            return count > 0 ? (level, count) : nil
        }
    }

    func storedItem(for finding: Finding) -> VaultItem? { items.first { $0.fingerprint == finding.fingerprint } }

    func rotationURL(forService service: String) -> URL? {
        detector.rules.first { $0.service == service }?.rotationURL.flatMap(URL.init(string:))
    }

    /// Where "Rotate" should go for a stored key: the page saved with it, or the provider's usual one.
    func rotationURL(for item: VaultItem) -> URL? {
        RotationLink.url(from: item.rotationURL) ?? rotationURL(forService: item.service)
    }

    /// For a leak: the saved page if this key is in the safe, otherwise the provider's usual one.
    func rotationURL(for finding: Finding) -> URL? {
        storedItem(for: finding).flatMap { rotationURL(for: $0) } ?? rotationURL(forService: finding.service)
    }

    /// The most serious key that is currently leaked, if any. Drives the menu bar icon's colour.
    var worstLeakSeverity: KeySeverity? { leakFindings.map { profile(of: $0).severity }.max() }

    var safeFileURL: URL { dataDirectory.appendingPathComponent("safe.json") }

    /// Items sorted so the ones needing action come first.
    var sortedItems: [VaultItem] {
        func rank(_ status: KeyStatus) -> Int {
            switch status {
            case .leaked: return 0
            case .expired, .overdue: return 1
            case .expiring, .dueSoon: return 2
            case .healthy: return 3
            }
        }
        return items.sorted {
            let a = rank(status(of: $0)), b = rank(status(of: $1))
            return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - The safe

    func createSafe(password: String, useTouchID: Bool) throws {
        let url = dataDirectory.appendingPathComponent("safe.json")
        let created = try Vault.create(at: url, password: password, salt: settings.installSalt)
        if useTouchID {
            // Not fatal if this fails: the master password always works.
            try? created.enableEnclaveUnlock(password: password, enclave: SecureEnclaveKeyProvider())
        }
        vault = created
        refreshVault()
    }

    func setTouchID(_ enabled: Bool, password: String) throws {
        guard let vault else { throw AppError.noSafe }
        if enabled {
            try vault.enableEnclaveUnlock(password: password, enclave: SecureEnclaveKeyProvider())
        } else {
            guard vault.verify(password: password) else { throw VaultError.wrongPassword }
            try vault.disableEnclaveUnlock()
        }
        refreshVault()
    }

    func changePassword(from old: String, to new: String) throws {
        guard let vault else { throw AppError.noSafe }
        try vault.changePassword(from: old, to: new)
    }

    /// What a pasted value looks like, without storing anything.
    func inspect(_ raw: String) -> CaptureCandidate? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        // Accept `NAME=value` as well as a bare value.
        if let assignment = detector.envAssignments(in: text).first ?? assignmentWithKnownShape(text) {
            let service = detector.identify(assignment.value)?.service ?? "API key"
            return CaptureCandidate(value: assignment.value, service: service,
                                    suggestedName: Self.readableName(fromEnvName: assignment.name), suggestedEnvName: assignment.name)
        }
        if let rule = detector.identify(text) {
            return CaptureCandidate(value: text, service: rule.service, suggestedName: rule.service, suggestedEnvName: nil)
        }
        guard text.count >= 12, !text.contains(" ") else { return nil }
        return CaptureCandidate(value: text, service: "API key", suggestedName: "", suggestedEnvName: nil)
    }

    private func assignmentWithKnownShape(_ text: String) -> EnvAssignment? {
        guard let equals = text.firstIndex(of: "=") else { return nil }
        let name = String(text[..<equals]).replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
        let value = String(text[text.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil, detector.identify(value) != nil else { return nil }
        return EnvAssignment(name: name, value: value)
    }

    static func readableName(fromEnvName name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
            .replacingOccurrences(of: "Api", with: "API").replacingOccurrences(of: "Id", with: "ID")
    }

    @discardableResult
    func addKey(name: String, value: String, service: String, envName: String?, expiresAt: Date?, rotationURL: String? = nil) throws -> VaultItem {
        guard let vault else { throw AppError.noSafe }
        guard canAddKey else { throw AppError.needsLicence }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let item = try vault.add(name: trimmedName.isEmpty ? service : trimmedName,
                                 value: value.trimmingCharacters(in: .whitespacesAndNewlines),
                                 service: service, envName: envName?.isEmpty == true ? nil : envName, expiresAt: expiresAt,
                                 rotationURL: RotationLink.url(from: rotationURL)?.absoluteString)
        refreshVault()
        return item
    }

    func update(_ id: UUID, _ change: (inout VaultItem) -> Void) {
        try? vault?.update(id, change)
        refreshVault()
    }

    func delete(_ id: UUID) {
        try? vault?.delete(id)
        revealed[id] = nil
        refreshVault()
    }

    /// Replace a key's value after rotating it at the provider. Every leaked copy of the
    /// old value is now harmless, so those findings are closed.
    func rotate(_ id: UUID, newValue: String) throws {
        guard let vault, let old = items.first(where: { $0.id == id }) else { throw AppError.noSafe }
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard vault.fingerprint(of: value) != old.fingerprint else { throw AppError.message("That is the same key. Paste the new one from the provider.") }
        try vault.replaceValue(of: id, with: value)
        revealed[id] = nil
        refreshVault()
        markRotated(fingerprint: old.fingerprint)
        toast = "\(old.name) rotated. Old copies are marked harmless."
    }

    func copy(_ item: VaultItem, asEnvLine: Bool = false) {
        Task {
            guard let value = await value(of: item, reason: "copy \(item.name)") else { return }
            let text = asEnvLine ? "\(item.envName ?? item.name.uppercased().replacingOccurrences(of: " ", with: "_"))=\(value)" : value
            ClipboardService.copySecret(text)
            lastClipboardChange = NSPasteboard.general.changeCount
            toast = "Copied \(item.name). The clipboard clears in 30 seconds."
        }
    }

    func reveal(_ item: VaultItem) {
        Task {
            guard let value = await value(of: item, reason: "show \(item.name)") else { return }
            revealed[item.id] = value
            // A revealed key is visible to anything that can see the screen. Keep it brief.
            try? await Task.sleep(for: .seconds(12))
            revealed[item.id] = nil
        }
    }

    func hide(_ id: UUID) { revealed[id] = nil }

    /// Gets a value out of the safe. This is the only path, and it always goes through
    /// Touch ID or the master password.
    private func value(of item: VaultItem, reason: String) async -> String? {
        guard let vault else { return nil }
        return await unlocked(reason: reason) { method in try vault.reveal(item.id, using: method) }
    }

    /// Runs `work` with Touch ID, and with the master password if Touch ID does not open
    /// the safe. That second path matters: the Secure Enclave key belongs to this Mac and
    /// this build of the app, so after moving to a new Mac or a differently signed build
    /// the fingerprint alone may stop working. The master password always does.
    private func unlocked<T: Sendable>(reason: String, _ work: @escaping @Sendable (UnlockMethod) throws -> T) async -> T? {
        guard let vault else { return nil }
        if vault.hasEnclaveUnlock {
            let enclave = UnlockMethod.enclave(SecureEnclaveKeyProvider(), reason: reason)
            if let result = try? await Task.detached(priority: .userInitiated, operation: { try work(enclave) }).value {
                return result
            }
        }
        let prompt = vault.hasEnclaveUnlock
            ? "Touch ID did not open the safe. Enter your master password to \(reason)."
            : "Enter your master password to \(reason)."
        guard let password = await askPassword(reason: prompt) else { return nil }
        do {
            return try await Task.detached(priority: .userInitiated) { try work(.password(password)) }.value
        } catch VaultError.wrongPassword {
            toast = "Wrong master password."
        } catch {
            toast = "Could not open the safe."
        }
        return nil
    }

    func askPassword(reason: String) async -> String? {
        onOpenSafe?()
        return await withCheckedContinuation { continuation in
            passwordRequest = PasswordRequest(reason: reason) { continuation.resume(returning: $0) }
        }
    }

    private func refreshVault() {
        items = vault?.items ?? []
        hasSafe = vault != nil
        touchIDEnabled = vault?.hasEnclaveUnlock ?? false
    }

    // MARK: - Scanning

    func grantFolderAccess() {
        guard let bookmark = access.request() else { return }
        settings.homeBookmark = bookmark
        saveSettings()
        hasFolderAccess = access.isGranted
        restartWatching()
        restartRunBroker()
    }

    func adoptFolder(_ url: URL) {
        guard let bookmark = access.adopt(url) else { return }
        settings.homeBookmark = bookmark
        saveSettings()
        hasFolderAccess = access.isGranted
        restartWatching()
        restartRunBroker()
    }

    func scanNow(fromScratch: Bool = false) {
        guard hasFolderAccess, !isScanning, !isDemo else { return }
        activity = .running(label: "Starting", files: 0)
        scanCancelled.set(false)
        let sources = sources
        let coordinator = coordinator
        let cancelled = scanCancelled
        scanQueue.async { [weak self] in
            if fromScratch { coordinator.resetState() }
            let report = coordinator.runFullScan(sources: sources, progress: { label, files in
                Task { @MainActor in
                    if self?.isScanning == true { self?.activity = .running(label: label, files: files) }
                }
            }, isCancelled: { cancelled.value })
            let snapshot = coordinator.store.findings
            Task { @MainActor in
                guard let self else { return }
                self.findings = snapshot
                self.activity = .idle
                self.settings.lastScan = Date()
                self.settings.hasCompletedSetup = true
                self.saveSettings()
                let fresh = report.newFindings.filter { $0.status == .open && $0.kind.isLeak }
                if !fresh.isEmpty { self.announce(fresh, live: false) }
            }
        }
    }

    func cancelScan() { scanCancelled.set(true) }

    private func restartWatching() {
        watcher?.stop()
        watcher = nil
        guard !isDemo, hasFolderAccess, settings.watchEnabled, isLicensed else { return }
        let fm = FileManager.default
        let roots = SourceCatalog.watchRoots(home: Paths.realHome).filter { fm.fileExists(atPath: $0.path) }.map(\.path)
        let sources = sources
        let coordinator = coordinator
        let watcher = FileWatcher { [weak self] paths in
            // Runs on the watcher's queue; hop to the scan queue so findings stay consistent.
            self?.scanQueue.async {
                var fresh: [Finding] = []
                for path in Set(paths) { fresh.append(contentsOf: coordinator.fileChanged(URL(fileURLWithPath: path), sources: sources)) }
                guard !fresh.isEmpty else { return }
                let snapshot = coordinator.store.findings
                Task { @MainActor in
                    self?.findings = snapshot
                    // A new key in a .env file is ordinary work, not an alarm.
                    self?.announce(fresh.filter { $0.status == .open && $0.kind.isLeak }, live: true)
                }
            }
        }
        watcher.start(paths: roots)
        self.watcher = watcher
    }

    private func announce(_ fresh: [Finding], live: Bool) {
        guard let first = fresh.first else { return }
        let secrets = Set(fresh.map(\.fingerprint)).count
        let title = secrets == 1 ? "\(first.service) key leaked" : "\(secrets) keys leaked"
        let place = secrets == 1 ? "Found in \(first.sourceLabel.lowercased())." : "Found in \(Set(fresh.map(\.sourceLabel)).count) places."
        let stored = storedItem(for: first).map { " It is your \($0.name)." } ?? ""
        let detail = place + (secrets == 1 ? stored : "") + " Rotate it."
        if live {
            alert = LeakAlert(title: title, detail: detail)
            Notifier.send(title: title, body: detail)
        }
    }

    func setStatus(_ status: FindingStatus, for finding: Finding, allCopies: Bool = true) {
        let coordinator = coordinator
        scanQueue.async { [weak self] in
            if allCopies { coordinator.store.setStatus(status, forFingerprint: finding.fingerprint) }
            else { coordinator.store.setStatus(status, for: finding.id) }
            let snapshot = coordinator.store.findings
            Task { @MainActor in self?.findings = snapshot }
        }
    }

    private func markRotated(fingerprint: String) {
        let coordinator = coordinator
        scanQueue.async { [weak self] in
            coordinator.store.setStatus(.rotated, forFingerprint: fingerprint)
            let snapshot = coordinator.store.findings
            Task { @MainActor in self?.findings = snapshot }
        }
    }

    /// Removes leaked copies from transcripts and shell history. Files that use the key
    /// (configs, .env files) are never touched; the report says what was left and why.
    func removeLocalCopies(of targets: [Finding]) {
        guard isLicensed else { licencePrompt = true; return }
        guard !isRemoving, !targets.isEmpty else { return }
        isRemoving = true
        let coordinator = coordinator
        let sources = sources
        scanQueue.async { [weak self] in
            let report = coordinator.removeLocalCopies(of: targets, sources: sources)
            let snapshot = coordinator.store.findings
            Task { @MainActor in
                self?.findings = snapshot
                self?.lastRemoval = report
                self?.isRemoving = false
            }
        }
    }

    /// Every open leak. Used by "Remove all local copies".
    func removeAllLocalCopies() {
        removeLocalCopies(of: leakFindings.filter { $0.localCopyRemovedAt == nil })
    }

    /// Whether exact file locations may be shown.
    func requireLicence() -> Bool {
        if isLicensed { return true }
        licencePrompt = true
        return false
    }

    // MARK: - Commands asking for keys (agentsafe run)

    private var runRequestsFolder: URL { RunHandoff.requestsFolder(home: Paths.realHome) }
    private var runResponsesFolder: URL { RunHandoff.responsesFolder(home: Paths.realHome) }

    /// The helper binary inside this app, for the "install" instructions.
    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentsafe").path }

    /// Watches the folder where the `agentsafe` command leaves its requests.
    private func restartRunBroker() {
        runWatcher?.stop()
        runWatcher = nil
        guard !isDemo, hasFolderAccess else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: runRequestsFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: runResponsesFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let watcher = FileWatcher { [weak self] _ in
            Task { @MainActor in self?.checkForRunRequests() }
        }
        watcher.start(paths: [runRequestsFolder.path], latency: 0.2)
        runWatcher = watcher
        checkForRunRequests()
    }

    /// Picks up the next waiting request, one at a time.
    private func checkForRunRequests() {
        let fm = FileManager.default
        // The command gave up (timed out or was stopped): take its prompt down.
        if let pending = pendingRun, !fm.fileExists(atPath: runRequestsFolder.appendingPathComponent("\(pending.request.id).json").path) {
            try? fm.removeItem(at: RunHandoff.seenMarker(for: pending.request.id, home: Paths.realHome))
            pendingRun = nil
        }
        guard pendingRun == nil else { return }
        let files = ((try? fm.contentsOfDirectory(at: runRequestsFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let data = try? Data(contentsOf: file), let request = try? RunHandoff.decoder.decode(RunRequest.self, from: data) else {
                try? fm.removeItem(at: file)   // not something the helper wrote
                continue
            }
            do {
                try RunHandoff.validate(request)
            } catch {
                // Stale or malformed: drop it without prompting. The helper has given up or will time out.
                try? fm.removeItem(at: file)
                continue
            }
            guard let vault else {
                reply(RunHandoff.failure(request, message: "Set up your safe in AgentSafe first."), to: request)
                continue
            }
            // Tell the helper its request arrived and the user is being asked.
            try? Data().write(to: RunHandoff.seenMarker(for: request.id, home: Paths.realHome))
            pendingRun = PendingRun(request: request, plan: vault.resolve(request.references))
            return
        }
    }

    private func reply(_ response: RunResponse, to request: RunRequest) {
        if let data = try? RunHandoff.encoder.encode(response) {
            try? SecureFile.write(data, to: runResponsesFolder.appendingPathComponent("\(request.id).json"))
        }
        try? FileManager.default.removeItem(at: runRequestsFolder.appendingPathComponent("\(request.id).json"))
    }

    /// Releases the keys to the waiting command, after Touch ID.
    func approveRun() {
        guard let pending = pendingRun, let vault, pending.plan.canProceed else { return }
        Task {
            let count = pending.plan.matched.count
            let response = await unlocked(reason: "give \(count) \(count == 1 ? "key" : "keys") to “\(pending.commandLine.prefix(60))”") { method in
                try RunHandoff.approve(pending.request, plan: pending.plan, vault: vault, using: method)
            }
            // No answer from Touch ID or the password prompt counts as a refusal.
            reply(response ?? RunHandoff.deny(pending.request, message: "Not approved in AgentSafe."), to: pending.request)
            pendingRun = nil
            checkForRunRequests()
        }
    }

    func denyRun() {
        guard let pending = pendingRun else { return }
        var message = "Denied in AgentSafe."
        if !pending.plan.canProceed {
            var parts: [String] = []
            if !pending.plan.missing.isEmpty { parts.append("not in your safe: \(pending.plan.missing.joined(separator: ", "))") }
            if !pending.plan.notAllowed.isEmpty {
                parts.append("not switched on for commands: \(pending.plan.notAllowed.map(\.envName).joined(separator: ", "))")
            }
            message = "AgentSafe could not give these keys (" + parts.joined(separator: "; ") + "). Store each key under its variable name and switch on \"Commands may use this key\"."
        }
        reply(RunHandoff.failure(pending.request, message: message), to: pending.request)
        pendingRun = nil
        checkForRunRequests()
    }

    /// Lets a key be requested by `agentsafe run`, or stops that.
    func setAllowRun(_ allowed: Bool, for id: UUID) {
        update(id) { $0.allowRun = allowed ? true : nil }
    }

    /// Called when the Touch ID check for opening the safe window is cancelled, so that
    /// anything waiting on that window (a password prompt) is released instead of hanging.
    func safeWindowRefused() {
        passwordRequest?.reply(nil)
        passwordRequest = nil
    }

    // MARK: - Rotation reminders

    /// One notification when keys are due, repeated at most every three days. A reminder
    /// that fires daily gets switched off, and then it protects nobody.
    private func remindIfDue(now: Date = Date()) {
        guard isLicensed, !isDemo else { return }
        if let last = settings.lastReminder, now.timeIntervalSince(last) < 3 * 86_400 { return }
        let due = items.filter {
            switch status(of: $0) {
            case .overdue, .expired, .dueSoon, .expiring: return true
            case .healthy, .leaked: return false
            }
        }
        guard let first = due.first else { return }
        let title = due.count == 1 ? "1 key needs rotating" : "\(due.count) keys need rotating"
        let body = due.count == 1 ? "\(first.name): \(status(of: first).shortText.lowercased())." : "Starting with \(first.name). Open AgentSafe to see them."
        Notifier.send(title: title, body: body)
        settings.lastReminder = now
        saveSettings()
    }

    // MARK: - Clipboard capture

    func restartClipboardWatch() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        guard settings.clipboardWatch, !isDemo else { return }
        lastClipboardChange = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
    }

    private func checkClipboard() {
        let count = NSPasteboard.general.changeCount
        guard count != lastClipboardChange else { return }
        lastClipboardChange = count
        guard hasSafe, let text = ClipboardService.currentString(), text.count < 600,
              let found = inspect(text), found.service != "API key" || text.contains("=") else { return }
        // Already in the safe? Then this is just the user copying their own key.
        if let vault, vault.item(matchingFingerprint: vault.fingerprint(of: found.value)) != nil { return }
        candidate = found
    }

    // MARK: - Hardening

    var claudeSettingsURL: URL { Paths.realHome.appendingPathComponent(".claude/settings.json") }

    func hardeningPlan() -> Result<HardeningPlan, Error> {
        // Screenshots use made-up data only, so they never reflect this Mac's real settings.
        let existing = isDemo ? nil : try? Data(contentsOf: claudeSettingsURL)
        return Result { try ClaudeHardening.plan(existing: existing) }
    }

    func applyHardening() throws -> Int {
        let plan = try hardeningPlan().get()
        guard !plan.added.isEmpty else { return 0 }
        try FileManager.default.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plan.result.write(to: claudeSettingsURL, options: .atomic)
        return plan.added.count
    }

    // MARK: - Backup

    func exportBackup(backupPassword: String) async throws -> Data {
        guard let vault else { throw AppError.noSafe }
        guard backupPassword.count >= Vault.minimumPasswordLength else { throw VaultError.passwordTooShort }
        let exported = await unlocked(reason: "export an encrypted backup") { method in
            try Backup.export(try vault.revealAll(using: method), password: backupPassword)
        }
        guard let exported else { throw AppError.message("The safe was not unlocked.") }
        return exported
    }

    func importBackup(_ data: Data, backupPassword: String) throws -> (added: Int, skipped: Int) {
        guard let vault else { throw AppError.noSafe }
        let entries = try Backup.read(data, password: backupPassword)
        if !isLicensed, items.count + entries.count > Self.freeKeyLimit { throw AppError.needsLicence }
        let result = try vault.restore(entries)
        refreshVault()
        return result
    }

    // MARK: - Licence and settings

    func activate(licenseKey: String) throws {
        let verified = try LicenseVerifier.verify(licenseKey, publicKey: Self.licensePublicKey)
        license = verified
        settings.licenseKey = licenseKey.components(separatedBy: .whitespacesAndNewlines).joined()
        saveSettings()
        restartWatching()
    }

    func setWatchEnabled(_ enabled: Bool) {
        settings.watchEnabled = enabled
        saveSettings()
        restartWatching()
    }

    func setPlacement(_ placement: Placement) {
        settings.placement = placement
        saveSettings()
        onPlacementChange?()
    }

    func setOpenOnHover(_ enabled: Bool) {
        settings.openOnHover = enabled
        saveSettings()
    }

    func setClipboardWatch(_ enabled: Bool) {
        settings.clipboardWatch = enabled
        saveSettings()
        restartClipboardWatch()
    }

    func saveSettings() {
        guard !isDemo, let data = try? JSONEncoder().encode(settings) else { return }
        try? SecureFile.write(data, to: dataDirectory.appendingPathComponent("settings.json"))
    }

    // MARK: - Demo data (screenshots and previews only)

    func loadDemo(findings demoFindings: [Finding], license demoLicense: License?) {
        findings = demoFindings
        license = demoLicense
        hasFolderAccess = true
        settings.lastScan = Date().addingTimeInterval(-240)
        settings.hasCompletedSetup = true
    }
}

/// A yes/no value that is safe to read from one thread while another sets it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        stored = newValue
    }
}
