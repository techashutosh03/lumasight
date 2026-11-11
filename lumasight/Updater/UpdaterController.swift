//
//  UpdaterController.swift
//  lumasight
//
//  Replaces the unsandboxed Sparkle auto-updater in this privacy-first build.
//
//  Why automatic updates are disabled:
//  - Under macOS App Sandbox (`ENABLE_APP_SANDBOX = YES`), Sparkle cannot safely
//    replace the app bundle without `SUEnableInstallerLauncherService = true`,
//    embedded XPC services, outbound network entitlements (`network.client`),
//    and mach-lookup temporary exceptions.
//  - Keeping lumasight completely offline (zero network entitlements) eliminates
//    background network connections and updater attack surface. Users can
//    manually open the verified HTTPS project releases page in their browser.
//

import AppKit
import Observation

@Observable
@MainActor
final class UpdaterController {
    static let releasesURL = URL(string: "https://github.com/techashutosh03/lumasight/releases")!

    /// Automatic in-app updates are disabled in this offline sandboxed build.
    let canCheckForUpdates = false
    let isPresentingUpdateUI = false
    let statusMessage = "In-app auto-updater is disabled to keep lumasight offline and strictly App Sandboxed."

    func start() {
        // Intentional no-op: no background network requests or update prompts on launch.
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(Self.releasesURL)
    }
}
