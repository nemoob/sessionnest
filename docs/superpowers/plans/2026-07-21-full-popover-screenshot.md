# Full Popover Screenshot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a status-popover button that renders the complete scrollable statistics overview as a PNG and replaces the macOS image clipboard so the result can be pasted immediately.

**Architecture:** A focused `StatusPopoverScreenshotCopier` renders an unconstrained SwiftUI view with `ImageRenderer`, encodes it as PNG, and writes one `NSPasteboardItem`. The popover reuses one overview content builder for both the live `ScrollView` and the off-screen long image, omitting only the screenshot action from the exported variant.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit `NSPasteboard`, Swift Testing, macOS 14+

## Global Constraints

- Capture the complete overview, including content below the 620-point viewport.
- Exclude the desktop, macOS menu bar, popover shadow, and screenshot button itself.
- Preserve the visible account plan and email because this is a complete-content capture.
- Produce a PNG that can be pasted directly from the system clipboard.
- Do not save or upload the screenshot, request Screen Recording permission, add a dependency, or add persistence.
- Do not clear the existing clipboard until a valid PNG has been produced.
- Keep the live popover at 420 by 620 points and keep it open after capture.

---

### Task 1: Render a complete SwiftUI view into the image clipboard

**Files:**
- Create: `Sources/SessionNest/StatusPopoverScreenshot.swift`
- Create: `Tests/SessionNestTests/StatusPopoverScreenshotTests.swift`

**Interfaces:**
- Consumes: any `SwiftUI.View`, a render scale, and an `NSPasteboard`.
- Produces: `@MainActor struct StatusPopoverScreenshotCopier` with `copy(content:scale:pasteboard:) throws`, plus `StatusPopoverScreenshotError`.

- [ ] **Step 1: Write the failing PNG and full-height tests**

```swift
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
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter StatusPopoverScreenshotTests`

Expected: compilation fails because `StatusPopoverScreenshotCopier` and
`StatusPopoverScreenshotError` do not exist.

- [ ] **Step 3: Implement the smallest renderer and PNG writer**

```swift
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
        item.setData(pngData, forType: .png)
        guard pasteboard.writeObjects([item]) else {
            throw StatusPopoverScreenshotError.pasteboardWriteFailed
        }
    }
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `swift test --filter StatusPopoverScreenshotTests`

Expected: both screenshot copier tests pass; the PNG is 200 by 820 pixels and the failed render leaves the prior string intact.

- [ ] **Step 5: Commit the renderer**

```bash
git add Sources/SessionNest/StatusPopoverScreenshot.swift \
  Tests/SessionNestTests/StatusPopoverScreenshotTests.swift
git commit -m "Add full-content screenshot renderer"
```

### Task 2: Add the screenshot action and reuse the complete overview content

**Files:**
- Modify: `Sources/SessionNest/SessionNestStatusPopover.swift:316-539`
- Modify: `Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift:20-29`

**Interfaces:**
- Consumes: `StatusPopoverScreenshotCopier.copy(content:scale:pasteboard:)` from Task 1 and the existing popover overview data.
- Produces: `StatusPopoverScreenshotFeedback`, `overviewContent(includesScreenshotAction:)`, and the camera/checkmark/error interaction.

- [ ] **Step 1: Write the failing feedback-state test**

```swift
@Test func screenshotFeedbackUsesClearClipboardMessagesAndSymbols() {
    #expect(StatusPopoverScreenshotFeedback.idle.systemImage == "camera")
    #expect(
        StatusPopoverScreenshotFeedback.idle.title
            == "复制完整截图（包含账号信息）"
    )
    #expect(StatusPopoverScreenshotFeedback.copied.systemImage == "checkmark")
    #expect(
        StatusPopoverScreenshotFeedback.copied.title
            == "完整截图已复制，可直接粘贴"
    )
    #expect(StatusPopoverScreenshotFeedback.failed.systemImage == "exclamationmark.triangle")
    #expect(StatusPopoverScreenshotFeedback.failed.errorText == "截图失败，请重试")
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter screenshotFeedbackUsesClearClipboardMessagesAndSymbols`

Expected: compilation fails because `StatusPopoverScreenshotFeedback` does not exist.

- [ ] **Step 3: Add the feedback model and live header action**

```swift
enum StatusPopoverScreenshotFeedback: Equatable {
    case idle
    case copied
    case failed

    var systemImage: String {
        switch self {
        case .idle: "camera"
        case .copied: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .idle: "复制完整截图（包含账号信息）"
        case .copied: "完整截图已复制，可直接粘贴"
        case .failed: "截图失败，请重试"
        }
    }

    var errorText: String? {
        self == .failed ? title : nil
    }
}
```

Add `@State private var screenshotFeedback = StatusPopoverScreenshotFeedback.idle`. Extract the
existing `VStack` at lines 374-535 into
`overviewContent(includesScreenshotAction: Bool)`. Keep the live structure as:

```swift
private var overview: some View {
    ScrollView {
        overviewContent(includesScreenshotAction: true)
            .padding(.trailing, SessionNestStatusPopoverLayout.scrollContentTrailingGutter)
    }
    .padding(.trailing, -SessionNestStatusPopoverLayout.scrollViewTrailingExtension)
}
```

Insert this action after the header divider and before refresh:

```swift
if includesScreenshotAction {
    StatusPopoverHeaderButton(
        title: screenshotFeedback.title,
        action: copyCompleteOverview
    ) {
        Image(systemName: screenshotFeedback.systemImage)
    }
}
```

Only in the live variant, show `screenshotFeedback.errorText` below the header using caption-sized
red text.

- [ ] **Step 4: Render the export variant and update feedback**

```swift
private var screenshotOverview: some View {
    overviewContent(includesScreenshotAction: false)
        .padding(16)
        .frame(width: SessionNestStatusPopoverLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(AppTheme(storedValue: storedTheme).colorScheme)
}

@MainActor
private func copyCompleteOverview() {
    do {
        try StatusPopoverScreenshotCopier().copy(content: screenshotOverview)
        screenshotFeedback = .copied
    } catch {
        screenshotFeedback = .failed
    }
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        screenshotFeedback = .idle
    }
}
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run: `swift test --filter 'StatusPopoverScreenshot|screenshotFeedback'`

Expected: the renderer and feedback tests pass.

- [ ] **Step 6: Run the complete repository check**

Run: `bash Scripts/check.sh`

Expected: strict formatting, build, and all Swift tests pass with zero failures.

- [ ] **Step 7: Commit the popover integration**

```bash
git add Sources/SessionNest/SessionNestStatusPopover.swift \
  Tests/SessionNestTests/SessionNestStatusItemControllerTests.swift
git commit -m "Copy complete status popover screenshot"
```

### Task 3: Package and exercise the clipboard flow locally

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: the completed screenshot action from Tasks 1 and 2.
- Produces: a verified local `.app` whose status popover places a complete long PNG on the general pasteboard.

- [ ] **Step 1: Build and verify the application signature**

Run:

```bash
bash Scripts/package-app.sh
codesign --verify --deep --strict dist/SessionNest.app
```

Expected: release build exits zero and `codesign` reports no error.

- [ ] **Step 2: Launch the built application and exercise the action**

Replace the running development app with `dist/SessionNest.app`, open the menu-bar popover, and
click the camera action once.

Expected: the popover stays open and its action becomes a checkmark briefly; macOS does not request
Screen Recording permission.

- [ ] **Step 3: Verify the general clipboard contains the complete long PNG**

Inspect `NSPasteboard.general.data(forType: .png)` with a one-shot Swift command or paste into a
native image destination.

Expected: the image is wider than zero, taller than 620 points at 1x logical scale, starts with the
SessionNest/account header, ends with the Token coverage/footer rows, and contains no camera action.

- [ ] **Step 4: Check the final diff and repository state**

Run:

```bash
git diff origin/main...HEAD --check
git status --short
```

Expected: no whitespace errors and no uncommitted source or test files.
