import AppKit
import SwiftUI

/// User-customizable colors for each `PortType`, persisted to `UserDefaults`.
/// Points and wires of a given data type all read their color from here, so
/// changing a type's color (via a wire's right-click menu or in Settings)
/// updates every port/wire of that type at once.
final class PortColorStore: ObservableObject {
    static let shared = PortColorStore()

    @Published private var overrides: [PortType: Color] = [:]

    private static func defaultsKey(for type: PortType) -> String {
        "portColor.\(type.rawValue)"
    }

    private init() {
        for type in PortType.allCases {
            guard
                let components = UserDefaults.standard.array(forKey: Self.defaultsKey(for: type)) as? [Double],
                components.count == 4
            else { continue }
            overrides[type] = Color(red: components[0], green: components[1], blue: components[2], opacity: components[3])
        }
    }

    func color(for type: PortType) -> Color {
        overrides[type] ?? type.defaultColor
    }

    func setColor(_ color: Color, for type: PortType) {
        overrides[type] = color
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        let components: [Double] = [
            Double(nsColor.redComponent),
            Double(nsColor.greenComponent),
            Double(nsColor.blueComponent),
            Double(nsColor.alphaComponent)
        ]
        UserDefaults.standard.set(components, forKey: Self.defaultsKey(for: type))
    }

    func resetColor(for type: PortType) {
        overrides.removeValue(forKey: type)
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(for: type))
    }

    func binding(for type: PortType) -> Binding<Color> {
        Binding(
            get: { self.color(for: type) },
            set: { self.setColor($0, for: type) }
        )
    }
}
