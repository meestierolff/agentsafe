import AgentSafeCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var notch: NotchController?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var modelChanges: AnyCancellable?
    private var runChanges: AnyCancellable?
    private var approvalWindow: NSWindow?
    /// True only while the safe window is open after a successful owner check.
    private var safeUnlocked = false
    private var ownerCheckInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)  // the Aqua look is a light look
        installMainMenu()
        model.onOpenSafe = { [weak self] in self?.showSafe() }
        installStatusItem()
        let notch = NotchController(model: model)
        notch.anchor = { [weak self] in self?.statusItem?.button?.window?.frame }
        self.notch = notch
        notch.apply(model.settings.placement)
        model.onPlacementChange = { [weak self] in
            guard let self else { return }
            self.notch?.apply(self.model.settings.placement)
        }
        // Keep the menu bar icon's lamp and count in step with the model.
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshStatusItem() }
        }
        refreshStatusItem()
        // A command asking for keys gets its own small window, separate from the safe.
        runChanges = model.$pendingRun.receive(on: DispatchQueue.main).sink { [weak self] pending in
            self?.showApproval(for: pending)
        }
        // Close the safe when the Mac sleeps or the screen locks, so it is locked on return.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.window?.close() }
            }
        }
        model.start()
        if !model.hasSafe { showSafe() }
    }

    /// A folder dropped on the app icon, or opened with AgentSafe from Finder, grants access to it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            model.adoptFolder(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The only way the safe window is ever shown. Once a safe exists, it asks macOS to
    /// confirm the owner (Touch ID) every time, so an agent that can click "Open safe"
    /// still cannot get in. First-run setup has nothing to protect yet and skips the check.
    func showSafe() {
        notch?.close()
        if safeUnlocked || !model.hasSafe {
            presentSafe()
            return
        }
        guard !ownerCheckInProgress else { return }
        ownerCheckInProgress = true
        OwnerCheck.confirm(reason: "open your safe") { [weak self] confirmed in
            guard let self else { return }
            self.ownerCheckInProgress = false
            if confirmed {
                self.safeUnlocked = true
                self.presentSafe()
            } else {
                self.model.safeWindowRefused()
            }
        }
    }

    private func presentSafe() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "AgentSafe"
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.contentView = NSHostingView(rootView: SafeRootView(model: model))
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the safe locks it: the next open asks for Touch ID again.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === window {
            safeUnlocked = false
        } else if closing === approvalWindow, model.pendingRun != nil {
            model.denyRun()   // closing the prompt is a refusal, never an approval
        }
    }

    /// Shows or hides the prompt for a command that is asking for keys.
    private func showApproval(for pending: PendingRun?) {
        guard let pending else {
            approvalWindow?.orderOut(nil)
            return
        }
        if approvalWindow == nil {
            let created = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "AgentSafe"
            created.isReleasedWhenClosed = false
            created.isFloatingPanel = true
            created.level = .floating
            created.delegate = self
            approvalWindow = created
        }
        approvalWindow?.contentView = NSHostingView(rootView: RunApprovalView(model: model, pending: pending))
        approvalWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        approvalWindow?.makeKeyAndOrderFront(nil)
    }

    // Without an Edit menu, ⌘V and ⌘C do nothing in text fields, even in a menu-bar-only app.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit AgentSafe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// The menu bar icon. macOS places it with the other icons at the right of the menu
    /// bar, which is where the panel opens from unless the notch position is chosen.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.image(.clear)
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu.addItem(withTitle: "Open Safe", action: #selector(openSafe), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Scan Now", action: #selector(scanNow), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit AgentSafe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem = item
    }

    /// The shield's outline shows the state: green, orange when a key has leaked, red when
    /// a leaked key is serious. The numbers live in the tooltip, so colour is never the only signal.
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let leaks = model.openLeakCount
        let due = model.attentionCount
        button.image = StatusIcon.image(StatusIcon.Tone(worstLeak: model.worstLeakSeverity))
        button.attributedTitle = NSAttributedString(string: "")
        var parts: [String] = []
        if leaks > 0 { parts.append("\(leaks) leaked \(leaks == 1 ? "key" : "keys")") }
        if due > 0 { parts.append("\(due) \(due == 1 ? "key" : "keys") to rotate") }
        let summary = parts.isEmpty ? "AgentSafe: nothing leaked" : "AgentSafe: " + parts.joined(separator: ", ")
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu, let item = statusItem {
            // Attach the menu just for this click, so a plain click stays free for the panel.
            item.menu = statusMenu
            item.button?.performClick(nil)
            item.menu = nil
        } else if model.settings.placement == .menuBar {
            notch?.toggle()
        } else {
            showSafe()
        }
    }

    @objc private func openSafe() { showSafe() }
    @objc private func scanNow() { model.scanNow() }
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
    MainActor.assumeIsolated { Snapshot.run(outputDirectory: URL(fileURLWithPath: arguments[index + 1])) }
    exit(0)
}
if arguments.contains("--scan-summary") {
    ScanSummary.run()
    exit(0)
}
if arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon: it lives in the notch
app.run()
