//
//  lumasightApp.swift
//  lumasight
//
//  Created by Jonathan Zhou on 2026-07-21.
//

import SwiftUI

@main
struct lumasightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        settingsWindow
    }

    private var settingsWindow: some Scene {
        let open = openWindow
        let delegate = appDelegate
        DispatchQueue.main.async {
            delegate.bindOpenWindowAction { open(id: "settings") }
        }
        return Window("lumasight Settings", id: "settings") {
            SettingsWindowView(environment: appDelegate.environment)
                .onAppear {
                    delegate.bindOpenWindowAction { open(id: "settings") }
                }
        }
        .defaultSize(SettingsMetrics.windowSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let environment = AppEnvironment()

    private var statusItem: NSStatusItem?
    private var cameraStatusMenuItem: NSMenuItem?
    private var demoStatusMenuItem: NSMenuItem?
    private var demoActionMenuItem: NSMenuItem?
    private var lockActionMenuItem: NSMenuItem?

    var openSettingsWindowAction: (() -> Void)?

    func bindOpenWindowAction(_ action: @escaping () -> Void) {
        openSettingsWindowAction = action
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(lumasightSettings.shared.showsInMenuBar ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        lumasightSettings.shared.bindMenuBarVisibility { [weak self] isVisible in
            self?.setMenuBarVisibility(isVisible)
        }
        setMenuBarVisibility(lumasightSettings.shared.showsInMenuBar)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        if lumasightSettings.shared.hasCompletedOnboarding {
            if !lumasightSettings.shared.hasAcknowledgedSecurityNotice {
                presentPostUpdateSecurityNotice()
            } else {
                reconcileActivationPolicy()
            }
        } else {
            presentOnboardingGate()
        }
    }

    private func setMenuBarVisibility(_ isVisible: Bool) {
        if isVisible {
            installStatusItemIfNeeded()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            cameraStatusMenuItem = nil
            demoStatusMenuItem = nil
            demoActionMenuItem = nil
            lockActionMenuItem = nil
        }
        reconcileActivationPolicy()
    }

    /// Prevents an unreachable "ghost" state: only hides the Dock icon when a visible menu bar item
    /// is installed AND no primary Settings window is open AND we are not actively forcing `.regular`.
    private func reconcileActivationPolicy() {
        let hasVisibleMainWindow = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
        if hasVisibleMainWindow || statusItem == nil {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        if let iconSize = icon?.size, iconSize.height > 0 {
            let menuBarHeight: CGFloat = 16
            icon?.size = NSSize(width: menuBarHeight * iconSize.width / iconSize.height, height: menuBarHeight)
        }
        item.button?.image = icon
        item.button?.setAccessibilityLabel("lumasight")

        let menu = NSMenu()
        menu.delegate = self

        let cameraStatus = NSMenuItem(title: "Camera: Checking…", action: nil, keyEquivalent: "")
        cameraStatus.isEnabled = false
        menu.addItem(cameraStatus)
        cameraStatusMenuItem = cameraStatus

        let demoStatus = NSMenuItem(title: "Presence Demo: Disabled", action: nil, keyEquivalent: "")
        demoStatus.isEnabled = false
        menu.addItem(demoStatus)
        demoStatusMenuItem = demoStatus

        let demoAction = NSMenuItem(title: "Run Presence Demo", action: #selector(togglePresenceDemo), keyEquivalent: "")
        demoAction.target = self
        menu.addItem(demoAction)
        demoActionMenuItem = demoAction

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let privacyItem = NSMenuItem(title: "Privacy & Data Cleanup…", action: #selector(openPrivacySettings), keyEquivalent: "")
        privacyItem.target = self
        privacyItem.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
        menu.addItem(privacyItem)

        let lockItem = NSMenuItem(title: "Lock lumasight Settings", action: #selector(lockSettings), keyEquivalent: "")
        lockItem.target = self
        lockItem.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        menu.addItem(lockItem)
        lockActionMenuItem = lockItem

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit lumasight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        updateMenuItems()
    }

    private func presentOnboardingGate() {
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
        reconcileActivationPolicy()
        OnboardingController.startFlow(
            resumingAt: lumasightSettings.shared.onboardingResumeStep,
            onFirstRunComplete: { [weak self] in
                self?.revealSettingsWindow()
            }
        )
    }

    private func presentPostUpdateSecurityNotice() {
        for window in NSApp.windows where window.canBecomeMain {
            window.close()
        }
        reconcileActivationPolicy()
        guard NotchOverlayController.shared.phase != .onboarding else { return }
        OnboardingController.startPostUpdateNotice()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow.canBecomeMain else { return }
        let stillOpen = NSApp.windows.contains { $0 !== closingWindow && $0.canBecomeMain && $0.isVisible }
        if !stillOpen && statusItem != nil {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenuItems()
    }

    private func updateMenuItems() {
        let permissionText: String
        switch CameraManager.currentPermission() {
        case .granted: permissionText = "Camera Permission: Granted"
        case .notDetermined: permissionText = "Camera Permission: Not Requested"
        case .denied: permissionText = "Camera Permission: Denied"
        case .restricted: permissionText = "Camera Permission: Restricted"
        }
        cameraStatusMenuItem?.title = permissionText

        let demo = environment.presenceCoordinator
        if demo.isRunning {
            demoStatusMenuItem?.title = "Presence Demo: Running"
            demoActionMenuItem?.title = "Stop Presence Demo"
            demoActionMenuItem?.isEnabled = true
        } else if demo.isEnabled {
            demoStatusMenuItem?.title = "Presence Demo: Ready"
            demoActionMenuItem?.title = "Run Presence Demo"
            demoActionMenuItem?.isEnabled = true
        } else {
            demoStatusMenuItem?.title = "Presence Demo: Disabled (Opt-in)"
            demoActionMenuItem?.title = "Enable in General Settings…"
            demoActionMenuItem?.isEnabled = true
        }

        if let lockActionMenuItem {
            let showLock = environment.privacyManager.isAppLockEnabled && environment.privacyManager.isAppUnlocked
            lockActionMenuItem.isHidden = !showLock
        }
    }

    @objc private func togglePresenceDemo() {
        guard !isBlockedByPostUpdateNotice else {
            presentPostUpdateSecurityNotice()
            return
        }
        let demo = environment.presenceCoordinator
        if demo.isRunning {
            demo.stop()
        } else if demo.isEnabled {
            Task { await demo.startTemporaryDemo() }
        } else {
            environment.selectedSettingsTab = .general
            revealSettingsWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealSettingsWindow()
        return false
    }

    @objc private func openSettingsWindow() {
        revealSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPrivacySettings() {
        environment.selectedSettingsTab = .privacy
        revealSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func lockSettings() {
        environment.privacyManager.lockApp()
    }

    private var isBlockedByPostUpdateNotice: Bool {
        lumasightSettings.shared.hasCompletedOnboarding && !lumasightSettings.shared.hasAcknowledgedSecurityNotice
    }

    private func revealSettingsWindow() {
        if isBlockedByPostUpdateNotice {
            presentPostUpdateSecurityNotice()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard lumasightSettings.shared.hasCompletedOnboarding else {
            if NotchOverlayController.shared.phase != .onboarding {
                presentOnboardingGate()
            }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        if let openSettingsWindowAction {
            openSettingsWindowAction()
        } else {
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        makeSettingsKeyAndActive()
    }

    private func makeSettingsKeyAndActive() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.orderSettingsFront()
            DispatchQueue.main.async {
                self?.orderSettingsFront()
            }
        }
    }

    private func orderSettingsFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
