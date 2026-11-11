//
//  PresenceCoordinator.swift
//  lumasight
//
//  Coordinates optional, user-initiated, strictly active-session local face
//  presence & notch overlay demos. Does not retain biometric templates, match
//  identities, store images/depth maps, or unlock macOS.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation

@Observable
@MainActor
final class PresenceCoordinator {
    enum Outcome: Equatable {
        case idle
        case cancelled
        case permissionDenied
        case noCamera
        case failed(String)
        case detectedFaceDemo
    }

    private(set) var lastOutcome: Outcome = .idle
    private(set) var statusDescription: String = "Idle — starts only when you run a local demo."
    private(set) var lastLivenessNote: String?
    private(set) var isScanning: Bool = false

    var isRunning: Bool { isScanning }
    var statusMessage: String { statusDescription }

    let depthCoordinator: DepthSessionCoordinator

    private var settings: lumasightSettings
    private let cameraFactory: @MainActor () -> CameraManager
    private let dismissOverlayHandler: @MainActor () -> Void
    private var scanCamera: CameraManager?
    private var scanTask: Task<Void, Never>?

    var isEnabled: Bool {
        get { settings.isPresenceDemoEnabled }
        set {
            settings.isPresenceDemoEnabled = newValue
            if !newValue {
                stop()
            }
        }
    }

    convenience init() {
        self.init(
            settings: lumasightSettings.shared,
            depthCoordinator: nil,
            cameraFactory: nil,
            dismissOverlayHandler: nil
        )
    }

    init(
        settings: lumasightSettings,
        depthCoordinator: DepthSessionCoordinator? = nil,
        cameraFactory: (@MainActor () -> CameraManager)? = nil,
        dismissOverlayHandler: (@MainActor () -> Void)? = nil
    ) {
        self.settings = settings
        self.depthCoordinator = depthCoordinator ?? DepthSessionCoordinator()
        self.cameraFactory = cameraFactory ?? { CameraManager() }
        self.dismissOverlayHandler = dismissOverlayHandler ?? { NotchOverlayController.shared.dismissImmediately() }
    }

    /// Runs a temporary, user-initiated face-detection demo inside the signed-in session.
    /// Processes frames transiently in memory only; never enrolls, matches, or saves data.
    func startTemporaryDemo(showOverlay: Bool = true) async {
        triggerPresenceDemo(showOverlay: showOverlay)
        await scanTask?.value
    }

    func triggerPresenceDemo(showOverlay: Bool = true) {
        guard settings.isPresenceDemoEnabled else {
            lastOutcome = .cancelled
            statusDescription = "Enable the local presence demo in Settings to run it."
            return
        }

        cancelActiveScan(dismissOverlay: false)
        isScanning = true
        lastOutcome = .idle
        lastLivenessNote = nil
        statusDescription = "Starting camera for transient face-detection demo…"

        if showOverlay && settings.effectiveUnlockAnimationStyle != .none {
            NotchOverlayController.shared.present(
                styleOverride: settings.effectiveUnlockAnimationStyle,
                onRetry: { [weak self] in
                    self?.triggerPresenceDemo(showOverlay: true)
                }
            )
        }

        let scanSeconds = min(max(settings.faceDetectionSeconds, lumasightSettings.faceDetectionRange.lowerBound), lumasightSettings.faceDetectionRange.upperBound)
        let livenessEnabled = settings.livenessChecksEnabled
        let livenessMode = settings.livenessMode
        let minimumFaceWidth = settings.minimumFaceWidth
        let enableMonocularDepth = settings.isDepthEstimationEnabled
        let hapticEnabled = settings.hapticFeedbackEnabled

        let camera = cameraFactory()
        scanCamera = camera
        camera.onDeviceDisconnected = { [weak self] in
            guard let self else { return }
            self.depthCoordinator.handleCameraDisconnected()
            self.statusDescription = "Camera disconnected during demo."
            self.lastOutcome = .noCamera
            self.cancelActiveScan(dismissOverlay: true)
        }

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await camera.start()
            guard !Task.isCancelled else {
                camera.teardown()
                return
            }

            if camera.permission != .granted {
                self.depthCoordinator.updateForLiveCamera(
                    capabilityInput: CameraDepthCapabilityInput.forMacOSDevice(
                        camera.activeDevice,
                        authorizationStatus: Self.avStatus(from: camera.permission)
                    ),
                    rgbFrame: nil,
                    enableMonocularEstimate: false
                )
                self.lastOutcome = .permissionDenied
                self.statusDescription = camera.errorMessage ?? "Camera permission not granted."
                camera.teardown()
                self.scanCamera = nil
                self.isScanning = false
                if showOverlay {
                    NotchOverlayController.shared.finish(success: false)
                }
                return
            }

            guard camera.isRunning || camera.errorMessage == nil else {
                self.lastOutcome = .noCamera
                self.statusDescription = camera.errorMessage ?? "No connected camera available."
                camera.teardown()
                self.scanCamera = nil
                self.isScanning = false
                if showOverlay {
                    NotchOverlayController.shared.finish(success: false)
                }
                return
            }

            self.statusDescription = "Detecting face locally (in-memory only, no templates stored)…"
            let liveness: LivenessAnalyzer?
            if livenessEnabled {
                let analyzer = LivenessAnalyzer()
                analyzer.modeProvider = { livenessMode }
                liveness = analyzer
            } else {
                liveness = nil
            }
            let deadline = Date().addingTimeInterval(TimeInterval(scanSeconds))
            var lastProcessedID: UInt64 = 0
            var succeeded = false

            while !Task.isCancelled && Date() < deadline {
                if !camera.isRunning && camera.errorMessage != nil {
                    break
                }

                if let frame = camera.currentFrame, frame.id != lastProcessedID {
                    lastProcessedID = frame.id

                    let capability = CameraDepthCapabilityInput.forMacOSDevice(
                        camera.activeDevice,
                        authorizationStatus: .authorized
                    )
                    self.depthCoordinator.updateForLiveCamera(
                        capabilityInput: capability,
                        rgbFrame: frame.image,
                        enableMonocularEstimate: enableMonocularDepth
                    )

                    let detected = await Task.detached(priority: .userInitiated) {
                        Self.detectTransientFaceAndLiveness(
                            in: frame,
                            minimumFaceWidth: minimumFaceWidth,
                            includeLivenessFeatures: livenessEnabled
                        )
                    }.value

                    guard !Task.isCancelled else { break }

                    if let (face, livenessFrame) = detected {
                        if let liveness, let livenessFrame {
                            let snapshot = liveness.observe(livenessFrame)
                            switch snapshot.decision {
                            case .confirmed(let cue):
                                self.lastLivenessNote = cue.map { "Experimental 2D cue confirmed: \($0.title) (non-security)" }
                                    ?? "Light mode experimental cues passed (non-security)"
                                succeeded = true
                            case .denied(let cue):
                                self.lastLivenessNote = "Experimental 2D cue flagged: \(cue.title) (non-security heuristic)"
                            case .pending:
                                break
                            }
                        } else {
                            // Vision detected a well-framed face in-memory (no identity lookup).
                            _ = face
                            succeeded = true
                        }
                        if succeeded { break }
                    }
                }

                try? await Task.sleep(for: .milliseconds(60))
            }

            camera.teardown()
            if self.scanCamera === camera {
                self.scanCamera = nil
            }
            self.depthCoordinator.stop()
            self.isScanning = false

            guard !Task.isCancelled else {
                self.lastOutcome = .cancelled
                self.statusDescription = "Demo cancelled and camera released."
                return
            }

            if succeeded {
                self.lastOutcome = .detectedFaceDemo
                self.statusDescription = "Demo complete (face detected transiently; nothing stored)."
                if hapticEnabled {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            } else {
                self.lastOutcome = .failed(camera.errorMessage ?? "No qualifying face detected before timeout.")
                self.statusDescription = camera.errorMessage ?? "Demo timed out without completing."
            }

            if showOverlay {
                NotchOverlayController.shared.finish(success: succeeded)
            }
        }
    }

    func stop() {
        cancelActiveScan(dismissOverlay: true)
        statusDescription = "Idle — camera released."
    }

    private func cancelActiveScan(dismissOverlay: Bool) {
        scanTask?.cancel()
        scanTask = nil
        scanCamera?.teardown()
        scanCamera = nil
        depthCoordinator.stop()
        isScanning = false
        if dismissOverlay {
            dismissOverlayHandler()
        }
    }

    private nonisolated static func avStatus(from permission: CameraPermission) -> AVAuthorizationStatus {
        switch permission {
        case .granted: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        }
    }

    private nonisolated static func detectTransientFaceAndLiveness(
        in frame: CameraFrame,
        minimumFaceWidth: Float,
        includeLivenessFeatures: Bool
    ) -> (DetectedFace, LivenessFrame?)? {
        guard let faces = try? FaceDetector.detectFaces(in: frame.image), !faces.isEmpty else {
            return nil
        }

        let qualifying = faces
            .filter { $0.normalizedBoundingBox.width >= CGFloat(minimumFaceWidth) }
            .max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
            ?? faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })

        guard let face = qualifying,
              face.normalizedBoundingBox.width >= CGFloat(minimumFaceWidth) else {
            return nil
        }

        guard includeLivenessFeatures else {
            return (face, nil)
        }

        let faceCrop = FaceDetector.crop(face, from: frame.image)
        let livenessFrame = LivenessFeatureExtractor.extract(
            from: face,
            frame: frame.image,
            faceCrop: faceCrop
        )
        return (face, livenessFrame)
    }
}
