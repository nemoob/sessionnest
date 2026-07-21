import AppKit
import SwiftUI

enum StatusPopoverScreenshotError: Error {
    case renderingFailed
    case encodingFailed
    case pasteboardWriteFailed
}

@MainActor
struct StatusPopoverScreenshotCopier {
    func copy<Content: View>(
        content: Content,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2,
        pasteboard: NSPasteboard = .general
    ) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else {
            throw StatusPopoverScreenshotError.renderingFailed
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw StatusPopoverScreenshotError.encodingFailed
        }
        let item = NSPasteboardItem()
        guard item.setData(pngData, forType: .png) else {
            throw StatusPopoverScreenshotError.pasteboardWriteFailed
        }
        guard pasteboard.writeObjects([item]) else {
            throw StatusPopoverScreenshotError.pasteboardWriteFailed
        }
    }
}
