import AgentSafeCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SafeTab: String, CaseIterable, Identifiable {
    case keys = "Keys"
    case leaks = "Leaks"
    case harden = "Harden agents"
    case backup = "Backup"
    case settings = "Settings"
    var id: String { rawValue }
}

struct SafeRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.black.opacity(0.35))
            ZStack {
                Pinstripes()
                if model.safeUnreadable {
                    UnreadableSafeView(model: model)
                } else if !model.hasSafe || !model.hasFolderAccess && !model.settings.hasCompletedSetup {
                    SetupView(model: model)
                } else {
                    Group {
                        switch model.selectedTab {
                        case .keys: KeysView(model: model)
                        case .leaks: LeaksView(model: model)
                        case .harden: HardenView(model: model)
                        case .backup: BackupView(model: model)
                        case .settings: SettingsView(model: model)
                        }
                    }
                    .padding(16)
                }
            }
            if let toast = model.toast {
                Text(toast).font(Aqua.font(11.5)).foregroundStyle(Aqua.ink)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 1.0, green: 0.97, blue: 0.80))
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(.black.opacity(0.2)), alignment: .top)
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(7))
                        if model.toast == toast { model.toast = nil }
                    }
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .sheet(item: $model.passwordRequest) { request in
            PasswordSheet(request: request) { model.passwordRequest = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                SafeGlyph().frame(width: 30, height: 30)
                Text("AgentSafe").font(Aqua.font(17, bold: true)).foregroundStyle(Aqua.ink)
                    .shadow(color: .white.opacity(0.8), radius: 0, x: 0, y: 1)
                Spacer()
                LCDStrip(segments: [
                    LCDSegment(value: "\(model.openLeakCount)", label: model.openLeakCount == 1 ? "LEAK" : "LEAKS", tone: model.openLeakCount > 0 ? .alarm : .calm),
                    LCDSegment(value: "\(model.items.count)", label: model.items.count == 1 ? "KEY" : "KEYS"),
                    LCDSegment(value: "\(model.attentionCount)", label: "TO ROTATE", tone: model.attentionCount > 0 ? .warn : .calm),
                    LCDSegment(value: "\(model.exposedCount)", label: "IN .ENV", tone: model.exposedCount > 0 ? .warn : .calm),
                ], height: 30)
                .frame(width: 470)
            }
            if model.hasSafe {
                HStack(spacing: 6) {
                    ForEach(SafeTab.allCases) { tab in
                        Button(tab.rawValue) { model.selectedTab = tab }
                            .buttonStyle(GelButtonStyle(kind: model.selectedTab == tab ? .primary : .plain))
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 11)
        .background(BrushedMetal())
    }
}

/// The app mark: a brushed-metal safe door with a blue gel combination dial. Drawn in code.
struct SafeGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = max(0.75, side * 0.018)
            ZStack {
                // Door
                RoundedRectangle(cornerRadius: side * 0.22)
                    .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: side * 0.22).strokeBorder(.black.opacity(0.45), lineWidth: line))
                RoundedRectangle(cornerRadius: side * 0.16)
                    .strokeBorder(LinearGradient(colors: [.black.opacity(0.22), .white.opacity(0.75)], startPoint: .top, endPoint: .bottom), lineWidth: line)
                    .padding(side * 0.075)
                // Dial
                Circle()
                    .fill(RadialGradient(colors: [Aqua.blueLight, Aqua.blue, Aqua.blueDeep], center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: side * 0.40))
                    .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: line))
                    .padding(side * 0.19)
                // Tick marks around the dial
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(.white.opacity(i % 3 == 0 ? 0.95 : 0.6))
                        .frame(width: side * 0.022, height: side * (i % 3 == 0 ? 0.07 : 0.045))
                        .offset(y: -side * 0.245).rotationEffect(.degrees(Double(i) * 30))
                }
                // Gel highlight
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: side * 0.36, height: side * 0.17).offset(y: -side * 0.155)
                // Three-spoke handle
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(.black.opacity(0.35), lineWidth: line * 0.7))
                        .frame(width: side * 0.07, height: side * 0.19)
                        .offset(y: -side * 0.085).rotationEffect(.degrees(Double(i) * 120))
                }
                Circle().fill(RadialGradient(colors: [.white, Color(white: 0.70)], center: UnitPoint(x: 0.4, y: 0.3), startRadius: 0, endRadius: side * 0.08))
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: line * 0.7))
                    .frame(width: side * 0.15, height: side * 0.15)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - First run

struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var password = ""
    @State private var confirm = ""
    @State private var useTouchID = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.hasSafe ? "One more step" : "Set up your safe")
                .font(Aqua.font(20, bold: true)).foregroundStyle(Aqua.ink)

            if !model.hasSafe {
                AquaBox(title: "1. Choose a master password") {
                    Text("It opens your safe if Touch ID is unavailable, and it protects your backups. AgentSafe cannot recover it for you, so write it down somewhere offline.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    SecureField("Master password, at least \(Vault.minimumPasswordLength) characters", text: $password).textFieldStyle(AquaFieldStyle())
                    SecureField("Type it again", text: $confirm).textFieldStyle(AquaFieldStyle())
                    Toggle("Use Touch ID to copy or show keys", isOn: $useTouchID).font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    if let error { Text(error).font(Aqua.font(11.5)).foregroundStyle(Aqua.danger) }
                    Button("Create safe") { create() }.buttonStyle(.gelPrimary)
                }
            } else {
                AquaBox(title: "2. Let AgentSafe look for leaked keys") {
                    Text("AgentSafe needs to read your home folder to check agent transcripts, agent configs, shell history and .env files. macOS will ask you to choose the folder. The app has no network access, so nothing it reads can leave this Mac.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Choose home folder") {
                            model.grantFolderAccess()
                            if model.hasFolderAccess { model.selectedTab = .leaks; model.scanNow() }
                        }.buttonStyle(.gelPrimary)
                        Button("Skip for now") { model.settings.hasCompletedSetup = true; model.saveSettings() }.buttonStyle(.gel)
                    }
                }
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func create() {
        guard password == confirm else { error = "The two passwords are different."; return }
        do {
            try model.createSafe(password: password, useTouchID: useTouchID)
            password = ""; confirm = ""; error = nil
            if model.hasFolderAccess { model.settings.hasCompletedSetup = true; model.saveSettings(); model.scanNow() }
        } catch VaultError.passwordTooShort {
            error = "Use at least \(Vault.minimumPasswordLength) characters."
        } catch VaultError.alreadyExists {
            error = "A safe file already exists, so nothing was created. Quit and reopen AgentSafe."
        } catch {
            self.error = "Could not create the safe: \(error.localizedDescription)"
        }
    }
}

/// Shown instead of setup when a safe file exists but cannot be read.
struct UnreadableSafeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AgentSafe could not read your safe").font(Aqua.font(20, bold: true)).foregroundStyle(Aqua.ink)
            AquaBox(title: nil) {
                Text("The safe file is still on your Mac and has not been changed. AgentSafe will not create a new one over it.")
                    .aquaBody().fixedSize(horizontal: false, vertical: true)
                Text("This usually means the file was written by a newer version of the app, or was damaged. Install the latest version first. If that does not help, move the file somewhere safe, restart AgentSafe, set up a new safe and restore your keys from a backup.")
                    .aquaBody().fixedSize(horizontal: false, vertical: true)
                Text(Paths.display(model.safeFileURL.path)).font(Aqua.mono(11)).foregroundStyle(Aqua.ink).textSelection(.enabled)
                Button("Show the file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.safeFileURL]) }.buttonStyle(.gel)
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PasswordSheet: View {
    var request: PasswordRequest
    var dismiss: () -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Master password").font(Aqua.font(14, bold: true)).foregroundStyle(Aqua.ink)
            Text(request.reason).aquaBody()
            SecureField("Master password", text: $password).textFieldStyle(AquaFieldStyle()).onSubmit { finish(password) }
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.buttonStyle(.gel)
                Button("Unlock") { finish(password) }.buttonStyle(.gelPrimary)
            }
        }
        .padding(20).frame(width: 380)
        .background(Pinstripes())
    }

    private func finish(_ value: String?) {
        request.reply(value?.isEmpty == true ? nil : value)
        dismiss()
    }
}

// MARK: - Keys

struct KeysView: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?
    @State private var adding = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    if model.items.isEmpty {
                        Text("No keys yet.\nAdd one here, or paste it into the notch.")
                            .font(Aqua.font(12)).foregroundStyle(Aqua.inkSoft).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(model.sortedItems.enumerated()), id: \.element.id) { index, item in
                                    KeyListRow(item: item, status: model.status(of: item), selected: selection == item.id)
                                        .background(selection == item.id ? Aqua.blue : (index.isMultiple(of: 2) ? Color.white : Aqua.rowTint))
                                        .contentShape(Rectangle())
                                        .onTapGesture { selection = item.id; adding = false }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Color.white)
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))

                HStack {
                    Button("Add key") { adding = true; selection = nil }.buttonStyle(.gelPrimary)
                    Spacer()
                    if !model.isLicensed {
                        Text("\(model.items.count) of \(AppModel.freeKeyLimit) free").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft)
                    }
                }
            }
            .frame(width: 300)

            Group {
                if adding {
                    AddKeyView(model: model) { added in adding = false; selection = added }
                } else if let item = model.items.first(where: { $0.id == selection }) {
                    ScrollView { KeyDetailView(model: model, item: item) { selection = nil }.id(item.id) }
                } else {
                    AquaBox(title: nil) {
                        Text("Select a key to copy, show or rotate it.").aquaBody()
                        Text("Key names and dates are visible without unlocking. The values are encrypted, and getting one out always takes \(model.touchIDEnabled ? "Touch ID" : "your master password").")
                            .aquaBody().fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { if selection == nil { selection = model.sortedItems.first?.id } }
    }
}

struct KeyListRow: View {
    var item: VaultItem
    var status: KeyStatus
    var selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            StatusLamp(color: status.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Aqua.font(12.5, bold: true)).foregroundStyle(selected ? .white : Aqua.ink).lineLimit(1)
                Text(status.shortText).font(Aqua.font(10.5))
                    .foregroundStyle(selected ? .white.opacity(0.9) : (status.needsAttention ? status.color : Aqua.inkSoft))
            }
            Spacer()
            Text(item.service).font(Aqua.font(10.5)).foregroundStyle(selected ? .white.opacity(0.85) : Aqua.inkSoft)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct AddKeyView: View {
    @ObservedObject var model: AppModel
    var done: (UUID?) -> Void
    @State private var value = ""
    @State private var name = ""
    @State private var envName = ""
    @State private var link = ""
    @State private var hasExpiry = false
    @State private var expiry = Date().addingTimeInterval(90 * 86_400)
    @State private var error: String?

    private var draft: CaptureCandidate? { model.inspect(value) }

    var body: some View {
        AquaBox(title: "Add a key") {
            SecureField("Paste the key (or NAME=value)", text: $value).textFieldStyle(AquaFieldStyle())
            if let draft {
                Text("Looks like: \(draft.service)  \(Redactor.preview(draft.value))").font(Aqua.font(11.5)).foregroundStyle(Aqua.ok)
            } else if !value.isEmpty {
                Text("That does not look like a key yet.").font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft)
            }
            TextField(draft?.suggestedName.isEmpty == false ? draft!.suggestedName : "Name, for example “OpenAI production”", text: $name).textFieldStyle(AquaFieldStyle())
            TextField(draft?.suggestedEnvName ?? "Variable name (optional), for example OPENAI_API_KEY", text: $envName).textFieldStyle(AquaFieldStyle())
            TextField(draft.flatMap { model.rotationURL(forService: $0.service)?.absoluteString } ?? "Page where you manage this key (optional), https://…", text: $link)
                .textFieldStyle(AquaFieldStyle())
            Text("Paste the address of the page you got this key from. \"Rotate\" will take you straight back there. Leave it empty to use the provider's usual page.")
                .font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)
            if !link.isEmpty, RotationLink.url(from: link) == nil {
                Text("That is not an https address, so it will not be saved.").font(Aqua.font(11)).foregroundStyle(Aqua.warn)
            }
            Toggle("This key has an expiry date", isOn: $hasExpiry).font(Aqua.font(12)).foregroundStyle(Aqua.ink)
            if hasExpiry { DatePicker("Expires", selection: $expiry, displayedComponents: .date).font(Aqua.font(12)) }
            if let error { Text(error).font(Aqua.font(11.5)).foregroundStyle(Aqua.danger) }
            HStack {
                Button("Save to safe") { save() }.buttonStyle(.gelPrimary).disabled(draft == nil)
                Button("Cancel") { done(nil) }.buttonStyle(.gel)
            }
        }
    }

    private func save() {
        guard let draft else { return }
        do {
            let item = try model.addKey(name: name.isEmpty ? draft.suggestedName : name, value: draft.value, service: draft.service,
                                        envName: envName.isEmpty ? draft.suggestedEnvName : envName, expiresAt: hasExpiry ? expiry : nil,
                                        rotationURL: link)
            done(item.id)
        } catch VaultError.duplicate {
            error = "That key is already in your safe."
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct KeyDetailView: View {
    @ObservedObject var model: AppModel
    var item: VaultItem
    var onDelete: () -> Void
    @State private var rotating = false
    @State private var newValue = ""
    @State private var rotateError: String?
    @State private var confirmingDelete = false
    @State private var link = ""
    @State private var linkNote: String?

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()

    var body: some View {
        let status = model.status(of: item)
        VStack(alignment: .leading, spacing: 12) {
            AquaBox(title: nil) {
                HStack(spacing: 9) {
                    StatusLamp(color: status.color, size: 12)
                    Text(item.name).font(Aqua.font(17, bold: true)).foregroundStyle(Aqua.ink)
                    Spacer()
                    Text(item.service).font(Aqua.font(12)).foregroundStyle(Aqua.inkSoft)
                }
                HStack(spacing: 8) {
                    Text(status.shortText).font(Aqua.font(12, bold: true)).foregroundStyle(status.color)
                    ProfileChips(profile: model.profile(of: item))
                }
                Text(model.profile(of: item).summary).font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(model.revealed[item.id] ?? item.preview)
                        .font(Aqua.mono(12)).foregroundStyle(Aqua.ink).textSelection(.disabled)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.25))))
                }
                HStack(spacing: 7) {
                    Button("Copy") { model.copy(item) }.buttonStyle(.gelPrimary)
                    Button("Copy as NAME=value") { model.copy(item, asEnvLine: true) }.buttonStyle(.gel)
                    if model.revealed[item.id] == nil {
                        Button("Show for 12 seconds") { model.reveal(item) }.buttonStyle(.gel)
                    } else {
                        Button("Hide") { model.hide(item.id) }.buttonStyle(.gel)
                    }
                }
                if model.envFileCopies(of: item) > 0 {
                    let copies = model.envFileCopies(of: item)
                    Text("A copy of this key is also in \(copies) .env \(copies == 1 ? "file" : "files"), where any agent opened in that folder can read it. See Leaks.")
                        .font(Aqua.font(11)).foregroundStyle(Aqua.warn).fixedSize(horizontal: false, vertical: true)
                }
                if model.revealed[item.id] != nil {
                    Text("While a key is on screen, anything that can see your screen can read it, including a computer-use agent. Copy is safer than Show.")
                        .font(Aqua.font(11)).foregroundStyle(Aqua.warn).fixedSize(horizontal: false, vertical: true)
                }
            }

            AquaBox(title: "Rotation") {
                Text("Stored \(Self.dateFormat.string(from: item.createdAt)). Current value since \(Self.dateFormat.string(from: item.lastRotatedAt)).").aquaBody()
                HStack(spacing: 10) {
                    Text("Remind me to rotate every").font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    Picker("", selection: Binding(
                        get: { item.rotateAfterDays ?? model.policy.recommendedDays(for: item.service) },
                        set: { days in model.update(item.id) { $0.rotateAfterDays = days } })) {
                            ForEach([30, 60, 90, 180, 365], id: \.self) { Text("\($0) days").tag($0) }
                        }.labelsHidden().frame(width: 110)
                }
                HStack(spacing: 10) {
                    Toggle("Expires on", isOn: Binding(
                        get: { item.expiresAt != nil },
                        set: { on in model.update(item.id) { $0.expiresAt = on ? Date().addingTimeInterval(90 * 86_400) : nil } }))
                        .font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    if let expires = item.expiresAt {
                        DatePicker("", selection: Binding(get: { expires }, set: { date in model.update(item.id) { $0.expiresAt = date } }), displayedComponents: .date).labelsHidden()
                    }
                }
                HStack(spacing: 8) {
                    Text("Rotation page").font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    TextField(model.rotationURL(forService: item.service)?.absoluteString ?? "https://…", text: $link)
                        .textFieldStyle(AquaFieldStyle())
                        .onSubmit { saveLink() }
                    Button("Save") { saveLink() }.buttonStyle(.gelSmall)
                }
                if let linkNote { Text(linkNote).font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft) }
                if rotating {
                    Text("Create a new key at the provider, revoke the old one there, then paste the new one here.").aquaBody().fixedSize(horizontal: false, vertical: true)
                    SecureField("New key", text: $newValue).textFieldStyle(AquaFieldStyle())
                    if let rotateError { Text(rotateError).font(Aqua.font(11.5)).foregroundStyle(Aqua.danger) }
                    HStack {
                        Button("Replace key") { replace() }.buttonStyle(.gelPrimary).disabled(newValue.isEmpty)
                        Button("Cancel") { rotating = false; newValue = "" }.buttonStyle(.gel)
                    }
                } else {
                    HStack {
                        Button("Rotate this key") {
                            rotating = true
                            if let url = model.rotationURL(for: item) { NSWorkspace.shared.open(url) }
                        }.buttonStyle(status.needsAttention ? .gelPrimary : .gel)
                        if let url = model.rotationURL(for: item) {
                            Text("Opens \(url.host ?? "the key page") in your browser.").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft)
                        }
                    }
                }
            }

            AquaBox(title: "Commands") {
                Toggle("Commands may use this key through “agentsafe run”", isOn: Binding(
                    get: { item.allowRun == true }, set: { model.setAllowRun($0, for: item.id) }))
                    .font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                Text("Off by default. When on, a command started with agentsafe run can ask for this key, and you approve each request with Touch ID. The command that receives the key can read it, so only switch this on for keys your projects need to run.")
                    .font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if confirmingDelete {
                    Text("Delete “\(item.name)” from the safe?").font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    Button("Delete") { model.delete(item.id); onDelete() }.buttonStyle(.gelDanger)
                    Button("Keep") { confirmingDelete = false }.buttonStyle(.gel)
                } else {
                    Button("Delete key") { confirmingDelete = true }.buttonStyle(.gel)
                }
            }
        }
        .onAppear { link = item.rotationURL ?? "" }
    }

    private func saveLink() {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            model.update(item.id) { $0.rotationURL = nil }
            linkNote = "Using the provider's usual page."
        } else if let url = RotationLink.url(from: trimmed) {
            model.update(item.id) { $0.rotationURL = url.absoluteString }
            link = url.absoluteString
            linkNote = "Saved. Rotate will open this page."
        } else {
            linkNote = "Only https addresses can be saved."
        }
    }

    private func replace() {
        do {
            try model.rotate(item.id, newValue: newValue)
            rotating = false; newValue = ""; rotateError = nil
        } catch {
            rotateError = error.localizedDescription
        }
    }
}

// MARK: - Leaks

struct LeakGroup: Identifiable {
    let fingerprint: String
    var findings: [Finding]
    var profile: KeyProfile
    var id: String { fingerprint }
    var first: Finding { findings[0] }
    var status: FindingStatus { findings.contains { $0.status == .open } ? .open : first.status }
    /// Copies in transcripts and shell history that are still on disk.
    var removable: [Finding] { findings.filter { $0.kind.isRecord && $0.canScrub && $0.localCopyRemovedAt == nil } }
    var allCopiesRemoved: Bool { findings.allSatisfy { $0.localCopyRemovedAt != nil } }
}

extension KeySeverity {
    var colour: Color {
        switch self {
        case .critical: return Aqua.danger
        case .high: return Color(red: 0.88, green: 0.38, blue: 0.10)
        case .medium: return Aqua.warn
        case .low: return Aqua.inkSoft
        }
    }
}

/// A small coloured label: severity, or live versus sandbox.
struct Chip: View {
    var text: String
    var colour: Color

    var body: some View {
        Text(text).font(Aqua.font(10, bold: true)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(colour))
    }
}

struct ProfileChips: View {
    var profile: KeyProfile

    var body: some View {
        HStack(spacing: 5) {
            Chip(text: profile.severity.label, colour: profile.severity.colour)
            switch profile.environment {
            case .production: Chip(text: "Live", colour: Aqua.blueDeep)
            case .sandbox: Chip(text: "Sandbox", colour: Aqua.inkSoft)
            case .unknown: EmptyView()
            }
        }
    }
}

struct LeaksView: View {
    enum Section: String, CaseIterable, Identifiable {
        case leaked = "Leaked by agents"
        case exposed = "Sitting in .env files"
        var id: String { rawValue }
    }

    @ObservedObject var model: AppModel
    @State private var section: Section = .leaked
    @State private var expanded: Set<String> = []
    @State private var showResolved = false
    @State private var confirmingRemoveAll = false

    private func groups(for section: Section) -> [LeakGroup] {
        let leakedPrints = Set(model.findings.filter { $0.kind.isLeak }.map(\.fingerprint))
        let visible = model.findings.filter { finding in
            guard showResolved || finding.status == .open else { return false }
            // A key that leaked is shown once, under "leaked", with all its places.
            return section == .leaked ? leakedPrints.contains(finding.fingerprint) : !leakedPrints.contains(finding.fingerprint)
        }
        return Dictionary(grouping: visible, by: \.fingerprint)
            .map { print, findings -> LeakGroup in
                let sorted = findings.sorted { ($0.kind.isLeak ? 0 : 1, $0.path) < ($1.kind.isLeak ? 0 : 1, $1.path) }
                return LeakGroup(fingerprint: print, findings: sorted, profile: model.profile(of: sorted[0]))
            }
            // Open before resolved, then the most dangerous first, then the most widely spread.
            .sorted {
                ($0.status == .open ? 0 : 1, -$0.profile.severity.rawValue, -$0.findings.count, $0.first.service, $0.fingerprint)
                    < ($1.status == .open ? 0 : 1, -$1.profile.severity.rawValue, -$1.findings.count, $1.first.service, $1.fingerprint)
            }
    }

    var body: some View {
        let shown = groups(for: section)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if case .running(let label, let files) = model.activity {
                    ProgressView().controlSize(.small)
                    Text("Scanning \(label.lowercased()): \(files) files checked").font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    Button("Stop") { model.cancelScan() }.buttonStyle(.gel)
                } else if !model.hasFolderAccess {
                    Text("AgentSafe has not been allowed to read your home folder yet.").font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    Button("Choose home folder") { model.grantFolderAccess(); model.scanNow() }.buttonStyle(.gelPrimary)
                } else {
                    Button("Scan now") { model.scanNow() }.buttonStyle(.gelPrimary)
                    Button("Rescan everything") { model.scanNow(fromScratch: true) }.buttonStyle(.gel)
                    if let last = model.settings.lastScan {
                        Text("Last scan \(NotchExpandedView.ago(last).lowercased())").font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft)
                    }
                }
                Spacer()
                Toggle("Show rotated and ignored", isOn: $showResolved).font(Aqua.font(11.5)).foregroundStyle(Aqua.ink)
            }

            HStack(spacing: 6) {
                Button("\(Section.leaked.rawValue) (\(model.openLeakCount))") { section = .leaked }
                    .buttonStyle(GelButtonStyle(kind: section == .leaked ? .primary : .plain, compact: true))
                Button("\(Section.exposed.rawValue) (\(model.exposedCount))") { section = .exposed }
                    .buttonStyle(GelButtonStyle(kind: section == .exposed ? .primary : .plain, compact: true))
                Spacer()
                if section == .leaked, model.openLeakCount > 0 { removeAllControl }
            }

            if section == .leaked, model.openLeakCount > 0 { summaryLine }
            if model.licencePrompt, !model.isLicensed { LicencePrompt(model: model) }
            if let report = model.lastRemoval { RemovalSummary(report: report) { model.lastRemoval = nil } }

            Text(section == .leaked
                 ? "These are copies that should not exist. A key in an agent transcript was sent to the model provider, and anything running as you can read the file. Removing the local copy does not undo that. Rotating the key does."
                 : "These keys are in plaintext .env files. That is normal, but any agent you open in that folder can read them. Move the ones you care about into the safe, and use Harden agents to stop Claude Code reading .env files.")
                .font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)

            if shown.isEmpty {
                AquaBox(title: nil) {
                    HStack(spacing: 9) {
                        StatusLamp(color: Aqua.ok, size: 12)
                        Text(model.settings.lastScan == nil ? "Run a scan to see what your agents have left behind."
                             : (section == .leaked ? "No leaked keys found." : "No keys found in .env files."))
                            .font(Aqua.font(13, bold: true)).foregroundStyle(Aqua.ink)
                    }
                    if model.settings.lastScan != nil {
                        Text("Detection is by known key formats and .env variable names. A clean result is good news, not proof.").aquaBody()
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(shown) { group in
                            LeakCard(model: model, group: group, isLeak: section == .leaked, isExpanded: expanded.contains(group.id)) {
                                guard model.requireLicence() else { return }
                                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// "12 critical, 30 high": how bad the list is before reading it.
    private var summaryLine: some View {
        HStack(spacing: 6) {
            Text("\(model.openLeakCount) leaked \(model.openLeakCount == 1 ? "key" : "keys"), worst first:")
                .font(Aqua.font(12, bold: true)).foregroundStyle(Aqua.ink)
            ForEach(model.leakSeverityCounts, id: \.severity) { entry in
                Chip(text: "\(entry.count) \(entry.severity.label.lowercased())", colour: entry.severity.colour)
            }
        }
    }

    @ViewBuilder
    private var removeAllControl: some View {
        if model.isRemoving {
            ProgressView().controlSize(.small)
            Text("Removing copies").font(Aqua.font(11.5)).foregroundStyle(Aqua.ink)
        } else if confirmingRemoveAll {
            Text("Close your agent sessions first. Remove every copy from transcripts and shell history?").font(Aqua.font(11.5)).foregroundStyle(Aqua.ink)
            Button("Remove") { confirmingRemoveAll = false; model.removeAllLocalCopies() }.buttonStyle(GelButtonStyle(kind: .danger, compact: true))
            Button("Cancel") { confirmingRemoveAll = false }.buttonStyle(.gelSmall)
        } else {
            Button("Remove all local copies") {
                if model.requireLicence() { confirmingRemoveAll = true }
            }.buttonStyle(.gelSmallPrimary)
        }
    }
}

/// Explains what a licence adds, at the moment someone reaches for it.
struct LicencePrompt: View {
    @ObservedObject var model: AppModel

    var body: some View {
        AquaBox(title: "Pay once, keep your Mac safe forever") {
            Text("The scan and the rotation links are free, and rotating is the fix that matters. A licence adds the clean-up: the exact file and line of every copy, and one click to remove them all from your transcripts and shell history. It also unlocks unlimited keys in the safe and the always-on watch.")
                .aquaBody().fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Buy a licence") { NSWorkspace.shared.open(URL(string: "https://safeagent.live/#price")!) }.buttonStyle(.gelPrimary)
                Button("I have a licence key") { model.licencePrompt = false; model.selectedTab = .settings }.buttonStyle(.gel)
                Button("Not now") { model.licencePrompt = false }.buttonStyle(.gel)
            }
        }
    }
}

/// What "Remove local copies" did, including everything it deliberately left alone.
struct RemovalSummary: View {
    var report: RemovalReport
    var dismiss: () -> Void

    private func count(_ reason: RemovalReport.SkipReason) -> Int { report.skipped.filter { $0.reason == reason }.count }

    var body: some View {
        AquaBox(title: nil) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.copiesRemoved == 0 ? "No copies were removed."
                         : "Removed \(report.copiesRemoved) \(report.copiesRemoved == 1 ? "copy" : "copies") from \(report.removed.count) \(report.removed.count == 1 ? "file" : "files").")
                        .font(Aqua.font(12.5, bold: true)).foregroundStyle(Aqua.ink)
                    if count(.inUse) > 0 { line("\(count(.inUse)) left alone because the file uses the key (a config or .env file). Move those keys into the safe.") }
                    if count(.database) > 0 { line("\(count(.database)) left alone because the file is a database and cannot be edited safely.") }
                    if count(.recentlyModified) > 0 { line("\(count(.recentlyModified)) skipped because the file changed in the last two minutes, so an agent may still be writing to it. Try again later.") }
                    if count(.unreadable) + count(.notFound) > 0 { line("\(count(.unreadable) + count(.notFound)) could not be changed.") }
                    Text("The keys stay on this list until you mark them rotated: they were already sent to the model provider.")
                        .font(Aqua.font(11.5, bold: true)).foregroundStyle(Aqua.danger)
                }
                Spacer()
                Button("Dismiss") { dismiss() }.buttonStyle(.gelSmall)
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)
    }
}

struct LeakCard: View {
    @ObservedObject var model: AppModel
    var group: LeakGroup
    var isLeak: Bool
    var isExpanded: Bool
    var toggle: () -> Void

    var body: some View {
        let finding = group.first
        let stored = model.storedItem(for: finding)
        AquaBox(title: nil) {
            HStack(alignment: .top, spacing: 10) {
                StatusLamp(color: group.status != .open ? Aqua.ok : group.profile.severity.colour, size: 12).padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(stored?.name ?? finding.name ?? "\(finding.service) key").font(Aqua.font(13.5, bold: true)).foregroundStyle(Aqua.ink)
                        Text(finding.preview).font(Aqua.mono(11.5)).foregroundStyle(Aqua.inkSoft)
                        ProfileChips(profile: group.profile)
                        if group.status != .open {
                            Chip(text: group.status == .rotated ? "Rotated" : "Ignored", colour: Aqua.ok)
                        }
                    }
                    Text(group.profile.summary).font(Aqua.font(11.5)).foregroundStyle(Aqua.ink).fixedSize(horizontal: false, vertical: true)
                    Text(summary(stored: stored)).font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if group.status == .open {
                            if isLeak, let url = model.rotationURL(for: finding) {
                                Button("Open \(finding.service)") { NSWorkspace.shared.open(url) }.buttonStyle(.gelSmallPrimary)
                            }
                            Button("I rotated it") { model.setStatus(.rotated, for: finding) }.buttonStyle(.gelSmall)
                            if isLeak, !group.removable.isEmpty {
                                Button(group.removable.count == 1 ? "Remove local copy" : "Remove \(group.removable.count) local copies") {
                                    model.removeLocalCopies(of: group.removable)
                                }.buttonStyle(.gelSmall).disabled(model.isRemoving)
                            }
                            Button("Ignore") { model.setStatus(.ignored, for: finding) }.buttonStyle(.gelSmall)
                        } else {
                            Button("Reopen") { model.setStatus(.open, for: finding) }.buttonStyle(.gelSmall)
                        }
                        Button(isExpanded ? "Hide places" : "Show places") { toggle() }.buttonStyle(.gelSmall)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            if isExpanded, model.isLicensed {
                VStack(spacing: 0) {
                    ForEach(Array(group.findings.enumerated()), id: \.element.id) { index, place in
                        HStack(spacing: 8) {
                            Text(place.sourceLabel).font(Aqua.font(11, bold: true)).foregroundStyle(Aqua.ink).frame(width: 170, alignment: .leading)
                            Text("\(Paths.display(place.path)):\(place.line)").font(Aqua.mono(10.5)).foregroundStyle(Aqua.inkSoft)
                                .lineLimit(1).truncationMode(.middle).help(place.path)
                            Spacer()
                            if place.count > 1 { Text("×\(place.count)").font(Aqua.mono(10.5)).foregroundStyle(Aqua.inkSoft) }
                            if place.localCopyRemovedAt != nil {
                                Text("Copy removed").font(Aqua.font(10.5, bold: true)).foregroundStyle(Aqua.ok)
                            } else if !place.kind.isRecord {
                                Text("In use here: move it to the safe").font(Aqua.font(10.5)).foregroundStyle(Aqua.inkSoft)
                            } else if place.canScrub {
                                Button("Remove local copy") { model.removeLocalCopies(of: [place]) }.buttonStyle(.gelSmall).disabled(model.isRemoving)
                            } else {
                                Text("Database: rotate only").font(Aqua.font(10.5)).foregroundStyle(Aqua.inkSoft)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(index.isMultiple(of: 2) ? Color.white : Aqua.rowTint)
                    }
                }
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            }
        }
    }

    private func summary(stored: VaultItem?) -> String {
        let places = group.findings.count
        let kinds = Set(group.findings.map(\.sourceLabel)).sorted().joined(separator: ", ")
        var text = "Found in \(places) \(places == 1 ? "file" : "files"): \(kinds)."
        if stored != nil { text += " This is a key in your safe." }
        if group.status == .open, group.allCopiesRemoved { text += " The local copies are removed. It still needs rotating." }
        return text
    }
}

// MARK: - Harden

struct HardenView: View {
    @ObservedObject var model: AppModel
    @State private var result: String?

    var body: some View {
        ScrollView { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.hardeningPlan() {
            case .failure:
                AquaBox(title: "Claude Code") {
                    Text("Your Claude Code settings file could not be read as JSON, so AgentSafe will not change it. Fix the file at ~/.claude/settings.json and come back.").aquaBody()
                }
            case .success(let plan):
                AquaBox(title: "Stop Claude Code from reading secret files") {
                    Text("This adds deny rules to ~/.claude/settings.json. They apply in every project and cannot be overridden by a project's own allow rules.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(ClaudeHardening.rules.enumerated()), id: \.element.rule) { index, rule in
                            HStack {
                                StatusLamp(color: plan.alreadyPresent.contains(rule.rule) ? Aqua.ok : Aqua.warn, size: 8)
                                Text(rule.explanation).font(Aqua.font(11.5)).foregroundStyle(Aqua.ink).frame(width: 250, alignment: .leading)
                                Text(rule.rule).font(Aqua.mono(10.5)).foregroundStyle(Aqua.inkSoft)
                                Spacer()
                                Text(plan.alreadyPresent.contains(rule.rule) ? "In place" : "Will be added").font(Aqua.font(10.5)).foregroundStyle(Aqua.inkSoft)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(index.isMultiple(of: 2) ? Color.white : Aqua.rowTint)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                    HStack {
                        if plan.added.isEmpty {
                            Text("All \(plan.alreadyPresent.count) rules are in place.").font(Aqua.font(12, bold: true)).foregroundStyle(Aqua.ok)
                        } else {
                            Button("Add \(plan.added.count) \(plan.added.count == 1 ? "rule" : "rules")") { apply() }.buttonStyle(.gelPrimary)
                                .disabled(!model.hasFolderAccess)
                            if !model.hasFolderAccess { Text("Allow access to your home folder first (Leaks tab).").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft) }
                        }
                        if let result { Text(result).font(Aqua.font(11.5)).foregroundStyle(Aqua.ink) }
                    }
                }
                AquaBox(title: "What this does and does not do") {
                    Text("These rules block Claude Code's own file tools, and shell commands it recognises as reading a file, such as cat, head, tail and sed. Example files like .env.example stay readable.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    Text("They do not stop a script the agent writes from opening the file, or a recursive grep run from the same folder. Treat them as a seatbelt, not a lock: the stronger fix is to keep the key out of files altogether, in the safe.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    Text("The settings file is rewritten with its keys in alphabetical order. Nothing else in it is changed.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func apply() {
        do {
            let count = try model.applyHardening()
            result = "Added \(count) \(count == 1 ? "rule" : "rules"). New Claude Code sessions pick them up."
        } catch {
            result = "Could not write the settings file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Backup

struct BackupView: View {
    @ObservedObject var model: AppModel
    @State private var password = ""
    @State private var confirm = ""
    @State private var importPassword = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AquaBox(title: "Save an encrypted backup") {
                Text("Your keys exist only on this Mac. A backup is one encrypted file you can keep on a USB stick or in any cloud folder: without its password it shows nothing, not even key names.")
                    .aquaBody().fixedSize(horizontal: false, vertical: true)
                SecureField("Backup password, at least \(Vault.minimumPasswordLength) characters", text: $password).textFieldStyle(AquaFieldStyle()).frame(maxWidth: 380)
                SecureField("Type it again", text: $confirm).textFieldStyle(AquaFieldStyle()).frame(maxWidth: 380)
                Button(busy ? "Working" : "Save backup") { export() }.buttonStyle(.gelPrimary)
                    .disabled(busy || model.items.isEmpty || password.isEmpty)
                if model.items.isEmpty { Text("There is nothing to back up yet.").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft) }
            }
            AquaBox(title: "Restore from a backup") {
                Text("Keys already in the safe are skipped.").aquaBody()
                SecureField("Backup password", text: $importPassword).textFieldStyle(AquaFieldStyle()).frame(maxWidth: 380)
                Button("Choose backup file") { restore() }.buttonStyle(.gel).disabled(importPassword.isEmpty)
            }
            if let message { Text(message).font(Aqua.font(12)).foregroundStyle(Aqua.ink) }
            Spacer()
        }
    }

    private func export() {
        guard password == confirm else { message = "The two backup passwords are different."; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await model.exportBackup(backupPassword: password)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "AgentSafe \(Date().formatted(.iso8601.year().month().day())).\(Backup.fileExtension)"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                password = ""; confirm = ""
                message = "Backup saved to \(Paths.display(url.path))."
            } catch VaultError.passwordTooShort {
                message = "Use at least \(Vault.minimumPasswordLength) characters for the backup password."
            } catch {
                message = "Backup not saved: \(error.localizedDescription)"
            }
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            let result = try model.importBackup(data, backupPassword: importPassword)
            importPassword = ""
            message = "Restored \(result.added) \(result.added == 1 ? "key" : "keys"), skipped \(result.skipped) already present."
        } catch BackupError.wrongPassword {
            message = "Wrong backup password."
        } catch BackupError.notABackup {
            message = "That file is not an AgentSafe backup."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - A command asking for keys

/// The prompt shown when `agentsafe run` asks for keys. It names every key, because the
/// command line it shows is only what the requester claims to be running.
struct RunApprovalView: View {
    @ObservedObject var model: AppModel
    var pending: PendingRun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.plan.canProceed ? "A command wants to use your keys" : "A command asked for keys it cannot have")
                .font(Aqua.font(16, bold: true)).foregroundStyle(Aqua.ink)

            AquaBox(title: nil) {
                Text(pending.commandLine).font(Aqua.mono(12, bold: true)).foregroundStyle(Aqua.ink).lineLimit(3).textSelection(.enabled)
                Text("in \(Paths.display(pending.request.directory))").font(Aqua.mono(11)).foregroundStyle(Aqua.inkSoft).lineLimit(1).truncationMode(.middle)
            }

            // Shown before any fingerprint, so it lists only what the request itself named.
            // Which of your keys match stays hidden until you approve.
            VStack(spacing: 0) {
                if pending.plan.canProceed {
                    ForEach(Array(pending.plan.matched.enumerated()), id: \.element.envName) { index, match in
                        row(match.envName, profile: model.profile(of: match.item), tint: index)
                    }
                } else {
                    ForEach(pending.request.names, id: \.self) { name in
                        problemRow(name, "not available to commands")
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))

            if pending.plan.canProceed {
                Text("The command will be able to read these keys. AgentSafe cannot check what the command really is, so approve only something you started yourself a moment ago.")
                    .font(Aqua.font(11.5)).foregroundStyle(Aqua.ink).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Nothing was released. Each key must be in your safe under that variable name, with “Commands may use this key” switched on. Open the safe to check, then run the command again.")
                    .font(Aqua.font(11.5)).foregroundStyle(Aqua.ink).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if pending.plan.canProceed {
                    Button("Deny") { model.denyRun() }.buttonStyle(.gel)
                    Button("Approve with Touch ID") { model.approveRun() }.buttonStyle(.gelPrimary)
                } else {
                    Button("Close") { model.denyRun() }.buttonStyle(.gel)
                }
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(Pinstripes())
    }

    private func row(_ name: String, profile: KeyProfile, tint: Int) -> some View {
        HStack(spacing: 8) {
            Text(name).font(Aqua.mono(11.5, bold: true)).foregroundStyle(Aqua.ink)
            Spacer()
            ProfileChips(profile: profile)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(tint.isMultiple(of: 2) ? Color.white : Aqua.rowTint)
    }

    private func problemRow(_ name: String, _ reason: String) -> some View {
        HStack(spacing: 8) {
            StatusLamp(color: Aqua.danger, size: 8)
            Text(name).font(Aqua.mono(11.5, bold: true)).foregroundStyle(Aqua.ink)
            Text(reason).font(Aqua.font(11)).foregroundStyle(Aqua.danger)
            Spacer()
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.white)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var licenseText = ""
    @State private var licenseMessage: String?
    @State private var touchIDPassword = ""
    @State private var message: String?
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AquaBox(title: "Licence") {
                    if let license = model.license {
                        HStack(spacing: 8) {
                            StatusLamp(color: Aqua.ok, size: 11)
                            Text("Licensed\(license.email.map { " to \($0)" } ?? ""). Thank you.").font(Aqua.font(12.5, bold: true)).foregroundStyle(Aqua.ink)
                        }
                    } else {
                        Text("Free: the scan, what leaked and how serious it is, links to rotate each key, backups, and \(AppModel.freeKeyLimit) keys in the safe. A licence adds the exact location of every copy, one-click removal, unlimited keys, the always-on watch and rotation reminders. Pay once, keep your Mac safe forever.")
                            .aquaBody().fixedSize(horizontal: false, vertical: true)
                        HStack {
                            TextField("Paste your licence key", text: $licenseText).textFieldStyle(AquaFieldStyle())
                            Button("Activate") { activate() }.buttonStyle(.gelPrimary).disabled(licenseText.isEmpty)
                            Button("Buy a licence") { NSWorkspace.shared.open(URL(string: "https://safeagent.live/#price")!) }.buttonStyle(.gel)
                        }
                        if let licenseMessage { Text(licenseMessage).font(Aqua.font(11.5)).foregroundStyle(Aqua.danger) }
                    }
                }

                AquaBox(title: "Where it sits") {
                    Picker("", selection: Binding(get: { model.settings.placement }, set: { model.setPlacement($0) })) {
                        Text("Beside my menu bar icons").tag(Placement.menuBar)
                        Text("Over the notch").tag(Placement.notch)
                    }.pickerStyle(.radioGroup).labelsHidden().font(Aqua.font(12))
                    Text(model.settings.placement == .menuBar
                         ? "Click the shield icon in the menu bar to open the panel. Right-click it for the menu."
                         : "Click the strip over the notch to open the panel.")
                        .font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft)
                    Text("Opening it always asks for Touch ID. A leak alert turns the icon red and sends a notification; it never opens the panel by itself.")
                        .font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)
                }

                AquaBox(title: "Watching") {
                    Toggle("Watch for leaks all the time and alert me in the notch", isOn: Binding(get: { model.settings.watchEnabled }, set: { model.setWatchEnabled($0) }))
                        .font(Aqua.font(12)).foregroundStyle(Aqua.ink).disabled(!model.isLicensed)
                    if !model.isLicensed { Text("Needs a licence. Manual scans are always free.").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft) }
                    Toggle("Open AgentSafe when I log in", isOn: Binding(get: { launchAtLogin }, set: { LoginItem.set($0); launchAtLogin = LoginItem.isEnabled }))
                        .font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    Toggle("Offer to save a key when I copy one", isOn: Binding(get: { model.settings.clipboardWatch }, set: { model.setClipboardWatch($0) }))
                        .font(Aqua.font(12)).foregroundStyle(Aqua.ink)
                    Text("Off by default. When on, AgentSafe looks at what you copy to spot key formats, and macOS may ask you to allow that.").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft)
                }

                AquaBox(title: "Command line") {
                    Text("The agentsafe command starts a project with keys from the safe, so the project needs no .env file with real values. Run it from this app, or link it into a folder on your PATH:")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    Text("sudo ln -sf \"\(model.helperPath)\" /usr/local/bin/agentsafe")
                        .font(Aqua.mono(10.5)).foregroundStyle(Aqua.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy that command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("sudo ln -sf \"\(model.helperPath)\" /usr/local/bin/agentsafe", forType: .string)
                        }.buttonStyle(.gelSmall)
                        Text("Then, in a project: agentsafe init, and agentsafe run -- npm run dev").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft)
                    }
                    Text("The helper runs outside the app's sandbox, as any command-line tool does. It has no network code and never stores a key; it only passes requests to this app.")
                        .font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft).fixedSize(horizontal: false, vertical: true)
                }

                AquaBox(title: "Unlocking") {
                    Text(model.touchIDEnabled ? "Touch ID is on. Copying or showing a key asks for your fingerprint, or your Mac password when the sensor is unavailable."
                                              : "Touch ID is off. Copying or showing a key asks for your master password.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField("Master password", text: $touchIDPassword).textFieldStyle(AquaFieldStyle()).frame(maxWidth: 260)
                        Button(model.touchIDEnabled ? "Turn Touch ID off" : "Turn Touch ID on") { toggleTouchID() }.buttonStyle(.gel).disabled(touchIDPassword.isEmpty)
                    }
                    if let message { Text(message).font(Aqua.font(11.5)).foregroundStyle(Aqua.ink) }
                }

                AquaBox(title: "About") {
                    Text("AgentSafe runs in the macOS sandbox with no network permission, so it cannot send anything anywhere. You can check: run “codesign -d --entitlements - /Applications/AgentSafe.app” and look for the absence of a network entitlement.")
                        .aquaBody().fixedSize(horizontal: false, vertical: true)
                    Text("Because it cannot go online, it cannot check for updates either. New versions are at safeagent.live.").aquaBody()
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").font(Aqua.font(11)).foregroundStyle(Aqua.inkSoft)
                }
            }
        }
    }

    private func activate() {
        do {
            try model.activate(licenseKey: licenseText)
            licenseText = ""; licenseMessage = nil
        } catch {
            licenseMessage = "That licence key is not valid. Copy the whole key from your purchase page."
        }
    }

    private func toggleTouchID() {
        do {
            try model.setTouchID(!model.touchIDEnabled, password: touchIDPassword)
            touchIDPassword = ""
            message = model.touchIDEnabled ? "Touch ID is on." : "Touch ID is off."
        } catch VaultError.wrongPassword {
            message = "Wrong master password."
        } catch {
            message = "Could not change Touch ID: \(error.localizedDescription)"
        }
    }
}
