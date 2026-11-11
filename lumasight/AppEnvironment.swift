//
//  AppEnvironment.swift
//  lumasight
//
//  Owns app-wide, long-lived controllers so Settings pages share one instance instead of racing duplicates.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let privacyManager = PrivacyManager.shared
    let presenceCoordinator: PresenceCoordinator
    let updater = UpdaterController()

    /// Selected tab in Settings — updated by Menu Bar shortcuts (e.g. "Privacy & Data…").
    var selectedSettingsTab: SettingsTab = .general

    /// Revealed by tapping the app icon 5 times on the About page. Plain in-memory `var` so it resets on every relaunch.
    var isDebugSectionRevealed = false

    init() {
        presenceCoordinator = PresenceCoordinator()
    }
}
