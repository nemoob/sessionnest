# Refresh Button Visual State Design

## Goal

Make the menu bar popover refresh button visually consistent with the website, GitHub, and main-window buttons while still communicating that a refresh is running.

## Interaction

- Keep the same foreground color, 30-point circular hit area, hover background, pressed background, tooltip, and accessibility label as the other header buttons.
- Do not dim the refresh button while a refresh is running.
- Rotate the existing refresh symbol while work is in progress, then return it to its resting orientation.
- Continue using the controller's existing guard to ignore duplicate refresh requests.
- Do not change the header spacing, divider, menu bar status width, or other buttons.

## Implementation

Introduce a small refresh-symbol view responsible only for the rotation animation. Keep `StatusPopoverHeaderButton` as the shared visual container and pass the refresh symbol as its label without disabling the button.

## Verification

- Add a focused state test confirming that refreshing keeps the button visually enabled and activates animation.
- Run the complete repository check.
- Package and launch the local app to verify the header layout is unchanged.
