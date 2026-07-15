import AppKit
import SwiftUI

final class SessionNestAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SessionNestApp: App {
    @NSApplicationDelegateAdaptor(SessionNestAppDelegate.self) private var appDelegate
    @AppStorage("sessionnest.theme") private var storedTheme = AppTheme.system.rawValue
    private let model: SessionListModel?
    private let startupError: String?
    private let statusItemController: SessionNestStatusItemController

    init() {
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
            let model = SessionListModel(client: client, store: store)
            self.model = model
            startupError = nil
            statusItemController = SessionNestStatusItemController(model: model)
        } catch {
            model = nil
            startupError = error.localizedDescription
            statusItemController = SessionNestStatusItemController(model: nil)
        }
    }

    var body: some Scene {
        Window("SessionNest", id: "main") {
            Group {
                if let model {
                    SessionManagerView(model: model)
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    StartupErrorView(message: startupError ?? "未知启动错误")
                        .frame(minWidth: 680, minHeight: 420)
                }
            }
            .preferredColorScheme(AppTheme(storedValue: storedTheme).colorScheme)
            .background {
                StatusItemOpenWindowBridge(controller: statusItemController)
            }
        }
    }
}

private struct StatusItemOpenWindowBridge: View {
    let controller: SessionNestStatusItemController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                controller.install()
                controller.setOpenMainWindowAction {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
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
