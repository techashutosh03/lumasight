//
//  CameraSettingsPage.swift
//  lumasight
//

import AVFoundation
import SwiftUI

struct CameraSettingsPage: View {
    @State private var devices: [CameraDevice] = CameraDeviceCatalog.availableDevices()
    @Bindable private var settings = lumasightSettings.shared
    @State private var previewCamera = CameraManager()
    @State private var isPreviewShown = false

    private var permission: CameraPermission {
        CameraManager.currentPermission()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                cameraPicker(title: "Default", selection: $settings.defaultCameraID)
                SettingsGroupDivider()
                cameraPicker(title: "Built-in display", selection: $settings.builtInDisplayCameraID)
                SettingsGroupDivider()
                cameraPicker(title: "External display", selection: $settings.externalDisplayCameraID)
            }

            if devices.isEmpty {
                SettingsCaption(text: "No video cameras detected. Connect a camera and tap Refresh in the top-right header.")
            }

            HStack {
                SettingsSectionTitle(text: "Preview")
                Spacer()
                if isPreviewShown {
                    Button("Hide preview") {
                        hidePreview()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(lumasightTheme.accent)
                }
            }
            .padding(.bottom, -4)

            previewArea
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                        .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )

            if let error = previewCamera.errorMessage {
                SettingsCaption(text: error)
                    .foregroundStyle(.red)

                if permission == .denied || permission == .restricted {
                    Button("Open Camera Privacy Settings") {
                        openCameraPrivacySettings()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(lumasightTheme.accent)
                }
            }
        }
        .preference(key: HeaderTrailingActionKey.self, value: HeaderAction(perform: refreshDevices))
        .onChange(of: settings.defaultCameraID) { restartPreview() }
        .onChange(of: settings.builtInDisplayCameraID) { restartPreview() }
        .onChange(of: settings.externalDisplayCameraID) { restartPreview() }
        .onDisappear {
            previewCamera.teardown()
            isPreviewShown = false
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if isPreviewShown {
            CameraPreviewView(session: previewCamera.session, faces: [])
        } else {
            ZStack {
                SettingsMetrics.rowColor
                SettingsPrimaryButton(title: "Show preview", action: showPreview)
            }
        }
    }

    private func showPreview() {
        isPreviewShown = true
        previewCamera.onDeviceDisconnected = {
            isPreviewShown = false
        }
        Task { await previewCamera.start() }
    }

    private func hidePreview() {
        previewCamera.teardown()
        isPreviewShown = false
    }

    private func restartPreview() {
        guard isPreviewShown else { return }
        previewCamera.stop()
        Task { await previewCamera.start() }
    }

    private func cameraPicker(title: String, selection: Binding<String?>) -> some View {
        SettingsRowContent(title: title) {
            SettingsMenuPickerPill(label: cameraLabel(for: selection.wrappedValue)) {
                Button("System default") { selection.wrappedValue = nil }
                ForEach(devices) { device in
                    Button(device.name) { selection.wrappedValue = device.id }
                }
            }
        }
    }

    private func refreshDevices() {
        devices = CameraDeviceCatalog.availableDevices()
    }

    private func cameraLabel(for id: String?) -> String {
        guard let id, let device = devices.first(where: { $0.id == id }) else {
            return "System default"
        }
        return device.name
    }

    private func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}
