//
//  NotchWindowController.swift
//  lumasight
//
//  Owns the notch overlay window's lifecycle: creation, positioning, and show/hide
//  strictly within the active user session using supported public AppKit APIs.
//

import AppKit

@MainActor
final class NotchWindowController {
    /// Holds non-Sendable AppKit timer and observer tokens cleanly so `deinit` (which is
    /// `nonisolated` under `-default-isolation MainActor`) and explicit `teardown()` can both
    /// invalidate callbacks idempotently without data races.
    private nonisolated final class CallbackResources: @unchecked Sendable {
        private let lock = NSLock()
        private var cursorPollTimer: Timer?
        private var screenObserver: NSObjectProtocol?

        func setScreenObserver(_ observer: NSObjectProtocol) {
            lock.lock()
            let previous = screenObserver
            screenObserver = observer
            lock.unlock()
            if let previous {
                NotificationCenter.default.removeObserver(previous)
            }
        }

        func setTimer(_ timer: Timer?) {
            lock.lock()
            let previous = cursorPollTimer
            cursorPollTimer = timer
            lock.unlock()
            previous?.invalidate()
        }

        var hasTimer: Bool {
            lock.lock()
            let active = cursorPollTimer != nil
            lock.unlock()
            return active
        }

        func invalidateAll() {
            lock.lock()
            let timer = cursorPollTimer
            let observer = screenObserver
            cursorPollTimer = nil
            screenObserver = nil
            lock.unlock()

            timer?.invalidate()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        deinit {
            invalidateAll()
        }
    }

    private var window: NotchWindow?
    private let resources = CallbackResources()

    /// What the overlay controller asked for via `setInteractive(_:)`.
    private var wantsInteractive = false
    /// The visible panel's frame inside the window, in the hosting view's
    /// top-down coordinates — reported by `NotchOverlayView`.
    private var interactiveContentRect: CGRect?

    /// Slack around the visible panel before clicks pass through — keeps a
    /// click on the very edge of the shape (or mid hover-bump) from missing.
    private static let interactiveRectOutset: CGFloat = 6

    /// The SwiftUI content to host — set once by NotchOverlayController.
    var contentView: NSView? {
        didSet { window?.contentView = contentView }
    }

    /// Fired on display changes so the overlay controller can re-read `currentGeometry` —
    /// plugging in a notched display can change the panel's shape, not just its width.
    var onScreenParametersChanged: (@MainActor () -> Void)?

    init() {
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenParametersChanged()
            }
        }
        resources.setScreenObserver(observer)
    }

    deinit {
        resources.invalidateAll()
    }

    /// Idempotent teardown of timers, observers, and overlay visibility.
    func teardown() {
        wantsInteractive = false
        onScreenParametersChanged = nil
        resources.invalidateAll()
        window?.orderOut(nil)
    }

    /// Creates the window (once), positions and orders it front in the active user session.
    func show() {
        let window = windowIfNeeded()
        reposition(window)
        window.orderFrontRegardless()
        updateCursorPolling()
    }

    /// Forces layout/composite now instead of waiting for the next display cycle —
    /// see `NotchOverlayController.primeWindowIfNeeded`.
    func displaySynchronously() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func hide() {
        guard let window else { return }
        window.orderOut(nil)
        updateCursorPolling()
    }

    /// `key: true` additionally makes the panel key — needed only for onboarding's
    /// text field to receive keystrokes.
    func setInteractive(_ interactive: Bool, key: Bool = false) {
        wantsInteractive = interactive
        window?.acceptsKey = interactive
        updateCursorPolling()
        guard interactive, key, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Forwarded from `NotchOverlayView` every time the visible panel's frame changes.
    func setInteractiveContentRect(_ rect: CGRect?) {
        if let rect, Self.isValidFiniteRect(rect) {
            interactiveContentRect = rect
        } else {
            interactiveContentRect = nil
        }
        updateMousePassthrough()
    }

    var currentGeometry: NotchGeometry {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen) ?? NotchGeometry.forMainScreen()
    }

    // MARK: - Click-through outside the visible panel

    private func updateMousePassthrough() {
        guard let window else { return }
        guard wantsInteractive else {
            window.ignoresMouseEvents = true
            return
        }
        guard let rect = interactiveContentRect,
              Self.isValidFiniteRect(rect),
              let hostView = window.contentView,
              hostView.bounds.height.isFinite,
              hostView.bounds.height > 0 else {
            window.ignoresMouseEvents = false
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        guard mouseLocation.x.isFinite, mouseLocation.y.isFinite else {
            window.ignoresMouseEvents = true
            return
        }
        let windowPoint = window.convertPoint(fromScreen: mouseLocation)
        let local = hostView.convert(windowPoint, from: nil)
        // `rect` is top-down (SwiftUI); normalise the AppKit point to match.
        let topDown = CGPoint(x: local.x, y: hostView.isFlipped ? local.y : hostView.bounds.height - local.y)
        guard topDown.x.isFinite, topDown.y.isFinite else {
            window.ignoresMouseEvents = true
            return
        }
        let expandedRect = rect.insetBy(dx: -Self.interactiveRectOutset, dy: -Self.interactiveRectOutset)
        let isOverPanel = Self.isValidFiniteRect(expandedRect) && expandedRect.contains(topDown)
        if window.ignoresMouseEvents == isOverPanel {
            window.ignoresMouseEvents = !isOverPanel
        }
    }

    static func isValidFiniteRect(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }

    private func updateCursorPolling() {
        let shouldPoll = wantsInteractive && (window?.isVisible ?? false)
        if shouldPoll, !resources.hasTimer {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMousePassthrough() }
            }
            RunLoop.main.add(timer, forMode: .common)
            resources.setTimer(timer)
        } else if !shouldPoll {
            resources.setTimer(nil)
        }
        updateMousePassthrough()
    }

    private func windowIfNeeded() -> NotchWindow {
        if let window { return window }
        let size = NotchGeometry.windowSize(for: currentGeometry.style)
        let safeWidth = (size.width.isFinite && size.width > 0) ? size.width : 400
        let safeHeight = (size.height.isFinite && size.height > 0) ? size.height : 400
        let rect = NSRect(x: 0, y: 0, width: safeWidth, height: safeHeight)
        let newWindow = NotchWindow(contentRect: rect)
        newWindow.animationBehavior = .none
        newWindow.contentView = contentView
        window = newWindow
        return newWindow
    }

    private func reposition(_ window: NotchWindow) {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let screenFrame = screen.frame
        let size = window.frame.size
        guard screenFrame.width.isFinite, screenFrame.height.isFinite,
              size.width.isFinite, size.height.isFinite else { return }
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height
        )
        guard origin.x.isFinite, origin.y.isFinite else { return }
        window.setFrameOrigin(origin)
    }

    private func screenParametersChanged() {
        onScreenParametersChanged?()
        guard let window, window.isVisible else { return }
        reposition(window)
    }
}
