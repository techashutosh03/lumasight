//
//  SettingsTab.swift
//  lumasight
//
//  The tab bar's tab list. Debug-only Vision Lab is appended only once revealed.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case privacy
    case camera
    case recognition
    case about
    case debugFaceLab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .privacy: return "Privacy"
        case .camera: return "Camera"
        case .recognition: return "Vision & Depth"
        case .about: return "About"
        case .debugFaceLab: return "Vision Lab"
        }
    }

    var icon: SettingsTabIcon {
        switch self {
        case .general: return .system("gearshape.fill")
        case .privacy: return .system("hand.raised.fill")
        case .camera: return .system("video.fill")
        case .recognition: return .system("cube.transparent")
        case .about: return .system("info.circle.fill")
        case .debugFaceLab: return .system("flask")
        }
    }

    /// Tabs in tab bar order, minus `.debugFaceLab` unless revealed.
    static func visibleTabs(includingDebug: Bool) -> [SettingsTab] {
        includingDebug ? allCases : allCases.filter { $0 != .debugFaceLab }
    }
}
