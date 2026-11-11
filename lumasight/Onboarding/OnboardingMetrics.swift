//
//  OnboardingMetrics.swift
//  lumasight
//
//  Onboarding layout constants centralized so panel-fit tuning stays predictable.
//

import SwiftUI

enum OnboardingMetrics {
    static let stepAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)
    static let fieldAutofocusDelay: Double = 0.48

    // MARK: - Panel Size

    static let panelWidth: CGFloat = 380

    static let notchIntroHeight: CGFloat = 175
    static let pillIntroHeight: CGFloat = 175
    static let notchPermissionsHeight: CGFloat = 210
    static let pillPermissionsHeight: CGFloat = 210
    static let notchSecurityNoticeHeight: CGFloat = 315
    static let pillSecurityNoticeHeight: CGFloat = 315
    static let notchCompleteHeight: CGFloat = 95
    static let pillCompleteHeight: CGFloat = 95

    static func panelHeight(for step: OnboardingStep, style: NotchPanelStyle) -> CGFloat {
        switch (step, style) {
        case (.intro, .notch): return notchIntroHeight
        case (.intro, .pill): return pillIntroHeight
        case (.permissions, .notch): return notchPermissionsHeight
        case (.permissions, .pill): return pillPermissionsHeight
        case (.securityNotice, .notch): return notchSecurityNoticeHeight
        case (.securityNotice, .pill): return pillSecurityNoticeHeight
        case (.complete, .notch): return notchCompleteHeight
        case (.complete, .pill): return pillCompleteHeight
        }
    }

    static func panelSize(for step: OnboardingStep, style: NotchPanelStyle) -> CGSize {
        CGSize(width: panelWidth, height: panelHeight(for: step, style: style))
    }

    static func panelBottomRadius(for step: OnboardingStep) -> CGFloat {
        55
    }

    static let maxPanelWidth: CGFloat = panelWidth

    static func maxPanelHeight(for style: NotchPanelStyle) -> CGFloat {
        switch style {
        case .notch:
            return [notchIntroHeight, notchPermissionsHeight, notchSecurityNoticeHeight, notchCompleteHeight].max()
                ?? notchSecurityNoticeHeight
        case .pill:
            return [pillIntroHeight, pillPermissionsHeight, pillSecurityNoticeHeight, pillCompleteHeight].max()
                ?? pillSecurityNoticeHeight
        }
    }

    // MARK: - Content Insets

    static let titleTopInset: CGFloat = 50
    static let pillTitleTopInset: CGFloat = 32

    static let notchContentLeadingInset: CGFloat = 28
    static let notchContentTrailingInset: CGFloat = 28
    static let notchContentBottomInset: CGFloat = 40

    static let pillContentLeadingInset: CGFloat = 30
    static let pillContentTrailingInset: CGFloat = 30
    static let pillContentBottomInset: CGFloat = 36

    static func titleTopInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillTitleTopInset : titleTopInset
    }

    static func contentLeadingInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentLeadingInset : notchContentLeadingInset
    }

    static func contentTrailingInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentTrailingInset : notchContentTrailingInset
    }

    static func contentBottomInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentBottomInset : notchContentBottomInset
    }

    // MARK: - Shared Control Geometry

    static let controlHorizontalPadding: CGFloat = 24
    static let pillButtonHeight: CGFloat = 38
    static let pillButtonRadius: CGFloat = 17
    static let primaryButtonWidth: CGFloat = 160
    static let permissionRowHeight: CGFloat = 44
    static let grantButtonSize = CGSize(width: 60, height: 26)
    static let statusDotSize: CGFloat = 16

    // MARK: - Completion Timings

    static let checkmarkDrawDuration: Double = 0.28
    static let completeScreenDismissDelay: Double = 2.0
}

extension View {
    func onboardingContentPadding() -> some View {
        modifier(OnboardingContentPadding())
    }

    func onboardingContentHorizontalPadding() -> some View {
        modifier(OnboardingContentHorizontalPadding())
    }
}

private struct OnboardingContentHorizontalPadding: ViewModifier {
    @Environment(\.notchPanelStyle) private var style

    func body(content: Content) -> some View {
        content
            .padding(.leading, OnboardingMetrics.contentLeadingInset(for: style))
            .padding(.trailing, OnboardingMetrics.contentTrailingInset(for: style))
    }
}

private struct OnboardingContentPadding: ViewModifier {
    @Environment(\.notchPanelStyle) private var style

    func body(content: Content) -> some View {
        content
            .onboardingContentHorizontalPadding()
            .padding(.top, OnboardingMetrics.titleTopInset(for: style))
            .padding(.bottom, OnboardingMetrics.contentBottomInset(for: style))
    }
}
