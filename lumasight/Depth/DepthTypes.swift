//
//  DepthTypes.swift
//  lumasight
//
//  Provenance-explicit depth data types. Clearly distinguishes calibrated hardware
//  depth, relative monocular estimates, and unavailable depth hardware/APIs.
//

import CoreGraphics
import Foundation

/// Explicit origin of any depth reading surfaced by lumasight.
nonisolated enum DepthProvenance: String, Equatable, Sendable {
    /// Depth or disparity captured from supported depth hardware with validated calibration/pixel data.
    case hardwareMeasured
    /// Non-metric relative depth inferred from a local Core ML monocular depth model.
    case monocularEstimated
    /// No usable depth source is available or enabled.
    case unavailable

    nonisolated var badgeTitle: String {
        switch self {
        case .hardwareMeasured: return "Hardware Measured"
        case .monocularEstimated: return "Estimated (Non-Metric)"
        case .unavailable: return "Depth Unavailable"
        }
    }

    nonisolated var provenanceDescription: String {
        switch self {
        case .hardwareMeasured:
            return "Measured from supported depth hardware metadata/pixels."
        case .monocularEstimated:
            return "Estimated non-metric relative depth inferred from 2D RGB. Not measured 3D geometry or proof of liveness/identity."
        case .unavailable:
            return "No live depth stream is available."
        }
    }
}

/// Physical or relative unit of a depth map.
nonisolated enum DepthUnit: String, Equatable, Sendable {
    case meters
    case inverseMeters
    case relativeNormalized
    case unknown

    nonisolated var displayLabel: String {
        switch self {
        case .meters: return "m (absolute depth)"
        case .inverseMeters: return "1/m (disparity)"
        case .relativeNormalized: return "relative units (non-metric)"
        case .unknown: return "unavailable"
        }
    }

    nonisolated var shortUnit: String {
        switch self {
        case .meters: return "m"
        case .inverseMeters: return "1/m"
        case .relativeNormalized: return "rel"
        case .unknown: return "—"
        }
    }

    nonisolated var isPhysicalUnit: Bool {
        self == .meters || self == .inverseMeters
    }
}

/// Matches AVDepthData.Accuracy cleanly without inventing metric scale when relative.
nonisolated enum DepthAccuracyKind: String, Equatable, Sendable {
    case absolute
    case relative
    case none

    nonisolated var displayLabel: String {
        switch self {
        case .absolute: return "Absolute"
        case .relative: return "Relative (non-metric scale)"
        case .none: return "None"
        }
    }
}

/// Explicit reason why depth is unavailable or rejected.
nonisolated enum DepthAvailabilityReason: Error, Equatable, Sendable {
    /// Apple's public live camera depth streaming APIs (`AVCaptureDepthDataOutput`,
    /// `AVCaptureDevice.supportedDepthDataFormats`) are marked `API_UNAVAILABLE(macos)` on native macOS.
    case unsupportedPlatformLiveStreaming
    case hardwareLacksDepthSensor(deviceName: String)
    case permissionDenied
    case permissionRestricted
    case permissionNotDetermined
    case noMonocularModelBundled
    case cameraDisconnected
    case calibrationMissing
    case invalidDepthValues
    case synchronizationMismatch(skewMilliseconds: Double)
    case userDisabled
    case unreadableAuxiliaryData(detail: String)

    nonisolated var title: String {
        switch self {
        case .unsupportedPlatformLiveStreaming:
            return "Live depth streaming unavailable on macOS"
        case .hardwareLacksDepthSensor(let name):
            return "No depth sensor on \"\(name)\""
        case .permissionDenied:
            return "Camera access denied"
        case .permissionRestricted:
            return "Camera access restricted"
        case .permissionNotDetermined:
            return "Camera permission not granted"
        case .noMonocularModelBundled:
            return "Estimated depth disabled (no local model bundled)"
        case .cameraDisconnected:
            return "Camera disconnected or unavailable"
        case .calibrationMissing:
            return "Camera calibration data missing"
        case .invalidDepthValues:
            return "Depth values failed validation"
        case .synchronizationMismatch:
            return "Color and depth frames out of sync"
        case .userDisabled:
            return "Depth preview stopped"
        case .unreadableAuxiliaryData:
            return "No valid auxiliary depth map in image"
        }
    }

    nonisolated var explanation: String {
        switch self {
        case .unsupportedPlatformLiveStreaming:
            return "Built-in Mac webcams only capture 2D RGB video, and Apple's public live depth streaming APIs (AVCaptureDepthDataOutput and AVCaptureDevice depth formats) are unavailable on native macOS. You can still inspect depth metadata embedded in an existing portrait photo (HEIC/DNG)."
        case .hardwareLacksDepthSensor(let name):
            return "\"\(name)\" reports RGB video only and does not expose calibrated depth capture formats."
        case .permissionDenied:
            return "Enable camera access for lumasight in System Settings -> Privacy & Security -> Camera to run camera demos."
        case .permissionRestricted:
            return "Camera access is restricted by system policy on this Mac."
        case .permissionNotDetermined:
            return "Start a camera feature explicitly when ready to request camera permission."
        case .noMonocularModelBundled:
            return "No licensed local Core ML monocular depth model is bundled in lumasight. Runtime model downloads and unrelated embedding models are never used as substitutes."
        case .cameraDisconnected:
            return "The selected camera was removed or no camera is available."
        case .calibrationMissing:
            return "Hardware depth requires valid camera intrinsic calibration to report metric measurements."
        case .invalidDepthValues:
            return "The depth buffer contained no finite positive samples or failed dimensional checks."
        case .synchronizationMismatch(let skewMs):
            return String(format: "Color and depth frame timestamps differed by %.1f ms (exceeding synchronization tolerance).", skewMs)
        case .userDisabled:
            return "Enable or start the demo explicitly to inspect depth status."
        case .unreadableAuxiliaryData(let detail):
            return detail
        }
    }
}

/// Validated camera intrinsic parameters extracted from `AVCameraCalibrationData`.
nonisolated struct CameraCalibrationSummary: Equatable, Sendable {
    let focalLengthX: Float
    let focalLengthY: Float
    let principalPointX: Float
    let principalPointY: Float
    let referenceWidth: Float
    let referenceHeight: Float
    let pixelSizeMillimeters: Float

    nonisolated var isValid: Bool {
        let scalars = [
            focalLengthX,
            focalLengthY,
            principalPointX,
            principalPointY,
            referenceWidth,
            referenceHeight,
        ]
        guard scalars.allSatisfy({ $0.isFinite }) else { return false }
        return focalLengthX > 0
            && focalLengthY > 0
            && referenceWidth > 0
            && referenceHeight > 0
            && (!pixelSizeMillimeters.isNaN && !pixelSizeMillimeters.isInfinite && pixelSizeMillimeters >= 0)
    }

    nonisolated var summaryLine: String {
        String(
            format: "fx=%.1f fy=%.1f cx=%.1f cy=%.1f (ref %.0fx%.0f)",
            focalLengthX, focalLengthY, principalPointX, principalPointY, referenceWidth, referenceHeight
        )
    }
}

/// Transient in-memory depth statistics and preview grid. Never written to disk.
nonisolated struct DepthFrameMetrics: Equatable, Sendable {
    static let previewGridColumns = 16
    static let previewGridRows = 12

    let provenance: DepthProvenance
    let accuracy: DepthAccuracyKind
    let unit: DepthUnit
    /// True strictly when depth is hardware-measured, `accuracy == .absolute`, calibration is valid, and unit is physical.
    let isMetricAbsolute: Bool
    let width: Int
    let height: Int
    let isFiltered: Bool
    let validPixelFraction: Float
    let minValue: Float
    let maxValue: Float
    let medianValue: Float
    let calibration: CameraCalibrationSummary?
    /// Bounded normalized 0...1 relative visualization values (`columns * rows`) kept strictly in memory.
    let normalizedPreviewGrid: [Float]
    let previewColumns: Int
    let previewRows: Int

    nonisolated var honestyDisclaimer: String {
        switch provenance {
        case .hardwareMeasured:
            if isMetricAbsolute {
                return "Measured hardware depth with valid calibration (\(unit.displayLabel))."
            }
            return "Hardware disparity/depth map with relative scale — treat distances as approximate, not absolute metric proof."
        case .monocularEstimated:
            return "Estimated relative depth from a 2D RGB image. Non-metric visualization only; not real-world distance, identity, or liveness."
        case .unavailable:
            return "Depth unavailable."
        }
    }

    nonisolated var rangeSummary: String {
        String(
            format: "%.2f – %.2f %@ (median %.2f, %.0f%% valid)",
            minValue,
            maxValue,
            unit.shortUnit,
            medianValue,
            validPixelFraction * 100
        )
    }
}

/// Unified state consumed by UI and tests.
nonisolated struct DepthAssessment: Equatable, Sendable {
    let provenance: DepthProvenance
    let metrics: DepthFrameMetrics?
    let unavailableReason: DepthAvailabilityReason?
    let sourceLabel: String

    nonisolated static func unavailable(
        reason: DepthAvailabilityReason,
        sourceLabel: String = "Depth Subsystem"
    ) -> DepthAssessment {
        DepthAssessment(
            provenance: .unavailable,
            metrics: nil,
            unavailableReason: reason,
            sourceLabel: sourceLabel
        )
    }

    nonisolated static func measured(
        metrics: DepthFrameMetrics,
        sourceLabel: String
    ) -> DepthAssessment {
        DepthAssessment(
            provenance: .hardwareMeasured,
            metrics: metrics,
            unavailableReason: nil,
            sourceLabel: sourceLabel
        )
    }

    nonisolated static func estimated(
        metrics: DepthFrameMetrics,
        sourceLabel: String
    ) -> DepthAssessment {
        DepthAssessment(
            provenance: .monocularEstimated,
            metrics: metrics,
            unavailableReason: nil,
            sourceLabel: sourceLabel
        )
    }
}
