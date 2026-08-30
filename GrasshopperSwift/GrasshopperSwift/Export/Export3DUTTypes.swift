import Foundation
import UniformTypeIdentifiers

// MARK: - UTTypes for the 3D export formats

extension UTType {
    static var objFile: UTType { UTType(filenameExtension: "obj") ?? .data }
    static var mtlFile: UTType { UTType(filenameExtension: "mtl") ?? .data }
    static var stlFile: UTType { UTType(filenameExtension: "stl") ?? .data }
    static var plyFile: UTType { UTType(filenameExtension: "ply") ?? .data }
    static var glbFile: UTType { UTType(filenameExtension: "glb") ?? .data }
    static var daeFile: UTType { UTType(filenameExtension: "dae") ?? .xml }
    static var fbxFile: UTType { UTType(filenameExtension: "fbx") ?? .data }
    static var usdaFile: UTType { UTType(filenameExtension: "usda") ?? .data }
    static var usdzFile: UTType { UTType(filenameExtension: "usdz") ?? .data }
    static var stepFile: UTType { UTType(filenameExtension: "step") ?? .data }
    static var igesFile: UTType { UTType(filenameExtension: "iges") ?? .data }
    static var threeMFFile: UTType { UTType(filenameExtension: "3mf") ?? .data }
}
