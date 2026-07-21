import AppKit
import SwiftUI

enum StatusPopoverScreenshotError: Error {
    case renderingFailed
    case encodingFailed
    case pasteboardWriteFailed
}

enum StatusPopoverScreenshotBackground {
    static func colorScheme(
        for theme: AppTheme,
        systemColorScheme: ColorScheme
    ) -> ColorScheme {
        theme.colorScheme ?? systemColorScheme
    }

    static func color(for colorScheme: ColorScheme) -> Color {
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: appearanceName) else {
            return Color(nsColor: .windowBackgroundColor)
        }
        var backgroundColor = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            backgroundColor =
                NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)
                ?? NSColor.windowBackgroundColor
        }
        return Color(nsColor: backgroundColor)
    }
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
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw StatusPopoverScreenshotError.pasteboardWriteFailed
        }
    }
}

struct StatusPopoverScreenshotProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}
