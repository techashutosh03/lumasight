//
//  FaceLabView.swift
//  lumasight
//
//  Transient Vision & Depth Lab: inspects local Vision face detection, experimental
//  2D liveness cues, and hardware/estimated depth provenance without persisting
//  any face embeddings, photos, or templates.
//

import AppKit
import CoreGraphics
import SwiftUI

struct FaceLabView: View {
    @Bindable var controller: FaceLabController
    @Bindable private var settings = lumasightSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cameraSection
            detectionSection
            depthSection
            livenessSection
            overlayPreviewSection
            if !controller.statusLog.isEmpty {
                logSection
            }
        }
        .onDisappear {
            controller.stop()
        }
    }

    // MARK: - Live Camera

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsSectionTitle(text: "Live Camera (Transient In-Memory)")
                Spacer()
                if controller.camera.isRunning {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text("Camera Active")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.14), in: Capsule())
                }
            }

            SettingsGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.28))

                        if controller.camera.isRunning {
                            CameraPreviewView(
                                session: controller.camera.session,
                                faces: controller.detectedFaces
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 22))
                                    .foregroundStyle(SettingsMetrics.textSecondary)
                                Text(controller.camera.errorMessage ?? "Camera off. Start explicitly to inspect live frames.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SettingsMetrics.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .frame(height: 190)

                    HStack(spacing: 10) {
                        Button(controller.camera.isRunning ? "Stop Camera" : "Start Camera") {
                            if controller.camera.isRunning {
                                controller.stop()
                            } else {
                                Task { await controller.start() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(controller.camera.isRunning ? Color.red.opacity(0.85) : lumasightTheme.accent)

                        Spacer()

                        Text("Zero templates or frames saved")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .padding(.top, 10)
            }
        }
    }

    // MARK: - Transient Face Readout

    private var detectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Vision Face Readout (In-Memory)")
            SettingsGroup {
                if let face = controller.primaryFace {
                    let widthOK = face.normalizedBoundingBox.width >= CGFloat(settings.minimumFaceWidth)
                    infoRow(
                        label: "Faces detected",
                        value: "\(controller.detectedFaces.count) (primary width \(Int((face.normalizedBoundingBox.width * 100).rounded()))% — \(widthOK ? "in range" : "move closer"))"
                    )
                    SettingsGroupDivider()
                    infoRow(
                        label: "Quality & landmarks",
                        value: "quality \(face.quality.map { String(format: "%.2f", $0) } ?? "—") • landmarks \(face.landmarks == nil ? "none" : "present")"
                    )
                    SettingsGroupDivider()
                    infoRow(
                        label: "Head pose (rad)",
                        value: "yaw \(angleText(face.yaw))  pitch \(angleText(face.pitch))  roll \(angleText(face.roll))"
                    )
                } else {
                    infoRow(
                        label: "Status",
                        value: controller.camera.isRunning ? "No face currently framed" : "Start camera to inspect face geometry"
                    )
                }
            }
        }
    }

    // MARK: - Honest Depth Architecture Panel

    private var depthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Depth / 3D Provenance & Diagnostics")
            SettingsGroup {
                VStack(alignment: .leading, spacing: 10) {
                    depthAssessmentBlock(
                        title: "Live Camera Depth Source",
                        assessment: controller.depthCoordinator.liveAssessment
                    )

                    SettingsGroupDivider()

                    SettingsRowContent(
                        title: "Allow monocular fallback (when model bundled)",
                        subtitle: controller.depthCoordinator.isMonocularModelBundled
                            ? "Estimates non-metric relative depth on RGB-only cameras."
                            : "Disabled: no licensed Core ML monocular depth model is bundled."
                    ) {
                        lumasightToggle(isOn: $settings.isDepthEstimationEnabled)
                            .disabled(!controller.depthCoordinator.isMonocularModelBundled)
                    }

                    SettingsGroupDivider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Portrait Photo Depth Inspection")
                                .font(.system(size: 13))
                                .foregroundStyle(SettingsMetrics.textPrimary)
                            Text("Inspect embedded HEIC/DNG AVDepthData via macOS ImageIO metadata.")
                                .font(.system(size: 11))
                                .foregroundStyle(SettingsMetrics.textSecondary)
                        }
                        Spacer()
                        if controller.depthCoordinator.inspectedImageAssessment != nil {
                            Button("Clear") {
                                controller.clearInspectedImage()
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Choose Photo…") {
                            controller.chooseImageForDepthInspection()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                    .padding(.bottom, controller.depthCoordinator.inspectedImageAssessment == nil ? 12 : 4)

                    if let photoAssessment = controller.depthCoordinator.inspectedImageAssessment {
                        SettingsGroupDivider()
                        depthAssessmentBlock(
                            title: "Selected Photo Depth Metadata",
                            assessment: photoAssessment
                        )
                        .padding(.bottom, 10)
                    }
                }
            }
            SettingsCaption(
                text: "2D RGB video never produces calibrated 3D depth. Any estimated or visualized depth map is non-metric and is never proof of real-world distance, identity, or liveness."
            )
        }
    }

    @ViewBuilder
    private func depthAssessmentBlock(title: String, assessment: DepthAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Spacer()
                depthBadge(for: assessment.provenance)
            }

            if let metrics = assessment.metrics {
                Text("Source: \(assessment.sourceLabel) • \(metrics.width)x\(metrics.height) • \(metrics.accuracy.displayLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                Text("Range: \(metrics.rangeSummary)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                if let calibration = metrics.calibration {
                    Text("Calibration: \(calibration.summaryLine)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                } else {
                    Text("Calibration: Missing (non-metric scale)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                }

                DepthGridHeatmapView(
                    values: metrics.normalizedPreviewGrid,
                    columns: metrics.previewColumns,
                    rows: metrics.previewRows,
                    provenance: metrics.provenance
                )

                Text(metrics.honestyDisclaimer)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            } else if let reason = assessment.unavailableReason {
                Text(reason.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Text(reason.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.top, 10)
    }

    private func depthBadge(for provenance: DepthProvenance) -> some View {
        let color: Color
        switch provenance {
        case .hardwareMeasured: color = .green
        case .monocularEstimated: color = .orange
        case .unavailable: color = SettingsMetrics.textSecondary
        }
        return Text(provenance.badgeTitle)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: - Experimental 2D Liveness Cues

    private var livenessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsSectionTitle(text: "Experimental 2D Liveness Cues")
                Spacer()
                Button("Reset Window") {
                    controller.resetLivenessWindow()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }

            SettingsGroup {
                ForEach(LivenessCue.allCases) { cue in
                    let state = controller.livenessSnapshot.state(for: cue)
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { controller.enabledLivenessCues.contains(cue) },
                            set: { _ in controller.toggleCue(cue) }
                        )) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(cue.title)
                                    .font(.system(size: 12, weight: .medium))
                                Text(cue.role == .deny ? "DENY" : "CONFIRM")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(cue.role == .deny ? Color.red : lumasightTheme.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background((cue.role == .deny ? Color.red : lumasightTheme.accent).opacity(0.14), in: Capsule())
                            }
                            Text(cue.explanation)
                                .font(.system(size: 10))
                                .foregroundStyle(SettingsMetrics.textSecondary)
                        }
                        Spacer()
                        Text(state.hasFired ? "Fired" : String(format: "%.2f (c=%.2f)", state.reading.level, state.reading.confidence))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(state.hasFired ? Color.orange : SettingsMetrics.textSecondary)
                    }
                    .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                    .padding(.vertical, 8)

                    if cue != LivenessCue.allCases.last {
                        SettingsGroupDivider()
                    }
                }
            }

            SettingsCaption(
                text: "These signals run strictly on 2D RGB landmarks/specular cues and can be bypassed or misclassified; they do not provide hardware depth verification or authentication."
            )
        }
    }

    // MARK: - Overlay Demo Controls & Log

    private var overlayPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Overlay Demo Preview")
            SettingsGroup {
                HStack(spacing: 10) {
                    Button("Preview Success") {
                        controller.triggerOverlayPreview(success: true)
                    }
                    .buttonStyle(.bordered)
                    Button("Preview Timeout") {
                        controller.triggerOverlayPreview(success: false)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                .padding(.vertical, 10)
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionTitle(text: "Session Log")
            SettingsGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.statusLog.prefix(8), id: \.self) { entry in
                        Text(entry)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 9)
    }

    private func angleText(_ value: Float?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "—"
    }
}

private struct DepthGridHeatmapView: View {
    let values: [Float]
    let columns: Int
    let rows: Int
    let provenance: DepthProvenance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                guard size.width > 0, size.height > 0,
                      columns > 0, rows > 0,
                      values.count == columns * rows else { return }

                let cellW = size.width / CGFloat(columns)
                let cellH = size.height / CGFloat(rows)
                for r in 0..<rows {
                    for c in 0..<columns {
                        let v = Double(min(max(values[r * columns + c], 0), 1))
                        let rect = CGRect(x: CGFloat(c) * cellW, y: CGFloat(r) * cellH, width: cellW + 0.5, height: cellH + 0.5)
                        let baseColor = provenance == .hardwareMeasured ? Color.cyan : Color.orange
                        context.fill(Path(rect), with: .color(baseColor.opacity(0.15 + v * 0.85)))
                    }
                }
            }
            .frame(height: 96)
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Normalized visualization grid (not proof of real-world distance, identity, or liveness)")
                .font(.system(size: 10))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
    }
}
