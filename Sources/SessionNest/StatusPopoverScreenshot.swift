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
        try copy(content: content, scale: scale) { pngData in
            Self.replaceClipboard(with: pngData, pasteboard: pasteboard)
        }
    }

    func copy<Content: View>(
        content: Content,
        scale: CGFloat,
        writePNG: (Data) -> Bool
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
        guard writePNG(pngData) else {
            throw StatusPopoverScreenshotError.pasteboardWriteFailed
        }
    }

    static func replaceClipboard(
        with pngData: Data,
        pasteboard: NSPasteboard
    ) -> Bool {
        let item = NSPasteboardItem()
        // 先构造完整 PNG 项，避免新内容无效时触碰用户原有剪贴板。
        guard item.setData(pngData, forType: .png) else {
            return false
        }
        // 统一走事务式替换，确保图片与文本复制拥有相同的失败恢复语义。
        return replaceClipboard(with: item, pasteboard: pasteboard)
    }

    static func replaceClipboard(
        with text: String,
        pasteboard: NSPasteboard
    ) -> Bool {
        let item = NSPasteboardItem()
        // 先构造完整文本项，避免新内容无效时触碰用户原有剪贴板。
        guard item.setString(text, forType: .string) else {
            return false
        }
        // 统一走事务式替换，确保诊断复制失败时可以恢复旧内容。
        return replaceClipboard(with: item, pasteboard: pasteboard)
    }

    private static func replaceClipboard(
        with item: NSPasteboardItem,
        pasteboard: NSPasteboard
    ) -> Bool {
        // 必须完整复制旧剪贴板的全部项目和类型；任何类型无法读取都直接放弃替换。
        guard let previousItems = copiedItems(from: pasteboard) else {
            return false
        }
        // 仅在完整备份成功后清空并写入新内容，写入失败则恢复原始多类型内容。
        return replaceClipboardItems(
            previousItems: previousItems,
            newItem: item,
            clearContents: { pasteboard.clearContents() },
            writeObjects: { pasteboard.writeObjects($0) }
        )
    }

    static func replaceClipboardItems(
        previousItems: [NSPasteboardItem]?,
        newItem: NSPasteboardItem,
        clearContents: () -> Void,
        writeObjects: ([NSPasteboardItem]) -> Bool
    ) -> Bool {
        // 缺少完整备份时禁止清空，确保无法恢复的剪贴板保持原样。
        guard let previousItems else {
            return false
        }
        // 完整备份后再开始替换。
        clearContents()
        // 新内容写入失败时恢复旧剪贴板的全部项目和类型。
        guard writeObjects([newItem]) else {
            clearContents()
            _ = writeObjects(previousItems)
            return false
        }
        return true
    }

    private static func copiedItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        // 有已声明类型却无法枚举项目时视为备份失败，不能误判为空剪贴板后清空。
        guard let sourceItems = pasteboard.pasteboardItems else {
            return pasteboard.types?.isEmpty == false ? nil : []
        }
        // 逐项复制所有类型的原始数据，确保失败恢复不会退化成仅恢复纯文本。
        return try? sourceItems.map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                guard
                    let data = source.data(forType: type),
                    copy.setData(data, forType: type)
                else {
                    throw StatusPopoverScreenshotError.pasteboardWriteFailed
                }
            }
            return copy
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
