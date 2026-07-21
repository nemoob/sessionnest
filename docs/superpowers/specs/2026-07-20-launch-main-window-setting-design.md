# Launch Main Window Setting Design

## Goal

Let users choose whether SessionNest opens its main window at application launch while preserving the current menu-bar-first default.

## User Experience

- Add a **启动** section to the menu bar popover settings page.
- Add a toggle labeled **启动时默认打开主窗口**.
- Keep the toggle off when no preference has been saved, so upgrades and fresh installs continue launching in the menu bar only.
- Apply changes on the next application launch. Changing the toggle does not open or close the current window.
- When enabled, the next launch opens the main window and shows the Dock icon.
- Closing the main window keeps SessionNest running in the menu bar and hides the Dock icon, matching the existing behavior.

## Storage and Application Flow

Store one Boolean preference in `UserDefaults`; no SQLite migration or new dependency is needed. The settings view writes the preference through `AppStorage`. During `applicationDidFinishLaunching`, the app installs the menu bar controller first, then opens the existing main window path only when the stored preference is enabled. This reuses the current window lifecycle and activation-policy transitions.

## Failure and Compatibility Behavior

Missing or unreadable preference data falls back to `false`. Existing users keep the current menu-bar-only launch behavior. The preference is local and contains no session or account data.

## Verification

- Verify the default is disabled and the stored value persists.
- Verify launch behavior resolves to menu-bar-only when disabled and open-main-window when enabled.
- Verify the existing close-window behavior remains accessory/menu-bar mode.
- Run the complete repository check, package the app, verify its signature, and launch the local build.
