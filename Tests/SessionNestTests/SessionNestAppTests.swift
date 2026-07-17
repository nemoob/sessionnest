import AppKit
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
