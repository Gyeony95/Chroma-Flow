//
//  ToastView.swift
//  ChromaFlow
//
//  Created on 2026-02-01.
//

import SwiftUI

struct ToastView: View {
    let notification: ToastNotification
    let onDismiss: () -> Void

    @State private var opacity: Double = 0
    @State private var offsetX: CGFloat = 400

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: notification.icon)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(hex: notification.style.gradientColors.start),
                            Color(hex: notification.style.gradientColors.end)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                if let subtitle = notification.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(width: 320)
        .background(
            ZStack {
                // Adaptive glass background
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)

                // Subtle gradient overlay
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: notification.style.gradientColors.start).opacity(0.1),
                                Color(hex: notification.style.gradientColors.end).opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.1), radius: 40, x: 0, y: 16)
        .opacity(opacity)
        .offset(x: offsetX)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                opacity = 1
                offsetX = 0
            }

            // Auto-dismiss after duration
            DispatchQueue.main.asyncAfter(deadline: .now() + notification.duration, execute: {
                dismiss()
            })
        }
        .onTapGesture {
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            opacity = 0
            offsetX = 400
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: {
            onDismiss()
        })
    }
}

// Helper extension for hex color conversion
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        ToastView(
            notification: ToastNotification(
                title: "P3 Color Space Activated",
                subtitle: "Wide gamut mode enabled",
                style: .success
            ),
            onDismiss: {}
        )
    }
}
