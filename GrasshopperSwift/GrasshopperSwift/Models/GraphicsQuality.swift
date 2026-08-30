import Foundation

// MARK: - GraphicsQualityTier

/// A bundle of realistic-view render settings (post-processing effects,
/// anti-aliasing, shadow fidelity, render resolution), from cheapest to most
/// expensive. `GraphicsQualityController` picks one automatically based on
/// measured frame time (or the user pins one directly in Settings).
enum GraphicsQualityTier: Int, CaseIterable, Comparable, Identifiable, Codable {
    case low = 0
    case medium
    case high
    case ultra

    var id: Int { rawValue }

    static func < (lhs: GraphicsQualityTier, rhs: GraphicsQualityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        case .ultra:  return "Ultra"
        }
    }

    static func parse(_ raw: String) -> GraphicsQualityTier {
        allCases.first { $0.displayName.lowercased() == raw.lowercased() } ?? .high
    }
}

// MARK: - GraphicsQualityController

/// Drives the "how much of the realistic-view feature set depends on
/// computing power" behavior: samples how long each rendered frame actually
/// takes, and — when adaptive mode is on — steps the quality tier down when
/// the Mac can't keep up with the target frame rate, or back up when there's
/// sustained headroom.
///
/// This does not touch which BRDF features exist on a material (metallic-
/// roughness, clear coat, anisotropy, sheen, subsurface stay available at
/// every tier — they're an authoring choice, not a perf knob). It scales the
/// screen-space/post-processing pipeline instead: SSAO, bloom, shadow
/// fidelity, MSAA, dynamic resolution, and HDR color-buffer precision — the
/// parts of the Filament pipeline whose cost scales with pixel count and
/// screen-space sample counts rather than with which materials are on screen.
final class GraphicsQualityController: ObservableObject {
    static let shared = GraphicsQualityController()

    @Published private(set) var currentTier: GraphicsQualityTier
    @Published private(set) var measuredFPS: Double = 0

    private let defaults = UserDefaults.standard

    // EMA of per-frame duration (seconds). alpha trades responsiveness for
    // stability — low enough that a single dropped frame (e.g. a spike from
    // window resize) doesn't immediately trigger a tier change.
    private var emaFrameSeconds: Double = 1.0 / 60.0
    private let emaAlpha = 0.08

    // Frames left before another tier step is allowed. Stepping down is
    // allowed sooner than stepping up (a stutter should be fixed quickly;
    // recovering to a higher tier requires longer sustained headroom so the
    // tier doesn't oscillate every time the scene briefly gets simple).
    private var cooldownFrames = 0

    private init() {
        currentTier = GraphicsQualityController.readManualTier(from: UserDefaults.standard)
    }

    // MARK: Settings (mirrors the @AppStorage-backed keys the Settings UI writes)

    static let targetFPSKey = "graphicsTargetFPS"
    static let adaptiveEnabledKey = "graphicsAdaptiveEnabled"
    static let manualTierKey = "graphicsManualTier"

    var targetFPS: Double {
        let v = defaults.double(forKey: Self.targetFPSKey)
        return v > 0 ? v : 60
    }

    var adaptiveEnabled: Bool {
        defaults.object(forKey: Self.adaptiveEnabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.adaptiveEnabledKey)
    }

    private static func readManualTier(from defaults: UserDefaults) -> GraphicsQualityTier {
        guard let raw = defaults.string(forKey: manualTierKey) else { return .high }
        return GraphicsQualityTier.parse(raw)
    }

    // MARK: Frame feedback

    /// Call once per rendered frame with the wall-clock time that frame's
    /// `beginFrame`/`render`/`endFrame` call took. Used as a proxy for GPU+CPU
    /// load: when the device can't keep up, that call blocks longer (either
    /// waiting on a drawable or on Filament's internal backpressure), so a
    /// rising duration reliably signals the device is struggling — no
    /// platform-specific GPU counter needed.
    func recordFrame(duration: Double) {
        emaFrameSeconds = emaFrameSeconds * (1 - emaAlpha) + duration * emaAlpha
        measuredFPS = 1.0 / max(emaFrameSeconds, 1e-6)

        guard adaptiveEnabled else {
            let manual = Self.readManualTier(from: defaults)
            if manual != currentTier { currentTier = manual }
            return
        }

        if cooldownFrames > 0 {
            cooldownFrames -= 1
            return
        }

        let target = targetFPS
        if measuredFPS < target * 0.85, currentTier > .low {
            currentTier = GraphicsQualityTier(rawValue: currentTier.rawValue - 1) ?? .low
            cooldownFrames = 90   // ~1.5s at 60Hz before allowed to step again
        } else if measuredFPS > target * 1.15, currentTier < .ultra {
            currentTier = GraphicsQualityTier(rawValue: currentTier.rawValue + 1) ?? .ultra
            cooldownFrames = 240  // require longer sustained headroom before climbing back up
        }
    }
}
