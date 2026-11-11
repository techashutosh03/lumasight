//
//  OnboardingStepViews.swift
//  lumasight
//
//  Screens of the notch-hosted onboarding flow. Explains platform limits and
//  transient camera operation cleanly with zero password or biometric storage.
//

import AppKit
import SwiftUI

// MARK: - 1. Intro

struct IntroStepView: View {
    let controller: OnboardingController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("lumasight")
                    .font(lumasightTheme.Font.title)
                    .foregroundStyle(lumasightTheme.textPrimary)
                Text("Local Vision & Depth Demo")
                    .font(lumasightTheme.Font.button)
                    .foregroundStyle(lumasightTheme.textSecondary)

                Spacer(minLength: 12)

                PillButton(title: "Next") {
                    controller.advance()
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            lumasightLogoView()
                .frame(width: 106, height: 106)
                .padding(.top, 4)
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(lumasightTheme.panel)
    }
}

private struct lumasightLogoView: View {
    var body: some View {
        LoopingVideoView(resourceName: "logoanimation")
    }
}

// MARK: - 2. Permissions

struct PermissionsStepView: View {
    let controller: OnboardingController

    private var cameraDetail: String {
        switch controller.cameraPermission {
        case .granted:
            return "Camera access granted for optional local demos"
        case .notDetermined:
            return "Optional — requested only if you start a camera demo"
        case .denied:
            return "Denied — tap Grant to open System Settings, or Skip"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(lumasightTheme.Font.title)
                .foregroundStyle(lumasightTheme.textPrimary)
                .padding(.leading, 4)

            PermissionRow(
                title: "Camera",
                detail: cameraDetail,
                granted: controller.cameraPermission == .granted
            ) { controller.grantCamera() }

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                if controller.canAdvanceFromPermissions {
                    PillButton(title: "Next") {
                        controller.advance()
                    }
                } else {
                    PillButton(title: "Skip", style: .secondary) {
                        controller.skipCameraSetup()
                    }
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(lumasightTheme.panel)
    }
}

// MARK: - 3. Security & Platform Notice

struct SecurityNoticeStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(lumasightTheme.textPrimary)
                .padding(.top, 12)
                .padding(.leading, 4)
                .accessibilityHidden(true)

            Text("lumasight cannot unlock macOS and is not Face ID.")
                .font(lumasightTheme.Font.title)
                .foregroundStyle(lumasightTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Text("lumasight runs strictly in your signed-in session. It never collects macOS passwords, saves face templates or photos, or grants authentication. Frames are processed transiently in memory only.")
                .font(lumasightTheme.Font.passwordCaption)
                .foregroundStyle(lumasightTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
                .padding(.bottom, 8)

            HStack(spacing: 10) {
                if controller.isPostUpdateNotice {
                    PillButton(title: "Quit", style: .secondary) {
                        controller.declinePostUpdateNotice()
                    }
                } else {
                    PillButton(title: "Back", style: .secondary) {
                        controller.back()
                    }
                }
                PillButton(title: "I understand", isDefault: true) {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(lumasightTheme.panel)
    }
}

// MARK: - 4. Complete

struct CompleteStepView: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("You're all set")
                .font(lumasightTheme.Font.title)
                .foregroundStyle(lumasightTheme.textPrimary)
            Spacer(minLength: 4)
            AnimatedCheckmark(color: .white, lineWidth: 5)
                .frame(width: 20, height: 15)
        }
        .onboardingContentHorizontalPadding()
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(lumasightTheme.panel)
    }
}
