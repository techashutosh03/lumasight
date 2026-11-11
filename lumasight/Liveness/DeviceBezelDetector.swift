//
//  DeviceBezelDetector.swift
//  lumasight
//
//  Looks for a device bezel (phone/tablet) around the face via
//  VNDetectRectanglesRequest; only ever produces positive evidence of
//  spoofing, never positive evidence of liveness.
//

import Vision
import CoreGraphics

struct DeviceBezelObservation {
    /// Largest device-plausible rectangle found this frame, same pixel space as `DetectedFace.boundingBox`.
    let rectangle: CGRect?
    /// Fraction of the face's bounding box area that falls inside `rectangle`.
    let faceOverlapFraction: CGFloat?

    nonisolated static let none = DeviceBezelObservation(rectangle: nil, faceOverlapFraction: nil)
}

nonisolated enum DeviceBezelDetector {
    /// First-pass estimates, not validated against real footage — tune here if false positives/negatives show up.
    private static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        // Fraction of image area, not width/height.
        request.minimumSize = 0.12
        request.maximumObservations = 5
        // Covers phone-in-portrait through widescreen landscape (e.g. 16:9 / 21:9).
        request.minimumAspectRatio = 0.30
        request.maximumAspectRatio = 2.50
        // Generous so a phone held at a slight angle still registers.
        request.quadratureTolerance = 30

        return request
    }

    /// Synchronous and CPU-bound — call from a background task, same as `FaceDetector.detectFaces`.
    static func detect(in image: CGImage, faceBoundingBox: CGRect) -> DeviceBezelObservation {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty
        else { return .none }

        let imageSize = CGSize(width: image.width, height: image.height)
        let candidates = results.map { FaceDetector.convertToImageSpace($0.boundingBox, imageSize: imageSize) }
        // Largest candidate is assumed to be the device itself, not a smaller qualifying detail.
        guard let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return .none
        }

        let faceArea = faceBoundingBox.width * faceBoundingBox.height
        guard faceArea > 0, faceArea.isFinite else { return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: nil) }
        let intersection = largest.intersection(faceBoundingBox)
        guard !intersection.isNull, !intersection.isEmpty else {
            return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: 0)
        }
        let overlap = (intersection.width * intersection.height) / faceArea
        guard overlap.isFinite else {
            return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: 0)
        }
        return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: min(max(overlap, 0), 1))
    }
}
