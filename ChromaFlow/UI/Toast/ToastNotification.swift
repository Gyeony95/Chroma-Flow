//
//  ToastNotification.swift
//  ChromaFlow
//
//  Created on 2026-02-01.
//

import Foundation

enum ToastStyle {
    case success
    case info
    case warning
    case error

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var gradientColors: (start: String, end: String) {
        switch self {
        case .success: return ("#4CAF50", "#45A049")
        case .info: return ("#2196F3", "#1976D2")
        case .warning: return ("#FF9800", "#F57C00")
        case .error: return ("#F44336", "#D32F2F")
        }
    }
}

struct ToastNotification: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String
    let style: ToastStyle
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        style: ToastStyle = .info,
        duration: TimeInterval = 3.0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon ?? style.iconName
        self.style = style
        self.duration = duration
    }
}
