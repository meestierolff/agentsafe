import AppKit
import Foundation
import LocalAuthentication
import ServiceManagement
import UserNotifications

enum Paths {
    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()` points at the
    /// app's private container instead, so we ask the system account database.
    static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// Where AgentSafe keeps its own files. In the sandbox this is inside the container,
    /// which other apps (and agents running as you) cannot read without a system prompt.
    static var defaultDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSafe", isDirectory: true)
    }

    static func display(_ path: String) -> String {
        let home = realHome.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Permission to read the user's home folder, granted once through the system file dialog
/// and remembered as a security-scoped bookmark.
final class FolderAccess {
    private(set) var grantedURL: URL?

    var isGranted: Bool {
        if !Paths.isSandboxed { return true }  // development builds run unsandboxed
        return grantedURL != nil
    }

    /// Re-open access from a saved bookmark. Returns refreshed bookmark data if it had gone stale.
    func restore(from bookmark: Data?) -> Data? {
        guard Paths.isSandboxed, let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        grantedURL = url
        return stale ? try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
    }

    /// Shows the system dialog, opened on the home folder. Returns bookmark data to save.
    @MainActor
    func request() -> Data? {
        let panel = NSOpenPanel()
        panel.directoryURL = Paths.realHome
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = "Choose your home folder. AgentSafe reads agent transcripts, configs and .env files there to look for leaked keys. Nothing leaves your Mac."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return adopt(url)
    }

    /// Used when a folder arrives through Finder ("Open With" or a drop on the app icon).
    func adopt(_ url: URL) -> Data? {
        _ = url.startAccessingSecurityScopedResource()
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        grantedURL = url
        return data
    }

    /// True when the granted folder contains `path`.
    func covers(_ url: URL) -> Bool {
        guard Paths.isSandboxed else { return true }
        guard let granted = grantedURL?.path else { return false }
        return url.path == granted || url.path.hasPrefix(granted + "/")
    }
}

/// Tells us the moment a file changes under the folders agents write to.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void
    private let queue = DispatchQueue(label: "live.agentsafe.watcher")

    init(onChange: @escaping ([String]) -> Void) { self.onChange = onChange }

    /// - Parameter latency: how long to gather changes before reporting them.
    func start(paths: [String], latency: CFTimeInterval = 2.0) {
        stop()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            if count > 0 { watcher.onChange(changed) }
        }
        // A 2 second latency batches the burst of writes an agent makes per message.
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

enum ClipboardService {
    private static var clearTimer: Timer?

    /// Copies a secret so that well-behaved clipboard managers skip it, it does not sync
    /// to other devices, and it disappears on its own.
    @MainActor
    static func copySecret(_ value: String, clearAfter seconds: TimeInterval = 30) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        // Conventions from nspasteboard.org that clipboard managers honour.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.writeObjects([item])
        let changeCount = pasteboard.changeCount
        clearTimer?.invalidate()
        clearTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            // Only clear if the clipboard still holds what we put there.
            if NSPasteboard.general.changeCount == changeCount { NSPasteboard.general.clearContents() }
        }
    }

    @MainActor
    static func currentString() -> String? { NSPasteboard.general.string(forType: .string) }
}

enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AgentSafe: could not change login item: \(error.localizedDescription)")
        }
    }
}


/// Asks macOS to confirm that the person at the keyboard is the Mac's owner: Touch ID,
/// or the login password when no sensor is available. An agent driving the screen can
/// click a button, but it cannot put a finger on the sensor.
enum OwnerCheck {
    static func confirm(reason: String, completion: @escaping @MainActor (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No way to check on this Mac (no password set). Refuse rather than wave through.
            Task { @MainActor in completion(false) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            Task { @MainActor in completion(ok) }
        }
    }
}
