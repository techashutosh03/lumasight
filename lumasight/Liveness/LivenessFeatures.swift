//
//  LivenessFeatures.swift
//  lumasight
//
//  Vision-facing half of experimental 2D liveness cues: turns a transient
//  `DetectedFace` into a plain, Vision-free `LivenessFrame` in memory.
//

import CoreGraphics
import Foundation
import Vision

nonisolated enum LivenessFeatureExtractor {
    /// Never fails — a face with no landmarks still yields a frame; cues that need landmarks abstain.
    static func extract(
        from face: DetectedFace,
        frame: CGImage,
        faceCrop: CGImage? = nil,
        timestamp: Date = Date()
    ) -> LivenessFrame {
        let deviceOverlap = DeviceBezelDetector.detect(in: frame, faceBoundingBox: face.boundingBox).faceOverlapFraction
        let glare = faceCrop.flatMap { GlareCueExtractor.extract(faceCrop: $0) }

        guard let landmarks = face.landmarks else {
            return LivenessFrame(
                timestamp: timestamp, landmarks: [], interocularDistance: nil,
                yaw: face.yaw,
                leftEyeAspectRatio: nil, rightEyeAspectRatio: nil,
                noseOffsetRatio: nil,
                hasReliableLandmarks: false,
                deviceOverlapFraction: deviceOverlap,
                glare: glare
            )
        }

        let imageSize = face.imageSize
        let points = LandmarkGeometry.allPoints(from: landmarks, imageSize: imageSize)
        let interocular = LandmarkGeometry.interocularDistance(from: landmarks, imageSize: imageSize)
        let leftEAR = landmarks.leftEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: imageSize) }
        let rightEAR = landmarks.rightEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: imageSize) }

        let eyeLeft = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize)
        let eyeRight = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize)
        let noseCenter = landmarks.nose.flatMap { LandmarkGeometry.centroid(of: $0, imageSize: imageSize) }

        var noseOffsetRatio: CGFloat?
        if let interocular, interocular > 0, let eyeLeft, let eyeRight, let noseCenter {
            let eyeMidX = (eyeLeft.x + eyeRight.x) / 2
            noseOffsetRatio = (noseCenter.x - eyeMidX) / interocular
        }

        let hasFiveLandmarkAnchors = eyeLeft != nil && eyeRight != nil && noseCenter != nil

        return LivenessFrame(
            timestamp: timestamp,
            landmarks: points,
            interocularDistance: interocular,
            yaw: face.yaw,
            leftEyeAspectRatio: leftEAR, rightEyeAspectRatio: rightEAR,
            noseOffsetRatio: noseOffsetRatio,
            hasReliableLandmarks: hasFiveLandmarkAnchors,
            deviceOverlapFraction: deviceOverlap,
            glare: glare
        )
    }
}
