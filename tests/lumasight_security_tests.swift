//
//  lumasight_security_tests.swift
//  lumasight (tests)
//
//  Comprehensive standalone behavioral, privacy, depth-provenance, and
//  reliability tests compiled directly against the lumasight Swift sources.
//
//  Safety:
//  - Uses isolated `UserDefaults(suiteName:)` suites cleaned up on teardown.
//  - Uses an in-memory `MockKeychainStore` (never touches real user Keychain items).
//  - Uses temporary directories under `NSTemporaryDirectory()` (never touches user Home/Library).
//  - Uses injected camera/depth doubles (never triggers live TCC prompts or captures real camera frames).
//

import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Security
import SwiftUI

private func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
        exit(1)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if actual != expected {
        fputs("FAIL [\(file):\(line)]: \(message) — expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private nonisolated final class MockKeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var accounts: Set<String>
    private var blockedAccounts: [String: OSStatus]
    private var deleteFailures: [String: OSStatus]
    private(set) var deleteCalls: [String] = []

    init(
        initialAccounts: Set<String>,
        blockedAccounts: [String: OSStatus] = [:],
        deleteFailures: [String: OSStatus] = [:]
    ) {
        self.accounts = initialAccounts
        self.blockedAccounts = blockedAccounts
        self.deleteFailures = deleteFailures
    }

    func exists(account: String) -> Bool {
        lookupState(account: account) == .present
    }

    func lookupState(account: String) -> KeychainLookupState {
        lock.lock()
        defer { lock.unlock() }
        if let blocked = blockedAccounts[account] {
            return .inaccessible(blocked)
        }
        return accounts.contains(account) ? .present : .notFound
    }

    func delete(account: String) throws {
        lock.lock()
        deleteCalls.append(account)
        let failure = deleteFailures[account]
        if failure == nil {
            accounts.remove(account)
        }
        lock.unlock()
        if let failure {
            throw KeychainError.osStatus(failure)
        }
    }

    func remainingAccounts() -> Set<String> {
        lock.lock()
        let copy = accounts
        lock.unlock()
        return copy
    }
}

private nonisolated final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    func get() -> T {
        lock.lock()
        let val = storage
        lock.unlock()
        return val
    }

    func set(_ newValue: T) {
        lock.lock()
        storage = newValue
        lock.unlock()
    }
}

private struct MockMonocularEstimator: MonocularDepthEstimator {
    let modelName = "Mock Monocular Depth Model"
    let isModelAvailable: Bool
    let fakeMetricsResult: Result<DepthFrameMetrics, DepthAvailabilityReason>

    func estimateRelativeDepth(from image: CGImage) -> Result<DepthFrameMetrics, DepthAvailabilityReason> {
        fakeMetricsResult
    }
}

@main
@MainActor
struct lumasightSecurityTestRunner {
    static func main() async {
        print("Running lumasight security, privacy, depth, and reliability tests...")
        testSettingsMigrationAndSingleSourceOfTruth()
        await testPrivacyManagerSafeCleanupUserGuidedFlowAndErrors()
        await testCameraPermissionDenialMissingDeviceCancellationAndTeardown()
        await testPresenceDemoOptInTransientAndNoBiometricsSaved()
        testDepthArchitectureMeasuredEstimatedUnavailableAndValidation()
        testDisplayFallbackAndGeometryValidation()
        testFaceDetectorEdgeCaseSafety()
        testCallbackAndMonitorTeardown()
        testOnboardingRemovesPasswordEnrollmentAndPII()
        print("All lumasight security, privacy, depth, and reliability tests passed.")
    }

    // MARK: - 1. Settings Migration (v1/v2 -> v3) & Clamping

    private static func testSettingsMigrationAndSingleSourceOfTruth() {
        let suiteName = "com.jonathan.glance.test.migration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to allocate isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(1, forKey: lumasightSettings.Key.schemaVersion)
        defaults.set(true, forKey: "GlanceSettings.isFaceUnlockEnabled")
        defaults.set(["wake", "space"], forKey: "GlanceSettings.unlockTriggers")
        defaults.set(300, forKey: "GlanceSettings.autoLockInterval")
        defaults.set(true, forKey: "GlanceSettings.autoRetryOnce")
        defaults.set(0.63, forKey: "GlanceSettings.matchThreshold")
        defaults.set("password", forKey: lumasightSettings.Key.onboardingResumeStep)
        defaults.set(true, forKey: lumasightSettings.Key.hasCompletedOnboarding)
        defaults.set(true, forKey: lumasightSettings.Key.hasAcknowledgedSecurityNotice)
        defaults.set(UnlockAnimationStyle.none.rawValue, forKey: lumasightSettings.Key.unlockAnimationStyle)

        let settings = lumasightSettings(userDefaults: defaults)

        expectEqual(
            defaults.integer(forKey: lumasightSettings.Key.schemaVersion),
            lumasightSettings.currentSchemaVersion,
            "Schema version must migrate cleanly to current v3"
        )
        for legacyKey in lumasightSettings.Key.legacyKeys {
            expect(defaults.object(forKey: legacyKey) == nil, "Obsolete key '\(legacyKey)' must be removed during migration")
        }
        expectEqual(settings.onboardingResumeStep, .intro, "Removed 'password' resume step must map safely to .intro")
        expectEqual(settings.hasAcknowledgedSecurityNotice, false, "Upgraded v1 installs must re-acknowledge security notice")
        expectEqual(settings.isPresenceDemoEnabled, false, "Presence demo must default to disabled")
        expectEqual(settings.isAppLockEnabled, false, "App lock must default to disabled")
        expectEqual(settings.isDepthEstimationEnabled, false, "Monocular depth estimation must default to disabled")
        expectEqual(settings.unlockAnimationStyle, .original, "Legacy .none style migrates safely")

        expectEqual(OnboardingStep.fromPersistedRawValue("enroll"), .intro, "Removed 'enroll' step migrates cleanly")
        expectEqual(OnboardingStep.fromPersistedRawValue("name"), .intro, "Removed 'name' step migrates cleanly")
        expectEqual(OnboardingStep.fromPersistedRawValue("preSetup"), .intro, "Removed 'preSetup' step migrates cleanly")

        expectEqual(DetectionDistanceLevel.standard.minimumFaceWidth, lumasightSettings.defaultMinimumFaceWidth, "DetectionDistanceLevel.standard matches defaultMinimumFaceWidth")

        settings.minimumFaceWidth = Float.infinity
        expectEqual(settings.minimumFaceWidth, lumasightSettings.defaultMinimumFaceWidth, "Infinite minimumFaceWidth falls back safely")
        settings.minimumFaceWidth = 0.01
        expectEqual(settings.minimumFaceWidth, lumasightSettings.minimumFaceWidthRange.lowerBound, "minimumFaceWidth clamps min")
        settings.minimumFaceWidth = 0.99
        expectEqual(settings.minimumFaceWidth, lumasightSettings.minimumFaceWidthRange.upperBound, "minimumFaceWidth clamps max")

        settings.faceDetectionSeconds = 0
        expectEqual(settings.faceDetectionSeconds, lumasightSettings.faceDetectionRange.lowerBound, "faceDetectionSeconds clamps min")
        settings.faceDetectionSeconds = 999
        expectEqual(settings.faceDetectionSeconds, lumasightSettings.faceDetectionRange.upperBound, "faceDetectionSeconds clamps max")

        settings.showUnlockAnimation = false
        expectEqual(settings.effectiveUnlockAnimationStyle, .none, "Disabling showUnlockAnimation resolves effective style to .none")

        print("  PASS: Settings migration & clamping")
    }

    // MARK: - 2. Safe Legacy Data Cleanup, Honest Failures, and User-Guided Flow

    private static func testPrivacyManagerSafeCleanupUserGuidedFlowAndErrors() async {
        let suiteName = "com.jonathan.glance.test.privacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempSupportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumasight-privacy-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempSupportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSupportDir) }

        let legacyFaceURL = tempSupportDir.appendingPathComponent(PrivacyManager.legacyFaceFileName)
        let localProfileURL = tempSupportDir.appendingPathComponent(PrivacyManager.legacyLocalEnrollmentFileName)
        let unrelatedFileURL = tempSupportDir.appendingPathComponent("unrelated-note.txt")

        try! Data("legacy-encrypted".utf8).write(to: legacyFaceURL)
        try! Data("[]".utf8).write(to: localProfileURL)
        try! Data("keep-me".utf8).write(to: unrelatedFileURL)

        let unrelatedKeychainAccount = "unrelated.thirdparty.account"
        let mockKeychain = MockKeychainStore(initialAccounts: [
            PrivacyManager.legacyPasswordAccount,
            PrivacyManager.legacySessionKeyAccount,
            unrelatedKeychainAccount,
        ])

        let settings = lumasightSettings(userDefaults: defaults)
        let privacy = PrivacyManager(
            keychain: mockKeychain,
            fileManager: .default,
            legacySupportDirectory: tempSupportDir,
            settings: settings
        )

        expect(privacy.hasLegacyKeychainData, "Must detect legacy Keychain items")
        expect(privacy.hasLegacyEncryptedFaceFile, "Must detect legacy encrypted face file")
        expect(privacy.hasLegacyUnencryptedFaceFile, "Must detect legacy local face JSON file")
        expect(privacy.hasAnyStoredData, "hasAnyStoredData should report true when data exists")

        let summary = privacy.deleteAllLegacyData()
        expect(summary.succeededWithoutErrors, "Cleanup must succeed without errors")
        expectEqual(summary.keychainItemsRemoved, 2, "Must remove both legacy Keychain entries")
        expectEqual(summary.filesRemoved, 2, "Must remove both legacy files")
        expectEqual(privacy.hasLegacyKeychainData, false, "Legacy Keychain items gone")
        expectEqual(privacy.hasAnyContainerLegacyFiles, false, "Legacy container files gone")
        expectEqual(privacy.hasAnyStoredData, false, "No legacy data left")
        expect(mockKeychain.remainingAccounts().contains(unrelatedKeychainAccount), "Unrelated Keychain item preserved")
        expect(FileManager.default.fileExists(atPath: unrelatedFileURL.path), "Unrelated file preserved")

        // Second pass must be idempotent
        let secondSummary = privacy.deleteAllLegacyData()
        expectEqual(secondSummary, PrivacyManager.CleanupSummary(keychainItemsRemoved: 0, filesRemoved: 0, errors: []), "Repeat cleanup idempotent")

        // Failure case: blocked Keychain lookup & delete failure must report errors honestly (never false success)
        let failingKeychain = MockKeychainStore(
            initialAccounts: [PrivacyManager.legacyPasswordAccount],
            blockedAccounts: [PrivacyManager.legacySessionKeyAccount: errSecAuthFailed],
            deleteFailures: [PrivacyManager.legacyPasswordAccount: errSecInteractionNotAllowed]
        )
        let blockedPrivacy = PrivacyManager(
            keychain: failingKeychain,
            fileManager: .default,
            legacySupportDirectory: tempSupportDir,
            settings: settings
        )
        expect(blockedPrivacy.isLegacyKeychainLookupBlocked, "Must expose blocked Keychain lookup state")
        let failSummary = blockedPrivacy.deleteAllLegacyData()
        expectEqual(failSummary.succeededWithoutErrors, false, "Blocked/failed Keychain delete must fail loudly")
        expectEqual(failSummary.keychainItemsRemoved, 0, "Failed delete must report 0 Keychain items removed")
        expectEqual(failSummary.errors.count, 2, "Must report both delete failure and blocked lookup accurately")

        // User-guided NSOpenPanel flow outside container:
        let externalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumasight-external-test-\(UUID().uuidString)", isDirectory: true)
        let externalGlanceFolder = externalRoot.appendingPathComponent("glance", isDirectory: true)
        let wrongFolder = externalRoot.appendingPathComponent("Documents", isDirectory: true)
        try! FileManager.default.createDirectory(at: externalGlanceFolder, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: wrongFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalRoot) }

        let extEnc = externalGlanceFolder.appendingPathComponent("face-identities.enc")
        let extJson = externalGlanceFolder.appendingPathComponent("face-identities.json")
        let extKeep = externalGlanceFolder.appendingPathComponent("user-notes.md")
        let docFile = wrongFolder.appendingPathComponent("tax-return.pdf")
        try! Data("enc".utf8).write(to: extEnc)
        try! Data("json".utf8).write(to: extJson)
        try! Data("keep".utf8).write(to: extKeep)
        try! Data("pdf".utf8).write(to: docFile)

        // Selecting wrong folder / unrelated file skips safely without deletion
        let rejected = privacy.cleanUserSelectedLegacyItems(at: [wrongFolder, docFile, extKeep])
        expectEqual(rejected.filesRemoved, 0, "Unrelated folder/files must never be deleted")
        expectEqual(rejected.errors.count, 3, "Each rejected selection produces an explanation")
        expect(FileManager.default.fileExists(atPath: docFile.path), "Unrelated file in wrong folder untouched")
        expect(FileManager.default.fileExists(atPath: extKeep.path), "Unrelated file untouched")

        // Selecting exact "glance" directory removes ONLY face-identities.enc & face-identities.json
        let cleanedFolder = privacy.cleanUserSelectedLegacyItems(at: [externalGlanceFolder])
        expect(cleanedFolder.succeededWithoutErrors, "Valid glance folder cleanup succeeds")
        expectEqual(cleanedFolder.filesRemoved, 2, "Removes both legacy files in selected glance folder")
        expect(!FileManager.default.fileExists(atPath: extEnc.path), "face-identities.enc deleted")
        expect(!FileManager.default.fileExists(atPath: extJson.path), "face-identities.json deleted")
        expect(FileManager.default.fileExists(atPath: extKeep.path), "Unrelated file inside glance folder preserved")

        // App Lock state toggling
        expectEqual(privacy.isAppUnlocked, true, "App Lock disabled starts unlocked")
        privacy.isAppLockEnabled = true
        privacy.lockApp()
        expectEqual(privacy.isAppUnlocked, false, "lockApp() locks settings when enabled")
        privacy.isAppLockEnabled = false
        expectEqual(privacy.isAppUnlocked, true, "Disabling App Lock unlocks UI")

        print("  PASS: PrivacyManager cleanup, user-guided sandbox flow, error honesty & App Lock")
    }

    // MARK: - 3. Camera Permission Denial, Cancellation, and Teardown

    private static func testCameraPermissionDenialMissingDeviceCancellationAndTeardown() async {
        let promptRequested = SendableBox(false)
        let deniedCamera = CameraManager(
            authorizationStatusProvider: { .denied },
            accessRequestProvider: {
                promptRequested.set(true)
                return false
            },
            deviceResolver: { nil }
        )
        await deniedCamera.start()
        expectEqual(promptRequested.get(), false, "Must not prompt TCC when .denied")
        expectEqual(deniedCamera.permission, .denied, "Permission reflects .denied")
        expectEqual(deniedCamera.isRunning, false, "Camera remains stopped on denial")
        expect(deniedCamera.errorMessage != nil && !deniedCamera.errorMessage!.isEmpty, "Denial explains how to enable camera")

        let restrictedCamera = CameraManager(
            authorizationStatusProvider: { .restricted },
            accessRequestProvider: { false },
            deviceResolver: { nil }
        )
        await restrictedCamera.start()
        expectEqual(restrictedCamera.permission, .restricted, "Permission reflects .restricted")
        expectEqual(restrictedCamera.isRunning, false, "Restricted keeps camera stopped")

        let declinedCamera = CameraManager(
            authorizationStatusProvider: { .notDetermined },
            accessRequestProvider: { false },
            deviceResolver: { nil }
        )
        await declinedCamera.start()
        expectEqual(declinedCamera.permission, .denied, "Declining transitions to .denied")
        expectEqual(declinedCamera.isRunning, false, "Camera stays stopped after decline")

        let noDeviceCamera = CameraManager(
            authorizationStatusProvider: { .authorized },
            accessRequestProvider: { true },
            deviceResolver: { nil }
        )
        await noDeviceCamera.start()
        expectEqual(noDeviceCamera.permission, .granted, "Authorized status reflected")
        expectEqual(noDeviceCamera.isRunning, false, "Missing device keeps camera stopped")

        // Cancellation mid-prompt + teardown + deinit
        let savedContinuation = SendableBox<CheckedContinuation<Bool, Never>?>(nil)
        weak var weakRef: CameraManager?
        do {
            let cancelCamera = CameraManager(
                authorizationStatusProvider: { .notDetermined },
                accessRequestProvider: {
                    await withCheckedContinuation { continuation in
                        savedContinuation.set(continuation)
                    }
                },
                deviceResolver: { nil }
            )
            weakRef = cancelCamera
            let startTask = Task { await cancelCamera.start() }
            for _ in 0..<50 where savedContinuation.get() == nil {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            cancelCamera.teardown()
            cancelCamera.teardown()
            savedContinuation.get()?.resume(returning: true)
            savedContinuation.set(nil)
            await startTask.value
            expectEqual(cancelCamera.isRunning, false, "Cancelled start() stays stopped after teardown()")
            expect(cancelCamera.currentFrame == nil, "teardown() leaves currentFrame nil")
        }
        await Task.yield()
        expect(weakRef == nil, "CameraManager releases cleanly without retain cycles")

        print("  PASS: CameraManager denial, restricted, missing device, cancellation & teardown")
    }

    // MARK: - 4. PresenceCoordinator Opt-in & Zero Persistence Guarantee

    private static func testPresenceDemoOptInTransientAndNoBiometricsSaved() async {
        let suiteName = "com.jonathan.glance.test.presence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempSupportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumasight-no-biometrics-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempSupportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempSupportDir) }

        let settings = lumasightSettings(userDefaults: defaults)
        var dismissCount = 0
        let depthCoordinator = DepthSessionCoordinator()
        let coordinator = PresenceCoordinator(
            settings: settings,
            depthCoordinator: depthCoordinator,
            cameraFactory: {
                CameraManager(
                    authorizationStatusProvider: { .denied },
                    accessRequestProvider: { false },
                    deviceResolver: { nil }
                )
            },
            dismissOverlayHandler: { dismissCount += 1 }
        )

        expectEqual(coordinator.isEnabled, false, "Presence demo must default to disabled")
        await coordinator.startTemporaryDemo(showOverlay: false)
        expectEqual(coordinator.isRunning, false, "Disabled presence demo does not start")
        expectEqual(coordinator.lastOutcome, .cancelled, "Disabled demo returns .cancelled outcome cleanly")

        coordinator.isEnabled = true
        await coordinator.startTemporaryDemo(showOverlay: false)
        expectEqual(coordinator.isRunning, false, "Camera denial cleanly stops presence demo")
        expectEqual(coordinator.lastOutcome, .permissionDenied, "Permission denial accurately recorded in outcome")
        expectEqual(depthCoordinator.liveAssessment.provenance, .unavailable, "Depth must remain unavailable when denied")
        expectEqual(depthCoordinator.liveAssessment.unavailableReason, .permissionDenied, "Depth unavailable reason reflects camera denial")

        let filesWritten = (try? FileManager.default.contentsOfDirectory(atPath: tempSupportDir.path)) ?? []
        expect(filesWritten.isEmpty, "Presence demo must never write any biometric/template/image files to disk")

        coordinator.stop()
        coordinator.stop()
        expect(dismissCount >= 2, "stop() dismisses overlay idempotently")

        print("  PASS: PresenceCoordinator opt-in, permission denial & zero disk persistence")
    }

    // MARK: - 5. Depth / 3D Provenance, Calibration, Validation, Sync & Teardown

    private static func testDepthArchitectureMeasuredEstimatedUnavailableAndValidation() {
        // A. Unavailable checks on native macOS & failure modes
        let macRGBInput = CameraDepthCapabilityInput(
            isNativeMacOSAppKit: true,
            authorizationStatus: .authorized,
            deviceConnected: true,
            deviceName: "FaceTime HD Camera",
            supportsSynchronizedDepthStream: true,
            hasCalibrationData: true
        )
        expectEqual(
            LiveDepthCapability.evaluate(macRGBInput),
            .unsupportedPlatformLiveStreaming,
            "Native macOS live camera capability must accurately report unsupportedPlatformLiveStreaming"
        )

        expectEqual(
            LiveDepthCapability.evaluate(CameraDepthCapabilityInput(
                isNativeMacOSAppKit: false,
                authorizationStatus: .denied,
                deviceConnected: true,
                deviceName: "Depth Cam",
                supportsSynchronizedDepthStream: true,
                hasCalibrationData: true
            )),
            .permissionDenied,
            "Permission denial reported before hardware access"
        )

        expectEqual(
            LiveDepthCapability.evaluate(CameraDepthCapabilityInput(
                isNativeMacOSAppKit: false,
                authorizationStatus: .authorized,
                deviceConnected: false,
                deviceName: nil,
                supportsSynchronizedDepthStream: false,
                hasCalibrationData: false
            )),
            .cameraDisconnected,
            "Missing/disconnected camera reports cameraDisconnected"
        )

        expectEqual(
            LiveDepthCapability.evaluate(CameraDepthCapabilityInput(
                isNativeMacOSAppKit: false,
                authorizationStatus: .authorized,
                deviceConnected: true,
                deviceName: "USB RGB Webcam",
                supportsSynchronizedDepthStream: false,
                hasCalibrationData: false
            )),
            .hardwareLacksDepthSensor(deviceName: "USB RGB Webcam"),
            "Non-depth webcam reports hardwareLacksDepthSensor"
        )

        expectEqual(
            LiveDepthCapability.evaluate(CameraDepthCapabilityInput(
                isNativeMacOSAppKit: false,
                authorizationStatus: .authorized,
                deviceConnected: true,
                deviceName: "TrueDepth",
                supportsSynchronizedDepthStream: true,
                hasCalibrationData: false
            )),
            .calibrationMissing,
            "Depth hardware missing calibration reports calibrationMissing"
        )

        // Default unbundled monocular estimator never downloads/substitutes fake models
        let unbundledEstimator = BundledMonocularDepthEstimator(bundle: .main)
        expectEqual(unbundledEstimator.isModelAvailable, false, "CLI bundle has no bundled monocular depth model")
        let dummyRGB = makeTestCGImage(width: 8, height: 8)!
        if case .failure(let reason) = unbundledEstimator.estimateRelativeDepth(from: dummyRGB) {
            expectEqual(reason, .noMonocularModelBundled, "Unbundled estimator returns .noMonocularModelBundled")
        } else {
            expect(false, "Unbundled estimator must fail rather than invent depth")
        }

        // Coordinator with unbundled estimator reports .noMonocularModelBundled when opted in on RGB macOS camera
        let coordinatorNoModel = DepthSessionCoordinator(monocularEstimator: unbundledEstimator)
        coordinatorNoModel.updateForLiveCamera(
            capabilityInput: macRGBInput,
            rgbFrame: dummyRGB,
            enableMonocularEstimate: true
        )
        expectEqual(coordinatorNoModel.liveAssessment.provenance, .unavailable, "Without bundled depth model, provenance stays unavailable")
        expectEqual(coordinatorNoModel.liveAssessment.unavailableReason, .noMonocularModelBundled, "Missing model reason surfaced clearly")

        // B. Validated hardware-measured DepthFloat32 + Calibration
        let validCalibration = CameraCalibrationSummary(
            focalLengthX: 1200,
            focalLengthY: 1200,
            principalPointX: 320,
            principalPointY: 240,
            referenceWidth: 640,
            referenceHeight: 480,
            pixelSizeMillimeters: 0.0014
        )
        expect(validCalibration.isValid, "Valid calibration intrinsics accepted")

        let invalidCalibration = CameraCalibrationSummary(
            focalLengthX: 0,
            focalLengthY: 1200,
            principalPointX: 320,
            principalPointY: 240,
            referenceWidth: 640,
            referenceHeight: 480,
            pixelSizeMillimeters: 0.0014
        )
        expect(!invalidCalibration.isValid, "Zero focal length calibration rejected")

        let float32Buffer = makeDepthFloat32PixelBuffer(
            width: 4,
            height: 4,
            pixelFormat: kCVPixelFormatType_DepthFloat32,
            values: [
                0.5, 0.6, 0.7, 0.8,
                0.55, 0.65, 0.75, 0.85,
                0.5, 0.6, .nan, 0.8,
                0.5, -1.0, .infinity, 0.9,
            ]
        )!
        switch DepthDataValidator.validatePixelBuffer(
            float32Buffer,
            provenance: .hardwareMeasured,
            unit: .meters,
            accuracy: .absolute,
            calibration: validCalibration,
            isFiltered: true
        ) {
        case .success(let metrics):
            expectEqual(metrics.provenance, .hardwareMeasured, "Hardware measured provenance preserved")
            expectEqual(metrics.unit, .meters, "Meters unit preserved")
            expect(metrics.isMetricAbsolute, "Valid calibrated absolute meters reports isMetricAbsolute = true")
            expectEqual(metrics.width, 4, "Width matches")
            expectEqual(metrics.height, 4, "Height matches")
            expectEqual(metrics.normalizedPreviewGrid.count, DepthFrameMetrics.previewGridColumns * DepthFrameMetrics.previewGridRows, "Grid size fixed")
            expect(metrics.minValue >= 0.5 && metrics.maxValue <= 0.9, "Non-positive / NaN / Inf pixels excluded cleanly")
        case .failure(let reason):
            expect(false, "Expected valid calibrated buffer to succeed, got \(reason)")
        }

        // Hardware map WITHOUT valid calibration must NEVER set isMetricAbsolute = true
        switch DepthDataValidator.validatePixelBuffer(
            float32Buffer,
            provenance: .hardwareMeasured,
            unit: .meters,
            accuracy: .absolute,
            calibration: invalidCalibration,
            isFiltered: false
        ) {
        case .success(let uncalibrated):
            expect(!uncalibrated.isMetricAbsolute, "Missing/invalid calibration must disallow isMetricAbsolute claim")
            expect(uncalibrated.calibration == nil, "Invalid calibration stripped cleanly")
        case .failure(let reason):
            expect(false, "Unexpected failure: \(reason)")
        }

        // C. Float16 Disparity pixel buffer validation (IEEE-754 half floats: 1.0=0x3C00, 0.5=0x3800)
        let float16Disparity = makeDepthFloat16PixelBuffer(
            width: 2,
            height: 2,
            pixelFormat: kCVPixelFormatType_DisparityFloat16,
            bitPatterns: [0x3C00, 0x3800, 0x4000, 0x7E00] // 1.0, 0.5, 2.0, NaN
        )!
        switch DepthDataValidator.validatePixelBuffer(
            float16Disparity,
            provenance: .hardwareMeasured,
            unit: .inverseMeters,
            accuracy: .relative,
            calibration: validCalibration,
            isFiltered: true
        ) {
        case .success(let metrics):
            expectEqual(metrics.unit, .inverseMeters, "Disparity unit accurately reported as inverseMeters")
            expect(!metrics.isMetricAbsolute, "Relative disparity must not claim isMetricAbsolute = true")
            expect(abs(metrics.minValue - 0.5) < 1e-4 && abs(metrics.maxValue - 2.0) < 1e-4, "Float16 bit patterns decoded accurately")
        case .failure(let reason):
            expect(false, "Expected valid float16 disparity to pass, got \(reason)")
        }

        // D. All-invalid depth pixel buffer rejected
        let allCorruptBuffer = makeDepthFloat32PixelBuffer(
            width: 2,
            height: 2,
            pixelFormat: kCVPixelFormatType_DepthFloat32,
            values: [.nan, -.infinity, -0.5, 0.0]
        )!
        if case .failure(let reason) = DepthDataValidator.validatePixelBuffer(
            allCorruptBuffer,
            provenance: .hardwareMeasured,
            unit: .meters,
            accuracy: .absolute,
            calibration: validCalibration,
            isFiltered: false
        ) {
            expectEqual(reason, .invalidDepthValues, "All non-positive/NaN/Inf buffer fails with .invalidDepthValues")
        } else {
            expect(false, "All-invalid depth buffer must be rejected")
        }

        // E. Color/Depth synchronization check + simulated compatible hardware flow
        expect(DepthDataValidator.validateSynchronization(colorTimestampSeconds: 10.0, depthTimestampSeconds: 10.02) == nil, "Small sync delta passes")
        if case .synchronizationMismatch = DepthDataValidator.validateSynchronization(colorTimestampSeconds: 10.0, depthTimestampSeconds: 10.2) {
            // expected
        } else {
            expect(false, "Large sync delta (>50ms) must fail synchronization check")
        }

        let capableInput = CameraDepthCapabilityInput(
            isNativeMacOSAppKit: false,
            authorizationStatus: .authorized,
            deviceConnected: true,
            deviceName: "Simulated Stereo Depth Cam",
            supportsSynchronizedDepthStream: true,
            hasCalibrationData: true
        )
        let measuredMetrics = DepthDataValidator.buildMetrics(
            fromDepthValues: [0.6, 0.7, 0.8, 0.9],
            width: 2,
            height: 2,
            provenance: .hardwareMeasured,
            unit: .meters,
            accuracy: .absolute,
            calibration: validCalibration,
            isFiltered: true
        )
        if case .success(let validSampleMetrics) = measuredMetrics {
            coordinatorNoModel.updateForLiveCamera(
                capabilityInput: capableInput,
                rgbFrame: dummyRGB,
                enableMonocularEstimate: false,
                synchronizedHardwareSample: (colorTime: 5.0, depthTime: 5.5, metrics: validSampleMetrics)
            )
            expectEqual(coordinatorNoModel.liveAssessment.provenance, .unavailable, "Desynced frame rejected cleanly")

            coordinatorNoModel.updateForLiveCamera(
                capabilityInput: capableInput,
                rgbFrame: dummyRGB,
                enableMonocularEstimate: false,
                synchronizedHardwareSample: (colorTime: 5.0, depthTime: 5.01, metrics: validSampleMetrics)
            )
            expectEqual(coordinatorNoModel.liveAssessment.provenance, .hardwareMeasured, "Synchronized calibrated sample accepted as hardwareMeasured")
        } else {
            expect(false, "Expected buildMetrics to succeed")
        }

        // F. Mock Monocular Estimator strictly coerced to non-metric estimated provenance
        let sneakyMockResult = DepthDataValidator.buildMetrics(
            fromDepthValues: [0.2, 0.4, 0.6, 0.8],
            width: 2,
            height: 2,
            provenance: .hardwareMeasured, // try sneaking hardwareMeasured + meters
            unit: .meters,
            accuracy: .absolute,
            calibration: validCalibration,
            isFiltered: false
        )
        let mockEstimator = MockMonocularEstimator(isModelAvailable: true, fakeMetricsResult: sneakyMockResult)
        let estimatedCoordinator = DepthSessionCoordinator(monocularEstimator: mockEstimator)
        estimatedCoordinator.updateForLiveCamera(
            capabilityInput: macRGBInput,
            rgbFrame: dummyRGB,
            enableMonocularEstimate: true
        )
        expectEqual(estimatedCoordinator.liveAssessment.provenance, .monocularEstimated, "Monocular estimator forced to .monocularEstimated")
        if let estMetrics = estimatedCoordinator.liveAssessment.metrics {
            expect(!estMetrics.isMetricAbsolute, "Monocular depth must NEVER claim isMetricAbsolute = true")
            expectEqual(estMetrics.unit, .relativeNormalized, "Monocular depth forced to relativeNormalized")
            expect(estMetrics.calibration == nil, "Monocular depth clears fake hardware calibration")
            expect(estMetrics.honestyDisclaimer.contains("Estimated relative depth"), "Monocular disclaimer explicitly marks estimate")
        } else {
            expect(false, "Expected estimated metrics from mock estimator")
        }

        // Teardown & disconnect state reset
        estimatedCoordinator.handleCameraDisconnected()
        expectEqual(estimatedCoordinator.liveAssessment.provenance, .unavailable, "Disconnect resets provenance to unavailable")
        expectEqual(estimatedCoordinator.liveAssessment.unavailableReason, .cameraDisconnected, "Disconnect sets cameraDisconnected")

        estimatedCoordinator.stop()
        expectEqual(estimatedCoordinator.liveAssessment.unavailableReason, .userDisabled, "Stop resets state cleanly")

        // Image inspection without depth auxiliary metadata fails closed cleanly
        let emptyPNGURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty-no-depth-\(UUID().uuidString).png")
        try? Data("not-an-image".utf8).write(to: emptyPNGURL)
        defer { try? FileManager.default.removeItem(at: emptyPNGURL) }
        let inspected = DepthDataValidator.inspectAuxiliaryDepth(fromImageAt: emptyPNGURL)
        expectEqual(inspected.provenance, .unavailable, "Image lacking auxiliary depth returns unavailable cleanly")

        print("  PASS: Depth provenance (measured, estimated, unavailable), calibration, sync & validation")
    }

    // MARK: - 6. Display Disconnection Fallback & Geometry Validation

    private static func testDisplayFallbackAndGeometryValidation() {
        expectEqual(
            NotchGeometry.preferredDisplayID(
                configuredID: "1",
                connectedIDs: ["2", "3"],
                notchedID: "3",
                mainID: "2",
                fallbackID: "2"
            ),
            "3",
            "Disconnected preferred display falls back to connected notched display"
        )
        expectEqual(
            NotchGeometry.preferredDisplayID(
                configuredID: "1",
                connectedIDs: ["2", "4"],
                notchedID: nil,
                mainID: "4",
                fallbackID: "2"
            ),
            "4",
            "Disconnected preferred without notch falls back to main display"
        )
        expectEqual(
            NotchGeometry.preferredDisplayID(
                configuredID: "1",
                connectedIDs: [],
                notchedID: nil,
                mainID: nil,
                fallbackID: nil
            ),
            nil,
            "No connected displays yields nil cleanly"
        )

        expectEqual(
            NotchGeometry.validatedNotchWidth(screenWidth: 1512, leftPadding: 650, rightPadding: 650, safeAreaTop: 32),
            CGSize(width: 212, height: 32),
            "Valid notched screen geometry calculates exact notch size"
        )
        expectEqual(NotchGeometry.validatedNotchWidth(screenWidth: .nan, leftPadding: 0, rightPadding: 0, safeAreaTop: 32), nil, "NaN screenWidth rejected")
        expectEqual(NotchGeometry.validatedNotchWidth(screenWidth: 1400, leftPadding: -10, rightPadding: 100, safeAreaTop: 32), nil, "Negative padding rejected")

        expectEqual(NotchWindowController.isValidFiniteRect(.null), false, "Null rect rejected")
        expectEqual(NotchWindowController.isValidFiniteRect(CGRect(x: 10, y: 20, width: 200, height: 80)), true, "Finite positive rect accepted")

        let shapes = [
            NotchShape(topRadius: 16, bottomRadius: 60, style: .notch),
            NotchShape(topRadius: 16, bottomRadius: 16, style: .pill),
        ]
        for shape in shapes {
            expect(shape.path(in: .null).isEmpty, "NotchShape yields empty Path for .null")
            expect(shape.path(in: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 40)).isEmpty, "NotchShape yields empty Path for NaN rect")
            expect(!shape.path(in: CGRect(x: 0, y: 0, width: 180, height: 90)).isEmpty, "NotchShape renders valid rect")
        }

        print("  PASS: Display fallback & geometry guards")
    }

    // MARK: - 7. FaceDetector Edge-Case Safety

    private static func testFaceDetectorEdgeCaseSafety() {
        expectEqual(FaceDetector.convertToImageSpace(.null, imageSize: CGSize(width: 640, height: 480)), .zero, "convertToImageSpace rejects .null")
        expectEqual(FaceDetector.convertToImageSpace(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), imageSize: .zero), .zero, "convertToImageSpace rejects zero imageSize")
        expectEqual(FaceDetector.convertToImageSpace(CGRect(x: .nan, y: 0.1, width: 0.5, height: 0.5), imageSize: CGSize(width: 640, height: 480)), .zero, "convertToImageSpace rejects NaN rect")

        if let cgImage = makeTestCGImage(width: 8, height: 8) {
            let badFace = DetectedFace(
                boundingBox: CGRect(x: CGFloat.nan, y: 0, width: 4, height: 4),
                normalizedBoundingBox: .zero,
                quality: nil, yaw: nil, roll: nil, pitch: nil, landmarks: nil,
                imageSize: CGSize(width: 8, height: 8)
            )
            expect(FaceDetector.crop(badFace, from: cgImage) == nil, "FaceDetector.crop returns nil for NaN box")

            let emptyFace = DetectedFace(
                boundingBox: .zero,
                normalizedBoundingBox: .zero,
                quality: nil, yaw: nil, roll: nil, pitch: nil, landmarks: nil,
                imageSize: CGSize(width: 8, height: 8)
            )
            expect(FaceDetector.crop(emptyFace, from: cgImage) == nil, "FaceDetector.crop returns nil for empty box")
        }

        print("  PASS: FaceDetector edge-case safety")
    }

    // MARK: - 8. Callback & Observer Teardown

    private static func testCallbackAndMonitorTeardown() {
        weak var weakController: NotchWindowController?
        do {
            let controller = NotchWindowController()
            weakController = controller
            controller.onScreenParametersChanged = {}
            controller.setInteractiveContentRect(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 50))
            controller.setInteractive(true, key: false)
            controller.teardown()
            controller.teardown()
        }
        expect(weakController == nil, "NotchWindowController releases cleanly after teardown()")

        print("  PASS: Callback & observer teardown idempotence")
    }

    // MARK: - 9. Onboarding Guardrails (No Password, Biometric Enrollment, or PII)

    private static func testOnboardingRemovesPasswordEnrollmentAndPII() {
        let rawSteps = OnboardingStep.allCases.map(\.rawValue)
        expect(!rawSteps.contains("password"), "OnboardingStep must not include password step")
        expect(!rawSteps.contains("enroll"), "OnboardingStep must not include biometric enrollment step")
        expect(!rawSteps.contains("name"), "OnboardingStep must not include profile naming step")
        expectEqual(OnboardingStep.allCases, [.intro, .permissions, .securityNotice, .complete], "Onboarding limited to 4 non-biometric steps")

        print("  PASS: Onboarding removes password collection, persistent enrollment & PII")
    }

    // MARK: - Test Image & CVPixelBuffer Helpers

    private static func makeTestCGImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        return ctx.makeImage()
    }

    private static func makeDepthFloat32PixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        values: [Float]
    ) -> CVPixelBuffer? {
        guard values.count == width * height else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, nil, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                ptr[x] = values[y * width + x]
            }
        }
        return pixelBuffer
    }

    private static func makeDepthFloat16PixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        bitPatterns: [UInt16]
    ) -> CVPixelBuffer? {
        guard bitPatterns.count == width * height else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, nil, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let ptr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                ptr[x] = bitPatterns[y * width + x]
            }
        }
        return pixelBuffer
    }
}
