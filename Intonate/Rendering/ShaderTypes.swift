import Metal
import simd

// Swift side of the structs in Waterfall.msl. WaterfallRendererTests checks that the two layouts match.

struct WaterfallUniforms {
    var headRow: Float
    var historyRows: Float
    var visibleRows: Float
    var nowX: Float
    var bandLow: Float
    var bandHigh: Float
    var midiLow: Float
    var midiHigh: Float
    var maxAge: Float
    var viewHeight: Float
}

struct OverlayInstance {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    var cornerRadius: Float
    var softness: Float
}

struct TrailVertex {
    var position: SIMD2<Float>
    var side: Float
    var pad: Float
    var color: SIMD4<Float>
}

/// Compiles the shaders from source when the app first needs them.
///
/// Compiling at build time would need the Metal toolchain, which Xcode 26 and later install as an
/// optional component that a clean build machine may not have. The run-time compiler is always part
/// of the OS. That trades a one-time setup cost, `rendererSetupMs` in `results/simulator_timing.json`,
/// for a project that builds anywhere. The price is that a shader error shows up in the renderer
/// tests and not in the build log.
enum ShaderLibrary {
    private static var cached: (device: MTLDevice, library: MTLLibrary)?

    static func shared(for device: MTLDevice) throws -> MTLLibrary {
        if let cached, cached.device === device { return cached.library }
        guard let url = Bundle(for: WaterfallRenderer.self).url(forResource: "Waterfall", withExtension: "msl") else {
            throw RendererError.missingResource("Waterfall.msl")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        cached = (device, library)
        return library
    }

    static func pipelineDescriptor(
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return descriptor
    }
}
