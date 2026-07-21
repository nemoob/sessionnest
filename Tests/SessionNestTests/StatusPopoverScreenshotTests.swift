import AppKit
import SwiftUI
import Testing

@testable import SessionNest

@MainActor
@Test func screenshotCopierWritesTheCompleteRenderedHeightAsPNG() throws {
    let pasteboard = NSPasteboard(name: .init("SessionNestScreenshotTests.complete"))
    pasteboard.clearContents()
    let content = VStack(spacing: 0) {
        Color.red.frame(height: 700)
        Color.blue.frame(height: 120)
    }
    .frame(width: 200)
    .fixedSize(horizontal: false, vertical: true)

    try StatusPopoverScreenshotCopier().copy(
        content: content,
        scale: 1,
        pasteboard: pasteboard
    )

    let data = try #require(pasteboard.data(forType: .png))
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(image.pixelsWide == 200)
    #expect(image.pixelsHigh == 820)
}

@MainActor
@Test func failedScreenshotRenderPreservesTheExistingClipboard() throws {
    let pasteboard = NSPasteboard(name: .init("SessionNestScreenshotTests.failure"))
    pasteboard.clearContents()
    pasteboard.setString("保留内容", forType: .string)

    #expect(throws: StatusPopoverScreenshotError.self) {
        try StatusPopoverScreenshotCopier().copy(
            content: EmptyView(),
            scale: 1,
            pasteboard: pasteboard
        )
    }
    #expect(pasteboard.string(forType: .string) == "保留内容")
}

@MainActor
@Test func successfulScreenshotReplacesTheExistingClipboard() throws {
    let pasteboard = NSPasteboard(name: .init("SessionNestScreenshotTests.replacement"))
    pasteboard.clearContents()
    pasteboard.setString("旧内容", forType: .string)

    try StatusPopoverScreenshotCopier().copy(
        content: Color.green.frame(width: 120, height: 80),
        scale: 1,
        pasteboard: pasteboard
    )

    #expect(pasteboard.data(forType: .png) != nil)
    #expect(pasteboard.string(forType: .string) == nil)
}

@MainActor
@Test func screenshotProgressBarRendersWithoutAnAppKitProgressView() throws {
    let pasteboard = NSPasteboard(name: .init("SessionNestScreenshotTests.progress"))
    pasteboard.clearContents()
    let content = StatusPopoverScreenshotProgressBar(value: 0.6, tint: .green)
        .frame(width: 200)

    try StatusPopoverScreenshotCopier().copy(
        content: content,
        scale: 1,
        pasteboard: pasteboard
    )

    let data = try #require(pasteboard.data(forType: .png))
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(image.pixelsWide == 200)
    #expect(image.pixelsHigh > 0)
}
