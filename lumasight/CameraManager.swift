//
//  CameraManager.swift
//  lumasight
//
//  Owns the AVCaptureSession and publishes the newest camera frame as a CGImage.
//  Runs entirely on-device; only starts on explicit user request and stops cleanly
//  on stop, permission denial, device removal, or session error.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation
import os

enum CameraPermission: Equatable {
    case notDetermined
    case granted
    case denied
    case restricted

    var summaryLabel: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .granted: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
}

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
struct CameraFrame {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private static let logger = Logger(subsystem: "com.jonathan.glance", category: "camera")

    private nonisolated final class ObserverBox: @unchecked Sendable {
        private let lock = NSLock()
        private var observers: [NSObjectProtocol] = []

        func replace(with newObservers: [NSObjectProtocol]) {
            lock.lock()
            let previous = observers
            observers = newObservers
            lock.unlock()
            for observer in previous {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func removeAll() {
            replace(with: [])
        }

        deinit {
            removeAll()
        }
    }

    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Active capture device while a camera session is configured, or nil when released.
    var activeDevice: AVCaptureDevice? { currentInput?.device }
    var onDeviceDisconnected: (@MainActor () -> Void)?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    nonisolated let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private nonisolated let sessionQueue = DispatchQueue(label: "com.jonathan.glance.camera.session")

    /// Handed to the delegate outside the actor; only ever touched via `Task { @MainActor ... }`.
    private let framePublisher = FramePublisher()
    private var startGeneration: UInt64 = 0
    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?

    @ObservationIgnored private let observerBox = ObserverBox()
    @ObservationIgnored private let authorizationStatusProvider: @Sendable () -> AVAuthorizationStatus
    @ObservationIgnored private let accessRequestProvider: @Sendable () async -> Bool
    @ObservationIgnored private let deviceResolver: () -> AVCaptureDevice?

    convenience override init() {
        self.init(
            authorizationStatusProvider: { AVCaptureDevice.authorizationStatus(for: .video) },
            accessRequestProvider: { await AVCaptureDevice.requestAccess(for: .video) },
            deviceResolver: { CameraDeviceCatalog.resolvedDevice() }
        )
    }

    init(
        authorizationStatusProvider: @escaping @Sendable () -> AVAuthorizationStatus,
        accessRequestProvider: @escaping @Sendable () async -> Bool,
        deviceResolver: @escaping () -> AVCaptureDevice?
    ) {
        self.authorizationStatusProvider = authorizationStatusProvider
        self.accessRequestProvider = accessRequestProvider
        self.deviceResolver = deviceResolver
        super.init()
        self.permission = Self.mapPermission(authorizationStatusProvider())
        framePublisher.owner = self
        installSessionObservers()
    }

    deinit {
        observerBox.removeAll()
        framePublisher.owner = nil
        let session = self.session
        let output = self.videoOutput
        sessionQueue.async {
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// Idempotent release of observers, callbacks, and running capture session.
    func teardown() {
        observerBox.removeAll()
        onDeviceDisconnected = nil
        stop()
    }

    /// Reads the current TCC camera permission without prompting.
    static func currentPermission() -> CameraPermission {
        mapPermission(AVCaptureDevice.authorizationStatus(for: .video))
    }

    private static func mapPermission(_ status: AVAuthorizationStatus) -> CameraPermission {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func refreshPermissionStatus() {
        permission = Self.mapPermission(authorizationStatusProvider())
    }

    func start() async {
        startGeneration &+= 1
        let myGeneration = startGeneration

        let status = authorizationStatusProvider()
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await accessRequestProvider()
            guard !Task.isCancelled, myGeneration == startGeneration else { return }
            permission = granted ? .granted : .denied
        case .restricted:
            permission = .restricted
        case .denied:
            permission = .denied
        @unknown default:
            permission = .denied
        }

        // Cancelled / stopped while awaiting user permission prompt.
        guard !Task.isCancelled, myGeneration == startGeneration else { return }

        guard permission == .granted else {
            isRunning = false
            currentFrame = nil
            errorMessage = Self.permissionErrorMessage(for: permission)
            Self.logger.notice("Camera start aborted due to authorization status: \(self.permission.summaryLabel, privacy: .public)")
            return
        }

        errorMessage = nil
        configureSessionIfNeeded()
        guard reconcileDeviceIfNeeded() else {
            isRunning = false
            currentFrame = nil
            return
        }

        let capturedSession = session
        let queue = sessionQueue
        sessionQueue.async { [weak self] in
            if !capturedSession.isRunning {
                capturedSession.startRunning()
            }
            let running = capturedSession.isRunning
            Task { @MainActor [weak self] in
                guard let self, self.startGeneration == myGeneration else {
                    if running {
                        queue.async {
                            if capturedSession.isRunning { capturedSession.stopRunning() }
                        }
                    }
                    return
                }
                self.isRunning = running
                if !running && self.errorMessage == nil {
                    self.errorMessage = "Camera failed to start."
                }
            }
        }
    }

    func stop() {
        startGeneration &+= 1
        let capturedSession = session
        sessionQueue.async {
            if capturedSession.isRunning {
                capturedSession.stopRunning()
            }
        }
        isRunning = false
        currentFrame = nil
    }

    private func installSessionObservers() {
        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let disconnectedID = (notification.object as? AVCaptureDevice)?.uniqueID
            Task { @MainActor [weak self] in
                self?.handleDeviceDisconnected(uniqueID: disconnectedID)
            }
        }

        let runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSessionRuntimeError()
            }
        }

        observerBox.replace(with: [disconnectObserver, runtimeErrorObserver])
    }

    private func handleDeviceDisconnected(uniqueID: String?) {
        guard isRunning || currentInput != nil else { return }
        guard let activeID = currentInput?.device.uniqueID else { return }
        if uniqueID == nil || uniqueID == activeID {
            Self.logger.notice("Active camera disconnected.")
            stop()
            clearCurrentInput()
            errorMessage = "Camera was disconnected. Reconnect a camera or choose another in Camera settings."
            onDeviceDisconnected?()
        }
    }

    private func handleSessionRuntimeError() {
        Self.logger.error("AVCaptureSession encountered a runtime error.")
        stop()
        errorMessage = "The camera session stopped unexpectedly. Stop and start again to retry."
    }

    private func clearCurrentInput() {
        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        session.commitConfiguration()
    }

    private static func permissionErrorMessage(for permission: CameraPermission) -> String {
        switch permission {
        case .restricted:
            return "Camera access is restricted by device management or Screen Time policies on this Mac."
        case .denied, .notDetermined:
            return "Camera access is not enabled. Enable lumasight in System Settings > Privacy & Security > Camera."
        case .granted:
            return ""
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    /// Called on every `start()` so a camera preference change in Settings or a reconnected device takes effect immediately.
    @discardableResult
    private func reconcileDeviceIfNeeded() -> Bool {
        guard let device = deviceResolver(), device.isConnected else {
            clearCurrentInput()
            errorMessage = "No connected camera found. Connect a camera or select one in Camera settings."
            return false
        }

        if let existing = currentInput?.device,
           existing.uniqueID == device.uniqueID,
           existing.isConnected {
            return true
        }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
            self.currentInput = nil
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            selectHighestResolutionFormat(for: device)
            session.commitConfiguration()
            return true
        } else {
            currentInput = nil
            session.commitConfiguration()
            errorMessage = "Unable to open the selected camera."
            return false
        }
    }

    /// Highest resolution regardless of fps — Vision still works from the downscaled frame; this only affects
    /// what `CameraFrame.source` (and therefore `renderCrop`) has to work with.
    private func selectHighestResolutionFormat(for device: AVCaptureDevice) {
        let best = device.formats.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }
        guard let best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            Self.logger.warning("Could not lock camera device for high-resolution format: \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        guard isRunning else { return }
        currentFrame = frame
    }

    /// Renders a native-resolution crop of `imageRect` from `frame.source`, for local diagnostics.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        guard !imageRect.isNull, !imageRect.isEmpty,
              imageRect.origin.x.isFinite, imageRect.origin.y.isFinite,
              imageRect.width.isFinite, imageRect.height.isFinite,
              maxEdge > 0, maxEdge.isFinite
        else { return nil }

        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0,
              frame.sourceSize.width > 0, frame.sourceSize.height > 0,
              frame.sourceSize.width.isFinite, frame.sourceSize.height.isFinite
        else { return nil }

        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: frame.sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isNull, !nativeRect.isEmpty,
              nativeRect.width.isFinite, nativeRect.height.isFinite
        else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        guard !cropped.extent.isNull, !cropped.extent.isEmpty,
              cropped.extent.width.isFinite, cropped.extent.height.isFinite
        else { return nil }

        return cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }

    private nonisolated static let cropRenderContext = CIContext()

    /// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor; this delegate converts there, then hops back.
    private nonisolated final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        weak var owner: CameraManager?
        private let ciContext = CIContext()
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0

        override init() {
            super.init()
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceExtent = sourceImage.extent
            guard !sourceExtent.isNull, !sourceExtent.isEmpty,
                  sourceExtent.width.isFinite, sourceExtent.height.isFinite
            else { return }

            var ciImage = sourceImage
            let longEdge = max(ciImage.extent.width, ciImage.extent.height)
            if longEdge > maxLongEdge {
                let scale = maxLongEdge / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            nextFrameID &+= 1
            let frame = CameraFrame(
                id: nextFrameID,
                image: cgImage,
                source: sourceImage,
                sourceSize: sourceExtent.size
            )

            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
