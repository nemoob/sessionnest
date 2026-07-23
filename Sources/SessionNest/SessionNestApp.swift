import AppKit
import CoreServices
import SwiftUI

final class CodexDataChangeMonitor: @unchecked Sendable {
    private let codexHomePath: String
    private let callback: @Sendable () -> Void
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "local.nemoob.sessionnest.codex-data-monitor")
    private var stream: FSEventStreamRef?

    init(
        codexHome: URL = LocalTokenScanTargetDiscovery.defaultCodexHome(),
        latency: CFTimeInterval = 1,
        callback: @escaping @Sendable () -> Void
    ) {
        codexHomePath = codexHome.standardizedFileURL.path
        self.latency = latency
        self.callback = callback
    }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: codexHomePath,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue
        else { return false }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, rawPaths, _, _ in
                    guard let info else { return }
                    let monitor = Unmanaged<CodexDataChangeMonitor>.fromOpaque(info)
                        .takeUnretainedValue()
                    let pathPointers = rawPaths.assumingMemoryBound(
                        to: UnsafePointer<CChar>?.self
                    )
                    let paths = (0..<count).compactMap { index in
                        pathPointers[index].map(String.init(cString:))
                    }
                    monitor.receive(paths)
                },
                &context,
                [codexHomePath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
            )
        else { return false }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    static func isRelevantChange(atPath path: String, codexHomePath: String) -> Bool {
        let home = URL(fileURLWithPath: codexHomePath).standardizedFileURL.path
        let changed = URL(fileURLWithPath: path).standardizedFileURL.path
        if changed == home {
            return true
        }
        let homePrefix = home + "/"
        guard changed.hasPrefix(homePrefix) else { return false }
        let relativePath = String(changed.dropFirst(homePrefix.count))
        if relativePath == "sessions" || relativePath.hasPrefix("sessions/") {
            return true
        }
        if relativePath == "archived_sessions"
            || relativePath.hasPrefix("archived_sessions/")
        {
            return true
        }
        return !relativePath.contains("/")
            && relativePath.hasPrefix("state_")
            && relativePath.contains(".sqlite")
    }

    private func receive(_ paths: [String]) {
        guard
            paths.contains(where: {
                Self.isRelevantChange(atPath: $0, codexHomePath: codexHomePath)
            })
        else { return }
        callback()
    }
}

enum SessionNestLaunchPreference {
    static let opensMainWindowKey = "sessionnest.launch.opensMainWindow"

    static func shouldOpenMainWindow(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: opensMainWindowKey)
    }
}

enum SessionNestPresentationTransition {
    case launch
    case openMainWindow
    case closeMainWindow

    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .launch, .closeMainWindow:
            .accessory
        case .openMainWindow:
            .regular
        }
    }
}

@MainActor
final class SessionNestAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: SessionListModel?
    private var startupError: String?
    private var statusItemController: SessionNestStatusItemController?
    private var mainWindowController: NSWindowController?
    private var updateChecker: AppUpdateChecker?
    private var codexDataChangeMonitor: CodexDataChangeMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shouldOpenMainWindow = SessionNestLaunchPreference.shouldOpenMainWindow()
        apply(.launch)
        prepareSession()

        let updateChecker = AppUpdateChecker.live()
        self.updateChecker = updateChecker
        let controller = SessionNestStatusItemController(
            model: model,
            updateChecker: updateChecker
        )
        statusItemController = controller
        controller.setOpenMainWindowAction { [weak self] in
            self?.openMainWindow()
        }
        controller.install()
        if shouldOpenMainWindow {
            openMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindowController?.window else { return }
        statusItemController?.setMainWindowVisible(false)
        apply(.closeMainWindow)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindowController?.window else { return }
        statusItemController?.setMainWindowVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindowController?.window else { return }
        statusItemController?.setMainWindowVisible(true)
    }

    private func prepareSession() {
        do {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            let databaseURL = try ApplicationSupportMigration.prepareDatabase(
                destinationURL:
                    applicationSupport
                    .appendingPathComponent("SessionNest", isDirectory: true)
                    .appendingPathComponent("manager.sqlite"),
                legacyURL:
                    applicationSupport
                    .appendingPathComponent("Codex Sessions", isDirectory: true)
                    .appendingPathComponent("manager.sqlite")
            )
            let store = try MetadataStore(databaseURL: databaseURL)
            let client = try CodexClient()
            let model = SessionListModel(
                client: client,
                store: store,
                browsingStateStore: SessionBrowsingStateStore()
            )
            self.model = model
            let monitor = CodexDataChangeMonitor { [weak model] in
                Task { @MainActor [weak model] in
                    model?.codexDataDidChange()
                }
            }
            if monitor.start() {
                model.enableCodexDataChangeMonitoring()
                codexDataChangeMonitor = monitor
            }
            startupError = nil
        } catch {
            model = nil
            codexDataChangeMonitor = nil
            startupError = error.localizedDescription
        }
    }

    private func openMainWindow() {
        apply(.openMainWindow)

        let controller = mainWindowController ?? makeMainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        statusItemController?.setMainWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainWindowController() -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SessionNest"
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SessionNestMainWindowContent(
                model: model,
                startupError: startupError
            )
        )
        window.center()
        return NSWindowController(window: window)
    }

    private func apply(_ transition: SessionNestPresentationTransition) {
        NSApp.setActivationPolicy(transition.activationPolicy)
    }
}

@main
struct SessionNestApp: App {
    @NSApplicationDelegateAdaptor(SessionNestAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private struct SessionNestMainWindowContent: View {
    let model: SessionListModel?
    let startupError: String?
    @AppStorage("sessionnest.theme") private var storedTheme = AppTheme.system.rawValue

    var body: some View {
        Group {
            if let model {
                SessionManagerView(model: model)
            } else {
                StartupErrorView(message: startupError ?? "未知启动错误")
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(AppTheme(storedValue: storedTheme).colorScheme)
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("无法启动 SessionNest", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text(message)
                Text("已检查以下 Codex CLI 路径：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(CodexExecutableLocator.defaultCandidates, id: \.path) { url in
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
    }
}
