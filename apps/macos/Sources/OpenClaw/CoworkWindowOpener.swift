import AppKit

/// Helpers that work around SwiftUI WindowGroup quirks on macOS:
/// - `openWindow(id:)` is only available inside a View; AppKit code paths
///   (menu bar extras, app delegate callbacks) cannot call it directly.
/// - After the user closes the main window once, launching the menu bar
///   entry does not automatically re-open the `WindowGroup` scene.
///
/// The app registers its main scene with id `"cowork-main"`, which gets
/// projected into AppKit as a window identifier. We open or focus that
/// window via `NSApp` so every entrypoint (menu bar "Open Chat",
/// keyboard shortcut, AppDelegate relaunch hook) behaves the same.
enum CoworkWindowOpener {
    private static let mainWindowID = "cowork-main"

    /// Bring the Cowork main window to the front, opening it if needed.
    @MainActor
    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = Self.findMainWindow() {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Fall back to the canonical `x-openclaw://open-main-window` deep link
        // handler. Opens via `open` which asks macOS to route the URL, which
        // triggers SwiftUI to re-instantiate the WindowGroup scene.
        if let url = URL(string: "openclaw://open-main-window") {
            NSWorkspace.shared.open(url)
        }

        // Last resort: ask NSApp to open untitled doc which SwiftUI maps to
        // the default WindowGroup.
        NSApp.sendAction(
            #selector(NSApplication.newWindowForTab(_:)),
            to: nil,
            from: nil)
    }

    @MainActor
    static func findMainWindow() -> NSWindow? {
        for window in NSApp.windows {
            guard window.isVisible || window.isMiniaturized || window.contentViewController != nil
            else { continue }
            let id = window.identifier?.rawValue ?? ""
            if id.contains(self.mainWindowID) { return window }
            if window.title == "OpenClaw" { return window }
        }
        return nil
    }
}
