import AppKit
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        apply(.launch)
        prepareSession()

        let controller = SessionNestStatusItemController(model: model)
        statusItemController = controller
        controller.setOpenMainWindowAction { [weak self] in
            self?.openMainWindow()
        }
        controller.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindowController?.window else { return }
        apply(.closeMainWindow)
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
            model = SessionListModel(client: client, store: store)
            startupError = nil
        } catch {
            model = nil
            startupError = error.localizedDescription
        }
    }

    private func openMainWindow() {
        apply(.openMainWindow)

        let controller = mainWindowController ?? makeMainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
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
