import AppKit
import SwiftUI

struct NodeView: View {
    @ObservedObject var node: Node
    @ObservedObject var graph: NodeGraph
    let onPortTap: (UUID, UUID, Bool) -> Void   // nodeID, portID, isInput
    let onTap: () -> Void
    let onDelete: () -> Void
    let liveOffset: CGSize
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            portsArea
        }
        .frame(width: Node.width)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(nodeBackground)
        .overlay(nodeBorder)
        .shadow(color: node.isSelected ? .accentColor.opacity(0.6) : .black.opacity(0.25),
                radius: node.isSelected ? 8 : 4, x: 0, y: 2)
        .offset(x: liveOffset.width, y: liveOffset.height)
        .onHover { isHovered in
            if isHovered {
                graph.hoveredNodeID = node.id
            } else if graph.hoveredNodeID == node.id {
                graph.hoveredNodeID = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(node.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            if node.isSelected {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("Delete node")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Node.headerHeight)
        .background(headerColor)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .overlay {
            NodeHeaderPanCapture(
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
        }
    }

    private var headerColor: Color {
        node.kind.category.color
    }

    // MARK: Ports

    private var portsArea: some View {
        let rowCount = max(node.inputs.count, node.outputs.count)
        return VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 0) {
                    // Input port
                    if row < node.inputs.count {
                        portView(port: node.inputs[row], index: row, isInput: true)
                    } else {
                        Spacer()
                    }
                    Spacer()
                    // Output port
                    if row < node.outputs.count {
                        portView(port: node.outputs[row], index: row, isInput: false)
                    } else {
                        Spacer()
                    }
                }
                .frame(height: Node.portRowHeight)
            }
            // Param value display
            paramDisplay
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func portView(port: Port, index: Int, isInput: Bool) -> some View {
        let isConnected = graph.connections.contains {
            isInput
                ? ($0.toNodeID == node.id && $0.toPortID == port.id)
                : ($0.fromNodeID == node.id && $0.fromPortID == port.id)
        }

        HStack(spacing: 4) {
            if !isInput { Spacer() }

            // Dot
            Circle()
                .fill(port.type.color)
                .frame(width: Node.portRadius * 2, height: Node.portRadius * 2)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: isConnected ? 0 : 1.5)
                )
                .onTapGesture { onPortTap(node.id, port.id, isInput) }

            // Label
            Text(port.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Value badge for output ports
            if !isInput, let val = port.value {
                Text(val.displayString)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(port.type.color.opacity(0.8)))
                    .lineLimit(1)
            }

            if isInput { Spacer() }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Param inline display (for param nodes)

    @ViewBuilder
    private var paramDisplay: some View {
        switch node.kind {
        case .numberSlider:
            NumberSliderInline(node: node, graph: graph)
        case .numberInput:
            NumberInputInline(node: node, graph: graph)
        case .booleanToggle:
            BooleanToggleInline(node: node, graph: graph)
        case .textInput:
            TextInputInline(node: node, graph: graph)
        case .colorPicker:
            ColorPickerInline(node: node, graph: graph)
        default:
            EmptyView()
        }
    }

    // MARK: Background / Border

    private var nodeBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.regularMaterial)
    }

    private var nodeBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(node.isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: node.isSelected ? 2 : 1)
    }
}

private struct NodeHeaderPanCapture: NSViewRepresentable {
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDragChanged: onDragChanged, onDragEnded: onDragEnded)
    }

    func makeNSView(context: Context) -> PanCaptureView {
        let view = PanCaptureView()
        let recognizer = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.buttonMask = 0x1
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateNSView(_ nsView: PanCaptureView, context: Context) {
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
    }

    final class Coordinator: NSObject {
        var onDragChanged: (CGSize) -> Void
        var onDragEnded: () -> Void

        init(onDragChanged: @escaping (CGSize) -> Void, onDragEnded: @escaping () -> Void) {
            self.onDragChanged = onDragChanged
            self.onDragEnded = onDragEnded
        }

        @objc func handlePan(_ recognizer: NSPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            let offset = CGSize(width: translation.x, height: -translation.y)

            switch recognizer.state {
            case .began, .changed:
                onDragChanged(offset)
            case .ended, .cancelled, .failed:
                onDragChanged(offset)
                onDragEnded()
            default:
                break
            }
        }
    }
}

private final class PanCaptureView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }
}

// MARK: - Right-click helper

private struct RightClickHandler: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> RightClickNSView { RightClickNSView(action: action) }
    func updateNSView(_ v: RightClickNSView, context: Context) { v.action = action }

    class RightClickNSView: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func rightMouseDown(with event: NSEvent) { action() }
    }
}

// MARK: - Param Inline Views

struct NumberSliderInline: View {
    @ObservedObject var node: Node
    @ObservedObject var graph: NodeGraph
    @State private var value: Double = 0
    @State private var isEditingRange = false

    private var safeRange: ClosedRange<Double> {
        node.sliderMin < node.sliderMax ? node.sliderMin...node.sliderMax : node.sliderMin...node.sliderMin
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Group {
                    if node.sliderStep > 0 {
                        Slider(value: $value, in: safeRange, step: node.sliderStep)
                    } else {
                        Slider(value: $value, in: safeRange)
                    }
                }
                .controlSize(.mini)
                .onChange(of: value) { _, v in
                    node.outputs[0].value = .number(v)
                    graph.evaluate()
                }
                Text(String(format: "%.2g", value))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            if isEditingRange {
                HStack(spacing: 4) {
                    TextField("Min", value: $node.sliderMin, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .frame(width: 40)
                    Text("→")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("Max", value: $node.sliderMax, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .frame(width: 40)
                    Text("/")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("Step", value: $node.sliderStep, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .frame(width: 40)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(RightClickHandler {
            withAnimation(.spring(duration: 0.2)) { isEditingRange.toggle() }
        })
        .onAppear {
            if case .number(let v) = node.outputs[safe: 0]??.value { value = v }
            else { node.outputs[0].value = .number(value) }
        }
    }
}

struct BooleanToggleInline: View {
    @ObservedObject var node: Node
    @ObservedObject var graph: NodeGraph
    @State private var isOn: Bool = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(isOn ? "True" : "False")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onChange(of: isOn) { _, v in
            node.outputs[0].value = .boolean(v)
            graph.evaluate()
        }
        .onAppear {
            if case .boolean(let v) = node.outputs[safe: 0]??.value { isOn = v }
            else { node.outputs[0].value = .boolean(isOn) }
        }
    }
}

struct TextInputInline: View {
    @ObservedObject var node: Node
    @ObservedObject var graph: NodeGraph
    @State private var text: String = ""

    var body: some View {
        TextField("Text…", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .onChange(of: text) { _, v in
                node.outputs[0].value = .text(v)
                graph.evaluate()
            }
            .onAppear {
                if case .text(let v) = node.outputs[safe: 0]??.value { text = v }
                else { node.outputs[0].value = .text(text) }
            }
    }
}

struct NumberInputInline: View {
    @ObservedObject var node: Node
    @ObservedObject var graph: NodeGraph
    @State private var value: Double = 0
    @State private var draftValue: String = ""
    @State private var isEditing = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("0", text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .focused($isFieldFocused)
                    .onSubmit(commitDraft)
                    .onChange(of: isFieldFocused) { _, focused in
                        if !focused {
                            commitDraft()
                        }
                    }
                    .background(
                        OutsideClickCommitter(isEnabled: isEditing) {
                            commitDraft()
                        }
                    )
            } else {
                Text(String(format: "%.4g", value))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture {
                        draftValue = formattedValue(value)
                        isEditing = true
                        isFieldFocused = true
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onAppear {
            if case .number(let v) = node.outputs[safe: 0]??.value {
                value = v
            } else {
                node.outputs[0].value = .number(value)
            }
            draftValue = formattedValue(value)
        }
    }

    private func commitDraft() {
        defer { isEditing = false }

        let trimmed = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed) else {
            draftValue = formattedValue(value)
            return
        }

        value = parsed
        draftValue = formattedValue(parsed)
        node.outputs[0].value = .number(parsed)
        graph.evaluate()
    }

    private func formattedValue(_ number: Double) -> String {
        String(format: "%.4g", number)
    }
}

struct ColorPickerInline: View {
    @ObservedObject var node: Node
    @ObservedObject var graph: NodeGraph
    @State private var color: Color = .teal

    var body: some View {
        HStack(spacing: 8) {
            SwiftUI.ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color)
                .frame(width: 28, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onChange(of: color) { _, newValue in
            node.outputs[0].value = .color(newValue)
            graph.evaluate()
        }
        .onAppear {
            if case .color(let stored) = node.outputs[safe: 0]??.value {
                color = stored
            } else {
                node.outputs[0].value = .color(color)
            }
        }
    }
}

private struct OutsideClickCommitter: NSViewRepresentable {
    let isEnabled: Bool
    let onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutsideClick: onOutsideClick)
    }

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        context.coordinator.onOutsideClick = onOutsideClick
        context.coordinator.setEnabled(isEnabled)
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onOutsideClick: () -> Void
        private weak var view: NSView?
        private var monitor: Any?

        init(onOutsideClick: @escaping () -> Void) {
            self.onOutsideClick = onOutsideClick
        }

        func attach(to view: NSView) {
            self.view = view
        }

        func setEnabled(_ enabled: Bool) {
            if enabled {
                startMonitoringIfNeeded()
            } else {
                stopMonitoring()
            }
        }

        func detach() {
            stopMonitoring()
            view = nil
        }

        private func startMonitoringIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let view = self.view, view.window != nil else {
                    return event
                }

                let frameInWindow = view.convert(view.bounds, to: nil)
                if !frameInWindow.contains(event.locationInWindow) {
                    self.onOutsideClick()
                }

                return event
            }
        }

        private func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

private final class TrackingView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
