import AppKit
import Foundation
import Testing

@testable import SessionNest

@MainActor
@Test func appStaysRunningAfterMainWindowCloses() {
    let delegate = SessionNestAppDelegate()

    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
}

@Test func appShowsInDockOnlyWhileMainWindowIsOpen() {
    #expect(SessionNestPresentationTransition.launch.activationPolicy == .accessory)
    #expect(SessionNestPresentationTransition.openMainWindow.activationPolicy == .regular)
    #expect(SessionNestPresentationTransition.closeMainWindow.activationPolicy == .accessory)
}

@Test func launchMainWindowPreferenceDefaultsOffAndPersistsLocally() {
    let suiteName = "SessionNestLaunchPreferenceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(
        SessionNestLaunchPreference.opensMainWindowKey
            == "sessionnest.launch.opensMainWindow"
    )
    #expect(!SessionNestLaunchPreference.shouldOpenMainWindow(defaults: defaults))

    defaults.set(true, forKey: SessionNestLaunchPreference.opensMainWindowKey)
    #expect(SessionNestLaunchPreference.shouldOpenMainWindow(defaults: defaults))

    defaults.set(false, forKey: SessionNestLaunchPreference.opensMainWindowKey)
    #expect(!SessionNestLaunchPreference.shouldOpenMainWindow(defaults: defaults))
}

@Test func codexDataChangeMonitorFiltersToSessionsAndStateDatabase() {
    let codexHome = "/tmp/sessionnest-codex-home"

    #expect(
        CodexDataChangeMonitor.isRelevantChange(
            atPath: "\(codexHome)/sessions/2026/07/23/rollout.jsonl",
            codexHomePath: codexHome
        ))
    #expect(
        CodexDataChangeMonitor.isRelevantChange(
            atPath: "\(codexHome)/archived_sessions/thread.jsonl",
            codexHomePath: codexHome
        ))
    #expect(
        CodexDataChangeMonitor.isRelevantChange(
            atPath: "\(codexHome)/state_5.sqlite-wal",
            codexHomePath: codexHome
        ))
    #expect(
        CodexDataChangeMonitor.isRelevantChange(
            atPath: codexHome,
            codexHomePath: codexHome
        ))
    #expect(
        !CodexDataChangeMonitor.isRelevantChange(
            atPath: "\(codexHome)/logs/codex.log",
            codexHomePath: codexHome
        ))
    #expect(
        !CodexDataChangeMonitor.isRelevantChange(
            atPath: "/tmp/other/sessions/rollout.jsonl",
            codexHomePath: codexHome
        ))
}

@Test func codexDataChangeMonitorObservesNewSessionLogWhenFSEventsIsAvailable() async throws {
    let fileManager = FileManager.default
    let codexHome = fileManager.temporaryDirectory
        .appendingPathComponent("SessionNestFSEvents-\(UUID().uuidString)", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: codexHome) }

    let probe = CodexDataChangeProbe()
    let monitor = CodexDataChangeMonitor(codexHome: codexHome, latency: 0.05) {
        Task { await probe.record() }
    }
    // 部分受限测试容器无法注册系统 FSEvents；产品会在同一路径保留定时回退。
    guard monitor.start() else { return }
    defer { monitor.stop() }

    // FSEvents 启动后创建真实 JSONL，验证递归目录变化能到达轻量回调。
    try await Task.sleep(for: .milliseconds(50))
    try Data("{\"type\":\"session_meta\"}\n".utf8).write(
        to: sessions.appendingPathComponent("rollout.jsonl")
    )

    var observedChange = false
    for _ in 0..<200 {
        if await probe.count > 0 {
            observedChange = true
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(observedChange)
}

@Test func codexDataChangeMonitorReportsUnavailableRootForTimedFallback() {
    let missingHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("MissingSessionNestHome-\(UUID().uuidString)", isDirectory: true)
    let monitor = CodexDataChangeMonitor(codexHome: missingHome) {}

    #expect(!monitor.start())
}

private actor CodexDataChangeProbe {
    var count = 0

    func record() {
        count += 1
    }
}
