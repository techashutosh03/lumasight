//
//  PrivacyManager.swift
//  lumasight
//
//  Manages app-level privacy controls, local footprint inspection, and safe deletion
//  of legacy pre-rename credentials and biometric files.
//
//  Current builds never store face templates, embeddings, images, or passwords.
//

import Foundation
import LocalAuthentication
import Observation
import Security

@Observable
@MainActor
final class PrivacyManager {
    static let shared = PrivacyManager()

    // MARK: - Legacy Credential & File Identifiers

    static let legacyPasswordAccount = "encryptedPassword"
    static let legacySessionKeyAccount = "sessionKey"
    static let legacyFaceFileName = "face-identities.enc"
    static let legacyLocalEnrollmentFileName = "face-identities.json"
    static let allowedLegacyFileNames: Set<String> = [
        legacyFaceFileName,
        legacyLocalEnrollmentFileName,
    ]

    @ObservationIgnored private let keychain: KeychainStoreProtocol
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let legacySupportDirectory: URL
    @ObservationIgnored private let settings: lumasightSettings

    var legacyFaceDataURL: URL {
        legacySupportDirectory.appendingPathComponent(Self.legacyFaceFileName)
    }

    var legacyLocalEnrollmentURL: URL {
        legacySupportDirectory.appendingPathComponent(Self.legacyLocalEnrollmentFileName)
    }

    var legacyFileURLsInContainer: [URL] {
        [legacyFaceDataURL, legacyLocalEnrollmentURL]
    }

    /// True if App Sandbox is active on this running process.
    var isRunningSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Whether any legacy pre-rename Keychain entries are visible to this build.
    var hasLegacyKeychainData: Bool {
        [Self.legacyPasswordAccount, Self.legacySessionKeyAccount]
            .contains { keychain.lookupState(account: $0) == .present }
    }

    /// True when the OS Keychain blocked non-interactive lookup (for example because
    /// a differently signed build owns a legacy access group or Keychain ACL).
    var isLegacyKeychainLookupBlocked: Bool {
        [Self.legacyPasswordAccount, Self.legacySessionKeyAccount].contains {
            if case .inaccessible = keychain.lookupState(account: $0) { return true }
            return false
        }
    }

    var hasLegacyEncryptedFaceFile: Bool {
        fileManager.fileExists(atPath: legacyFaceDataURL.path)
    }

    var hasLegacyUnencryptedFaceFile: Bool {
        fileManager.fileExists(atPath: legacyLocalEnrollmentURL.path)
    }

    var hasAnyContainerLegacyFiles: Bool {
        hasLegacyEncryptedFaceFile || hasLegacyUnencryptedFaceFile
    }

    var hasAnyStoredData: Bool {
        hasLegacyKeychainData || hasAnyContainerLegacyFiles
    }

    // MARK: - App-Level Lock (LocalAuthentication)

    /// Whether lumasight Settings require `LocalAuthentication` to open.
    var isAppLockEnabled: Bool {
        get { settings.isAppLockEnabled }
        set {
            settings.isAppLockEnabled = newValue
            if !newValue {
                isAppUnlocked = true
                authenticationError = nil
            }
        }
    }

    private(set) var isAppUnlocked: Bool = true
    private(set) var authenticationError: String?

    var canUseAppLock: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    var authenticationTypeDescription: String {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: &error) {
            switch context.biometryType {
            case .touchID:
                return "Touch ID or Apple Watch"
            case .opticID:
                return "Optic ID"
            case .faceID:
                return "Face ID"
            case .none:
                return "Apple Watch or System Authentication"
            @unknown default:
                return "System Authentication"
            }
        }
        return canUseAppLock ? "System Passcode" : "Not available"
    }

    init(
        keychain: KeychainStoreProtocol = SystemKeychainStore.shared,
        fileManager: FileManager = .default,
        legacySupportDirectory: URL? = nil,
        settings: lumasightSettings? = nil
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
        let resolvedSettings = settings ?? lumasightSettings.shared
        self.settings = resolvedSettings
        if let legacySupportDirectory {
            self.legacySupportDirectory = legacySupportDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.legacySupportDirectory = appSupport.appendingPathComponent("glance", isDirectory: true)
        }

        if resolvedSettings.isAppLockEnabled {
            self.isAppUnlocked = false
        }
    }

    // MARK: - Authentication

    func unlockApp() async {
        guard isAppLockEnabled else {
            isAppUnlocked = true
            authenticationError = nil
            return
        }

        let context = LAContext()
        var policyError: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: &policyError)
            ? .deviceOwnerAuthenticationWithBiometricsOrCompanion
            : .deviceOwnerAuthentication

        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            isAppUnlocked = false
            authenticationError = policyError?.localizedDescription ?? "System authentication is not available on this Mac."
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                policy,
                localizedReason: "Unlock lumasight Settings"
            )
            isAppUnlocked = success
            authenticationError = success ? nil : "Authentication failed."
        } catch let laError as LAError {
            isAppUnlocked = false
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                authenticationError = "Authentication was cancelled."
            case .biometryLockout:
                authenticationError = "Biometry is locked out. Unlock using your Mac password in the system prompt."
            case .passcodeNotSet:
                authenticationError = "Set a macOS login password or passcode to use App Lock."
            default:
                authenticationError = laError.localizedDescription
            }
        } catch {
            isAppUnlocked = false
            authenticationError = error.localizedDescription
        }
    }

    func lockApp() {
        if isAppLockEnabled {
            isAppUnlocked = false
            authenticationError = nil
        }
    }

    // MARK: - Legacy Data Deletion (Never Reads Password Payloads)

    struct CleanupSummary: Equatable {
        let keychainItemsRemoved: Int
        let filesRemoved: Int
        let errors: [String]

        var succeededWithoutErrors: Bool { errors.isEmpty }
    }

    /// Purges legacy pre-rename Keychain entries (`encryptedPassword`, `sessionKey`) and
    /// legacy biometric files inside the active Application Support container.
    /// Reports any OSStatus/file error explicitly and never deletes unrelated data.
    @discardableResult
    func deleteAllLegacyData() -> CleanupSummary {
        var keychainCount = 0
        var errors: [String] = []

        for account in [Self.legacyPasswordAccount, Self.legacySessionKeyAccount] {
            switch keychain.lookupState(account: account) {
            case .present:
                do {
                    try keychain.delete(account: account)
                    keychainCount += 1
                } catch {
                    errors.append("Failed to remove legacy Keychain item \"\(account)\": \(error.localizedDescription)")
                }
            case .inaccessible(let status):
                errors.append(
                    "Legacy Keychain item check for \"\(account)\" was blocked (OSStatus \(status)); remove \"\(SystemKeychainStore.defaultService)\" manually in Keychain Access if present."
                )
            case .notFound:
                break
            }
        }

        let fileResult = removeAllowedLegacyFiles(at: legacyFileURLsInContainer)
        errors.append(contentsOf: fileResult.errors)

        return CleanupSummary(
            keychainItemsRemoved: keychainCount,
            filesRemoved: fileResult.removedCount,
            errors: errors
        )
    }

    /// User-guided cleanup for files or the `glance` Application Support folder chosen
    /// explicitly via `NSOpenPanel` across the App Sandbox boundary.
    /// Strictly deletes ONLY `face-identities.enc` and `face-identities.json`; rejects
    /// all other files and never recursively scans arbitrary directories.
    func cleanUserSelectedLegacyItems(at selectedURLs: [URL]) -> CleanupSummary {
        var targets: [URL] = []
        var errors: [String] = []

        for url in selectedURLs {
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started { url.stopAccessingSecurityScopedResource() }
            }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                guard url.lastPathComponent == "glance" else {
                    errors.append("Skipped folder \"\(url.lastPathComponent)\": only a folder named \"glance\" can be inspected for legacy biometric files.")
                    continue
                }
                let candidates = Self.allowedLegacyFileNames.sorted().map { url.appendingPathComponent($0) }
                let existing = candidates.filter { fileManager.fileExists(atPath: $0.path) }
                if existing.isEmpty {
                    errors.append("No legacy files (face-identities.enc or face-identities.json) were found inside \"\(url.lastPathComponent)\".")
                } else {
                    for candidate in existing {
                        do {
                            try fileManager.removeItem(at: candidate)
                            targets.append(candidate)
                        } catch {
                            errors.append("Failed to remove \(candidate.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                guard Self.allowedLegacyFileNames.contains(url.lastPathComponent) else {
                    errors.append("Skipped \"\(url.lastPathComponent)\": only legacy files (face-identities.enc, face-identities.json) can be removed.")
                    continue
                }
                do {
                    try fileManager.removeItem(at: url)
                    targets.append(url)
                } catch {
                    errors.append("Failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        return CleanupSummary(
            keychainItemsRemoved: 0,
            filesRemoved: targets.count,
            errors: errors
        )
    }

    private func removeAllowedLegacyFiles(at urls: [URL]) -> (removedCount: Int, errors: [String]) {
        var removed = 0
        var errors: [String] = []

        for url in urls {
            guard Self.allowedLegacyFileNames.contains(url.lastPathComponent),
                  fileManager.fileExists(atPath: url.path) else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                errors.append("Failed to remove \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return (removed, errors)
    }
}
