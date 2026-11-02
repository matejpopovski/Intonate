import IntonateDSP
import IntonateTraining
import Metal
import QuartzCore
import simd

enum RendererError: Error {
    case missingResource(String)
}

/// What a frame should show, apart from the audio itself.
struct WaterfallScene {
    var geometry: WaterfallGeometry
    var timeline: ExerciseTimeline?
    /// Stream time at which the timeline starts.
    var leadIn: Double
}

/// Draws the spectrogram, the upcoming notes and the pitch trail.
///
/// History lives in one ring texture. Each new analysis column overwrites the oldest row and the
/// fragment shader offsets its lookup by a head position, so scrolling costs a uniform and not a
/// re-upload: a frame moves about 1.4 rows of 384 bytes however long the history is. The texture is
/// private and filled by blits from a shared buffer, a path that works in the Simulator as well as
/// on a device, where shared-storage textures do not behave the same.
final class WaterfallRenderer {
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let historyRows = 1_024
    private static let maxRowsPerFrame = 64
    private static let maxTrailPoints = 1_200
    private static let maxOverlays = 256
    private static let inFlight = 3

    let device: MTLDevice
    let queue: MTLCommandQueue

    private let feed: WaterfallFeed
    private let bandCount: Int
    private let waterfallPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let trailPipeline: MTLRenderPipelineState
    private let ringSampler: MTLSamplerState
    private let history: MTLTexture

    private let uploads: [MTLBuffer]
    private let overlays: [MTLBuffer]
    private let trails: [MTLBuffer]
    private let inFlightSlots = DispatchSemaphore(value: WaterfallRenderer.inFlight)
    private var slot = 0

    private var columnStaging: [Float]
    private var rowsWritten = 0
    private var needsClear = true

    private struct TrailPoint {
        var time: Double
        var midi: Double
        var error: Double?
    }

    private var trail: [TrailPoint] = []
    private var displayTime = 0.0
    private var lastFrameTime: CFTimeInterval?

    /// How long the oldest pitch frame in the latest draw waited for that draw, in milliseconds.
    private(set) var frameWaitMilliseconds: Double?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, feed: WaterfallFeed) throws {
        self.device = device
        self.feed = feed
        bandCount = feed.bandCount
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.missingResource("command queue")
        }
        self.queue = queue
        let library = try ShaderLibrary.shared(for: device)

        func pipeline(vertex: String, fragment: String, additive: Bool) throws -> MTLRenderPipelineState {
            let descriptor = ShaderLibrary.pipelineDescriptor(
                library: library,
                vertex: vertex,
                fragment: fragment,
                pixelFormat: pixelFormat
            )
            if additive {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        waterfallPipeline = try pipeline(vertex: "waterfall_vertex", fragment: "waterfall_fragment", additive: false)
        overlayPipeline = try pipeline(vertex: "overlay_vertex", fragment: "overlay_fragment", additive: true)
        trailPipeline = try pipeline(vertex: "trail_vertex", fragment: "trail_fragment", additive: true)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RendererError.missingResource("sampler")
        }
        ringSampler = sampler

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: bandCount,
            height: Self.historyRows,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        textureDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw RendererError.missingResource("history texture")
        }
        history = texture

        func buffers(length: Int) throws -> [MTLBuffer] {
            try (0..<Self.inFlight).map { _ in
                guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                    throw RendererError.missingResource("buffer of \(length) bytes")
                }
                return buffer
            }
        }
        uploads = try buffers(length: bandCount * Self.maxRowsPerFrame)
        overlays = try buffers(length: MemoryLayout<OverlayInstance>.stride * Self.maxOverlays)
        trails = try buffers(length: MemoryLayout<TrailVertex>.stride * Self.maxTrailPoints * 6)
        columnStaging = [Float](repeating: 0, count: bandCount * Self.maxRowsPerFrame)
    }

    /// Encodes one frame into `pass`. `completion` runs with the GPU time once the frame is done.
    func draw(
        into commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        size: CGSize,
        scene: WaterfallScene,
        frameTime: CFTimeInterval
    ) {
        inFlightSlots.wait()
        commandBuffer.addCompletedHandler { [inFlightSlots] _ in inFlightSlots.signal() }
        slot = (slot + 1) % Self.inFlight

        uploadColumns(commandBuffer)
        let (frames, streamTime, oldestPublish) = feed.collect()
        frameWaitMilliseconds = oldestPublish.map { (CACurrentMediaTime() - $0) * 1_000 }
        ingest(frames: frames, scene: scene)
        let now = advanceDisplayTime(streamTime: streamTime, frameTime: frameTime)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encodeWaterfall(encoder, size: size, scene: scene, now: now)
        var viewSize = SIMD2<Float>(Float(size.width), Float(size.height))
        encodeOverlays(encoder, viewSize: &viewSize, scene: scene, now: now)
        encodeTrail(encoder, viewSize: &viewSize, scene: scene, now: now)
        encoder.endEncoding()
    }

    // MARK: - Columns

    private func uploadColumns(_ commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        defer { blit.endEncoding() }

        if needsClear {
            clearHistory(blit)
            needsClear = false
        }

        defer { rowsWritten += feed.takeDroppedColumns() }

        var pending = feed.columns.availableToRead / bandCount
        // After a stall, the renderer skips ahead rather than trying to replay old columns.
        while pending > Self.maxRowsPerFrame {
            let skipped = min(pending - Self.maxRowsPerFrame, Self.maxRowsPerFrame)
            columnStaging.withUnsafeMutableBufferPointer { staging in
                _ = feed.columns.read(into: staging.baseAddress!, count: skipped * bandCount)
            }
            rowsWritten += skipped
            pending -= skipped
        }
        guard pending > 0 else { return }

        let upload = uploads[slot]
        let bytes = upload.contents().assumingMemoryBound(to: UInt8.self)
        let values = pending * bandCount
        columnStaging.withUnsafeMutableBufferPointer { staging in
            _ = feed.columns.read(into: staging.baseAddress!, count: values)
            for index in 0..<values {
                bytes[index] = UInt8(max(0, min(255, staging[index] * 255)))
            }
        }

        var uploaded = 0
        while uploaded < pending {
            let row = (rowsWritten + uploaded) % Self.historyRows
            let run = min(pending - uploaded, Self.historyRows - row)
            blit.copy(
                from: upload,
                sourceOffset: uploaded * bandCount,
                sourceBytesPerRow: bandCount,
                sourceBytesPerImage: bandCount * run,
                sourceSize: MTLSize(width: bandCount, height: run, depth: 1),
                to: history,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: row, z: 0)
            )
            uploaded += run
        }
        rowsWritten += pending
    }

    private func clearHistory(_ blit: MTLBlitCommandEncoder) {
        let length = bandCount * Self.historyRows
        guard let zeroes = device.makeBuffer(length: length, options: .storageModeShared) else { return }
        blit.copy(
            from: zeroes,
            sourceOffset: 0,
            sourceBytesPerRow: bandCount,
            sourceBytesPerImage: length,
            sourceSize: MTLSize(width: bandCount, height: Self.historyRows, depth: 1),
            to: history,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
    }

    private func ingest(frames: [PitchFrame], scene: WaterfallScene) {
        for frame in frames {
            guard let frequency = frame.frequency else {
                trail.append(TrailPoint(time: frame.time, midi: .nan, error: nil))
                continue
            }
            let midi = Tuning.standard.midi(frequency: frequency)
            var error: Double?
            if let timeline = scene.timeline, let note = timeline.note(at: frame.time - scene.leadIn) {
                error = midi - Double(note.midi)
            }
            trail.append(TrailPoint(time: frame.time, midi: midi, error: error))
        }
        if trail.count > Self.maxTrailPoints {
            trail.removeFirst(trail.count - Self.maxTrailPoints)
        }
    }

    /// The analysis arrives in bursts, every few milliseconds, but the picture has to move evenly. So
    /// the displayed time runs on the display clock and is steered gently towards the stream.
    private func advanceDisplayTime(streamTime: Double, frameTime: CFTimeInterval) -> Double {
        let target = streamTime - 0.06
        defer { lastFrameTime = frameTime }
        guard let last = lastFrameTime, displayTime > 0 else {
            displayTime = max(target, 0.001)
            return displayTime
        }
        displayTime += frameTime - last
        let drift = target - displayTime
        displayTime = abs(drift) > 0.25 ? target : displayTime + drift * 0.08
        return displayTime
    }

    // MARK: - Encoding

    private func encodeWaterfall(
        _ encoder: MTLRenderCommandEncoder,
        size: CGSize,
        scene: WaterfallScene,
        now: Double
    ) {
        let geometry = scene.geometry
        let map = feed.bandMap
        let tuning = Tuning.standard
        let span = Float(max(map.bandCount - 1, 1))
        // Half a texel inset: u = 0 and u = 1 are band edges, not band centres.
        func u(_ midi: Double) -> Float {
            let band = map.bandPosition(frequency: tuning.frequency(midi: midi))
            return (Float(band) + 0.5) / (span + 1)
        }
        let headRow = (now - feed.firstColumnTime) / feed.columnSeconds
        var uniforms = WaterfallUniforms(
            headRow: Float(headRow.truncatingRemainder(dividingBy: Double(Self.historyRows) * 16)),
            historyRows: Float(Self.historyRows),
            visibleRows: Float(geometry.pastSeconds / feed.columnSeconds),
            nowX: Float(geometry.nowX),
            bandLow: u(geometry.lowMidi),
            bandHigh: u(geometry.highMidi),
            midiLow: Float(geometry.lowMidi),
            midiHigh: Float(geometry.highMidi),
            maxAge: Float(min(headRow, Double(Self.historyRows - 2))),
            viewHeight: Float(size.height)
        )
        encoder.setRenderPipelineState(waterfallPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaterfallUniforms>.stride, index: 0)
        encoder.setFragmentTexture(history, index: 0)
        encoder.setFragmentSamplerState(ringSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func encodeOverlays(
        _ encoder: MTLRenderCommandEncoder,
        viewSize: inout SIMD2<Float>,
        scene: WaterfallScene,
        now: Double
    ) {
        let width = Double(viewSize.x)
        let height = Double(viewSize.y)
        let geometry = scene.geometry
        let buffer = overlays[slot]
        let instances = buffer.contents().assumingMemoryBound(to: OverlayInstance.self)
        var count = 0

        func append(_ rect: SIMD4<Float>, color: SIMD4<Float>, radius: Float, softness: Float) {
            guard count < Self.maxOverlays else { return }
            instances[count] = OverlayInstance(rect: rect, color: color, cornerRadius: radius, softness: softness)
            count += 1
        }

        if let timeline = scene.timeline {
            let barHeight = height / (geometry.highMidi - geometry.lowMidi) * 0.82
            for note in timeline.notes {
                let start = geometry.x(time: note.start + scene.leadIn, now: now)
                let end = geometry.x(time: note.end + scene.leadIn, now: now)
                guard end > -0.02, start < 1.02 else { continue }
                let centre = (1 - geometry.y(midi: Double(note.midi))) * height
                let rect = SIMD4<Float>(
                    Float(start * width + 1.5),
                    Float(centre - barHeight / 2),
                    Float(end * width - 1.5),
                    Float(centre + barHeight / 2)
                )
                let isCurrent = start <= geometry.nowX && end >= geometry.nowX
                let color: SIMD4<Float> =
                    isCurrent
                    ? SIMD4(0.40, 0.31, 0.15, 0.40)
                    : SIMD4(0.17, 0.135, 0.09, 0.22)
                append(rect, color: color, radius: Float(barHeight / 2), softness: isCurrent ? 16 : 5)
            }
        }

        let lineX = Float(geometry.nowX * width)
        append(
            SIMD4(lineX - 0.75, 0, lineX + 0.75, Float(height)),
            color: SIMD4(0.92, 0.80, 0.56, 0.9),
            radius: 0,
            softness: 18
        )

        encoder.setRenderPipelineState(overlayPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    private func encodeTrail(
        _ encoder: MTLRenderCommandEncoder,
        viewSize: inout SIMD2<Float>,
        scene: WaterfallScene,
        now: Double
    ) {
        let width = Double(viewSize.x)
        let height = Double(viewSize.y)
        let geometry = scene.geometry
        let buffer = trails[slot]
        let vertices = buffer.contents().assumingMemoryBound(to: TrailVertex.self)
        var count = 0
        let halfWidth: Float = 11

        func point(_ sample: TrailPoint) -> SIMD2<Float> {
            SIMD2(
                Float(geometry.x(time: sample.time, now: now) * width),
                Float((1 - geometry.y(midi: sample.midi)) * height)
            )
        }

        for (first, second) in zip(trail, trail.dropFirst()) {
            guard !first.midi.isNaN, !second.midi.isNaN, second.time - first.time < 0.05 else { continue }
            let a = point(first)
            let b = point(second)
            guard b.x >= 0, a.x <= Float(geometry.nowX * width) + 1 else { continue }
            let direction = simd_normalize(b - a + SIMD2(1e-4, 0))
            let normal = SIMD2(-direction.y, direction.x) * halfWidth
            let color = Self.trailColor(error: second.error)
            let quad: [(SIMD2<Float>, Float)] = [
                (a - normal, -1), (a + normal, 1), (b - normal, -1),
                (b - normal, -1), (a + normal, 1), (b + normal, 1),
            ]
            for (position, side) in quad {
                vertices[count] = TrailVertex(position: position, side: side, pad: 0, color: color)
                count += 1
            }
        }

        guard count > 0 else { return }
        encoder.setRenderPipelineState(trailPipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
    }

    /// Warm white while in tune, cooling to blue as the note drifts. Free singing has no target.
    static func trailColor(error: Double?) -> SIMD4<Float> {
        guard let error else { return SIMD4(0.95, 0.90, 0.80, 0.9) }
        let inTune = SIMD3<Float>(1.0, 0.93, 0.70)
        let off = SIMD3<Float>(0.35, 0.65, 1.0)
        let drift = Float(min(1, max(0, (abs(error) - 0.15) / 0.35)))
        let rgb = inTune + (off - inTune) * drift
        return SIMD4(rgb.x, rgb.y, rgb.z, 1) * 0.92
    }
}
