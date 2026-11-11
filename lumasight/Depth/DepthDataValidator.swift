//
//  DepthDataValidator.swift
//  lumasight
//
//  Validates `AVDepthData`, `CVPixelBuffer`, `AVCameraCalibrationData`, frame
//  synchronization skew, and ImageIO auxiliary depth maps cleanly on macOS.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import simd

nonisolated enum DepthDataValidator {
    static let maxReasonableDepthMeters: Float = 50.0
    static let maxReasonableDisparityInverseMeters: Float = 100.0
    static let defaultMaxSyncSkewSeconds: Double = 0.05

    // MARK: - Calibration Validation

    static func validateCalibration(_ calibration: AVCameraCalibrationData?) -> CameraCalibrationSummary? {
        guard let calibration else { return nil }
        let k = calibration.intrinsicMatrix
        let ref = calibration.intrinsicMatrixReferenceDimensions
        let summary = CameraCalibrationSummary(
            focalLengthX: k.columns.0.x,
            focalLengthY: k.columns.1.y,
            principalPointX: k.columns.2.x,
            principalPointY: k.columns.2.y,
            referenceWidth: Float(ref.width),
            referenceHeight: Float(ref.height),
            pixelSizeMillimeters: calibration.pixelSize
        )
        return summary.isValid ? summary : nil
    }

    static func validateCalibrationSummary(_ summary: CameraCalibrationSummary?) -> CameraCalibrationSummary? {
        guard let summary, summary.isValid else { return nil }
        return summary
    }

    // MARK: - Frame Synchronization Validation

    static func validateSynchronization(
        colorTimestampSeconds: Double,
        depthTimestampSeconds: Double,
        maxSkewSeconds: Double = defaultMaxSyncSkewSeconds
    ) -> DepthAvailabilityReason? {
        guard colorTimestampSeconds.isFinite, depthTimestampSeconds.isFinite, maxSkewSeconds > 0 else {
            return .invalidDepthValues
        }
        let skewSeconds = abs(colorTimestampSeconds - depthTimestampSeconds)
        if skewSeconds > maxSkewSeconds {
            return .synchronizationMismatch(skewMilliseconds: skewSeconds * 1_000.0)
        }
        return nil
    }

    // MARK: - AVDepthData & Pixel Buffer Validation

    static func validate(
        depthData: AVDepthData,
        requireCalibrationForAbsoluteMetric: Bool = false
    ) -> Result<DepthFrameMetrics, DepthAvailabilityReason> {
        let targetType: OSType
        let unit: DepthUnit
        switch depthData.depthDataType {
        case kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DepthFloat16:
            targetType = kCVPixelFormatType_DepthFloat32
            unit = .meters
        case kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_DisparityFloat16:
            targetType = kCVPixelFormatType_DisparityFloat32
            unit = .inverseMeters
        default:
            return .failure(.invalidDepthValues)
        }

        let converted = depthData.depthDataType == targetType
            ? depthData
            : depthData.converting(toDepthDataType: targetType)

        let accuracy: DepthAccuracyKind = converted.depthDataAccuracy == .absolute ? .absolute : .relative
        let calibration = validateCalibration(converted.cameraCalibrationData)

        if requireCalibrationForAbsoluteMetric && accuracy == .absolute && calibration == nil {
            return .failure(.calibrationMissing)
        }

        return validatePixelBuffer(
            converted.depthDataMap,
            provenance: .hardwareMeasured,
            unit: unit,
            accuracy: accuracy,
            calibration: calibration,
            isFiltered: converted.isDepthDataFiltered
        )
    }

    static func validatePixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        provenance: DepthProvenance,
        unit: DepthUnit,
        accuracy: DepthAccuracyKind,
        calibration: CameraCalibrationSummary?,
        isFiltered: Bool
    ) -> Result<DepthFrameMetrics, DepthAvailabilityReason> {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            return .failure(.invalidDepthValues)
        }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isFloat32 = format == kCVPixelFormatType_DepthFloat32 || format == kCVPixelFormatType_DisparityFloat32
        let isFloat16 = format == kCVPixelFormatType_DepthFloat16 || format == kCVPixelFormatType_DisparityFloat16
        guard isFloat32 || isFloat16 else {
            return .failure(.invalidDepthValues)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return .failure(.invalidDepthValues)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var values = [Float](repeating: .nan, count: width * height)

        for y in 0..<height {
            let rowPtr = baseAddress.advanced(by: y * bytesPerRow)
            if isFloat32 {
                let floatPtr = rowPtr.assumingMemoryBound(to: Float.self)
                for x in 0..<width {
                    values[y * width + x] = floatPtr[x]
                }
            } else {
                let halfPtr = rowPtr.assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    values[y * width + x] = float16ToFloat32(halfPtr[x])
                }
            }
        }

        return buildMetrics(
            fromDepthValues: values,
            width: width,
            height: height,
            provenance: provenance,
            unit: unit,
            accuracy: accuracy,
            calibration: calibration,
            isFiltered: isFiltered
        )
    }

    // MARK: - Single Shared Metric & Grid Builder

    static func buildMetrics(
        fromDepthValues values: [Float],
        width: Int,
        height: Int,
        provenance: DepthProvenance,
        unit: DepthUnit,
        accuracy: DepthAccuracyKind,
        calibration: CameraCalibrationSummary?,
        isFiltered: Bool
    ) -> Result<DepthFrameMetrics, DepthAvailabilityReason> {
        guard provenance != .unavailable,
              width > 0,
              height > 0,
              values.count == width * height else {
            return .failure(.invalidDepthValues)
        }

        let maxAllowed: Float
        switch unit {
        case .meters: maxAllowed = maxReasonableDepthMeters
        case .inverseMeters: maxAllowed = maxReasonableDisparityInverseMeters
        case .relativeNormalized: maxAllowed = 1.0_000_001
        case .unknown: return .failure(.invalidDepthValues)
        }

        var validSamples: [Float] = []
        validSamples.reserveCapacity(values.count)

        for value in values {
            if isValidSample(value, unit: unit, maxAllowed: maxAllowed) {
                validSamples.append(value)
            }
        }

        guard !validSamples.isEmpty else {
            return .failure(.invalidDepthValues)
        }

        validSamples.sort()
        let minVal = validSamples[0]
        let maxVal = validSamples[validSamples.count - 1]
        let mid = validSamples.count / 2
        let medianVal = validSamples.count.isMultiple(of: 2)
            ? (validSamples[mid - 1] + validSamples[mid]) * 0.5
            : validSamples[mid]
        let validFraction = Float(validSamples.count) / Float(values.count)

        let effectiveAccuracy: DepthAccuracyKind = provenance == .monocularEstimated ? .relative : accuracy
        let effectiveUnit: DepthUnit = provenance == .monocularEstimated ? .relativeNormalized : unit
        let validCalibration = validateCalibrationSummary(calibration)
        let isMetricAbsolute = provenance == .hardwareMeasured
            && effectiveAccuracy == .absolute
            && validCalibration != nil
            && effectiveUnit.isPhysicalUnit

        let cols = DepthFrameMetrics.previewGridColumns
        let rows = DepthFrameMetrics.previewGridRows
        let grid = downsampleNormalizedGrid(
            values: values,
            width: width,
            height: height,
            columns: cols,
            rows: rows,
            minVal: minVal,
            maxVal: maxVal,
            unit: unit,
            maxAllowed: maxAllowed
        )

        return .success(DepthFrameMetrics(
            provenance: provenance,
            accuracy: effectiveAccuracy,
            unit: effectiveUnit,
            isMetricAbsolute: isMetricAbsolute,
            width: width,
            height: height,
            isFiltered: isFiltered,
            validPixelFraction: validFraction,
            minValue: minVal,
            maxValue: maxVal,
            medianValue: medianVal,
            calibration: validCalibration,
            normalizedPreviewGrid: grid,
            previewColumns: cols,
            previewRows: rows
        ))
    }

    // MARK: - ImageIO Auxiliary Depth Inspection (User-Selected Files)

    /// Inspects optional auxiliary depth/disparity metadata embedded inside an existing image
    /// file (such as an iPhone Portrait HEIC or DNG) using macOS `ImageIO` + `AVDepthData`.
    /// Reads only into memory and never retains copies on disk.
    static func inspectAuxiliaryDepth(fromImageAt url: URL) -> DepthAssessment {
        let filename = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .unavailable(
                reason: .unreadableAuxiliaryData(detail: "Could not open \"\(filename)\" as a readable image."),
                sourceLabel: filename
            )
        }

        let auxiliaryKeys = [
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
        ]

        for key in auxiliaryKeys {
            guard let auxDict = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, key) as? [AnyHashable: Any] else {
                continue
            }
            guard let depthData = try? AVDepthData(fromDictionaryRepresentation: auxDict) else {
                return .unavailable(
                    reason: .invalidDepthValues,
                    sourceLabel: filename
                )
            }
            switch validate(depthData: depthData) {
            case .success(let metrics):
                return .measured(metrics: metrics, sourceLabel: filename)
            case .failure(let reason):
                return .unavailable(reason: reason, sourceLabel: filename)
            }
        }

        return .unavailable(
            reason: .unreadableAuxiliaryData(detail: "\"\(filename)\" does not contain embedded hardware depth or disparity metadata."),
            sourceLabel: filename
        )
    }

    // MARK: - Private Helpers

    private static func isValidSample(_ value: Float, unit: DepthUnit, maxAllowed: Float) -> Bool {
        guard value.isFinite else { return false }
        switch unit {
        case .meters, .inverseMeters:
            return value > 0 && value <= maxAllowed
        case .relativeNormalized:
            return value >= 0 && value <= maxAllowed
        case .unknown:
            return false
        }
    }

    private static func downsampleNormalizedGrid(
        values: [Float],
        width: Int,
        height: Int,
        columns: Int,
        rows: Int,
        minVal: Float,
        maxVal: Float,
        unit: DepthUnit,
        maxAllowed: Float
    ) -> [Float] {
        let span = max(maxVal - minVal, 1e-5)
        var grid = [Float](repeating: 0, count: columns * rows)

        for r in 0..<rows {
            let y0 = (r * height) / rows
            let y1 = max(y0 + 1, ((r + 1) * height) / rows)
            for c in 0..<columns {
                let x0 = (c * width) / columns
                let x1 = max(x0 + 1, ((c + 1) * width) / columns)

                var sum: Float = 0
                var count = 0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        let sample = values[y * width + x]
                        if isValidSample(sample, unit: unit, maxAllowed: maxAllowed) {
                            sum += sample
                            count += 1
                        }
                    }
                }
                if count > 0 {
                    let mean = sum / Float(count)
                    // Normalize closer/larger values consistently for visual shading only.
                    let normalized = min(max((mean - minVal) / span, 0), 1)
                    grid[r * columns + c] = normalized
                }
            }
        }

        return grid
    }

    /// Portable IEEE-754 binary16 -> binary32 decoder supporting arm64 and x86_64.
    static func float16ToFloat32(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exp = Int((bits & 0x7C00) >> 10)
        let mantissa = UInt32(bits & 0x03FF)

        if exp == 0 {
            if mantissa == 0 {
                return Float(bitPattern: sign)
            }
            // Subnormal half-float
            var m = mantissa
            var e = 127 - 15 + 1
            while (m & 0x0400) == 0 {
                m <<= 1
                e -= 1
            }
            m &= 0x03FF
            let floatBits = sign | (UInt32(e) << 23) | (m << 13)
            return Float(bitPattern: floatBits)
        } else if exp == 31 {
            // Inf or NaN
            let floatBits = sign | 0x7F80_0000 | (mantissa << 13)
            return Float(bitPattern: floatBits)
        } else {
            let floatExp = UInt32(exp - 15 + 127)
            let floatBits = sign | (floatExp << 23) | (mantissa << 13)
            return Float(bitPattern: floatBits)
        }
    }
}
