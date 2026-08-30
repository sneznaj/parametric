# Parametric

SwiftUI macOS prototype for a Grasshopper-style parametric modeling tool.

## Features

- **Node-based visual programming** — build parametric models by wiring together nodes on a graph canvas (`GraphCanvas`, `NodeView`, `NodeLibraryPanel`), with live evaluation via `NodeEvaluator`.
- **Geometry kernels** — CSG boolean operations, curve construction, and mesh generation (`CSGKernel`, `CurveKernel`, `MeshKernel`), plus math expression nodes for driving parameters.
- **Real-time PBR viewport** — Filament-backed rendering (`FilamentRenderView`) with physically based studio materials and image-based lighting.
- **Path-traced rendering** — a custom Metal path tracer (`PathTracerRenderer`, `PathTracerShaders.metal`) for higher-fidelity offline-style renders, with optional Intel Open Image Denoise (OIDN) cleanup pass.
- **Wide export support** — write geometry out to OBJ, STL, STEP, IGES, FBX, glTF, USD, PLY, 3MF, Collada, and SVG.
- **Workspace management** — save and reload node graphs as projects (`WorkspaceManager`).

## Layout

- `GrasshopperSwift/` contains the Xcode project, XcodeGen spec, and app source.
- `docs/reference/` contains local reference material, including the Rhino developer mirror.
- `.build/` is the local build workspace for products, DerivedData, packages, and archived artifacts.

## Build

```sh
make build
```

The built app is written to `.build/Products/Debug/GrasshopperSwift.app`.

Useful targets:

- `make run` builds and launches the app.
- `make build CONFIG=Release` builds a release configuration.
- `make package CONFIG=Release` creates `.build/dist/GrasshopperSwift-Release.zip`.
- `make project` regenerates `GrasshopperSwift.xcodeproj` from `GrasshopperSwift/project.yml` with XcodeGen.
- `make clean` removes `.build`.

Requirements:

- Xcode with the macOS SDK.
- XcodeGen only when regenerating the project file.
