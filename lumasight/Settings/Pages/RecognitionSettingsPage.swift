//
//  RecognitionSettingsPage.swift
//  lumasight
//
//  Configures transient local face-detection framing, experimental 2D liveness cues,
//  and honest depth source diagnostics. Does not store biometric templates or perform
//  identity matching.
//

import AVFoundation
import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: PresenceCoordinator
    @Bindable private var settings = lumasightSettings.shared

    private var depthCapabilityReason: DepthAvailabilityReason? {
        LiveDepthCapability.evaluate(
            device: CameraDeviceCatalog.resolvedDevice(),
            authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsOptionSliderRowContent(
                    title: "Detection framing distance",
                    stepLabels: DetectionDistanceLevel.allCases.map(\.title),
                    index: detectionDistanceIndex,
                    stopCount: DetectionDistanceLevel.allCases.count
                )
            }
            SettingsCaption(
                text: "Vision detects face rectangles and landmarks transiently in memory only. No face profiles, templates, or embeddings are stored or matched."
            )

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Depth / 3D Source")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Live hardware depth",
                        subtitle: depthCapabilityReason?.explanation ?? "Calibrated hardware depth stream available."
                    ) {
                        Text(depthCapabilityReason == nil ? "Available" : "Unavailable")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }

                    SettingsGroupDivider()

                    SettingsRowContent(
                        title: "Monocular depth estimate (non-metric)",
                        subtitle: coordinator.depthCoordinator.isMonocularModelBundled
                            ? "Optional relative depth estimate inferred from 2D RGB. Never metric or proof of identity."
                            : "Disabled: no licensed local Core ML monocular depth model is bundled in lumasight."
                    ) {
                        lumasightToggle(isOn: $settings.isDepthEstimationEnabled)
                            .disabled(!coordinator.depthCoordinator.isMonocularModelBundled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Experimental 2D Liveness Cues")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Liveness heuristic",
                        subtitle: "Experimental 2D cues checking glare or simple motion/blink changes. Never replaces hardware depth or proves identity.",
                        subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                    ) {
                        lumasightToggle(isOn: $settings.livenessChecksEnabled)
                    }
                    SettingsGroupDivider()
                    LivenessModePicker(
                        selection: $settings.livenessMode,
                        isEnabled: settings.livenessChecksEnabled
                    )
                }
            }
        }
    }

    private var detectionDistanceLevel: DetectionDistanceLevel {
        .nearest(to: settings.minimumFaceWidth)
    }

    private var detectionDistanceIndex: Binding<Double> {
        Binding(
            get: { detectionDistanceLevel.sliderIndex },
            set: { settings.minimumFaceWidth = DetectionDistanceLevel.from(sliderIndex: $0).minimumFaceWidth }
        )
    }
}
