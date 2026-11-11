//
//  lumasightSettings.swift
//  lumasight
//
//  Persists user preferences via UserDefaults and isolates non-security settings
//  from removed legacy unlock/password/biometric configuration.
//

import Foundation
import Observation

/// Active-session overlay visual style used when running an optional local demo.
enum UnlockAnimationStyle: String, CaseIterable, Identifiable {
    case none
    case minimal
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .original: return "Original"
        }
    }

    static let selectableCases: [UnlockAnimationStyle] = [.minimal, .original]
}

/// Maps slider positions (far / standard / close) to transient Vision face width thresholds.
enum DetectionDistanceLevel: CaseIterable {
    case close, standard, far

    var title: String {
        switch self {
        case .close: return "Close"
        case .standard: return "Default"
        case .far: return "Far"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.23
        case .standard: return lumasightSettings.defaultMinimumFaceWidth
        case .far: return 0.15
        }
    }

    var sliderIndex: Double {
        switch self {
        case .far: return 0
        case .standard: return 1
        case .close: return 2
        }
    }

    static func from(sliderIndex: Double) -> Self {
        switch Int(sliderIndex.rounded()) {
        case 0: return .far
        case 2: return .close
        default: return .standard
        }
    }

    static func nearest(to width: Float) -> Self {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .standard
    }
}

@Observable
final class lumasightSettings {
    static let shared = lumasightSettings()

    static let currentSchemaVersion = 3
    static let defaultMinimumFaceWidth: Float = 0.19
    static let minimumFaceWidthRange: ClosedRange<Float> = 0.12...0.35
    static let faceDetectionRange = 3...10

    // Persisted UserDefaults keys retain their legacy "GlanceSettings." prefix so
    // existing preferences and v1/v2 migrations remain intact under bundle ID com.jonathan.glance.
    enum Key {
        static let schemaVersion = "GlanceSettings.schemaVersion"
        static let isPresenceDemoEnabled = "GlanceSettings.isPresenceDemoEnabled"
        static let isAppLockEnabled = "GlanceSettings.isAppLockEnabled"
        static let livenessChecksEnabled = "GlanceSettings.livenessChecksEnabled"
        static let livenessMode = "GlanceSettings.livenessMode"
        static let isDepthEstimationEnabled = "GlanceSettings.isDepthEstimationEnabled"
        static let minimumFaceWidth = "GlanceSettings.minimumFaceWidth"
        static let unlockAnimationStyle = "GlanceSettings.unlockAnimationStyle"
        static let showUnlockAnimation = "GlanceSettings.showUnlockAnimation"
        static let retryOnHover = "GlanceSettings.retryOnHover"
        static let faceDetectionSeconds = "GlanceSettings.faceDetectionSeconds"
        static let hapticFeedbackEnabled = "GlanceSettings.hapticFeedbackEnabled"
        static let showsInMenuBar = "GlanceSettings.showsInMenuBar"
        static let preferredDisplayID = "GlanceSettings.preferredDisplayID"
        static let preferredDisplayName = "GlanceSettings.preferredDisplayName"
        static let defaultCameraID = "GlanceSettings.defaultCameraID"
        static let builtInDisplayCameraID = "GlanceSettings.builtInDisplayCameraID"
        static let externalDisplayCameraID = "GlanceSettings.externalDisplayCameraID"
        static let hasCompletedOnboarding = "GlanceSettings.hasCompletedOnboarding"
        static let onboardingResumeStep = "GlanceSettings.onboardingResumeStep"
        static let hasAcknowledgedSecurityNotice = "GlanceSettings.hasAcknowledgedSecurityNotice"

        // Deprecated keys removed during v1/v2 -> v3 migration.
        static let legacyKeys = [
            "GlanceSettings.isFaceUnlockEnabled",
            "GlanceSettings.unlockTriggers",
            "GlanceSettings.autoLockInterval",
            "GlanceSettings.autoRetryOnce",
            "GlanceSettings.matchThreshold",
        ]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var menuBarVisibilityDidChange: ((Bool) -> Void)?

    /// Whether optional, user-initiated active-session presence demonstration is enabled.
    var isPresenceDemoEnabled: Bool {
        didSet { defaults.set(isPresenceDemoEnabled, forKey: Key.isPresenceDemoEnabled) }
    }

    /// Whether `LocalAuthentication` is required to open lumasight Settings.
    var isAppLockEnabled: Bool {
        didSet { defaults.set(isAppLockEnabled, forKey: Key.isAppLockEnabled) }
    }

    /// Experimental 2D camera cues only — never a security guarantee.
    var livenessChecksEnabled: Bool {
        didSet { defaults.set(livenessChecksEnabled, forKey: Key.livenessChecksEnabled) }
    }

    var livenessMode: LivenessMode {
        didSet { defaults.set(livenessMode.rawValue, forKey: Key.livenessMode) }
    }

    /// Opt-in flag for monocular relative depth estimation if a licensed Core ML model is bundled.
    var isDepthEstimationEnabled: Bool {
        didSet { defaults.set(isDepthEstimationEnabled, forKey: Key.isDepthEstimationEnabled) }
    }

    var minimumFaceWidth: Float {
        didSet {
            let clamped = Self.clamp(minimumFaceWidth, to: Self.minimumFaceWidthRange, fallback: Self.defaultMinimumFaceWidth)
            if clamped != minimumFaceWidth {
                minimumFaceWidth = clamped
                return
            }
            defaults.set(minimumFaceWidth, forKey: Key.minimumFaceWidth)
        }
    }

    var unlockAnimationStyle: UnlockAnimationStyle {
        didSet { defaults.set(unlockAnimationStyle.rawValue, forKey: Key.unlockAnimationStyle) }
    }

    var showUnlockAnimation: Bool {
        didSet { defaults.set(showUnlockAnimation, forKey: Key.showUnlockAnimation) }
    }

    var effectiveUnlockAnimationStyle: UnlockAnimationStyle {
        showUnlockAnimation ? unlockAnimationStyle : .none
    }

    var retryOnHover: Bool {
        didSet { defaults.set(retryOnHover, forKey: Key.retryOnHover) }
    }

    var faceDetectionSeconds: Int {
        didSet {
            let clamped = Self.clampInt(faceDetectionSeconds, to: Self.faceDetectionRange)
            guard clamped == faceDetectionSeconds else {
                faceDetectionSeconds = clamped
                return
            }
            defaults.set(faceDetectionSeconds, forKey: Key.faceDetectionSeconds)
        }
    }

    var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Key.hapticFeedbackEnabled) }
    }

    var showsInMenuBar: Bool {
        didSet {
            guard showsInMenuBar != oldValue else { return }
            defaults.set(showsInMenuBar, forKey: Key.showsInMenuBar)
            menuBarVisibilityDidChange?(showsInMenuBar)
        }
    }

    var preferredDisplayID: String? {
        didSet { defaults.set(preferredDisplayID, forKey: Key.preferredDisplayID) }
    }

    var preferredDisplayName: String? {
        didSet { defaults.set(preferredDisplayName, forKey: Key.preferredDisplayName) }
    }

    var defaultCameraID: String? {
        didSet { defaults.set(defaultCameraID, forKey: Key.defaultCameraID) }
    }

    var builtInDisplayCameraID: String? {
        didSet { defaults.set(builtInDisplayCameraID, forKey: Key.builtInDisplayCameraID) }
    }

    var externalDisplayCameraID: String? {
        didSet { defaults.set(externalDisplayCameraID, forKey: Key.externalDisplayCameraID) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    var onboardingResumeStep: OnboardingStep? {
        didSet { defaults.set(onboardingResumeStep?.rawValue, forKey: Key.onboardingResumeStep) }
    }

    var hasAcknowledgedSecurityNotice: Bool {
        didSet { defaults.set(hasAcknowledgedSecurityNotice, forKey: Key.hasAcknowledgedSecurityNotice) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        Self.migrateIfNeeded(in: userDefaults)

        isPresenceDemoEnabled = userDefaults.object(forKey: Key.isPresenceDemoEnabled) as? Bool ?? false
        isAppLockEnabled = userDefaults.object(forKey: Key.isAppLockEnabled) as? Bool ?? false
        livenessChecksEnabled = userDefaults.object(forKey: Key.livenessChecksEnabled) as? Bool ?? true
        livenessMode = userDefaults.string(forKey: Key.livenessMode)
            .flatMap(LivenessMode.init(rawValue:)) ?? .light
        isDepthEstimationEnabled = userDefaults.object(forKey: Key.isDepthEstimationEnabled) as? Bool ?? false

        let rawWidth = userDefaults.object(forKey: Key.minimumFaceWidth) as? Float ?? Self.defaultMinimumFaceWidth
        minimumFaceWidth = Self.clamp(rawWidth, to: Self.minimumFaceWidthRange, fallback: Self.defaultMinimumFaceWidth)

        let storedStyle: UnlockAnimationStyle
        if let raw = userDefaults.string(forKey: Key.unlockAnimationStyle),
           let style = UnlockAnimationStyle(rawValue: raw) {
            storedStyle = style
        } else {
            storedStyle = .original
        }
        unlockAnimationStyle = storedStyle == .none ? .original : storedStyle
        showUnlockAnimation = userDefaults.object(forKey: Key.showUnlockAnimation) as? Bool ?? true

        retryOnHover = userDefaults.object(forKey: Key.retryOnHover) as? Bool ?? true
        let rawSeconds = userDefaults.object(forKey: Key.faceDetectionSeconds) as? Int ?? 5
        faceDetectionSeconds = Self.clampInt(rawSeconds, to: Self.faceDetectionRange)

        hapticFeedbackEnabled = userDefaults.object(forKey: Key.hapticFeedbackEnabled) as? Bool ?? false
        showsInMenuBar = userDefaults.object(forKey: Key.showsInMenuBar) as? Bool ?? true
        preferredDisplayID = userDefaults.string(forKey: Key.preferredDisplayID)
        preferredDisplayName = userDefaults.string(forKey: Key.preferredDisplayName)
        defaultCameraID = userDefaults.string(forKey: Key.defaultCameraID)
        builtInDisplayCameraID = userDefaults.string(forKey: Key.builtInDisplayCameraID)
        externalDisplayCameraID = userDefaults.string(forKey: Key.externalDisplayCameraID)
        hasCompletedOnboarding = userDefaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        onboardingResumeStep = userDefaults.string(forKey: Key.onboardingResumeStep)
            .flatMap(OnboardingStep.fromPersistedRawValue)
        hasAcknowledgedSecurityNotice = userDefaults.object(forKey: Key.hasAcknowledgedSecurityNotice) as? Bool ?? false
    }

    static func migrateIfNeeded(in defaults: UserDefaults) {
        let recordedVersion = defaults.integer(forKey: Key.schemaVersion)
        guard recordedVersion < currentSchemaVersion else { return }

        for key in Key.legacyKeys {
            defaults.removeObject(forKey: key)
        }

        if recordedVersion < 2 {
            // Force explicit opt-in after upgrading from legacy v1 unlock builds.
            defaults.set(false, forKey: Key.isPresenceDemoEnabled)
            defaults.set(false, forKey: Key.isAppLockEnabled)

            if defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool == true {
                defaults.set(false, forKey: Key.hasAcknowledgedSecurityNotice)
            }
        }

        if let rawResume = defaults.string(forKey: Key.onboardingResumeStep) {
            let mapped = OnboardingStep.fromPersistedRawValue(rawResume) ?? .intro
            defaults.set(mapped.rawValue, forKey: Key.onboardingResumeStep)
        }

        if defaults.string(forKey: Key.unlockAnimationStyle) == UnlockAnimationStyle.none.rawValue {
            defaults.set(UnlockAnimationStyle.original.rawValue, forKey: Key.unlockAnimationStyle)
            defaults.set(false, forKey: Key.showUnlockAnimation)
        }

        defaults.set(currentSchemaVersion, forKey: Key.schemaVersion)
    }

    func bindMenuBarVisibility(_ handler: @escaping (Bool) -> Void) {
        menuBarVisibilityDidChange = handler
    }

    private static func clamp(_ value: Float, to range: ClosedRange<Float>, fallback: Float) -> Float {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clampInt(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
