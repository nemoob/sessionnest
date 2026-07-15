import AppKit
import Testing

@testable import SessionNest

@MainActor
@Test func appStaysRunningAfterMainWindowCloses() {
    let delegate = SessionNestAppDelegate()

    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
}
