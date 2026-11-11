//
//  SessionLockButton.swift
//  lumasight
//
//  Header pill displayed when lumasight's optional LocalAuthentication Settings lock
//  is enabled: allows locking or unlocking lumasight's own Settings UI.
//

import SwiftUI

struct SessionLockButton: View {
    @Bindable var privacyManager: PrivacyManager

    @State private var isAuthenticating = false

    var body: some View {
        Button(action: toggleAppLock) {
            HStack(spacing: 7) {
                Image(systemName: privacyManager.isAppUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))

                Text(label)
                    .font(SettingsMetrics.headerButtonFont)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(SettingsMetrics.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: SettingsMetrics.headerButtonHeight)
            .background(Capsule().fill(SettingsMetrics.rowColor))
            .overlay(
                Capsule()
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isAuthenticating)
        .animation(SettingsMetrics.stateTransitionAnimation, value: privacyManager.isAppUnlocked)
        .animation(SettingsMetrics.stateTransitionAnimation, value: isAuthenticating)
        .accessibilityLabel(label)
        .accessibilityHint("Protects lumasight Settings using macOS system authentication. Does not unlock macOS.")
    }

    private var label: String {
        if isAuthenticating { return "Authenticating…" }
        return privacyManager.isAppUnlocked ? "Lock Settings" : "Settings Locked"
    }

    private func toggleAppLock() {
        if privacyManager.isAppUnlocked {
            privacyManager.lockApp()
            return
        }
        isAuthenticating = true
        Task {
            await privacyManager.unlockApp()
            isAuthenticating = false
        }
    }
}
