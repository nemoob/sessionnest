import Testing

@testable import SessionNest

@Suite("CodexScratchWorkspaceTests")
struct CodexScratchWorkspaceTests {
    @Test func detectsSessionRootFromExactPath() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/Users/me/Documents/Codex/2026-07-18/session-name"
            ) == "/Users/me/Documents/Codex/2026-07-18/session-name"
        )
    }

    @Test func detectsSessionRootFromDeeperWorkingDirectory() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/Users/me/Documents/Codex/2026-07-18/session-name/Sources/App"
            ) == "/Users/me/Documents/Codex/2026-07-18/session-name"
        )
    }

    @Test func acceptsValidLeapDay() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2024-02-29/leap-session"
            ) == "/tmp/Codex/2024-02-29/leap-session"
        )
    }

    @Test func selectsNearestValidCodexSequence() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-01-01/outer/Codex/2026-07-18/inner/Sources"
            ) == "/tmp/Codex/2026-01-01/outer/Codex/2026-07-18/inner"
        )
    }

    @Test func standardizesParentComponentsBeforeMatching() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-07-18/old/../session/Sources"
            ) == "/tmp/Codex/2026-07-18/session"
        )
    }

    @Test func rejectsSimilarDirectoryNames() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/MyCodex/2026-07-18/session"
            ) == nil
        )
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex2/2026-07-18/session"
            ) == nil
        )
    }

    @Test func rejectsInvalidDate() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2025-02-29/session"
            ) == nil
        )
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-13-01/session"
            ) == nil
        )
    }

    @Test func rejectsMissingSessionComponent() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "/tmp/Codex/2026-07-18"
            ) == nil
        )
    }

    @Test func rejectsRelativePath() {
        #expect(
            CodexScratchWorkspaceDetector.sessionRoot(
                for: "Codex/2026-07-18/session"
            ) == nil
        )
    }
}
