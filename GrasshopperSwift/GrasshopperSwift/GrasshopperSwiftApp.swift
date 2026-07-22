import SwiftUI

@main
struct GrasshopperSwiftApp: App {
    @StateObject private var graph = NodeGraph()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(graph)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 800)

        Window("Geometry Preview", id: "geometry-preview") {
            GeometryPreviewView()
                .environmentObject(graph)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 680, height: 560)

        Settings {
            SettingsView()
        }
    }
}

private struct SettingsView: View {
    @AppStorage("showConnectorHoverHighlight") private var showConnectorHoverHighlight = false

    var body: some View {
        Form {
            Toggle("Show connector hover highlight", isOn: $showConnectorHoverHighlight)
        }
        .padding(20)
        .frame(width: 360)
    }
}
