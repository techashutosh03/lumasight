//
//  NotchOverlayController.swift
//  lumasight
//
//  Owns the active-session notch/pill overlay used for onboarding and optional
//  local presence demonstrations. Never monitors the lock screen.
//

import AppKit
import SwiftUI
import Observation

@Observable
@MainActor
final class NotchOverlayController {
    static let shared = NotchOverlayController()

    enum Phase: Equatable {
        case closed
        case scanning
        case success
        case failure
        case collapsing
        case onboarding
    }

    enum Content: Equatable {
        case scan(ScanMedia)
        case onboarding(OnboardingController)

        static func == (lhs: Content, rhs: Content) -> Bool {
            switch (lhs, rhs) {
            case (.scan(let a), .scan(let b)): return a == b
            case (.onboarding(let a), .onboarding(let b)): return a === b
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .closed
    private(set) var content: Content = .scan(.idle)

    var media: ScanMedia {
        if case .scan(let media) = content { return media }
        return .idle
    }

    private(set) var geometry: NotchGeometry = .forMainScreen()
    private(set) var activeUnlockStyle: UnlockAnimationStyle = .original

    /// Optional single-use hover retry handler set by `present(onRetry:)`.
    private var onActivate: (() -> Void)?

    private let windowController = NotchWindowController()
    private var resolveTask: Task<Void, Never>?

    private var hasPrimedWindow = false

    private let successHoldDuration: Duration = .milliseconds(1_700)
    let failureHoldDuration: Duration = .seconds(5)
    let collapseAnimationDuration: Duration = .milliseconds(700)

    private init() {
        windowController.contentView = NSHostingView(rootView: NotchOverlayView(controller: self))
        windowController.onScreenParametersChanged = { [weak self] in
            guard let self else { return }
            self.geometry = self.windowController.currentGeometry
        }
    }

    // MARK: - Window priming (first show only)

    private func primeWindowIfNeeded(_ completion: @escaping @MainActor @Sendable () -> Void) {
        guard !hasPrimedWindow else {
            completion()
            return
        }
        hasPrimedWindow = true
        content = .scan(.idle)
        phase = .closed
        windowController.show()
        windowController.displaySynchronously()
        DispatchQueue.main.async(execute: completion)
    }

    // MARK: - Demo mode (PresenceCoordinator, Settings preview)

    func present(styleOverride: UnlockAnimationStyle? = nil, onRetry: (() -> Void)? = nil) {
        onActivate = onRetry
        resolveTask?.cancel()
        resolveTask = nil
        geometry = windowController.currentGeometry
        activeUnlockStyle = styleOverride ?? lumasightSettings.shared.effectiveUnlockAnimationStyle
        primeWindowIfNeeded { [weak self] in
            guard let self else { return }
            content = .scan(.idle)
            phase = .scanning
            windowController.show()
            updateInteractivity()
        }
    }

    // MARK: - Onboarding mode (OnboardingController)

    func presentOnboarding(_ controller: OnboardingController) {
        onActivate = nil
        resolveTask?.cancel()
        resolveTask = nil
        geometry = windowController.currentGeometry
        primeWindowIfNeeded { [weak self] in
            guard let self else { return }
            content = .onboarding(controller)
            phase = .onboarding
            windowController.show()
            updateInteractivity()
        }
    }

    func dismissOnboarding() {
        guard case .onboarding = content else { return }
        phase = .collapsing
        updateInteractivity()
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.collapseAnimationDuration)
            guard case .onboarding = self.content else { return }
            self.content = .scan(.idle)
            self.phase = .closed
            self.windowController.hide()
        }
    }

    // MARK: - Resolving

    func finish(success: Bool) {
        resolveTask?.cancel()

        let shouldAnimate = activeUnlockStyle != .none
        content = shouldAnimate ? .scan(success ? .success : .failure) : .scan(.idle)
        phase = success ? .success : .failure
        updateInteractivity()

        let hold = shouldAnimate ? (success ? successHoldDuration : failureHoldDuration) : Duration.milliseconds(400)
        resolveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            await self.collapse()
        }
    }

    func activate() {
        guard lumasightSettings.shared.retryOnHover else { return }
        switch phase {
        case .failure:
            guard let onActivate else {
                Task { await collapse() }
                return
            }
            resolveTask?.cancel()
            resolveTask = nil
            activeUnlockStyle = lumasightSettings.shared.effectiveUnlockAnimationStyle
            content = .scan(.idle)
            phase = .scanning
            updateInteractivity()
            onActivate()
        case .closed, .scanning, .success, .collapsing, .onboarding:
            break
        }
    }

    func collapse() async {
        guard phase != .closed, phase != .collapsing else { return }
        geometry = windowController.currentGeometry
        phase = .collapsing
        updateInteractivity()
        try? await Task.sleep(for: collapseAnimationDuration)
        guard phase == .collapsing else { return }

        content = .scan(.idle)
        phase = .closed
        windowController.hide()
    }

    func dismissImmediately() {
        guard phase != .success, phase != .collapsing else { return }
        resolveTask?.cancel()
        resolveTask = nil
        phase = .closed
        content = .scan(.idle)
        windowController.setInteractive(false)
        windowController.hide()
    }

    private func updateInteractivity() {
        windowController.setInteractive(phase == .failure || phase == .onboarding, key: phase == .onboarding)
    }

    func updateInteractiveContentRect(_ rect: CGRect?) {
        windowController.setInteractiveContentRect(rect)
    }
}
