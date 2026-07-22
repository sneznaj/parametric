# Parametric

SwiftUI macOS prototype for a Grasshopper-style parametric modeling tool.

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
