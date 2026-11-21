import AgentSafeCore
import AppKit
import SwiftUI

/// A borderless panel that can take keyboard focus (for pasting a key) without
/// bringing the whole app forward or stealing focus from the app you are working in.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct NotchGeometry: Equatable {
    /// Size of the black area that must stay black: the hardware notch, or a drawn one.
    var notch: CGSize
    var hasHardwareNotch: Bool
    /// Extra width on each side of the notch for the status lamp and the counter.
    var ear: CGFloat = 46

    var collapsed: CGSize { CGSize(width: notch.width + ear * 2, height: notch.height) }
    var expanded: CGSize { CGSize(width: max(collapsed.width, 580), height: notch.height + 386) }

    static func current(for screen: NSScreen?) -> NotchGeometry {
        guard let screen else { return NotchGeometry(notch: CGSize(width: 185, height: 32), hasHardwareNotch: false) }
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(notch: CGSize(width: width, height: screen.safeAreaInsets.top), hasHardwareNotch: true)
        }
        // No notch on this display: draw one the height of the menu bar.
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(notch: CGSize(width: 180, height: menuBar), hasHardwareNotch: false)
    }
}

@MainActor
final class NotchController: ObservableObject {
    @Published var expanded = false
    @Published private(set) var geometry: NotchGeometry
    @Published private(set) var placement: Placement = .menuBar

    private let panel: NotchPanel
    private let model: AppModel
    private var collapseWork: DispatchWorkItem?
    private var observers: [Any] = []
    private var clickMonitor: Any?
    /// True while the panel is open after a successful owner check. Cleared when it closes.
    private var unlocked = false
    private var ownerCheckInProgress = false
    /// While true the panel stays open even when the pointer leaves (the user is typing).
    var isPinned: () -> Bool = { false }
    /// Where the menu bar icon is on screen, so the panel can drop down from under it.
    var anchor: () -> CGRect? = { nil }

    static let panelSize = CGSize(width: 580, height: 398)

    init(model: AppModel) {
        self.model = model
        geometry = NotchGeometry.current(for: Self.targetScreen())
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar, so it can sit over the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        let host = NSHostingView(rootView: NotchRootView(model: model, controller: self))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.relayout() }
            })
        // A click anywhere outside the panel closes it. (Clicks inside are not "global".)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expanded, self.model.passwordRequest == nil else { return }
                self.close()
            }
        }
    }

    /// Prefer the display that has a real notch.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Shows the panel in its resting state for the chosen position: a small strip over
    /// the notch, or nothing at all when it lives behind the menu bar icon.
    func apply(_ placement: Placement) {
        collapseWork?.cancel()
        expanded = false
        self.placement = placement
        relayout()
        if placement == .notch { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    func relayout() {
        geometry = NotchGeometry.current(for: Self.targetScreen())
        applyFrame(expanded: expanded)
    }

    private func applyFrame(expanded: Bool) {
        switch placement {
        case .notch:
            guard let screen = Self.targetScreen() else { return }
            let size = expanded ? geometry.expanded : geometry.collapsed
            let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
        case .menuBar:
            let size = Self.panelSize
            let icon = anchor()
            let screen = NSScreen.screens.first { screen in icon.map { screen.frame.intersects($0) } ?? false } ?? NSScreen.main
            guard let screen else { return }
            let top = (icon?.minY ?? screen.visibleFrame.maxY) - 4
            let centre = icon?.midX ?? screen.frame.maxX - size.width / 2 - 12
            // Centred under the icon, but never hanging off the edge of the screen.
            let x = min(max(centre - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
            panel.setFrame(CGRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        }
    }

    func toggle() { if expanded { close() } else { open() } }

    /// Opens the panel. Once a safe exists this always asks macOS to confirm the owner
    /// first (Touch ID), because the panel shows key names and takes pasted keys. Only a
    /// deliberate click calls this: alerts, hovering and the clipboard never do, so the
    /// prompt cannot appear at a moment the user did not choose.
    func open() {
        guard !expanded else { return }
        if unlocked || !model.hasSafe {
            present()
            return
        }
        guard !ownerCheckInProgress else { return }
        ownerCheckInProgress = true
        OwnerCheck.confirm(reason: "open AgentSafe") { [weak self] confirmed in
            guard let self else { return }
            self.ownerCheckInProgress = false
            guard confirmed else { return }
            self.unlocked = true
            self.present()
        }
    }

    private func present() {
        collapseWork?.cancel()
        guard !expanded else { return }
        // Size and place the window first, then let the content animate into it.
        applyFrame(expanded: true)
        if placement == .menuBar { panel.orderFrontRegardless() }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { expanded = true }
    }

    func close(after delay: TimeInterval = 0) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Hover events can arrive out of order; trust where the pointer really is.
            if delay > 0, self.panel.frame.contains(NSEvent.mouseLocation) || self.isPinned() { return }
            withAnimation(.easeOut(duration: 0.18)) { self.expanded = false }
            self.unlocked = false   // closing locks it: the next open asks again
            self.panel.resignKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.expanded else { return }
                if self.placement == .menuBar { self.panel.orderOut(nil) } else { self.applyFrame(expanded: false) }
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func focusForTyping() { panel.makeKey() }
}

// MARK: - Views

struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(bottomLeadingRadius: bottomRadius, bottomTrailingRadius: bottomRadius).path(in: rect)
    }
}

struct NotchRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: NotchController

    var body: some View {
        Group {
            if controller.placement == .menuBar { dropDown } else { notch }
        }
        // A live leak does not open the panel by itself: the icon turns red and a
        // notification is sent. Opening is always a click followed by Touch ID.
    }

    /// Menu bar position: a panel that drops down from under the icon when it is clicked.
    private var dropDown: some View {
        ZStack {
            if controller.expanded {
                RoundedRectangle(cornerRadius: 20).fill(.black)
                NotchExpandedView(model: model, controller: controller)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Notch position: a strip over the notch that grows into the panel.
    private var notch: some View {
        let geometry = controller.geometry
        let size = controller.expanded ? geometry.expanded : geometry.collapsed
        return ZStack(alignment: .top) {
            NotchShape(bottomRadius: controller.expanded ? 22 : 10).fill(.black)
            if controller.expanded {
                NotchExpandedView(model: model, controller: controller)
                    .padding(.top, geometry.notch.height + 2)
                    .padding([.horizontal, .bottom], 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                NotchCollapsedView(model: model, geometry: geometry)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.open() }
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // No opening on hover: a passing pointer, or an agent moving it, must not bring up
        // the Touch ID prompt.
    }
}

/// What sits beside the notch all day: one lamp, one number.
struct NotchCollapsedView: View {
    @ObservedObject var model: AppModel
    var geometry: NotchGeometry

    private var tone: Color {
        if model.openLeakCount > 0 { return Aqua.lcdRed }
        if model.attentionCount > 0 { return Aqua.lcdAmber }
        return Aqua.lcdGreen
    }

    private var count: Int { model.openLeakCount > 0 ? model.openLeakCount : model.attentionCount }

    var body: some View {
        HStack(spacing: 0) {
            StatusLamp(color: tone, size: 8)
                .frame(width: geometry.ear)
            Spacer(minLength: geometry.notch.width)
            Group {
                if model.isScanning {
                    ProgressView().controlSize(.mini).colorScheme(.dark)
                } else if count > 0 {
                    Text("\(count)").font(Aqua.mono(12, bold: true)).foregroundStyle(tone).shadow(color: tone.opacity(0.8), radius: 3)
                }
            }
            .frame(width: geometry.ear)
        }
        .frame(height: geometry.notch.height)
    }
}

struct NotchExpandedView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: NotchController
    @State private var pasted = ""
    @State private var name = ""
    @State private var link = ""
    @FocusState private var pasteFocused: Bool

    private var draft: CaptureCandidate? { model.candidate ?? model.inspect(pasted) }

    var body: some View {
        VStack(spacing: 9) {
            LCDStrip(segments: lcdSegments, trailing: lcdTrailing)

            if let alert = model.alert {
                AlertBanner(alert: alert, onOpen: { model.selectedTab = .leaks; model.onOpenSafe?() }, onDismiss: { model.alert = nil })
            }

            if !model.hasSafe {
                SetupPrompt(model: model)
            } else {
                captureRow
                keyList
            }

            footer
        }
        .padding(11)
        .background(
            BrushedMetal()
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.9), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        )
        .onAppear { controller.isPinned = { !pasted.isEmpty || model.candidate != nil || model.passwordRequest != nil } }
        .onExitCommand { controller.close() }
    }

    private var lcdSegments: [LCDSegment] {
        let leaks = model.openLeakCount
        let due = model.attentionCount
        return [
            LCDSegment(value: "\(leaks)", label: leaks == 1 ? "LEAK" : "LEAKS", tone: leaks > 0 ? .alarm : .calm),
            LCDSegment(value: "\(model.items.count)", label: model.items.count == 1 ? "KEY" : "KEYS"),
            LCDSegment(value: "\(due)", label: "TO ROTATE", tone: due > 0 ? .warn : .calm),
        ]
    }

    private var lcdTrailing: String {
        if case .running(_, let files) = model.activity { return "SCANNING \(files)" }
        if !model.hasFolderAccess { return "NO ACCESS" }
        if model.isLicensed, model.settings.watchEnabled { return "WATCHING" }
        if let last = model.settings.lastScan { return "SCANNED " + Self.ago(last) }
        return "NOT SCANNED"
    }

    static func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "NOW" }
        if minutes < 60 { return "\(minutes)M AGO" }
        if minutes < 1_440 { return "\(minutes / 60)H AGO" }
        return "\(minutes / 1_440)D AGO"
    }

    @ViewBuilder
    private var captureRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                if let draft {
                    Text(draft.service).font(Aqua.font(11, bold: true)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Aqua.blueDeep))
                    Text(Redactor.preview(draft.value)).font(Aqua.mono(11.5)).foregroundStyle(Aqua.ink)
                    TextField(draft.suggestedName.isEmpty ? "Name this key" : draft.suggestedName, text: $name)
                        .textFieldStyle(AquaFieldStyle())
                        .onSubmit { save(draft) }
                    Button("Save to safe") { save(draft) }.buttonStyle(.gelSmallPrimary)
                    Button("Cancel") { reset() }.buttonStyle(.gelSmall)
                } else {
                    TextField("Paste a new key here (⌘V)", text: $pasted)
                        .textFieldStyle(AquaFieldStyle())
                        .focused($pasteFocused)
                        .onTapGesture { controller.focusForTyping(); pasteFocused = true }
                }
            }
            if let draft {
                // Asked for at the moment of saving, while the page is still open in the browser.
                HStack(spacing: 7) {
                    Text("Where did you create it?").font(Aqua.font(11)).foregroundStyle(Aqua.ink)
                    TextField(model.rotationURL(forService: draft.service)?.absoluteString ?? "Paste the page address, https://…", text: $link)
                        .textFieldStyle(AquaFieldStyle())
                        .onSubmit { save(draft) }
                }
                Text(link.isEmpty ? "Paste the page's address so Rotate can take you straight back. Leave empty to use the provider's usual page."
                     : (RotationLink.url(from: link) == nil ? "That is not an https address, so it will not be saved." : "Rotate will open this page."))
                    .font(Aqua.font(10.5)).foregroundStyle(Aqua.inkSoft).frame(maxWidth: .infinity, alignment: .leading)
            }
            if draft == nil, !pasted.isEmpty {
                Text("That does not look like a key. Paste the value on its own, or as NAME=value.")
                    .font(Aqua.font(10.5)).foregroundStyle(Aqua.inkSoft).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var keyList: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                Text("Your safe is empty. Paste a key above to store it.")
                    .font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft)
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.sortedItems.enumerated()), id: \.element.id) { index, item in
                            NotchKeyRow(model: model, item: item)
                                .background(index.isMultiple(of: 2) ? Color.white : Aqua.rowTint)
                        }
                    }
                }
                .frame(height: draft == nil ? 190 : 132)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isScanning {
                Button("Stop scan") { model.cancelScan() }.buttonStyle(.gelSmall)
            } else {
                Button("Scan now") {
                    if model.hasFolderAccess { model.scanNow() } else { model.onOpenSafe?() }
                }.buttonStyle(.gelSmall)
            }
            Button("Open safe") { model.onOpenSafe?() }.buttonStyle(.gelSmall)
            Spacer()
            if let toast = model.toast {
                Text(toast).font(Aqua.font(10.5)).foregroundStyle(Aqua.ink).lineLimit(2).multilineTextAlignment(.trailing)
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(6))
                        if model.toast == toast { model.toast = nil }
                    }
            } else {
                Text(model.touchIDEnabled ? "Copying needs Touch ID" : "Copying needs your master password")
                    .font(Aqua.font(10.5)).foregroundStyle(Aqua.inkSoft)
            }
        }
    }

    private func save(_ draft: CaptureCandidate) {
        do {
            try model.addKey(name: name.isEmpty ? draft.suggestedName : name, value: draft.value, service: draft.service,
                             envName: draft.suggestedEnvName, expiresAt: nil, rotationURL: link)
            // The key was on the clipboard a moment ago. Take it off.
            if ClipboardService.currentString()?.contains(draft.value) == true { NSPasteboard.general.clearContents() }
            model.toast = "Saved. The clipboard was cleared."
            reset()
        } catch VaultError.duplicate {
            model.toast = "That key is already in your safe."
            reset()
        } catch {
            model.toast = error.localizedDescription
            if case AppError.needsLicence = error { model.selectedTab = .settings; model.onOpenSafe?() }
        }
    }

    private func reset() {
        pasted = ""
        name = ""
        link = ""
        model.candidate = nil
    }
}

struct NotchKeyRow: View {
    @ObservedObject var model: AppModel
    var item: VaultItem

    var body: some View {
        let status = model.status(of: item)
        HStack(spacing: 8) {
            StatusLamp(color: status.color, size: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Aqua.font(12, bold: true)).foregroundStyle(Aqua.ink).lineLimit(1)
                Text(status.shortText).font(Aqua.font(10)).foregroundStyle(status.needsAttention ? status.color : Aqua.inkSoft)
            }
            Spacer(minLength: 6)
            Text(item.preview).font(Aqua.mono(10.5)).foregroundStyle(Aqua.inkSoft).lineLimit(1)
            Button("Copy") { model.copy(item) }.buttonStyle(.gelSmall)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
    }
}

struct AlertBanner: View {
    var alert: LeakAlert
    var onOpen: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            StatusLamp(color: Aqua.lcdRed, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(Aqua.font(12.5, bold: true)).foregroundStyle(.white)
                Text(alert.detail).font(Aqua.font(11)).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Show") { onOpen() }.buttonStyle(.gelSmall)
            Button("Dismiss") { onDismiss() }.buttonStyle(.gelSmall)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [Color(red: 0.86, green: 0.25, blue: 0.20), Color(red: 0.60, green: 0.09, blue: 0.07)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.black.opacity(0.45), lineWidth: 1))
        )
    }
}

struct SetupPrompt: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 9) {
            Text("Keep your API keys where agents cannot read them")
                .font(Aqua.font(14, bold: true)).foregroundStyle(Aqua.ink)
            Text("Set a master password, let AgentSafe look where agents leave keys, and see what has already leaked.")
                .font(Aqua.font(11.5)).foregroundStyle(Aqua.inkSoft).multilineTextAlignment(.center).frame(maxWidth: 400)
            Button("Set up AgentSafe") { model.onOpenSafe?() }.buttonStyle(.gelPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 226)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.55)))
    }
}

// MARK: - Status wording shared by the notch and the safe window

extension KeyStatus {
    var color: Color {
        switch self {
        case .healthy: return Aqua.ok
        case .dueSoon, .expiring: return Aqua.warn
        case .overdue, .expired, .leaked: return Aqua.danger
        }
    }

    var shortText: String {
        switch self {
        case .healthy(let days): return "Rotate in \(days) \(days == 1 ? "day" : "days")"
        case .dueSoon(let days): return days == 0 ? "Rotate today" : "Rotate within \(days) \(days == 1 ? "day" : "days")"
        case .overdue(let days): return "Rotation \(days) \(days == 1 ? "day" : "days") overdue"
        case .expiring(let days): return days == 0 ? "Expires today" : "Expires in \(days) \(days == 1 ? "day" : "days")"
        case .expired(let days): return "Expired \(days) \(days == 1 ? "day" : "days") ago"
        case .leaked: return "Leaked. Rotate now"
        }
    }
}
