import Metal

/// Runs Intel Open Image Denoise's "RT" AI filter on the path tracer's HDR
/// accumulation buffer, entirely on the GPU via OIDN's Metal device backend
/// (`oidn-framework/`, built from source with `OIDN_DEVICE_METAL=ON` — the
/// Homebrew bottle only ships the CPU device).
///
/// Denoising is periodic, not per-frame: `PathTracerHostView` triggers a pass
/// every few dozen samples on a background queue, and the previous denoised
/// frame stays on screen until the next one lands. Running the ~ms-scale
/// network on every 30fps frame would starve the path tracer of GPU time for
/// no visible benefit once a pass has already converged the image.
///
/// All Metal work below (both blits and the OIDN filter itself) runs on a
/// single dedicated command queue, so ordering between "copy in", "denoise",
/// and "copy out" falls out of Metal's same-queue in-order execution — no
/// cross-queue fences needed. The *first* copy (live accumulation texture ->
/// staging buffer) is the one exception: that source texture is still being
/// written every frame by the path tracer's own queue, so that specific blit
/// is encoded by the caller on the path tracer's queue instead (see
/// `PathTracerHostView`) to avoid a cross-queue race on a resource neither
/// queue is fenced against.
final class OIDNDenoiser {
    private let device: MTLDevice
    let queue: MTLCommandQueue
    private let oidnBox: OIDNMetalDeviceBox
    private var filter: OIDNFilter?

    private(set) var colorBuffer: MTLBuffer?
    private var outputBuffer: MTLBuffer?
    private(set) var outputTexture: MTLTexture?
    private var width = 0
    private var height = 0

    /// True while a denoise pass is running on `Self.workQueue` — callers
    /// should not trigger another pass until this clears.
    private(set) var isBusy = false

    private static let workQueue = DispatchQueue(label: "com.parametric.oidn-denoise")

    init?(device: MTLDevice) {
        guard oidnIsMetalDeviceSupported(device),
              let queue = device.makeCommandQueue(),
              let box = OIDNMetalDeviceBox(commandQueue: queue) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.oidnBox = box
    }

    /// (Re)allocates the staging buffers/filter/output texture for a new
    /// resolution. Cheap no-op when the size hasn't changed.
    private func ensureResources(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        if width == self.width, height == self.height, filter != nil { return true }

        let bytesPerPixel = MemoryLayout<Float>.stride * 4 // matches accumTexture's rgba32Float layout
        let byteSize = width * height * bytesPerPixel
        guard let colorBuffer = device.makeBuffer(length: byteSize, options: .storageModePrivate),
              let outputBuffer = device.makeBuffer(length: byteSize, options: .storageModePrivate) else {
            return false
        }

        let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        texDescriptor.usage = [.shaderRead]
        texDescriptor.storageMode = .private
        guard let outputTexture = device.makeTexture(descriptor: texDescriptor) else { return false }

        guard let colorImage = oidnNewSharedBufferFromMetal(oidnBox.handle, colorBuffer),
              let outputImage = oidnNewSharedBufferFromMetal(oidnBox.handle, outputBuffer) else {
            return false
        }
        defer {
            oidnReleaseBuffer(colorImage)
            oidnReleaseBuffer(outputImage)
        }

        let newFilter = oidnNewFilter(oidnBox.handle, "RT")
        // `pixelByteStride: 16` lets OIDN read/write the 3 color channels
        // directly out of our existing rgba32Float layout, skipping the 4th
        // (alpha) float each pixel — no separate packed buffer needed.
        oidnSetFilterImage(newFilter, "color", colorImage, OIDN_FORMAT_FLOAT3, width, height, 0, 16, 0)
        oidnSetFilterImage(newFilter, "output", outputImage, OIDN_FORMAT_FLOAT3, width, height, 0, 16, 0)
        oidnSetFilterBool(newFilter, "hdr", true)
        oidnCommitFilter(newFilter)

        if let message = deviceErrorMessage() {
            print("OIDNDenoiser: filter setup failed: \(message)")
            oidnReleaseFilter(newFilter)
            return false
        }

        if let oldFilter = filter { oidnReleaseFilter(oldFilter) }
        filter = newFilter
        self.colorBuffer = colorBuffer
        self.outputBuffer = outputBuffer
        self.outputTexture = outputTexture
        self.width = width
        self.height = height
        return true
    }

    /// Ensures buffers/filter exist for `width`x`height` and returns the
    /// staging buffer the caller should blit `accumTexture` into (on the
    /// caller's own queue — see the type doc for why). Call this before
    /// `denoiseAsync` so the blit and the async call agree on a size.
    func prepareColorBuffer(width: Int, height: Int) -> MTLBuffer? {
        guard ensureResources(width: width, height: height) else { return nil }
        return colorBuffer
    }

    private func deviceErrorMessage() -> String? {
        var message: UnsafePointer<CChar>?
        let error = oidnGetDeviceError(oidnBox.handle, &message)
        guard error != OIDN_ERROR_NONE else { return nil }
        return message.map { String(cString: $0) } ?? "error \(error.rawValue)"
    }

    /// Kicks off an async denoise pass reading from `colorBuffer` (which the
    /// caller must already have filled via a blit on its own queue, after a
    /// matching `prepareColorBuffer(width:height:)` call). Calls `completion`
    /// on the main queue with the denoised texture, or nil on failure. Does
    /// nothing (silently) if a pass is already in flight, or if `width`/
    /// `height` no longer match what `prepareColorBuffer` was last called
    /// with (e.g. the view resized in between) — the caller should check
    /// `isBusy` before filling `colorBuffer` to avoid clobbering one that's
    /// mid-flight.
    func denoiseAsync(width: Int, height: Int, completion: @escaping (MTLTexture?) -> Void) {
        guard !isBusy, width == self.width, height == self.height, colorBuffer != nil,
              let filter, let outputBuffer, let outputTexture else {
            completion(nil)
            return
        }
        isBusy = true

        Self.workQueue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }

            oidnExecuteFilter(filter) // synchronous: blocks this background thread until the GPU pass completes
            if let message = self.deviceErrorMessage() {
                print("OIDNDenoiser: execute failed: \(message)")
                DispatchQueue.main.async {
                    self.isBusy = false
                    completion(nil)
                }
                return
            }

            guard let commandBuffer = self.queue.makeCommandBuffer(),
                  let blit = commandBuffer.makeBlitCommandEncoder() else {
                DispatchQueue.main.async {
                    self.isBusy = false
                    completion(nil)
                }
                return
            }
            let bytesPerPixel = MemoryLayout<Float>.stride * 4
            blit.copy(from: outputBuffer, sourceOffset: 0,
                      sourceBytesPerRow: width * bytesPerPixel, sourceBytesPerImage: width * height * bytesPerPixel,
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: outputTexture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            DispatchQueue.main.async {
                self.isBusy = false
                completion(outputTexture)
            }
        }
    }
}
