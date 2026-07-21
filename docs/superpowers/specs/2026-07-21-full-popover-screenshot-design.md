# Full Popover Screenshot Design

## Goal

Add one action to the SessionNest status popover that captures the complete statistics overview,
including content below the visible scroll viewport, and places the result on the macOS clipboard
as a pasteable PNG.

## Considered Approaches

1. **Render the complete SwiftUI content off screen — recommended.** Reuse the overview content
   without its scroll-height constraint, render it at the popover width, and copy the resulting
   long image. This does not move the window, scroll automatically, or capture the desktop.
2. **Temporarily expand the real popover and capture its window.** This can flash, exceed the
   screen bounds, and disturb the selected menu-bar state, so it is rejected.
3. **Scroll and stitch multiple viewport captures.** This adds timing and overlap failure modes
   for content that SessionNest can already render directly, so it is rejected.

## Popover Interaction

- Add a camera-style action beside the existing public-link, refresh, and main-window actions.
- The action captures the current statistics overview from its header through the last coverage
  row, including every item that normally requires scrolling.
- The image excludes the macOS menu bar, desktop, popover shadow, and screenshot button itself.
  Other information currently displayed in the overview, including the account plan and email,
  remains included because this is a complete-content capture.
- A successful copy changes the action to a checkmark briefly and exposes the accessibility
  message `完整截图已复制，可直接粘贴`.
- A failed render or clipboard write keeps the popover open and shows a short failure message.
- The action does not close the popover or trigger a data refresh.

## Rendering and Clipboard Flow

- Extract the existing overview stack into reusable content while leaving the live `ScrollView`
  and its 420-by-620 layout unchanged.
- For capture, render that same content at the popover width with an unconstrained vertical size,
  the currently selected SessionNest theme, and an opaque window-background color.
- Use SwiftUI `ImageRenderer` for the application's own view. This avoids Screen Recording
  permission because no other window or screen pixels are read.
- Encode the rendered image as PNG and replace the image contents of the general pasteboard so
  the user can paste it directly with Command-V (or the target application's paste shortcut).
- Keep the renderer and pasteboard conversion synchronous on the main actor; the content is small
  enough that no new queue, cache, persistence, dependency, or permission is needed.

## Error and Privacy Boundaries

- Never clear the existing clipboard until a valid PNG has been produced.
- If PNG encoding or the pasteboard write fails, leave the old clipboard untouched.
- The screenshot is kept only in the system clipboard; SessionNest does not save it to disk or
  upload it.
- The button help text states that the complete overview includes account information.

## Testing and Verification

- Add a failing test first for copying valid PNG data to an isolated pasteboard, then implement
  the smallest clipboard writer needed to pass it.
- Add focused tests for success and failure feedback and for the full-content capture configuration
  being wider than zero and vertically unconstrained rather than limited to 620 points.
- Run `bash Scripts/check.sh` and build the release app.
- Launch locally, open the status popover, click the screenshot action, paste into a native image
  destination, and verify the pasted image contains both the top header and the final overview row.
- Confirm the app does not request Screen Recording permission and the popover remains open.
