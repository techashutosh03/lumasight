//
//  NotchWindow.swift
//  lumasight
//
//  Borderless, transparent, click-through panel. Created once and never resized —
//  all expansion/collapse is SwiftUI animating content inside this fixed window
//  (never call setFrame/setContentSize on it; only setFrameOrigin, to reposition).
//

import AppKit

final class NotchWindow: NSPanel {
    /// Floats above standard app windows and menu bar strictly within the active user session
    /// using supported AppKit window levels — never shields or overlays the macOS login screen.
    private static let overlayWindowLevel = NSWindow.Level.mainMenu + 3

    /// Whether the panel may become key. Tracked separately from
    /// `ignoresMouseEvents`, which `NotchWindowController` flips on and off as
    /// the cursor moves over/away from the visible panel.
    var acceptsKey = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = Self.overlayWindowLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Click-through by default until onboarding or a demo retry makes the panel interactive.
        ignoresMouseEvents = true
    }

    /// Must become key while interactive so onboarding text inputs or tap-to-retry work;
    /// never becomes main, so it doesn't take over as the app's primary window.
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}
