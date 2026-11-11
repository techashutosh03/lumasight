//
//  SettingsWindowView.swift
//  lumasight
//
//  Root layout: one `.sidebar` material behind the whole window, the
//  selected page scrolling beneath a transparent header (traffic lights and
//  optional App Lock pill) and a floating tab bar pinned to the bottom.
//

import AppKit
import SwiftUI

struct HeaderAction: Equatable {
    private let id = UUID()
    let perform: () -> Void

    static func == (lhs: HeaderAction, rhs: HeaderAction) -> Bool { lhs.id == rhs.id }
}

struct HeaderTrailingActionKey: PreferenceKey {
    static var defaultValue: HeaderAction? { nil }
    static func reduce(value: inout HeaderAction?, nextValue: () -> HeaderAction?) {
        value = nextValue() ?? value
    }
}

struct SettingsWindowView: View {
    @Bindable var environment: AppEnvironment
    @State private var headerTrailingAction: HeaderAction?
    @State private var isAuthenticating = false
    @Environment(\.dismissWindow) private var dismissWindow

    private var isSettingsLocked: Bool {
        environment.privacyManager.isAppLockEnabled && !environment.privacyManager.isAppUnlocked
    }

    var body: some View {
        if lumasightSettings.shared.hasCompletedOnboarding {
            settingsContent
        } else {
            Color.clear
                .onAppear { dismissWindow(id: "settings") }
        }
    }

    private var settingsContent: some View {
        ZStack {
            VisualEffectView()
            SettingsMetrics.windowTintColor
            if isSettingsLocked {
                appLockedOverlay
            } else {
                contentPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .tint(lumasightTheme.accent)
        .onDisappear {
            environment.selectedSettingsTab = .general
            environment.privacyManager.lockApp()
        }
        .background(
            SettingsTabSwipeRecognizer { direction in
                guard !isSettingsLocked else { return }
                selectAdjacentTab(for: direction)
            }
        )
    }

    private var appLockedOverlay: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "lumasight Settings Locked",
            buttonTitle: isAuthenticating ? "Authenticating…" : "Unlock Settings",
            isButtonEnabled: !isAuthenticating,
            caption: environment.privacyManager.authenticationError
                ?? "Authenticate with \(environment.privacyManager.authenticationTypeDescription) to view or change lumasight settings."
        ) {
            isAuthenticating = true
            Task {
                await environment.privacyManager.unlockApp()
                isAuthenticating = false
            }
        }
        .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
    }

    private var contentPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            pageBody
                .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
                .padding(.top, SettingsMetrics.headerHeight + 4)
                .padding(.bottom, SettingsMetrics.pageBottomInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                ProgressiveHeaderBlur(height: SettingsMetrics.headerBlurHeight)
                header
            }
        }
        .overlay(alignment: .bottom) {
            SettingsTabBar(
                selection: $environment.selectedSettingsTab,
                isDebugSectionRevealed: environment.isDebugSectionRevealed
            )
            .padding(.bottom, SettingsMetrics.tabBarBottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(HeaderTrailingActionKey.self) { headerTrailingAction = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer()

            if let headerTrailingAction {
                Button(action: headerTrailingAction.perform) {
                    Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .frame(width: SettingsMetrics.headerButtonHeight, height: SettingsMetrics.headerButtonHeight)
                        .background(Circle().fill(SettingsMetrics.rowColor))
                        .overlay(
                            Circle()
                                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh camera list")
                .accessibilityLabel("Refresh camera list")
            }

            if environment.privacyManager.isAppLockEnabled {
                SessionLockButton(privacyManager: environment.privacyManager)
            }
        }
        .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
        .frame(height: SettingsMetrics.headerHeight)
    }

    @ViewBuilder
    private var pageBody: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            switch environment.selectedSettingsTab {
            case .general:
                GeneralSettingsPage(coordinator: environment.presenceCoordinator)
            case .privacy:
                PrivacySettingsPage(privacyManager: environment.privacyManager)
            case .camera:
                CameraSettingsPage()
            case .recognition:
                RecognitionSettingsPage(coordinator: environment.presenceCoordinator)
            case .about:
                AboutSettingsPage(updater: environment.updater, environment: environment)
            case .debugFaceLab:
                LazyFaceLabPage()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectAdjacentTab(for direction: SettingsTabSwipeDirection) {
        let tabs = SettingsTab.visibleTabs(includingDebug: environment.isDebugSectionRevealed)
        guard let currentIndex = tabs.firstIndex(of: environment.selectedSettingsTab) else { return }

        let adjacentIndex: Int
        switch direction {
        case .left:
            adjacentIndex = currentIndex + 1
        case .right:
            adjacentIndex = currentIndex - 1
        }

        guard tabs.indices.contains(adjacentIndex) else { return }
        withAnimation(SettingsMetrics.tabSelectionAnimation) {
            environment.selectedSettingsTab = tabs[adjacentIndex]
        }
    }
}

private struct LazyFaceLabPage: View {
    @State private var controller: FaceLabController?

    var body: some View {
        Group {
            if let controller {
                FaceLabView(controller: controller)
            } else {
                ProgressView("Loading Vision Lab…")
                    .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
                    .task {
                        await Task.yield()
                        guard !Task.isCancelled, controller == nil else { return }
                        controller = FaceLabController()
                    }
            }
        }
        .onDisappear {
            controller?.teardown()
            controller = nil
        }
    }
}

private enum SettingsTabSwipeDirection {
    case left
    case right
}

private struct SettingsTabSwipeRecognizer: NSViewRepresentable {
    let onSwipe: (SettingsTabSwipeDirection) -> Void

    func makeNSView(context: Context) -> SwipeHostingView {
        SwipeHostingView(onSwipe: onSwipe)
    }

    func updateNSView(_ view: SwipeHostingView, context: Context) {
        view.onSwipe = onSwipe
        view.installEventMonitorIfNeeded()
    }
}

private final class SwipeHostingView: NSView {
    private nonisolated final class MonitorHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var monitor: Any?

        var isInstalled: Bool {
            lock.lock()
            let installed = monitor != nil
            lock.unlock()
            return installed
        }

        func set(_ newMonitor: Any?) {
            lock.lock()
            let oldMonitor = monitor
            monitor = newMonitor
            lock.unlock()
            if let oldMonitor {
                NSEvent.removeMonitor(oldMonitor)
            }
        }

        func removeIfNeeded() {
            set(nil)
        }

        deinit {
            removeIfNeeded()
        }
    }

    var onSwipe: (SettingsTabSwipeDirection) -> Void
    private let monitorHolder = MonitorHolder()
    private var accumulatedHorizontalScroll: CGFloat = 0
    private var accumulatedVerticalScroll: CGFloat = 0
    private var didNavigateThisGesture = false

    private let swipeDistanceThreshold: CGFloat = 36

    init(onSwipe: @escaping (SettingsTabSwipeDirection) -> Void) {
        self.onSwipe = onSwipe
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            monitorHolder.removeIfNeeded()
        } else {
            installEventMonitorIfNeeded()
        }
    }

    func installEventMonitorIfNeeded() {
        guard window != nil, !monitorHolder.isInstalled else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, event.hasPreciseScrollingDeltas else {
                return event
            }
            self.handleTrackpadScroll(event)
            return event
        }
        monitorHolder.set(monitor)
    }

    private func handleTrackpadScroll(_ event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            resetSwipeTracking()
        }

        guard !didNavigateThisGesture else {
            return
        }

        accumulatedHorizontalScroll += event.scrollingDeltaX
        accumulatedVerticalScroll += event.scrollingDeltaY

        let horizontalDistance = abs(accumulatedHorizontalScroll)
        let verticalDistance = abs(accumulatedVerticalScroll)
        guard horizontalDistance >= swipeDistanceThreshold,
              horizontalDistance > verticalDistance * 1.5
        else { return }

        didNavigateThisGesture = true
        onSwipe(accumulatedHorizontalScroll < 0 ? .left : .right)
    }

    private func resetSwipeTracking() {
        accumulatedHorizontalScroll = 0
        accumulatedVerticalScroll = 0
        didNavigateThisGesture = false
    }

    deinit {
        monitorHolder.removeIfNeeded()
    }
}
