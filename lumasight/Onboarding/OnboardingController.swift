//
//  OnboardingController.swift
//  lumasight
//
//  State machine behind the notch-hosted onboarding flow: optional camera
//  permission and explicit macOS platform-limitation & privacy acknowledgment.
//  Never enrolls persistent face templates, never stores macOS passwords,
//  and never unlocks macOS.
//

import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI

/// `String`-backed so `lumasightSettings.onboardingResumeStep` can persist it directly by name.
enum OnboardingStep: String, CaseIterable {
    case intro
    case permissions
    case securityNotice
    case complete

    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    var showsBackButton: Bool {
        switch self {
        case .permissions, .securityNotice: return true
        case .intro, .complete: return false
        }
    }

    var resumeTarget: OnboardingStep { self }

    /// Safely migrates removed onboarding step raw values (`password`, `preSetup`,
    /// `selectCamera`, `enroll`, `name`) to `.intro` instead of failing or getting stuck.
    static func fromPersistedRawValue(_ raw: String) -> OnboardingStep? {
        if let exact = OnboardingStep(rawValue: raw) {
            return exact
        }
        switch raw {
        case "password", "preSetup", "selectCamera", "enroll", "name":
            return .intro
        default:
            return nil
        }
    }
}

enum CameraPermissionState: Equatable {
    case granted
    case notDetermined
    case denied
}

@Observable
@MainActor
final class OnboardingController {
    enum NavDirection { case forward, backward }

    let isPostUpdateNotice: Bool
    private var onFirstRunComplete: (() -> Void)?

    private(set) var navDirection: NavDirection = .forward
    private(set) var cameraPermission: CameraPermissionState = .notDetermined

    private nonisolated final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func replace(with newTask: Task<Void, Never>?) {
            lock.lock()
            let previous = task
            task = newTask
            lock.unlock()
            previous?.cancel()
        }

        func cancel() {
            replace(with: nil)
        }

        deinit {
            cancel()
        }
    }

    @ObservationIgnored private let permissionsPollBox = TaskBox()
    @ObservationIgnored private let dismissTaskBox = TaskBox()

    private(set) var step: OnboardingStep = .intro {
        didSet {
            guard !isPostUpdateNotice else { return }
            if step == .complete {
                lumasightSettings.shared.hasCompletedOnboarding = true
                lumasightSettings.shared.hasAcknowledgedSecurityNotice = true
                lumasightSettings.shared.onboardingResumeStep = nil
            } else {
                lumasightSettings.shared.onboardingResumeStep = step.resumeTarget
            }
        }
    }

    private var currentPanelStyle: NotchPanelStyle {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen)?.style ?? .notch
    }

    var panelSize: CGSize { OnboardingMetrics.panelSize(for: step, style: currentPanelStyle) }
    var panelBottomRadius: CGFloat { OnboardingMetrics.panelBottomRadius(for: step) }
    var canAdvanceFromPermissions: Bool { cameraPermission == .granted }

    init(isPostUpdateNotice: Bool = false) {
        self.isPostUpdateNotice = isPostUpdateNotice
        refreshPermissions()
        if isPostUpdateNotice {
            self.step = .securityNotice
        }
    }

    deinit {
        permissionsPollBox.cancel()
        dismissTaskBox.cancel()
    }

    // MARK: - Entry Points

    static func startFlow(resumingAt step: OnboardingStep? = nil, onFirstRunComplete: (() -> Void)? = nil) {
        let controller = OnboardingController()
        controller.onFirstRunComplete = onFirstRunComplete
        if let step, step != .intro, step != .complete {
            controller.step = step
            if step == .permissions {
                controller.startPermissionsPolling()
            }
        }
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    static func startPostUpdateNotice(onComplete: (() -> Void)? = nil) {
        let controller = OnboardingController(isPostUpdateNotice: true)
        controller.onFirstRunComplete = onComplete
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    // MARK: - Navigation

    func advance() {
        navDirection = .forward
        let leavingStep = step
        withAnimation(OnboardingMetrics.stepAnimation) {
            if isPostUpdateNotice {
                step = .complete
            } else {
                switch step {
                case .intro: step = .permissions
                case .permissions: step = .securityNotice
                case .securityNotice: step = .complete
                case .complete: break
                }
            }
        }

        if leavingStep == .permissions {
            stopPermissionsPolling()
        }

        switch step {
        case .permissions:
            startPermissionsPolling()
        case .complete:
            if isPostUpdateNotice {
                lumasightSettings.shared.hasAcknowledgedSecurityNotice = true
            }
            scheduleCompletionDismiss()
        case .intro, .securityNotice:
            break
        }
    }

    func skipCameraSetup() {
        navDirection = .forward
        stopPermissionsPolling()
        withAnimation(OnboardingMetrics.stepAnimation) {
            step = .securityNotice
        }
    }

    func declinePostUpdateNotice() {
        teardown()
        NSApp.terminate(nil)
    }

    func back() {
        guard !isPostUpdateNotice else { return }
        navDirection = .backward
        guard let previous = step.previous else { return }
        withAnimation(OnboardingMetrics.stepAnimation) {
            step = previous
        }
        if step == .permissions {
            startPermissionsPolling()
        } else {
            stopPermissionsPolling()
        }
    }

    func teardown() {
        stopPermissionsPolling()
        dismissTaskBox.cancel()
    }

    // MARK: - Camera Permission Polling

    private func startPermissionsPolling() {
        refreshPermissions()
        permissionsPollBox.replace(with: Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.refreshPermissions()
            }
        })
    }

    private func stopPermissionsPolling() {
        permissionsPollBox.cancel()
    }

    private func refreshPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraPermission = .granted
        case .notDetermined: cameraPermission = .notDetermined
        case .denied, .restricted: cameraPermission = .denied
        @unknown default: cameraPermission = .denied
        }
    }

    func grantCamera() {
        Task { [weak self] in
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                self?.refreshPermissions()
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func scheduleCompletionDismiss() {
        dismissTaskBox.replace(with: Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.completeScreenDismissDelay))
            guard let self, !Task.isCancelled else { return }
            let onComplete = self.onFirstRunComplete
            self.teardown()
            NotchOverlayController.shared.dismissOnboarding()
            onComplete?()
        })
    }
}
