import SwiftUI

/// SwiftUI wrapper for the Metal path-traced "Ultra Realistic" preview.
/// Mirrors `FilamentRenderView`'s shape (`shapes` + `renderConfig` in), plus
/// a progress readout and a restart trigger since — unlike the real-time
/// Filament view — this one visibly converges over time.
struct UltraRealisticRenderView: NSViewRepresentable {
    let shapes: [TrackedShape]
    var renderConfig: RenderConfig = .cinematicDefault
    @Binding var sampleCount: Int
    @Binding var targetSampleCount: Int
    var resetToken: Int
    var denoiseEnabled: Bool = true
    var noiseTarget: Double = 0.03
    var allowExtendedSampling: Bool = true

    func makeNSView(context: Context) -> PathTracerHostView {
        let view = PathTracerHostView()
        let sampleBinding = $sampleCount
        let targetBinding = $targetSampleCount
        view.onSampleCountChanged = { count, target in
            DispatchQueue.main.async {
                sampleBinding.wrappedValue = count
                targetBinding.wrappedValue = target
            }
        }
        return view
    }

    func updateNSView(_ nsView: PathTracerHostView, context: Context) {
        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            nsView.resetAccumulation()
        }
        nsView.denoiseEnabled = denoiseEnabled
        nsView.noiseTarget = Float(noiseTarget)
        nsView.allowExtendedSampling = allowExtendedSampling
        nsView.update(trackedShapes: shapes, renderConfig: renderConfig)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastResetToken = 0
    }
}
