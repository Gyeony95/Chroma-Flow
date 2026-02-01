//
//  ToastOverlay.swift
//  ChromaFlow
//
//  Created on 2026-02-01.
//

import SwiftUI

struct ToastOverlay: View {
    @State private var toastManager = ToastManager.shared

    var body: some View {
        ZStack {
            if let toast = toastManager.currentToast {
                VStack {
                    HStack {
                        Spacer()
                        ToastView(notification: toast) {
                            toastManager.dismiss()
                        }
                        .padding(.trailing, 20)
                    }
                    .padding(.top, 20)

                    Spacer()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .allowsHitTesting(toastManager.currentToast != nil)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
            .ignoresSafeArea()

        ToastOverlay()
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                    ToastManager.shared.showProfileChanged(
                        ColorProfile(id: UUID(), name: "P3 Wide Gamut", colorSpace: .displayP3, iccProfileURL: nil, isCustom: false, whitePoint: ColorProfile.CIExyY(x: 0.3127, y: 0.3290, Y: 100), gamut: nil),
                        for: "Photoshop"
                    )
                })
            }
    }
}
