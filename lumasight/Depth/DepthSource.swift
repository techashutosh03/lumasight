//
//  DepthSource.swift
//  lumasight
//
//  Explicit depth capability discovery and session coordination. Never fakes
//  hardware depth from 2D RGB video, never downloads runtime models, and never
//  substitutes face-recognition embeddings for depth estimation.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Input model for evaluating live camera depth capability across OS platforms and test doubles.
nonisolated struct CameraDepthCapabilityInput: Equatable, Sendable {
    let isNativeMacOSAppKit: Bool
    let authorizationStatus: AVAuthorizationStatus
    let deviceConnected: Bool
    let deviceName: String?
    let supportsSynchronizedDepthStream: Bool
    let hasCalibrationData: Bool

    static func forMacOSDevice(
        _ device: AVCaptureDevice?,
        authorizationStatus: AVAuthorizationStatus
    ) -> CameraDepthCapabilityInput {
        #if os(macOS)
        let isMacOS = true
        #else
        let isMacOS = false
        #endif
        return CameraDepthCapabilityInput(
            isNativeMacOSAppKit: isMacOS,
            authorizationStatus: authorizationStatus,
            deviceConnected: device?.isConnected ?? false,
            deviceName: device?.localizedName,
            supportsSynchronizedDepthStream: false,
            hasCalibrationData: false
        )
    }
}

/// Evaluates whether calibrated live hardware depth streaming can operate on the current platform & device.
nonisolated enum LiveDepthCapability {
    static func evaluate(
        device: AVCaptureDevice?,
        authorizationStatus: AVAuthorizationStatus
    ) -> DepthAvailabilityReason? {
        evaluate(CameraDepthCapabilityInput.forMacOSDevice(device, authorizationStatus: authorizationStatus))
    }

    static func evaluate(_ input: CameraDepthCapabilityInput) -> DepthAvailabilityReason? {
        switch input.authorizationStatus {
        case .denied:
            return .permissionDenied
        case .restricted:
            return .permissionRestricted
        case .notDetermined:
            return .permissionNotDetermined
        case .authorized:
            break
        @unknown default:
            return .permissionNotDetermined
        }

        guard input.deviceConnected, let deviceName = input.deviceName else {
            return .cameraDisconnected
        }

        // Verified against MacOSX SDK headers: AVCaptureDepthDataOutput, AVCaptureDataOutputSynchronizer,
        // and AVCaptureDevice.supportedDepthDataFormats are annotated API_UNAVAILABLE(macos).
        if input.isNativeMacOSAppKit {
            return .unsupportedPlatformLiveStreaming
        }

        guard input.supportsSynchronizedDepthStream else {
            return .hardwareLacksDepthSensor(deviceName: deviceName)
        }

        guard input.hasCalibrationData else {
            return .calibrationMissing
        }

        return nil
    }
}

/// Interface for an optional, explicitly licensed, bundled Core ML monocular depth model.
nonisolated protocol MonocularDepthEstimator: Sendable {
    var modelName: String { get }
    var isModelAvailable: Bool { get }
    func estimateRelativeDepth(from image: CGImage) -> Result<DepthFrameMetrics, DepthAvailabilityReason>
}

/// Default estimator: looks strictly for a local bundled depth model resource.
/// Never downloads models at runtime and never substitutes unrelated vision models.
nonisolated struct BundledMonocularDepthEstimator: MonocularDepthEstimator {
    static let bundledModelResourceName = "MonocularDepth"

    let modelName = "Bundled Monocular Depth Core ML Model"
    let isModelAvailable: Bool

    init(bundle: Bundle = .main) {
        self.isModelAvailable = bundle.url(forResource: Self.bundledModelResourceName, withExtension: "mlmodelc") != nil
    }

    func estimateRelativeDepth(from image: CGImage) -> Result<DepthFrameMetrics, DepthAvailabilityReason> {
        // No licensed monocular depth model is currently bundled in the repository.
        // We fail closed with .noMonocularModelBundled rather than synthesizing fake depth.
        return .failure(.noMonocularModelBundled)
    }
}

/// Coordinates transient depth assessment cleanly across live camera state, optional monocular
/// estimation (if enabled and bundled), and user-selected image inspection.
@Observable
@MainActor
final class DepthSessionCoordinator {
    private(set) var liveAssessment: DepthAssessment = .unavailable(reason: .userDisabled, sourceLabel: "Live Camera")
    private(set) var inspectedImageAssessment: DepthAssessment?

    private let monocularEstimator: any MonocularDepthEstimator

    init(monocularEstimator: any MonocularDepthEstimator = BundledMonocularDepthEstimator()) {
        self.monocularEstimator = monocularEstimator
    }

    var isMonocularModelBundled: Bool {
        monocularEstimator.isModelAvailable
    }

    /// Evaluates depth capability/estimates for a live camera frame transiently in memory.
    func updateForLiveCamera(
        capabilityInput: CameraDepthCapabilityInput,
        rgbFrame: CGImage?,
        enableMonocularEstimate: Bool,
        synchronizedHardwareSample: (colorTime: Double, depthTime: Double, metrics: DepthFrameMetrics)? = nil
    ) {
        if let unavailable = LiveDepthCapability.evaluate(capabilityInput) {
            if enableMonocularEstimate,
               let rgbFrame,
               unavailable == .unsupportedPlatformLiveStreaming || isLackOfSensorReason(unavailable) {
                evaluateMonocularFallback(
                    rgbFrame: rgbFrame,
                    cameraName: capabilityInput.deviceName ?? "RGB Camera",
                    underlyingHardwareReason: unavailable
                )
                return
            }

            liveAssessment = .unavailable(
                reason: unavailable,
                sourceLabel: capabilityInput.deviceName ?? "Live Camera"
            )
            return
        }

        // Hardware capability reported available: require synchronized calibrated sample.
        guard let sample = synchronizedHardwareSample else {
            liveAssessment = .unavailable(reason: .invalidDepthValues, sourceLabel: capabilityInput.deviceName ?? "Depth Camera")
            return
        }

        if let syncError = DepthDataValidator.validateSynchronization(
            colorTimestampSeconds: sample.colorTime,
            depthTimestampSeconds: sample.depthTime
        ) {
            liveAssessment = .unavailable(reason: syncError, sourceLabel: capabilityInput.deviceName ?? "Depth Camera")
            return
        }

        liveAssessment = .measured(
            metrics: sample.metrics,
            sourceLabel: capabilityInput.deviceName ?? "Depth Camera"
        )
    }

    /// Inspects a user-selected still image for auxiliary hardware depth metadata.
    func inspectSelectedImage(at url: URL) {
        inspectedImageAssessment = DepthDataValidator.inspectAuxiliaryDepth(fromImageAt: url)
    }

    func clearInspectedImage() {
        inspectedImageAssessment = nil
    }

    func handleCameraDisconnected() {
        liveAssessment = .unavailable(reason: .cameraDisconnected, sourceLabel: "Live Camera")
    }

    func stop() {
        liveAssessment = .unavailable(reason: .userDisabled, sourceLabel: "Live Camera")
    }

    private func evaluateMonocularFallback(
        rgbFrame: CGImage,
        cameraName: String,
        underlyingHardwareReason: DepthAvailabilityReason
    ) {
        guard monocularEstimator.isModelAvailable else {
            liveAssessment = .unavailable(
                reason: .noMonocularModelBundled,
                sourceLabel: "\(cameraName) (RGB only)"
            )
            return
        }

        switch monocularEstimator.estimateRelativeDepth(from: rgbFrame) {
        case .success(let metrics):
            // Ensure provenance & non-metric flags are strictly preserved even for injected models.
            let sanitized = DepthFrameMetrics(
                provenance: .monocularEstimated,
                accuracy: .relative,
                unit: .relativeNormalized,
                isMetricAbsolute: false,
                width: metrics.width,
                height: metrics.height,
                isFiltered: metrics.isFiltered,
                validPixelFraction: metrics.validPixelFraction,
                minValue: metrics.minValue,
                maxValue: metrics.maxValue,
                medianValue: metrics.medianValue,
                calibration: nil,
                normalizedPreviewGrid: metrics.normalizedPreviewGrid,
                previewColumns: metrics.previewColumns,
                previewRows: metrics.previewRows
            )
            liveAssessment = .estimated(metrics: sanitized, sourceLabel: "\(monocularEstimator.modelName) on \(cameraName)")
        case .failure:
            liveAssessment = .unavailable(reason: underlyingHardwareReason, sourceLabel: cameraName)
        }
    }

    private func isLackOfSensorReason(_ reason: DepthAvailabilityReason) -> Bool {
        if case .hardwareLacksDepthSensor = reason { return true }
        return false
    }
}
