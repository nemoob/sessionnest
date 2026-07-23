import AppKit
import SwiftUI
import Testing

@testable import SessionNest

@MainActor
@Test func screenshotCopierWritesTheCompleteRenderedHeightAsPNG() throws {
    let content = VStack(spacing: 0) {
        Color.red.frame(height: 700)
        Color.blue.frame(height: 120)
    }
    .frame(width: 200)
    .fixedSize(horizontal: false, vertical: true)

    var writtenData: Data?
    try StatusPopoverScreenshotCopier().copy(
        content: content,
        scale: 1,
        writePNG: {
            writtenData = $0
            return true
        }
    )

    let data = try #require(writtenData)
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(image.pixelsWide == 200)
    #expect(image.pixelsHigh == 820)
}

@MainActor
@Test func failedScreenshotRenderDoesNotTouchTheClipboardWriter() throws {
    var writeCount = 0

    #expect(throws: StatusPopoverScreenshotError.self) {
        try StatusPopoverScreenshotCopier().copy(
            content: EmptyView(),
            scale: 1,
            writePNG: { _ in
                writeCount += 1
                return true
            }
        )
    }
    #expect(writeCount == 0)
}

@MainActor
@Test func successfulScreenshotPassesPNGToTheClipboardWriter() throws {
    var writtenData: Data?
    try StatusPopoverScreenshotCopier().copy(
        content: Color.green.frame(width: 120, height: 80),
        scale: 1,
        writePNG: {
            writtenData = $0
            return true
        }
    )

    let data = try #require(writtenData)
    #expect(NSBitmapImageRep(data: data) != nil)
}

@MainActor
@Test func failedScreenshotWriteRestoresTheExistingClipboard() throws {
    let previousItem = NSPasteboardItem()
    #expect(previousItem.setString("保留内容", forType: .string))
    let customType = NSPasteboard.PasteboardType("cn.nemoob.sessionnest.test")
    let customData = Data([0x00, 0x7F, 0xFF])
    #expect(previousItem.setData(customData, forType: customType))
    let newItem = NSPasteboardItem()
    #expect(newItem.setData(Data("png".utf8), forType: .png))
    var clearCount = 0
    var writes: [[NSPasteboardItem]] = []

    let replaced = StatusPopoverScreenshotCopier.replaceClipboardItems(
        previousItems: [previousItem],
        newItem: newItem,
        clearContents: { clearCount += 1 },
        writeObjects: {
            writes.append($0)
            return writes.count > 1
        }
    )

    #expect(!replaced)
    #expect(clearCount == 2)
    #expect(writes.count == 2)
    #expect(writes[0].first?.data(forType: .png) == Data("png".utf8))
    #expect(writes[1].first?.string(forType: .string) == "保留内容")
    #expect(writes[1].first?.data(forType: customType) == customData)
}

@MainActor
@Test func incompleteClipboardBackupNeverClearsExistingContents() {
    let newItem = NSPasteboardItem()
    #expect(newItem.setString("新内容", forType: .string))
    var clearCount = 0
    var writeCount = 0

    let replaced = StatusPopoverScreenshotCopier.replaceClipboardItems(
        previousItems: nil,
        newItem: newItem,
        clearContents: { clearCount += 1 },
        writeObjects: { _ in
            writeCount += 1
            return true
        }
    )

    #expect(!replaced)
    #expect(clearCount == 0)
    #expect(writeCount == 0)
}

@MainActor
@Test func screenshotProgressBarRendersWithoutAnAppKitProgressView() throws {
    let content = StatusPopoverScreenshotProgressBar(value: 0.6, tint: .green)
        .frame(width: 200)

    var writtenData: Data?
    try StatusPopoverScreenshotCopier().copy(
        content: content,
        scale: 1,
        writePNG: {
            writtenData = $0
            return true
        }
    )

    let data = try #require(writtenData)
    let image = try #require(NSBitmapImageRep(data: data))
    #expect(image.pixelsWide == 200)
    #expect(image.pixelsHigh > 0)
}

@MainActor
@Test func systemDarkScreenshotUsesTheCurrentDarkAppearance() throws {
    let colorScheme = StatusPopoverScreenshotBackground.colorScheme(
        for: .system,
        systemColorScheme: .dark
    )
    let content = StatusPopoverScreenshotBackground.color(for: colorScheme)
        .frame(width: 40, height: 40)
        .environment(\.colorScheme, colorScheme)

    var writtenData: Data?
    try StatusPopoverScreenshotCopier().copy(
        content: content,
        scale: 1,
        writePNG: {
            writtenData = $0
            return true
        }
    )

    let data = try #require(writtenData)
    let image = try #require(NSBitmapImageRep(data: data))
    let centerColor = try #require(image.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
    #expect(centerColor.brightnessComponent < 0.5)
}

@Test func explicitScreenshotThemeOverridesTheSystemAppearance() {
    #expect(
        StatusPopoverScreenshotBackground.colorScheme(
            for: .light,
            systemColorScheme: .dark
        ) == .light
    )
    #expect(
        StatusPopoverScreenshotBackground.colorScheme(
            for: .dark,
            systemColorScheme: .light
        ) == .dark
    )
}
