import Combine
import Foundation
import SwiftUI
import AppKit

final class CanvasViewport: ObservableObject {
    @Published var offset: CGSize = .zero
    @Published var scale: CGFloat = 1.0
    @Published var size: CGSize = .zero

    private var insertionStep: CGFloat = 0

    var visibleRect: CGRect {
        guard size.width > 0, size.height > 0, scale > 0 else {
            return CGRect(x: 80, y: 80, width: 480, height: 320)
        }

        return CGRect(
            x: -offset.width / scale,
            y: -offset.height / scale,
            width: size.width / scale,
            height: size.height / scale
        )
    }

    func nextNodePosition(nodeSize: CGSize) -> CGPoint {
        let visibleRect = visibleRect
        let padding: CGFloat = 24
        let maxX = max(visibleRect.minX + padding, visibleRect.maxX - nodeSize.width - padding)
        let maxY = max(visibleRect.minY + padding, visibleRect.maxY - nodeSize.height - padding)

        let baseX = min(max(visibleRect.minX + padding, visibleRect.midX - nodeSize.width / 2), maxX)
        let baseY = min(max(visibleRect.minY + padding, visibleRect.midY - nodeSize.height / 2), maxY)

        let step = min(28, max(16, min(visibleRect.width, visibleRect.height) * 0.06))
        let spanX = max(0, maxX - baseX)
        let spanY = max(0, maxY - baseY)
        let columns = max(1, Int(spanX / step) + 1)
        let rows = max(1, Int(spanY / step) + 1)
        let slotCount = max(1, columns * rows)
        let slot = Int(insertionStep) % slotCount
        let column = slot % columns
        let row = slot / columns

        insertionStep += 1

        return CGPoint(
            x: min(baseX + CGFloat(column) * step, maxX),
            y: min(baseY + CGFloat(row) * step, maxY)
        )
    }
}

// MARK: - Port

enum PortType: String, Codable, CaseIterable {
    case number, vector2, vector3, boolean, text, color, geometry, material, any

    var color: Color {
        switch self {
        case .number:   return .orange
        case .vector2:  return .green
        case .vector3:  return .blue
        case .boolean:  return .red
        case .text:     return .purple
        case .color:    return .pink
        case .geometry: return .teal
        case .material: return .yellow
        case .any:      return .gray
        }
    }
}

struct Port: Identifiable {
    let id: UUID
    let name: String
    let type: PortType
    let isInput: Bool
    var value: PortValue?

    init(id: UUID = UUID(), name: String, type: PortType, isInput: Bool, value: PortValue? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.isInput = isInput
        self.value = value
    }
}

// MARK: - Port Value

enum PortValue {
    case number(Double)
    case vector2(CGPoint)
    case vector3(x: Double, y: Double, z: Double)
    case boolean(Bool)
    case text(String)
    case color(Color)
    case geometry([GeometricShape])
    case material(Material3D)

    var displayString: String {
        switch self {
        case .number(let v):        return String(format: "%.3g", v)
        case .vector2(let p):       return String(format: "(%.2g, %.2g)", p.x, p.y)
        case .vector3(let x, let y, let z): return String(format: "(%.2g, %.2g, %.2g)", x, y, z)
        case .boolean(let b):       return b ? "True" : "False"
        case .text(let s):          return s
        case .color:                return "Color"
        case .geometry(let shapes): return "\(shapes.count) shape\(shapes.count == 1 ? "" : "s")"
        case .material(let m):
            return "\(m.resolvedSurfaceType.rawValue) \(m.resolvedFinish.rawValue) r:\(String(format: "%.2g", m.roughness)) m:\(String(format: "%.2g", m.metalness))"
        }
    }

    func asDouble() -> Double? {
        if case .number(let v) = self { return v }
        if case .boolean(let b) = self { return b ? 1 : 0 }
        return nil
    }

    func asColorComponents() -> (r: Double, g: Double, b: Double)? {
        guard case .color(let color) = self else { return nil }
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return (
            r: Double(nsColor.redComponent),
            g: Double(nsColor.greenComponent),
            b: Double(nsColor.blueComponent)
        )
    }
}

// MARK: - Connection

struct Connection: Identifiable {
    let id: UUID
    let fromNodeID: UUID
    let fromPortID: UUID
    let toNodeID: UUID
    let toPortID: UUID

    init(id: UUID = UUID(), fromNodeID: UUID, fromPortID: UUID, toNodeID: UUID, toPortID: UUID) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.fromPortID = fromPortID
        self.toNodeID = toNodeID
        self.toPortID = toPortID
    }
}

// MARK: - Node

class Node: Identifiable, ObservableObject {
    let id: UUID
    let kind: NodeKind
    @Published var position: CGPoint
    @Published var inputs: [Port]
    @Published var outputs: [Port]
    @Published var isSelected: Bool = false
    @Published var label: String
    // Slider configuration (only used by numberSlider nodes)
    @Published var sliderMin: Double = 0
    @Published var sliderMax: Double = 100
    @Published var sliderStep: Double = 0

    init(id: UUID = UUID(), kind: NodeKind, position: CGPoint, inputs: [Port], outputs: [Port], label: String? = nil) {
        self.id = id
        self.kind = kind
        self.position = position
        self.inputs = inputs
        self.outputs = outputs
        self.label = label ?? kind.defaultLabel
    }

    var title: String { kind.defaultLabel }

    static let width: CGFloat = 160
    static let headerHeight: CGFloat = 32
    static let portRowHeight: CGFloat = 24
    static let portRadius: CGFloat = 7

    var height: CGFloat {
        let rows = CGFloat(max(inputs.count, outputs.count))
        return Node.headerHeight + rows * Node.portRowHeight + 8
    }

    func inputPortPosition(index: Int, in graph: NodeGraph) -> CGPoint {
        let y = Node.headerHeight + CGFloat(index) * Node.portRowHeight + Node.portRowHeight / 2
        return CGPoint(x: position.x, y: position.y + y)
    }

    func outputPortPosition(index: Int, in graph: NodeGraph) -> CGPoint {
        let y = Node.headerHeight + CGFloat(index) * Node.portRowHeight + Node.portRowHeight / 2
        return CGPoint(x: position.x + Node.width, y: position.y + y)
    }
}

// MARK: - Node Kind

enum NodeKind: String, CaseIterable {
    // Params
    case numberSlider, numberInput, booleanToggle, textInput, colorPicker, point2D, point3D
    // Math
    case add, subtract, multiply, divide, modulo, power, absolute, negate
    // Logic
    case logicAnd, logicOr, logicNot, greaterThan, lessThan, equality
    // Text
    case concatenate, textLength, uppercase, lowercase
    // Vector
    case constructPoint, deconstruct, distance, vectorAdd, vectorScale
    // Utility
    case output, remap, clamp, lerp
    // Geometry – 2D
    case geoPoint, geoLine, geoCircle, geoPolygon, geoGrid
    case geoRectangle, geoEllipse, geoArc, geoBezier, geoLoftSurface
    // Geometry – 3D
    case geoSphere, geoBox, geoCylinder, geoCone, geoTorus
    // Transforms
    case geoTranslate, geoRotate, geoScale
    // Material
    case material, materialABSPlastic, materialAnodizedAluminum, materialBrushedStainless, materialBeadBlastedSteel, materialChrome

    var defaultLabel: String {
        switch self {
        case .numberSlider: return "Number Slider"
        case .numberInput: return "Number Input"
        case .booleanToggle: return "Boolean"
        case .textInput: return "Text"
        case .colorPicker: return "Color"
        case .point2D: return "Point 2D"
        case .point3D: return "Point 3D"
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .multiply: return "Multiply"
        case .divide: return "Divide"
        case .modulo: return "Modulo"
        case .power: return "Power"
        case .absolute: return "Absolute"
        case .negate: return "Negate"
        case .logicAnd: return "And"
        case .logicOr: return "Or"
        case .logicNot: return "Not"
        case .greaterThan: return "Greater Than"
        case .lessThan: return "Less Than"
        case .equality: return "Equality"
        case .concatenate: return "Concatenate"
        case .textLength: return "Text Length"
        case .uppercase: return "Uppercase"
        case .lowercase: return "Lowercase"
        case .constructPoint: return "Construct Pt"
        case .deconstruct: return "Deconstruct Pt"
        case .distance: return "Distance"
        case .vectorAdd: return "Vector Add"
        case .vectorScale: return "Vector Scale"
        case .output: return "Output"
        case .remap: return "Remap"
        case .clamp: return "Clamp"
        case .lerp: return "Lerp"
        // Geometry – 2D
        case .geoPoint:     return "Point"
        case .geoLine:      return "Line"
        case .geoCircle:    return "Circle"
        case .geoPolygon:   return "Polygon"
        case .geoGrid:      return "Grid"
        case .geoRectangle: return "Rectangle"
        case .geoEllipse:   return "Ellipse"
        case .geoArc:       return "Arc"
        case .geoBezier:    return "Bezier"
        case .geoLoftSurface: return "Loft Surface"
        // Geometry – 3D
        case .geoSphere:    return "Sphere"
        case .geoBox:       return "Box"
        case .geoCylinder:  return "Cylinder"
        case .geoCone:      return "Cone"
        case .geoTorus:     return "Torus"
        // Transforms
        case .geoTranslate: return "Translate"
        case .geoRotate:    return "Rotate"
        case .geoScale:     return "Scale"
        case .material:     return "Material"
        case .materialABSPlastic: return "ABS Plastic"
        case .materialAnodizedAluminum: return "Anodized Aluminum"
        case .materialBrushedStainless: return "Brushed Stainless"
        case .materialBeadBlastedSteel: return "Bead-Blasted Steel"
        case .materialChrome: return "Chrome"
        }
    }

    var category: NodeCategory {
        switch self {
        case .numberSlider, .numberInput, .booleanToggle, .textInput, .colorPicker, .point2D, .point3D:
            return .params
        case .add, .subtract, .multiply, .divide, .modulo, .power, .absolute, .negate:
            return .math
        case .logicAnd, .logicOr, .logicNot, .greaterThan, .lessThan, .equality:
            return .logic
        case .concatenate, .textLength, .uppercase, .lowercase:
            return .text
        case .constructPoint, .deconstruct, .distance, .vectorAdd, .vectorScale:
            return .vector
        case .output, .remap, .clamp, .lerp:
            return .utility
        case .geoPoint, .geoLine, .geoCircle, .geoPolygon, .geoGrid,
             .geoRectangle, .geoEllipse, .geoArc, .geoBezier, .geoLoftSurface,
             .geoSphere, .geoBox, .geoCylinder, .geoCone, .geoTorus,
             .geoTranslate, .geoRotate, .geoScale,
             .material, .materialABSPlastic, .materialAnodizedAluminum,
             .materialBrushedStainless, .materialBeadBlastedSteel, .materialChrome:
            return .geometry
        }
    }

    var systemImage: String {
        switch self {
        case .numberSlider: return "slider.horizontal.3"
        case .numberInput: return "number"
        case .booleanToggle: return "togglepower"
        case .textInput: return "text.cursor"
        case .colorPicker: return "paintpalette"
        case .point2D: return "dot.square"
        case .point3D: return "cube"
        case .add: return "plus"
        case .subtract: return "minus"
        case .multiply: return "multiply"
        case .divide: return "divide"
        case .modulo: return "percent"
        case .power: return "x.squareroot"
        case .absolute: return "abs"
        case .negate: return "minus.circle"
        case .logicAnd: return "circle.grid.2x2"
        case .logicOr: return "circle.grid.3x3"
        case .logicNot: return "exclamationmark.circle"
        case .greaterThan: return "greaterthan"
        case .lessThan: return "lessthan"
        case .equality: return "equal"
        case .concatenate: return "text.append"
        case .textLength: return "character.cursor.ibeam"
        case .uppercase: return "textformat.characters.largecaps"
        case .lowercase: return "textformat.abc"
        case .constructPoint: return "scope"
        case .deconstruct: return "arrow.up.left.and.down.right.magnifyingglass"
        case .distance: return "ruler"
        case .vectorAdd: return "arrow.up.right"
        case .vectorScale: return "arrow.up.right.and.arrow.down.left"
        case .output: return "square.and.arrow.up"
        case .remap: return "arrow.left.arrow.right"
        case .clamp: return "arrow.left.to.line.alt"
        case .lerp: return "slider.horizontal.below.rectangle"
        // Geometry – 2D
        case .geoPoint:     return "smallcircle.filled.circle"
        case .geoLine:      return "line.diagonal"
        case .geoCircle:    return "circle"
        case .geoPolygon:   return "hexagon"
        case .geoGrid:      return "grid"
        case .geoRectangle: return "rectangle"
        case .geoEllipse:   return "oval"
        case .geoArc:       return "arrow.clockwise"
        case .geoBezier:    return "scribble"
        case .geoLoftSurface: return "square.stack.3d.up"
        // Geometry – 3D
        case .geoSphere:    return "globe"
        case .geoBox:       return "cube"
        case .geoCylinder:  return "cylinder"
        case .geoCone:      return "cone"
        case .geoTorus:     return "circle.dotted"
        // Transforms
        case .geoTranslate: return "move.3d"
        case .geoRotate:    return "rotate.3d"
        case .geoScale:     return "arrow.up.left.and.arrow.down.right"
        // Material
        case .material:     return "paintbrush.pointed"
        case .materialABSPlastic: return "capsule.lefthalf.filled"
        case .materialAnodizedAluminum: return "square.stack.3d.forward.dottedline"
        case .materialBrushedStainless: return "cylinder.split.1x2"
        case .materialBeadBlastedSteel: return "square.grid.3x3.topleft.filled"
        case .materialChrome: return "sparkles.rectangle.stack"
        }
    }
}

enum NodeCategory: String, CaseIterable {
    case params = "Params"
    case math = "Math"
    case logic = "Logic"
    case text = "Text"
    case vector = "Vector"
    case utility = "Utility"
    case geometry = "Geometry"

    var color: Color {
        switch self {
        case .params:   return .blue
        case .math:     return .orange
        case .logic:    return .red
        case .text:     return .purple
        case .vector:   return .green
        case .utility:  return .gray
        case .geometry: return .teal
        }
    }

    var systemImage: String {
        switch self {
        case .params:   return "slider.horizontal.3"
        case .math:     return "function"
        case .logic:    return "circle.grid.2x2"
        case .text:     return "text.alignleft"
        case .vector:   return "arrow.up.right"
        case .utility:  return "wrench.and.screwdriver"
        case .geometry: return "square.3.layers.3d"
        }
    }

    var kinds: [NodeKind] {
        NodeKind.allCases.filter { $0.category == self }
    }
}

// MARK: - NodeGraph

class NodeGraph: ObservableObject {
    private static let outputStylePortCount = 5
    private static let outputMinimumGeometryPortCount = 1
    private static let outputFreeGeometryPortBuffer = 2
    private static let outputGeometryPortGrowthChunk = 8

    @Published var nodes: [Node] = [] {
        didSet {
            bindNodes()
            normalizeOutputNodes()
        }
    }
    @Published var connections: [Connection] = []
    @Published var previewShapes: [GeometricShape] = []
    @Published var hoveredNodeID: UUID? = nil
    @Published var hoveredConnectionID: UUID? = nil

    private var nodeSubscriptions: [UUID: AnyCancellable] = [:]

    init() {
        bindNodes()
        normalizeOutputNodes()
    }

    func addNode(_ node: Node) {
        nodes.append(node)
        normalizeOutputPorts(for: node)
        evaluate()
    }

    func removeNode(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.fromNodeID == id || $0.toNodeID == id }
        if hoveredNodeID == id {
            hoveredNodeID = nil
        }
        if !connections.contains(where: { $0.id == hoveredConnectionID }) {
            hoveredConnectionID = nil
        }
        normalizeOutputNodes()
        evaluate()
    }

    func addConnection(_ conn: Connection) {
        let resolvedConnection = resolveConnectionTarget(for: conn)

        // Remove existing connection to the same input port
        connections.removeAll {
            $0.toNodeID == resolvedConnection.toNodeID && $0.toPortID == resolvedConnection.toPortID
        }
        connections.append(resolvedConnection)
        if let node = node(id: resolvedConnection.toNodeID) {
            normalizeOutputPorts(for: node)
        }
        evaluate()
    }

    func removeConnection(_ id: UUID) {
        connections.removeAll { $0.id == id }
        if hoveredConnectionID == id {
            hoveredConnectionID = nil
        }
        normalizeOutputNodes()
        evaluate()
    }

    func node(id: UUID) -> Node? {
        nodes.first { $0.id == id }
    }

    private func bindNodes() {
        let validIDs = Set(nodes.map(\.id))
        nodeSubscriptions = nodeSubscriptions.filter { validIDs.contains($0.key) }

        for node in nodes where nodeSubscriptions[node.id] == nil {
            nodeSubscriptions[node.id] = node.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    func portValue(nodeID: UUID, portID: UUID) -> PortValue? {
        guard let node = node(id: nodeID) else { return nil }
        return (node.outputs + node.inputs).first { $0.id == portID }?.value
    }

    // Topological evaluation
    func evaluate() {
        normalizeOutputNodes()

        // Build adjacency: node -> nodes it depends on
        var inDegree = [UUID: Int]()
        var deps = [UUID: [UUID]]()
        for node in nodes {
            inDegree[node.id] = 0
            deps[node.id] = []
        }
        for conn in connections {
            deps[conn.toNodeID, default: []].append(conn.fromNodeID)
            inDegree[conn.toNodeID, default: 0] += 1
        }

        var queue = nodes.filter { inDegree[$0.id] == 0 }.map { $0.id }
        var order = [UUID]()
        while !queue.isEmpty {
            let id = queue.removeFirst()
            order.append(id)
            for conn in connections where conn.fromNodeID == id {
                inDegree[conn.toNodeID, default: 1] -= 1
                if inDegree[conn.toNodeID] == 0 {
                    queue.append(conn.toNodeID)
                }
            }
        }

        for nodeID in order {
            guard let node = self.node(id: nodeID) else { continue }
            // Pull values from connected outputs into inputs
            for i in node.inputs.indices {
                if let conn = connections.first(where: { $0.toNodeID == nodeID && $0.toPortID == node.inputs[i].id }),
                   let srcNode = self.node(id: conn.fromNodeID),
                   let srcPort = srcNode.outputs.first(where: { $0.id == conn.fromPortID }) {
                    node.inputs[i].value = srcPort.value
                }
            }
            NodeEvaluator.evaluate(node: node)
        }

        previewShapes = nodes.flatMap(previewShapes(for:))
    }

    private func previewShapes(for node: Node) -> [GeometricShape] {
        guard node.kind == .output else { return [] }
        let geometryPortCount = outputGeometryPortCount(for: node)

        let color = node.inputs[safe: geometryPortCount]??.value?.asColorComponents() ?? (0.72, 0.72, 0.78)
        let roughness = max(0, min(1, node.inputs[safe: geometryPortCount + 1]??.value?.asDouble() ?? 0.35))
        let metalness = max(0, min(1, node.inputs[safe: geometryPortCount + 2]??.value?.asDouble() ?? 0.0))
        let clearcoat = max(0, min(1, node.inputs[safe: geometryPortCount + 3]??.value?.asDouble() ?? 0.08))
        let bump = max(0, min(1, node.inputs[safe: geometryPortCount + 4]??.value?.asDouble() ?? 0.18))
        let material = Material3D(
            r: color.0, g: color.1, b: color.2,
            roughness: roughness,
            metalness: metalness,
            clearcoat: clearcoat,
            normal: bump
        )

        return node.inputs.prefix(geometryPortCount).flatMap { port -> [GeometricShape] in
            guard case .geometry(let shapes) = port.value else { return [] }
            return shapes.map { $0.applyingMaterial(material) }
        }
    }

    private func resolveConnectionTarget(for connection: Connection) -> Connection {
        guard let targetNode = node(id: connection.toNodeID),
              targetNode.kind == .output,
              let tappedInputIndex = targetNode.inputs.firstIndex(where: { $0.id == connection.toPortID })
        else {
            return connection
        }

        let tappedInput = targetNode.inputs[tappedInputIndex]
        guard tappedInput.type == .geometry else {
            return connection
        }

        normalizeOutputPorts(for: targetNode)

        let geometryPortCount = outputGeometryPortCount(for: targetNode)
        let preferredPort = targetNode.inputs[tappedInputIndex]
        let preferredPortIsFree = !connections.contains {
            $0.toNodeID == targetNode.id && $0.toPortID == preferredPort.id
        }
        if preferredPortIsFree {
            return connection
        }

        guard let nextFreePort = targetNode.inputs.prefix(geometryPortCount).first(where: { geometryPort in
            !connections.contains { $0.toNodeID == targetNode.id && $0.toPortID == geometryPort.id }
        }) else {
            return connection
        }

        return Connection(
            id: connection.id,
            fromNodeID: connection.fromNodeID,
            fromPortID: connection.fromPortID,
            toNodeID: connection.toNodeID,
            toPortID: nextFreePort.id
        )
    }

    private func normalizeOutputNodes() {
        for node in nodes {
            normalizeOutputPorts(for: node)
        }
    }

    private func normalizeOutputPorts(for node: Node) {
        guard node.kind == .output else { return }

        let stylePortCount = Self.outputStylePortCount
        guard node.inputs.count >= stylePortCount else { return }

        let geometryPortCount = outputGeometryPortCount(for: node)
        let geometryInputs = Array(node.inputs.prefix(geometryPortCount))
        let styleInputs = Array(node.inputs.suffix(stylePortCount))

        let connectedGeometryCount = geometryInputs.filter { geometryPort in
            connections.contains { $0.toNodeID == node.id && $0.toPortID == geometryPort.id }
        }.count

        let minimumDesiredGeometryCount = max(
            Self.outputMinimumGeometryPortCount,
            connectedGeometryCount + Self.outputFreeGeometryPortBuffer
        )

        let desiredGeometryCount: Int
        if geometryPortCount < minimumDesiredGeometryCount {
            let shortage = minimumDesiredGeometryCount - geometryPortCount
            let growth = max(Self.outputGeometryPortGrowthChunk, shortage)
            desiredGeometryCount = geometryPortCount + growth
        } else {
            desiredGeometryCount = minimumDesiredGeometryCount
        }

        guard desiredGeometryCount != geometryPortCount else {
            relabelOutputGeometryPorts(node)
            return
        }

        var updatedGeometryInputs = geometryInputs
        if desiredGeometryCount > geometryPortCount {
            for _ in geometryPortCount..<desiredGeometryCount {
                updatedGeometryInputs.append(
                    Port(name: "Geo", type: .geometry, isInput: true)
                )
            }
        } else {
            updatedGeometryInputs = Array(updatedGeometryInputs.prefix(desiredGeometryCount))
        }

        node.inputs = updatedGeometryInputs + styleInputs
        relabelOutputGeometryPorts(node)
    }

    private func relabelOutputGeometryPorts(_ node: Node) {
        guard node.kind == .output else { return }
        let geometryPortCount = outputGeometryPortCount(for: node)
        guard geometryPortCount > 0 else { return }

        for index in 0..<geometryPortCount {
            let label = geometryPortCount == 1 ? "Geo" : "Geo \(index + 1)"
            if node.inputs[index].name != label {
                node.inputs[index] = Port(
                    id: node.inputs[index].id,
                    name: label,
                    type: node.inputs[index].type,
                    isInput: node.inputs[index].isInput,
                    value: node.inputs[index].value
                )
            }
        }
    }

    private func outputGeometryPortCount(for node: Node) -> Int {
        guard node.kind == .output else { return 0 }
        return max(0, node.inputs.count - Self.outputStylePortCount)
    }
}
