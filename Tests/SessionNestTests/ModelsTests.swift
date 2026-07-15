import Foundation
import Testing

@testable import SessionNest

@Test func threadDerivesDisplayValues() throws {
    let thread = CodexThread(
        id: "019f-test",
        name: nil,
        preview: "First request\nmore text",
        cwd: "/Users/alice/Developer/sample-api",
        createdAt: 10,
        updatedAt: 20,
        recencyAt: 25,
        gitInfo: GitInfo(branch: "test")
    )

    #expect(thread.displayTitle == "First request")
    #expect(thread.activityTimestamp == 25)
    #expect(thread.openURL?.absoluteString == "codex://threads/019f-test")
}

@Test func namedThreadUsesNameBeforePreview() {
    let thread = CodexThread(
        id: "named",
        name: "Pinned title",
        preview: "First request",
        cwd: "/tmp/repo",
        createdAt: 1,
        updatedAt: 2,
        recencyAt: nil,
        gitInfo: nil
    )
    #expect(thread.displayTitle == "Pinned title")
    #expect(thread.activityTimestamp == 2)
}

@Test func threadDecodesRolloutPath() throws {
    let data = Data(
        #"{"id":"thread","name":null,"preview":"","cwd":"/tmp/repo","createdAt":1,"updatedAt":2,"recencyAt":null,"gitInfo":null,"path":"/tmp/rollout.jsonl"}"#
            .utf8
    )

    let thread = try JSONDecoder().decode(CodexThread.self, from: data)

    #expect(thread.path == "/tmp/rollout.jsonl")
}
