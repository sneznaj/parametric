import Metal
import simd

/// Builds the Metal ray-tracing scene (flattened vertex/index/material
/// buffers plus a single acceleration structure) from the same
/// `[TrackedShape]` + `RenderConfig` feed `FilamentRenderView` consumes.
///
/// Only shapes `MeshKernel` can tessellate to triangles are ray-traceable —
/// points/lines/polylines/curves have no surface to intersect and are
/// silently skipped here, matching Ultra Realistic's hard-surface-only scope.
final class PathTracerScene {
    private let device: MTLDevice

    private(set) var vertexBuffer: MTLBuffer?
    private(set) var normalBuffer: MTLBuffer?
    private(set) var indexBuffer: MTLBuffer?
    private(set) var triangleMaterialBuffer: MTLBuffer?
    private(set) var materialBuffer: MTLBuffer?
    private(set) var pointLightBuffer: MTLBuffer?
    private(set) var pointLightCount: Int = 0

    // Power-weighted light BVH over point lights + emissive triangles (see
    // `buildLightTree`), used by the kernel to importance-sample "which
    // light" instead of looping every light at every shading point.
    private(set) var lightTreeBuffer: MTLBuffer?
    private(set) var lightRefBuffer: MTLBuffer?
    private(set) var lightTreeNodeCount: Int = 0
    /// Per-triangle (primitive id) index into the light-record list, or
    /// `UInt32.max` if that triangle isn't emissive — lets a BSDF-sampled ray
    /// that lands on an emissive triangle look up its light-tree leaf so MIS
    /// can weight it against NEE (see `lightRecordToLeafNodeBuffer`).
    private(set) var trianglePrimIDToLightRecordBuffer: MTLBuffer?
    /// Per-light-record index into `lightTreeBuffer`'s leaf node — the other
    /// half of that same lookup (record -> leaf node -> walk parent pointers
    /// up to the root to get this light's tree-selection pdf from any point).
    private(set) var lightRecordToLeafNodeBuffer: MTLBuffer?

    private(set) var accelerationStructure: MTLAccelerationStructure?
    private(set) var triangleCount: Int = 0
    private(set) var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (SIMD3(-5, -5, -5), SIMD3(5, 5, 5))

    /// Bumped every time geometry, materials, or lights actually change, so
    /// the renderer knows to reset progressive accumulation.
    private(set) var generation: Int = 0

    private var lastShapes: [TrackedShape] = []
    private var lastRenderConfig: RenderConfig?

    init(device: MTLDevice) {
        self.device = device
    }

    /// App-space (Z-up) -> the same (x, z, -y) remap `FilamentHostView`'s
    /// entity builder uses (see `FilamentRenderView.swift`'s `makeEntity`),
    /// so Ultra Realistic and Realistic agree on orientation.
    private func remap(_ p: Point3D) -> SIMD3<Float> {
        SIMD3(Float(p.x), Float(p.z), Float(-p.y))
    }

    /// Rebuilds the GPU scene if content actually changed. Returns true when
    /// a rebuild happened (callers should reset accumulation in that case).
    @discardableResult
    func update(trackedShapes: [TrackedShape], renderConfig: RenderConfig, commandQueue: MTLCommandQueue) -> Bool {
        guard trackedShapes != lastShapes || renderConfig != lastRenderConfig else { return false }
        lastShapes = trackedShapes
        lastRenderConfig = renderConfig

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var triMaterial: [UInt32] = []
        var materialKeyToIndex: [Material3D.RenderKey: UInt32] = [:]
        var materials: [PTMaterial] = []

        func materialIndex(for material: Material3D) -> UInt32 {
            let key = material.renderKey
            if let existing = materialKeyToIndex[key] { return existing }
            let idx = UInt32(materials.count)
            materials.append(PTMaterial(
                baseColor: SIMD3(Float(material.r), Float(material.g), Float(material.b)),
                roughness: Float(max(material.roughness, 0.03)),
                metalness: Float(material.metalness),
                specular: Float(material.specular),
                clearcoat: Float(material.clearcoat),
                clearcoatRoughness: 0.02,
                sheenColor: SIMD3(Float(material.sheenR), Float(material.sheenG), Float(material.sheenB)),
                sheenRoughness: Float(material.sheenRoughness),
                anisotropy: Float(material.anisotropy),
                transmission: Float(material.transmission),
                ior: Float(material.ior),
                emission: SIMD3(Float(material.emissionR), Float(material.emissionG), Float(material.emissionB)) * Float(material.emissionStrength),
                subsurfaceColor: SIMD3(Float(material.subsurfaceR), Float(material.subsurfaceG), Float(material.subsurfaceB)),
                subsurfacePower: Float(material.subsurfacePower),
                thickness: Float(material.thickness),
                isSubsurface: material.resolvedShadingFamily == .subsurface ? 1 : 0
            ))
            materialKeyToIndex[key] = idx
            return idx
        }

        for tracked in trackedShapes {
            let geometry = tracked.shape.unwrapForRendering()
            guard let mesh = MeshKernel.meshData(from: geometry),
                  !mesh.vertices.isEmpty, !mesh.triangleIndices.isEmpty else { continue }

            let vertexNormals = MeshKernel.vertexNormals(for: geometry, mesh: mesh)
            let matIdx = materialIndex(for: tracked.shape.material())
            let baseIndex = UInt32(positions.count)

            positions.append(contentsOf: mesh.vertices.map(remap))
            normals.append(contentsOf: vertexNormals.map(remap))

            var t = 0
            while t + 2 < mesh.triangleIndices.count {
                indices.append(UInt32(mesh.triangleIndices[t]) + baseIndex)
                indices.append(UInt32(mesh.triangleIndices[t + 1]) + baseIndex)
                indices.append(UInt32(mesh.triangleIndices[t + 2]) + baseIndex)
                triMaterial.append(matIdx)
                t += 3
            }
        }

        // "Object Light" nodes: arbitrary geometry turned into an area light,
        // carried on RenderConfig instead of painted onto the shape (see
        // `SceneObjectLight`'s doc comment) — tessellated here with their own
        // synthetic emissive material rather than reusing whatever material
        // (if any) their Output node applied to them.
        for objectLight in renderConfig.objectLights {
            let material = Material3D(
                r: objectLight.color.r,
                g: objectLight.color.g,
                b: objectLight.color.b,
                roughness: 0.9,
                metalness: 0,
                emissionR: objectLight.color.r,
                emissionG: objectLight.color.g,
                emissionB: objectLight.color.b,
                emissionStrength: objectLight.intensity
            )
            let matIdx = materialIndex(for: material)

            for shape in objectLight.shapes {
                let geometry = shape.unwrapForRendering()
                guard let mesh = MeshKernel.meshData(from: geometry),
                      !mesh.vertices.isEmpty, !mesh.triangleIndices.isEmpty else { continue }

                let vertexNormals = MeshKernel.vertexNormals(for: geometry, mesh: mesh)
                let baseIndex = UInt32(positions.count)

                positions.append(contentsOf: mesh.vertices.map(remap))
                normals.append(contentsOf: vertexNormals.map(remap))

                var t = 0
                while t + 2 < mesh.triangleIndices.count {
                    indices.append(UInt32(mesh.triangleIndices[t]) + baseIndex)
                    indices.append(UInt32(mesh.triangleIndices[t + 1]) + baseIndex)
                    indices.append(UInt32(mesh.triangleIndices[t + 2]) + baseIndex)
                    triMaterial.append(matIdx)
                    t += 3
                }
            }
        }

        triangleCount = indices.count / 3

        guard !positions.isEmpty, !indices.isEmpty else {
            vertexBuffer = nil; normalBuffer = nil; indexBuffer = nil
            triangleMaterialBuffer = nil; materialBuffer = nil; accelerationStructure = nil
            pointLightBuffer = nil; pointLightCount = 0
            lightTreeBuffer = nil; lightRefBuffer = nil; lightTreeNodeCount = 0
            trianglePrimIDToLightRecordBuffer = nil; lightRecordToLeafNodeBuffer = nil
            generation += 1
            return true
        }

        vertexBuffer = makeBuffer(positions)
        normalBuffer = makeBuffer(normals)
        indexBuffer = makeBuffer(indices)
        triangleMaterialBuffer = makeBuffer(triMaterial)
        materialBuffer = materials.isEmpty ? makeBuffer([PTMaterial.neutral]) : makeBuffer(materials)

        let pointLights: [PTPointLight] = renderConfig.pointLights.map { light in
            PTPointLight(
                position: remap(light.position),
                color: SIMD3(Float(light.color.r), Float(light.color.g), Float(light.color.b)) * Float(light.intensity)
            )
        }
        pointLightCount = pointLights.count
        pointLightBuffer = pointLights.isEmpty ? makeBuffer([PTPointLight.zero]) : makeBuffer(pointLights)

        buildAccelerationStructure(commandQueue: commandQueue)
        sceneBounds = computeBounds(positions)

        let (treeNodes, lightRefs, recordToLeaf, triangleToRecord) = buildLightTree(
            pointLights: pointLights,
            positions: positions,
            indices: indices,
            triMaterial: triMaterial,
            materials: materials
        )
        lightTreeNodeCount = treeNodes.count
        lightTreeBuffer = treeNodes.isEmpty ? makeBuffer([PTLightTreeNode.dummy]) : makeBuffer(treeNodes)
        lightRefBuffer = lightRefs.isEmpty ? makeBuffer([PTLightRef.zero]) : makeBuffer(lightRefs)
        lightRecordToLeafNodeBuffer = recordToLeaf.isEmpty ? makeBuffer([UInt32.max]) : makeBuffer(recordToLeaf)
        trianglePrimIDToLightRecordBuffer = makeBuffer(triangleToRecord)

        generation += 1
        return true
    }

    private func makeBuffer<T>(_ elements: [T]) -> MTLBuffer? {
        elements.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }

    private func computeBounds(_ positions: [SIMD3<Float>]) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (SIMD3(-5, -5, -5), SIMD3(5, 5, 5)) }
        var hi = lo
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    private func buildAccelerationStructure(commandQueue: MTLCommandQueue) {
        guard let vertexBuffer, let indexBuffer else {
            accelerationStructure = nil
            return
        }

        let geometryDescriptor = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometryDescriptor.vertexBuffer = vertexBuffer
        geometryDescriptor.vertexFormat = .float3
        geometryDescriptor.vertexStride = MemoryLayout<SIMD3<Float>>.stride
        geometryDescriptor.indexBuffer = indexBuffer
        geometryDescriptor.indexType = .uint32
        geometryDescriptor.triangleCount = triangleCount

        let structureDescriptor = MTLPrimitiveAccelerationStructureDescriptor()
        structureDescriptor.geometryDescriptors = [geometryDescriptor]

        let sizes = device.accelerationStructureSizes(descriptor: structureDescriptor)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratchBuffer = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 4), options: .storageModePrivate),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeAccelerationStructureCommandEncoder() else {
            accelerationStructure = nil
            return
        }

        encoder.build(accelerationStructure: structure, descriptor: structureDescriptor,
                      scratchBuffer: scratchBuffer, scratchBufferOffset: 0)
        encoder.endEncoding()
        commandBuffer.commit()
        // Scene rebuilds only happen on structural graph edits (not every
        // frame), so a synchronous wait here is an acceptable, infrequent
        // stall rather than something that needs async completion handling.
        commandBuffer.waitUntilCompleted()

        accelerationStructure = structure
    }

    // MARK: - Light tree

    /// One leaf candidate for the light BVH: either a point light or an
    /// emissive triangle. `position` is used only as a fallback centroid;
    /// `boundsMin`/`boundsMax` drive the actual median-split build.
    private struct LightRecord {
        var isTriangle: Bool
        var index: UInt32       // point-light index, or triangle primitive id
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
        var power: Float
    }

    private func luminance(_ c: SIMD3<Float>) -> Float {
        dot(c, SIMD3(0.2126, 0.7152, 0.0722))
    }

    /// Builds a power-weighted binary light BVH via top-down median split on
    /// the largest-extent bounding-box axis — a simple, well-understood light
    /// importance structure (not the full Bitterli/Moana cone-culling light
    /// tree). Runs only when the scene actually changes (called from
    /// `update()`'s diff-gate), same cost profile as the accel-structure
    /// rebuild above.
    private func buildLightTree(
        pointLights: [PTPointLight],
        positions: [SIMD3<Float>],
        indices: [UInt32],
        triMaterial: [UInt32],
        materials: [PTMaterial]
    ) -> (nodes: [PTLightTreeNode], lightRefs: [PTLightRef], recordToLeafNode: [UInt32], trianglePrimIDToRecord: [UInt32]) {
        var records: [LightRecord] = []
        var trianglePrimIDToRecord = [UInt32](repeating: .max, count: triMaterial.count)

        for (i, light) in pointLights.enumerated() {
            let power = luminance(light.color)
            guard power > 0 else { continue }
            records.append(LightRecord(isTriangle: false, index: UInt32(i),
                                        boundsMin: light.position, boundsMax: light.position,
                                        power: power))
        }

        for primID in 0..<triMaterial.count {
            let material = materials[Int(triMaterial[primID])]
            let emissionPower = luminance(material.emission)
            guard emissionPower > 0 else { continue }
            let i0 = Int(indices[primID * 3 + 0])
            let i1 = Int(indices[primID * 3 + 1])
            let i2 = Int(indices[primID * 3 + 2])
            let v0 = positions[i0], v1 = positions[i1], v2 = positions[i2]
            let area = 0.5 * length(cross(v1 - v0, v2 - v0))
            guard area > 1e-8 else { continue }
            trianglePrimIDToRecord[primID] = UInt32(records.count)
            records.append(LightRecord(isTriangle: true, index: UInt32(primID),
                                        boundsMin: simd_min(simd_min(v0, v1), v2),
                                        boundsMax: simd_max(simd_max(v0, v1), v2),
                                        power: emissionPower * area))
        }

        guard !records.isEmpty else { return ([], [], [], trianglePrimIDToRecord) }

        let lightRefs: [PTLightRef] = records.map {
            PTLightRef(isTriangle: $0.isTriangle ? 1 : 0, index: $0.index, power: $0.power)
        }

        var nodes: [PTLightTreeNode] = []
        nodes.reserveCapacity(records.count * 2)
        var recordToLeafNode = [UInt32](repeating: .max, count: records.count)

        // Builds bottom-up; each node's own `parent` field is provisionally
        // set to its own index (a natural "I'm the root" sentinel) and
        // overwritten with the real parent index the moment that parent node
        // is created just below — so only the actual root keeps the
        // self-referencing sentinel once the whole build finishes.
        func build(_ order: inout [Int], _ lo: Int, _ hi: Int) -> Int {
            if hi - lo == 1 {
                let selfIndex = UInt32(nodes.count)
                let r = records[order[lo]]
                nodes.append(PTLightTreeNode(
                    boundsMin: r.boundsMin, boundsMax: r.boundsMax,
                    power: SIMD3(repeating: r.power),
                    leftChild: 0, rightChild: 0,
                    lightRefIndex: UInt32(order[lo]), isLeaf: 1,
                    parent: selfIndex
                ))
                recordToLeafNode[order[lo]] = selfIndex
                return Int(selfIndex)
            }

            var bmin = records[order[lo]].boundsMin
            var bmax = records[order[lo]].boundsMax
            for i in (lo + 1)..<hi {
                bmin = simd_min(bmin, records[order[i]].boundsMin)
                bmax = simd_max(bmax, records[order[i]].boundsMax)
            }
            let extent = bmax - bmin
            let axis = (extent.x >= extent.y && extent.x >= extent.z) ? 0 : (extent.y >= extent.z ? 1 : 2)

            let sortedSlice = order[lo..<hi].sorted { a, b in
                let ca = (records[a].boundsMin[axis] + records[a].boundsMax[axis]) * 0.5
                let cb = (records[b].boundsMin[axis] + records[b].boundsMax[axis]) * 0.5
                return ca < cb
            }
            for (offset, value) in sortedSlice.enumerated() { order[lo + offset] = value }

            let mid = lo + (hi - lo) / 2
            let leftIdx = build(&order, lo, mid)
            let rightIdx = build(&order, mid, hi)

            let selfIndex = UInt32(nodes.count)
            nodes[leftIdx].parent = selfIndex
            nodes[rightIdx].parent = selfIndex
            nodes.append(PTLightTreeNode(
                boundsMin: bmin, boundsMax: bmax,
                power: nodes[leftIdx].power + nodes[rightIdx].power,
                leftChild: UInt32(leftIdx), rightChild: UInt32(rightIdx),
                lightRefIndex: 0, isLeaf: 0,
                parent: selfIndex
            ))
            return Int(selfIndex)
        }

        var order = Array(0..<records.count)
        _ = build(&order, 0, records.count)

        return (nodes, lightRefs, recordToLeafNode, trianglePrimIDToRecord)
    }
}

private extension PTMaterial {
    static let neutral = PTMaterial(
        baseColor: SIMD3(0.7, 0.7, 0.7), roughness: 0.4, metalness: 0, specular: 0.5, clearcoat: 0,
        clearcoatRoughness: 0.02,
        sheenColor: SIMD3(0, 0, 0), sheenRoughness: 0.3,
        anisotropy: 0,
        transmission: 0, ior: 1.5,
        emission: SIMD3(0, 0, 0),
        subsurfaceColor: SIMD3(1, 1, 1), subsurfacePower: 12.234, thickness: 1.0,
        isSubsurface: 0
    )
}

private extension PTPointLight {
    static let zero = PTPointLight(position: SIMD3(0, 0, 0), color: SIMD3(0, 0, 0))
}

private extension PTLightTreeNode {
    static let dummy = PTLightTreeNode(
        boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(0, 0, 0), power: SIMD3(0, 0, 0),
        leftChild: 0, rightChild: 0, lightRefIndex: 0, isLeaf: 1, parent: 0
    )
}

private extension PTLightRef {
    static let zero = PTLightRef(isTriangle: 0, index: 0, power: 0)
}
