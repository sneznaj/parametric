import SwiftUI
import UniformTypeIdentifiers

// MARK: - UTType for .ghs files

extension UTType {
    static var grasshopperGraph: UTType {
        UTType(filenameExtension: "ghs") ?? .json
    }
}

// MARK: - File Actions Environment

struct GraphFileActions {
    let new: () -> Void
    let open: () -> Void
    let save: () -> Void
    let saveAs: () -> Void
}

private struct GraphFileActionsKey: EnvironmentKey {
    static let defaultValue = GraphFileActions(
        new: {},
        open: {},
        save: {},
        saveAs: {}
    )
}

extension EnvironmentValues {
    var graphFileActions: GraphFileActions {
        get { self[GraphFileActionsKey.self] }
        set { self[GraphFileActionsKey.self] = newValue }
    }
}

// MARK: - App

@main
struct GrasshopperSwiftApp: App {
    @StateObject private var workspace = WorkspaceManager()
    @State private var showUnsavedAlert = false
    @State private var pendingFileAction: FileAction?

    private enum FileAction {
        case new, open
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .environment(\.graphFileActions, GraphFileActions(
                    new: { requestFileAction(.new) },
                    open: { requestFileAction(.open) },
                    save: { saveActiveGraph() },
                    saveAs: { saveActiveGraphAs() }
                ))
                .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
                    Button("Save") {
                        performSaveThen(action: pendingFileAction ?? .new)
                    }
                    Button("Discard Changes", role: .destructive) {
                        performFileAction(pendingFileAction ?? .new)
                    }
                    Button("Cancel", role: .cancel) {
                        pendingFileAction = nil
                    }
                } message: {
                    Text("Your changes will be lost if you don't save them.")
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1200, height: 800)
        .commands {
            fileMenuCommands
            viewMenuCommands
        }

        Window("Geometry Preview", id: "geometry-preview") {
            GeometryPreviewView()
                .environmentObject(workspace)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 680, height: 560)

        Settings {
            SettingsView()
        }
    }

    // MARK: - File Menu

    @CommandsBuilder
    private var fileMenuCommands: some Commands {
        CommandMenu("File") {
            Button("New") {
                requestFileAction(.new)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open...") {
                requestFileAction(.open)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Close Tab") {
                closeActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            Button("Save") {
                saveActiveGraph()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As...") {
                saveActiveGraphAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    // MARK: - View Menu

    @AppStorage(kViewModeKey) private var storedViewMode: String = ViewMode.perspective.rawValue

    private var currentViewMode: ViewMode {
        ViewMode(rawValue: storedViewMode) ?? .perspective
    }

    @CommandsBuilder
    private var viewMenuCommands: some Commands {
        CommandMenu("View") {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Button {
                    storedViewMode = mode.rawValue
                } label: {
                    Text(mode.rawValue)
                }
                .keyboardShortcut(keyboardShortcut(for: mode))
                .disabled(ViewMode.crossesPipelineBoundary(from: currentViewMode, to: mode)
                          && !workspace.activeGraph.nodes.isEmpty)
            }
        }
    }

    private func keyboardShortcut(for mode: ViewMode) -> KeyboardShortcut? {
        switch mode {
        case .twoD:        return KeyboardShortcut("1", modifiers: .command)
        case .top:         return KeyboardShortcut("2", modifiers: .command)
        case .front:       return KeyboardShortcut("3", modifiers: .command)
        case .right:       return KeyboardShortcut("4", modifiers: .command)
        case .perspective: return KeyboardShortcut("5", modifiers: .command)
        case .realistic:   return KeyboardShortcut("6", modifiers: .command)
        case .ultraRealistic: return KeyboardShortcut("7", modifiers: .command)
        }
    }

    // MARK: - File Action Handling

    private func requestFileAction(_ action: FileAction) {
        if workspace.activeGraph.hasUnsavedChanges {
            pendingFileAction = action
            showUnsavedAlert = true
        } else {
            performFileAction(action)
        }
    }

    private func performFileAction(_ action: FileAction) {
        switch action {
        case .new:
            workspace.newTab()
        case .open:
            openGraph()
        }
    }

    private func performSaveThen(action: FileAction) {
        let graph = workspace.activeGraph
        if let url = graph.currentFileURL {
            do {
                try graph.save(to: url)
                performFileAction(action)
            } catch {
                NSAlert(error: error).runModal()
            }
        } else {
            saveActiveGraphAs { success in
                if success { performFileAction(action) }
            }
        }
    }

    private func closeActiveTab() {
        let index = workspace.activeIndex
        let graph = workspace.graphs[index]
        if graph.hasUnsavedChanges {
            // Delegate to ContentView's close-tab alert since
            // the tab bar close button and Cmd+W share the same flow.
            // Post a notification that ContentView listens to.
            NotificationCenter.default.post(
                name: .closeTabRequested,
                object: nil,
                userInfo: ["index": index]
            )
        } else {
            _ = workspace.closeTab(at: index)
        }
    }

    private func openGraph() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.grasshopperGraph]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Open Graph"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            if workspace.shouldReplaceCurrentTab() {
                try workspace.activeGraph.load(from: url)
            } else {
                let graph = NodeGraph()
                try graph.load(from: url)
                workspace.openGraph(graph)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Failed to open graph"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func saveActiveGraph() {
        let graph = workspace.activeGraph
        if let url = graph.currentFileURL {
            do {
                try graph.save(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        } else {
            saveActiveGraphAs()
        }
    }

    private func saveActiveGraphAs(_ completion: ((Bool) -> Void)? = nil) {
        let graph = workspace.activeGraph
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.grasshopperGraph]
        panel.nameFieldStringValue = graph.currentFileURL?.lastPathComponent ?? "Untitled.ghs"
        panel.canCreateDirectories = true
        panel.title = "Save Graph"

        guard panel.runModal() == .OK, let url = panel.url else {
            completion?(false)
            return
        }

        do {
            try graph.save(to: url)
            completion?(true)
        } catch {
            NSAlert(error: error).runModal()
            completion?(false)
        }
    }
}

// MARK: - Close Tab Notification

extension Notification.Name {
    static let closeTabRequested = Notification.Name("closeTabRequested")
}

private struct SettingsView: View {
    @AppStorage("showConnectorHoverHighlight") private var showConnectorHoverHighlight = true
    @AppStorage("enableWireClickColorPicker") private var enableWireClickColorPicker = true
    @AppStorage(kShow2DPreviewGridKey) private var show2DPreviewGrid = false
    @AppStorage(kShow2DPreviewAxesKey) private var show2DPreviewAxes = false
    @AppStorage(kShowNodesBackgroundDotsKey) private var showNodesBackgroundDots = true
    @AppStorage(kNodesBackgroundDotSizeKey) private var nodesBackgroundDotSize = 2.0
    @ObservedObject private var colorStore = PortColorStore.shared

    var body: some View {
        Form {
            Toggle("Show connector hover highlight", isOn: $showConnectorHoverHighlight)
            Toggle("Click a wire to change its data type's color", isOn: $enableWireClickColorPicker)

            GraphicsQualitySettingsSection()

            Section("Node Graph Background") {
                Toggle("Show dots", isOn: $showNodesBackgroundDots)
                Slider(value: $nodesBackgroundDotSize, in: 1...6, step: 0.5) {
                    Text("Dot size")
                } minimumValueLabel: {
                    Text("1")
                } maximumValueLabel: {
                    Text("6")
                }
                .disabled(!showNodesBackgroundDots)
            }

            Section("2D Preview") {
                Toggle("Show grid", isOn: $show2DPreviewGrid)
                Toggle("Show axes", isOn: $show2DPreviewAxes)
            }

            Section("Data Type Colors") {
                ForEach(PortType.allCases) { type in
                    ColorPicker(type.displayName, selection: colorStore.binding(for: type), supportsOpacity: false)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
