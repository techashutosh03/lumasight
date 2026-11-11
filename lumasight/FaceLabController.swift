//
//  FaceLabController.swift
//  lumasight
//
//  Transient in-memory Vision face-detection, experimental 2D liveness cues, and
//  provenance-explicit depth diagnostics. Stores no face embeddings, profiles, or images.
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class FaceLabController {
    let camera: CameraManager
    let depthCoordinator: DepthSessionCoordinator

    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var primaryFace: DetectedFace?
    private(set) var livenessSnapshot: LivenessSnapshot = .empty
    private(set) var livenessGeometry: GeometryLivenessResult = .empty
    private(set) var isRunningLoop = false
    private(set) var statusLog: [String] = []

    var enabledLivenessCues: Set<LivenessCue> = Set(LivenessCue.allCases) {
        didSet { livenessAnalyzer.enabledCuesProvider = { [weak self] in self?.enabledLivenessCues ?? [] } }
    }

    var livenessMode: LivenessMode = lumasightSettings.shared.livenessMode {
        didSet { livenessAnalyzer.modeProvider = { [weak self] in self?.livenessMode ?? .light } }
    }

    @ObservationIgnored private let livenessAnalyzer = LivenessAnalyzer()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var lastProcessedFrameID: UInt64 = 0

    convenience init() {
        self.init(camera: CameraManager(), depthCoordinator: DepthSessionCoordinator())
    }

    init(
        camera: CameraManager,
        depthCoordinator: DepthSessionCoordinator
    ) {
        self.camera = camera
        self.depthCoordinator = depthCoordinator

        livenessAnalyzer.modeProvider = { [weak self] in self?.livenessMode ?? .light }
        livenessAnalyzer.enabledCuesProvider = { [weak self] in self?.enabledLivenessCues ?? [] }

        camera.onDeviceDisconnected = { [weak self] in
            guard let self else { return }
            self.depthCoordinator.handleCameraDisconnected()
            self.appendLog("Camera disconnected; live capture stopped.")
            self.stop()
        }
    }

    deinit {
        loopTask?.cancel()
        previewTask?.cancel()
    }

    // MARK: - Camera Lifecycle (Explicit Opt-In, Transient Processing Only)

    func start() async {
        guard !isRunningLoop else { return }
        livenessAnalyzer.reset()
        livenessSnapshot = .empty
        livenessGeometry = .empty
        detectedFaces = []
        primaryFace = nil

        appendLog("Starting local camera stream (transient memory-only inspection)…")
        await camera.start()

        guard camera.permission == .granted else {
            let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
            depthCoordinator.updateForLiveCamera(
                capabilityInput: CameraDepthCapabilityInput.forMacOSDevice(
                    camera.activeDevice,
                    authorizationStatus: authStatus
                ),
                rgbFrame: nil,
                enableMonocularEstimate: false
            )
            appendLog(camera.errorMessage ?? "Camera permission not granted.")
            return
        }

        guard camera.isRunning else {
            appendLog(camera.errorMessage ?? "Unable to start camera.")
            return
        }

        isRunningLoop = true
        lastProcessedFrameID = 0
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.camera.isRunning {
                if let frame = self.camera.currentFrame, frame.id != self.lastProcessedFrameID {
                    self.lastProcessedFrameID = frame.id
                    await self.processFrame(frame)
                }
                try? await Task.sleep(for: .milliseconds(70))
            }
            self.isRunningLoop = false
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        previewTask?.cancel()
        previewTask = nil
        isRunningLoop = false
        camera.stop()
        depthCoordinator.stop()
        detectedFaces = []
        primaryFace = nil
        livenessAnalyzer.reset()
        livenessSnapshot = .empty
        livenessGeometry = .empty
        appendLog("Camera stopped and transient frame state cleared.")
    }

    func teardown() {
        stop()
        camera.teardown()
    }

    // MARK: - User-Selected Still Depth Photo Inspection

    func chooseImageForDepthInspection() {
        let panel = NSOpenPanel()
        panel.title = "Inspect Image Depth Metadata"
        panel.message = "Choose a portrait photo (for example an iPhone Portrait HEIC or DNG) to inspect embedded AVDepthData metadata transiently in memory."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var types: [UTType] = [.heic, .jpeg, .png]
        if let dngType = UTType("com.adobe.raw-image") {
            types.append(dngType)
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
        }
        depthCoordinator.inspectSelectedImage(at: url)
        let assessment = depthCoordinator.inspectedImageAssessment
        appendLog("Depth inspection for \"\(url.lastPathComponent)\": \(assessment?.provenance.badgeTitle ?? "Unavailable").")
    }

    func clearInspectedImage() {
        depthCoordinator.clearInspectedImage()
    }

    // MARK: - Overlay Demo Preview

    func triggerOverlayPreview(success: Bool) {
        previewTask?.cancel()
        NotchOverlayController.shared.present(styleOverride: lumasightSettings.shared.effectiveUnlockAnimationStyle)
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            NotchOverlayController.shared.finish(success: success)
            self.previewTask = nil
        }
    }

    func toggleCue(_ cue: LivenessCue) {
        if enabledLivenessCues.contains(cue) {
            enabledLivenessCues.remove(cue)
        } else {
            enabledLivenessCues.insert(cue)
        }
    }

    func resetLivenessWindow() {
        livenessAnalyzer.reset()
        livenessSnapshot = .empty
        livenessGeometry = .empty
    }

    // MARK: - Transient Frame Processing

    private func processFrame(_ frame: CameraFrame) async {
        let capability = CameraDepthCapabilityInput.forMacOSDevice(
            camera.activeDevice,
            authorizationStatus: .authorized
        )
        depthCoordinator.updateForLiveCamera(
            capabilityInput: capability,
            rgbFrame: frame.image,
            enableMonocularEstimate: lumasightSettings.shared.isDepthEstimationEnabled
        )

        let detectionResult = await Task.detached(priority: .userInitiated) { () -> ([DetectedFace], DetectedFace?, LivenessFrame?) in
            guard let faces = try? FaceDetector.detectFaces(in: frame.image), !faces.isEmpty else {
                return ([], nil, nil)
            }
            let primary = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
            guard let primary else {
                return (faces, nil, nil)
            }
            let crop = FaceDetector.crop(primary, from: frame.image)
            let livenessFrame = LivenessFeatureExtractor.extract(from: primary, frame: frame.image, faceCrop: crop)
            return (faces, primary, livenessFrame)
        }.value

        guard !Task.isCancelled, camera.isRunning else { return }

        detectedFaces = detectionResult.0
        primaryFace = detectionResult.1
        if let livenessFrame = detectionResult.2 {
            livenessSnapshot = livenessAnalyzer.observe(livenessFrame)
            livenessGeometry = livenessAnalyzer.lastGeometry
        } else {
            livenessSnapshot = .empty
            livenessGeometry = .empty
        }
    }

    private func appendLog(_ message: String) {
        let formatted = "[\(Self.timeFormatter.string(from: Date()))] \(message)"
        statusLog.insert(formatted, at: 0)
        if statusLog.count > 40 {
            statusLog.removeLast(statusLog.count - 40)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
