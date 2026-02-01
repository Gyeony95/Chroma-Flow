//
//  VirtualHDRView.swift
//  ChromaFlow
//
//  UI component for Virtual HDR Emulation controls
//

import SwiftUI

struct VirtualHDRView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPreset: VirtualHDREngine.HDRPreset = .balanced
    @State private var showAdvancedSettings = false

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Virtual HDR", systemImage: "tv.and.hifispeakerfill")
                    .font(.headline)

                Spacer()

                Toggle("", isOn: $appState.isVirtualHDREnabled)
                    .toggleStyle(.switch)
                    .onChange(of: appState.isVirtualHDREnabled) { _, newValue in
                        Task {
                            await toggleVirtualHDR(enabled: newValue)
                        }
                    }
            }

            if appState.isVirtualHDREnabled {
                // Preset Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preset")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("HDR Preset", selection: $selectedPreset) {
                        Text("Subtle").tag(VirtualHDREngine.HDRPreset.subtle)
                        Text("Balanced").tag(VirtualHDREngine.HDRPreset.balanced)
                        Text("Vivid").tag(VirtualHDREngine.HDRPreset.vivid)
                        Text("Cinematic").tag(VirtualHDREngine.HDRPreset.cinematic)
                        Text("Gaming").tag(VirtualHDREngine.HDRPreset.gaming)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedPreset) { _, newPreset in
                        Task {
                            await applyHDRPreset(newPreset)
                        }
                    }
                }

                // Intensity Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Intensity")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(appState.hdrIntensity * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $appState.hdrIntensity, in: 0...1) { _ in
                        Task {
                            await adjustHDRIntensity()
                        }
                    }
                    .tint(.blue)
                }

                // Advanced Settings Toggle
                Button(action: {
                    withAnimation(.spring(duration: 0.3)) {
                        showAdvancedSettings.toggle()
                    }
                }) {
                    HStack {
                        Text("Advanced Settings")
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showAdvancedSettings ? 90 : 0))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                // Advanced Settings
                if showAdvancedSettings {
                    VStack(alignment: .leading, spacing: 12) {
                        // Local Contrast Enhancement
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Local Contrast")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(appState.hdrLocalContrast * 100))%")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Slider(value: $appState.hdrLocalContrast, in: 0...1) { _ in
                                Task {
                                    await adjustLocalContrast()
                                }
                            }
                            .tint(.orange)
                        }

                        // Info Box
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)

                            Text("Virtual HDR simulates high dynamic range on SDR displays using advanced tone mapping and local contrast enhancement.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Display Capabilities
                if let displayID = appState.selectedDisplayID,
                   let hdrEngine = appState.virtualHDREngine {
                    let capabilities = hdrEngine.analyzeDisplayCapabilities(for: displayID)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Display Capabilities")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        HStack(spacing: 12) {
                            Label("\(Int(capabilities.estimatedPeakNits)) nits", systemImage: "sun.max.fill")
                                .font(.caption)

                            Label("\(capabilities.colorGamut)", systemImage: "paintpalette.fill")
                                .font(.caption)

                            Label("\(capabilities.bitDepth)-bit", systemImage: "square.stack.3d.up.fill")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            selectedPreset = appState.hdrPreset
        }
    }

    // MARK: - Actions

    private func toggleVirtualHDR(enabled: Bool) async {
        guard let displayID = appState.selectedDisplayID else { return }

        do {
            if enabled {
                try await appState.displayEngine.enableVirtualHDR(
                    for: displayID,
                    intensity: appState.hdrIntensity,
                    localContrast: appState.hdrLocalContrast
                )
            } else {
                try await appState.displayEngine.disableVirtualHDR(for: displayID)
            }
        } catch {
            ToastManager.shared.showError("Virtual HDR Error: \(error.localizedDescription)")
            // Reset toggle on error
            await MainActor.run {
                appState.isVirtualHDREnabled = !enabled
            }
        }
    }

    private func applyHDRPreset(_ preset: VirtualHDREngine.HDRPreset) async {
        guard let displayID = appState.selectedDisplayID else { return }

        appState.hdrPreset = preset
        appState.hdrIntensity = preset.intensity
        appState.hdrLocalContrast = preset.localContrast

        do {
            try await appState.displayEngine.applyVirtualHDRPreset(preset, for: displayID)
        } catch {
            ToastManager.shared.showError("Failed to apply HDR preset: \(error.localizedDescription)")
        }
    }

    private func adjustHDRIntensity() async {
        guard let displayID = appState.selectedDisplayID else { return }

        do {
            try await appState.displayEngine.adjustVirtualHDRIntensity(
                appState.hdrIntensity,
                for: displayID
            )
        } catch {
            ToastManager.shared.showError("Failed to adjust HDR intensity: \(error.localizedDescription)")
        }
    }

    private func adjustLocalContrast() async {
        guard let displayID = appState.selectedDisplayID,
              let hdrEngine = appState.virtualHDREngine else { return }

        await MainActor.run {
            Task {
                try await hdrEngine.adjustLocalContrast(appState.hdrLocalContrast, for: displayID)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var appState = AppState()

    VirtualHDRView()
        .environment(appState)
        .frame(width: 400)
}