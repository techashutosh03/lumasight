//
//  GeneralSettingsPage.swift
//  lumasight
//

import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var coordinator: PresenceCoordinator
    @Bindable private var settings = lumasightSettings.shared

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(title: "Launch at login") {
                    lumasightToggle(isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { newValue in
                            launchAtLoginEnabled = newValue
                            do {
                                try LaunchAtLogin.setEnabled(newValue)
                                launchAtLoginError = nil
                            } catch {
                                launchAtLoginEnabled = !newValue
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                    ))
                }
                SettingsGroupDivider()
                SettingsRowContent(
                    title: "Show in menu bar",
                    subtitle: settings.showsInMenuBar
                        ? "Keep quick status, Settings, and Quit accessible from the menu bar."
                        : "Menu bar icon hidden. The Dock icon remains visible so you can still reopen Settings or quit."
                ) {
                    lumasightToggle(isOn: $settings.showsInMenuBar)
                }
                SettingsGroupDivider()
                SettingsRowContent(
                    title: "Local presence demo",
                    subtitle: "Optional, user-initiated active-session camera test only. Never unlocks macOS or stores credentials.",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    lumasightToggle(isOn: $coordinator.isEnabled)
                }
                SettingsGroupDivider()
                SettingsActionRowContent(
                    title: "Run presence demo",
                    subtitle: coordinator.statusMessage,
                    buttonTitle: coordinator.isRunning ? "Stop Demo" : "Start Demo",
                    isDestructive: coordinator.isRunning,
                    isEnabled: coordinator.isEnabled || coordinator.isRunning
                ) {
                    if coordinator.isRunning {
                        coordinator.stop()
                    } else {
                        Task { await coordinator.startTemporaryDemo() }
                    }
                }
                if let note = coordinator.lastLivenessNote {
                    SettingsGroupDivider()
                    SettingsRowContent(
                        title: "Last demo heuristic",
                        subtitle: note
                    ) {
                        EmptyView()
                    }
                }
                SettingsGroupDivider()
                displayPicker()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }

            if let launchAtLoginError {
                SettingsCaption(text: launchAtLoginError)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Behaviour")
                SettingsGroup {
                    SettingsRowContent(title: "Retry demo on notch hover") {
                        lumasightToggle(isOn: $settings.retryOnHover)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "Haptic feedback") {
                        lumasightToggle(isOn: $settings.hapticFeedbackEnabled)
                    }
                    SettingsGroupDivider()
                    SettingsSteppedSliderRowContent(
                        title: "Demo scan duration",
                        valueLabel: "\(settings.faceDetectionSeconds)s",
                        index: Binding(
                            get: { Double(settings.faceDetectionSeconds - lumasightSettings.faceDetectionRange.lowerBound) },
                            set: { settings.faceDetectionSeconds = lumasightSettings.faceDetectionRange.lowerBound + Int($0.rounded()) }
                        ),
                        stopCount: lumasightSettings.faceDetectionRange.count
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Animation")
                SettingsGroup {
                    SettingsRowContent(title: "Show overlay animation") {
                        lumasightToggle(isOn: $settings.showUnlockAnimation)
                    }
                    SettingsGroupDivider()
                    UnlockAnimationPicker(
                        selection: $settings.unlockAnimationStyle,
                        isEnabled: settings.showUnlockAnimation
                    )
                }
            }
        }
    }

    private func displayPicker() -> some View {
        SettingsRowContent(title: "Display on") {
            SettingsMenuPickerPill(label: displayLabel) {
                Button("Main display") {
                    settings.preferredDisplayID = nil
                    settings.preferredDisplayName = nil
                }
                ForEach(screens.compactMap(NamedScreen.init), id: \.id) { screen in
                    Button(screen.name) {
                        settings.preferredDisplayID = screen.id
                        settings.preferredDisplayName = screen.name
                    }
                }
            }
        }
    }

    private struct NamedScreen {
        let id: String
        let name: String

        init?(_ screen: NSScreen) {
            guard let id = screen.stableDisplayID else { return nil }
            self.id = id
            self.name = screen.localizedName
        }
    }

    private var displayLabel: String {
        guard let targetID = settings.preferredDisplayID else { return "Main display" }
        if let connected = screens.first(where: { $0.stableDisplayID == targetID }) {
            return connected.localizedName
        }
        guard let name = settings.preferredDisplayName else { return "Selected display (disconnected — using fallback)" }
        return "\(name) (disconnected — using fallback)"
    }
}
