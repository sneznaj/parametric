import SwiftUI

/// "Graphics — Realistic View" section of the app Settings window. Controls
/// how the realistic-view render pipeline scales to this Mac's performance:
/// either fully automatic (measured frame time steps the quality tier up or
/// down to hold a target frame rate) or a fixed tier the user picks directly.
///
/// This does not gate which BRDF features a material can use (metallic-
/// roughness, clear coat, anisotropy, sheen, subsurface are always
/// available — see the Material node's inputs and the Velvet/Frosted Wax
/// presets); it scales the screen-space pipeline (SSAO, bloom, shadow
/// fidelity, MSAA, dynamic resolution, HDR precision) that FilamentRenderView
/// applies via `applyQualityTier(_:view:)`.
struct GraphicsQualitySettingsSection: View {
    @AppStorage(GraphicsQualityController.adaptiveEnabledKey) private var adaptiveEnabled = true
    @AppStorage(GraphicsQualityController.targetFPSKey) private var targetFPS = 60.0
    @AppStorage(GraphicsQualityController.manualTierKey) private var manualTierRaw = GraphicsQualityTier.high.displayName
    @ObservedObject private var controller = GraphicsQualityController.shared

    private var manualTier: Binding<GraphicsQualityTier> {
        Binding(
            get: { GraphicsQualityTier.parse(manualTierRaw) },
            set: { manualTierRaw = $0.displayName }
        )
    }

    var body: some View {
        Section("Graphics — Realistic View") {
            Toggle("Adaptive quality", isOn: $adaptiveEnabled)
            Text("Automatically scales the realistic view's effects to this Mac's performance — steps quality down if frames start dropping, and back up when there's headroom.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if adaptiveEnabled {
                Slider(value: $targetFPS, in: 24...120, step: 1) {
                    Text("Target frame rate")
                } minimumValueLabel: {
                    Text("24")
                } maximumValueLabel: {
                    Text("120")
                }
                Text("\(Int(targetFPS)) fps target — currently \(controller.currentTier.displayName) quality at \(Int(controller.measuredFPS.rounded())) fps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Quality", selection: manualTier) {
                    ForEach(GraphicsQualityTier.allCases) { tier in
                        Text(tier.displayName).tag(tier)
                    }
                }
                Text("Currently rendering at \(Int(controller.measuredFPS.rounded())) fps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
