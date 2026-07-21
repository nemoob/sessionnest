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
