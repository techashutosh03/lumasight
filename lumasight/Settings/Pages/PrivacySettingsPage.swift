//
//  PrivacySettingsPage.swift
//  lumasight
//
//  Exposes App-level LocalAuthentication lock, honest App Sandbox guarantees,
//  and confirmed cleanup for legacy Keychain entries and files.
//

import AppKit
import SwiftUI

struct PrivacySettingsPage: View {
    @Bindable var privacyManager: PrivacyManager

    @State private var confirmContainerDelete = false
    @State private var pendingUserSelectedURLs: [URL] = []
    @State private var confirmUserSelectedDelete = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "App-Level Protection")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Require \(privacyManager.authenticationTypeDescription) for Settings",
                        subtitle: "Uses Apple's public LocalAuthentication framework only to gate lumasight Settings — never unlocks macOS."
                    ) {
                        lumasightToggle(isOn: Binding(
                            get: { privacyManager.isAppLockEnabled },
                            set: { privacyManager.isAppLockEnabled = $0 }
                        ))
                        .disabled(!privacyManager.canUseAppLock && !privacyManager.isAppLockEnabled)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(
                        title: "App Sandbox",
                        subtitle: privacyManager.isRunningSandboxed
                            ? "Active (no network entitlements, no login automation, no Accessibility access)."
                            : "Process reports unsandboxed container (verify target signing/sandbox in Xcode)."
                    ) {
                        Text(privacyManager.isRunningSandboxed ? "Enforced" : "Off")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(privacyManager.isRunningSandboxed ? .green : .orange)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(
                        title: "Biometric Storage",
                        subtitle: "lumasight stores zero face embeddings, photos, depth maps, or passwords. Frames exist transiently in RAM only."
                    ) {
                        Text("None")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Legacy Data Cleanup")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Legacy mac-login Keychain items",
                        subtitle: keychainSubtitle
                    ) {
                        Text(keychainStatusBadge)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(
                                privacyManager.hasLegacyKeychainData || privacyManager.isLegacyKeychainLookupBlocked
                                    ? Color.orange : SettingsMetrics.textSecondary
                            )
                    }

                    SettingsGroupDivider()

                    SettingsRowContent(
                        title: "Legacy container files",
                        subtitle: containerFileSubtitle
                    ) {
                        Text(privacyManager.hasAnyContainerLegacyFiles ? "Present" : "None")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(privacyManager.hasAnyContainerLegacyFiles ? .orange : SettingsMetrics.textSecondary)
                    }

                    SettingsGroupDivider()

                    SettingsActionRowContent(
                        title: "Delete Container Legacy Data",
                        subtitle: "Removes only legacy pre-rename Keychain entries and container files after confirmation.",
                        buttonTitle: "Delete…",
                        isDestructive: true,
                        isEnabled: privacyManager.hasAnyStoredData || privacyManager.isLegacyKeychainLookupBlocked
                    ) {
                        confirmContainerDelete = true
                    }

                    SettingsGroupDivider()

                    SettingsActionRowContent(
                        title: "Pre-Sandbox User-Guided Cleanup",
                        subtitle: "Choose old `glance` folder or `face-identities.*` files outside the sandbox container via Open Panel.",
                        buttonTitle: "Select Items…",
                        isDestructive: false,
                        isEnabled: true
                    ) {
                        chooseExternalLegacyItems()
                    }
                }

                if let statusMessage {
                    SettingsCaption(text: statusMessage)
                        .foregroundStyle(statusIsError ? .red : .green)
                }

                SettingsCaption(
                    text: "Older unsandboxed builds wrote files under ~/Library/Application Support/glance/ and Keychain entries for \"com.jonathan.glance\". Use \"Select Items…\" above (or inspect Keychain Access manually if cross-team signing blocks programmatic Keychain deletion). Standard deletion does not erase historical Time Machine backups, APFS snapshots, or memory swaps."
                )
            }
        }
        .confirmationDialog(
            "Delete legacy items inside app container?",
            isPresented: $confirmContainerDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Legacy Items", role: .destructive) {
                performContainerCleanup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes strictly legacy Keychain entries (encryptedPassword, sessionKey) for com.jonathan.glance and legacy face-identities files in lumasight's container without reading password contents.")
        }
        .confirmationDialog(
            "Remove legacy files from selected location?",
            isPresented: $confirmUserSelectedDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Legacy Files Only", role: .destructive) {
                performUserSelectedCleanup()
            }
            Button("Cancel", role: .cancel) {
                pendingUserSelectedURLs = []
            }
        } message: {
            Text("lumasight will delete ONLY \"face-identities.enc\" and \"face-identities.json\" from your selection. Unrelated files are never modified or deleted.")
        }
    }

    private var keychainSubtitle: String {
        if privacyManager.hasLegacyKeychainData {
            return "Found legacy \"encryptedPassword\" or \"sessionKey\" items for com.jonathan.glance (contents never read)."
        }
        if privacyManager.isLegacyKeychainLookupBlocked {
            return "Lookup blocked by macOS Keychain ACL/signing isolation; inspect \"com.jonathan.glance\" in Keychain Access if you ran an older build."
        }
        return "None visible in container Keychain lookup."
    }

    private var keychainStatusBadge: String {
        if privacyManager.hasLegacyKeychainData { return "Present" }
        if privacyManager.isLegacyKeychainLookupBlocked { return "Blocked" }
        return "None"
    }

    private var containerFileSubtitle: String {
        if privacyManager.hasLegacyEncryptedFaceFile && privacyManager.hasLegacyUnencryptedFaceFile {
            return "Found legacy face-identities.enc and face-identities.json."
        }
        if privacyManager.hasLegacyEncryptedFaceFile {
            return "Found legacy face-identities.enc."
        }
        if privacyManager.hasLegacyUnencryptedFaceFile {
            return "Found legacy face-identities.json from a prior build."
        }
        return "None stored in lumasight's Application Support container."
    }

    private func performContainerCleanup() {
        let summary = privacyManager.deleteAllLegacyData()
        if summary.succeededWithoutErrors {
            statusIsError = false
            statusMessage = "Removed \(summary.keychainItemsRemoved) Keychain item(s) and \(summary.filesRemoved) container file(s)."
        } else {
            statusIsError = true
            statusMessage = summary.errors.joined(separator: " ")
        }
    }

    private func chooseExternalLegacyItems() {
        let panel = NSOpenPanel()
        panel.title = "Select Legacy Files or Folder"
        panel.message = "Select \"face-identities.enc\", \"face-identities.json\", or the pre-sandbox ~/Library/Application Support/glance folder. Unrelated files will be skipped untouched."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        panel.directoryURL = defaultDir

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        pendingUserSelectedURLs = panel.urls
        confirmUserSelectedDelete = true
    }

    private func performUserSelectedCleanup() {
        let urls = pendingUserSelectedURLs
        pendingUserSelectedURLs = []
        let summary = privacyManager.cleanUserSelectedLegacyItems(at: urls)
        if summary.succeededWithoutErrors {
            statusIsError = false
            statusMessage = "Removed \(summary.filesRemoved) legacy file(s) from your selection."
        } else if summary.filesRemoved > 0 {
            statusIsError = true
            statusMessage = "Removed \(summary.filesRemoved) file(s), with notes: \(summary.errors.joined(separator: " "))"
        } else {
            statusIsError = true
            statusMessage = summary.errors.joined(separator: " ")
        }
    }
}
