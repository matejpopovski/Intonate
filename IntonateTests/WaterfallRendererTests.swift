import IntonateDSP
import IntonateSynth
import IntonateTraining
import Metal
import XCTest

@testable import Intonate

/// Draws real frames offscreen and reads the pixels back. Needs a working GPU, so CI, which runs on
/// virtual machines, skips this class; `scripts/test-ios.sh` runs it locally.
final class WaterfallRendererTests: XCTestCase {
    private let size = CGSize(width: 390, height: 300)
    private let format = WaterfallRenderer.pixelFormat
    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "this environment has no Metal device")
    }

    private struct Picture {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        /// Brightness of one pixel, 0...1, with y measured from the top.
        func luma(x: Int, y: Int) -> Double {
            let index = (y * width + x) * 4
            return (0.11 * Double(bytes[index]) + 0.59 * Double(bytes[index + 1]) + 0.30 * Double(bytes[index + 2]))
                / 255
        }

        func averageLuma(xRange: Range<Int>, y: Int) -> Double {
            xRange.reduce(0) { $0 + luma(x: $1, y: y) } / Double(xRange.count)
        }

        var brightestRow: (row: Int, value: Double) {
            brightestRow(xRange: 8..<Int(Double(width) * 0.68))
        }

        func brightestRow(xRange: Range<Int>) -> (row: Int, value: Double) {
            var best = (row: 0, value: -1.0)
            for row in 0..<height {
                let value = averageLuma(xRange: xRange, y: row)
                if value > best.value { best = (row, value) }
            }
            return best
        }
    }

    private func draw(_ renderer: WaterfallRenderer, scene: WaterfallScene, frameTime: CFTimeInterval) throws -> Picture
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        let commandBuffer = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        renderer.draw(into: commandBuffer, pass: pass, size: size, scene: scene, frameTime: frameTime)

        let length = Int(size.width) * Int(size.height) * 4
        let readback = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: Int(size.width), height: Int(size.height), depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: Int(size.width) * 4,
            destinationBytesPerImage: length
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        let bytes = UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: UInt8.self), count: length)
        return Picture(width: Int(size.width), height: Int(size.height), bytes: Array(bytes))
    }

    /// Pushes `seconds` of a steady tone through the real pipeline into `feed`. Pitch frames are left
    /// out, or the bright trail would be what these tests measure instead of the spectrogram.
    private func feedTone(
        _ frequency: Double,
        seconds: Double,
        pipeline: AnalysisPipeline,
        feed: WaterfallFeed,
        renderer: WaterfallRenderer,
        scene: WaterfallScene,
        clock: inout Double
    ) throws {
        let rate = pipeline.configuration.sampleRate
        let signal = VoiceSynth.clip(contour: .constant(frequency), duration: seconds, sampleRate: rate, timbre: .sine)
        // Short chunks with a draw after each, so that the column ring never fills up.
        let chunk = 256
        var offset = 0
        try signal.withUnsafeBufferPointer { buffer in
            while offset < buffer.count {
                let count = min(chunk, buffer.count - offset)
                pipeline.process(
                    UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                    onPitch: { _ in },
                    onColumn: { feed.publish(column: $0) }
                )
                offset += count
                feed.publish(streamTime: Double(pipeline.sampleCount) / rate)
                clock += Double(count) / rate
                _ = try draw(renderer, scene: scene, frameTime: clock)
            }
        }
    }

    private func makeScene() -> WaterfallScene {
        WaterfallScene(geometry: WaterfallGeometry(lowMidi: 57, highMidi: 81), timeline: nil, leadIn: 0)
    }

    func testToneLightsTheRowOfItsPitch() throws {
        let configuration = AnalysisConfiguration()
        let pipeline = AnalysisPipeline(configuration: configuration)
        let feed = WaterfallFeed(configuration: configuration)
        let renderer = try WaterfallRenderer(device: device, pixelFormat: format, feed: feed)
        let scene = makeScene()
        var clock = 1.0

        try feedTone(440, seconds: 2, pipeline: pipeline, feed: feed, renderer: renderer, scene: scene, clock: &clock)
        let picture = try draw(renderer, scene: scene, frameTime: clock)

        // MIDI 69 sits halfway up a 57...81 window.
        let bright = picture.brightestRow
        XCTAssertGreaterThan(bright.value, 0.25)
        XCTAssertEqual(Double(bright.row), Double(picture.height) / 2, accuracy: 14)
        let away = picture.averageLuma(xRange: 8..<260, y: picture.height / 8)
        XCTAssertLessThan(away, bright.value / 3)
    }

    func testNewPitchEntersAtTheNowLineAndOldPitchMovesLeft() throws {
        let configuration = AnalysisConfiguration()
        let pipeline = AnalysisPipeline(configuration: configuration)
        let feed = WaterfallFeed(configuration: configuration)
        let renderer = try WaterfallRenderer(device: device, pixelFormat: format, feed: feed)
        let scene = makeScene()
        var clock = 1.0

        try feedTone(440, seconds: 1.5, pipeline: pipeline, feed: feed, renderer: renderer, scene: scene, clock: &clock)
        try feedTone(
            659.26,
            seconds: 1,
            pipeline: pipeline,
            feed: feed,
            renderer: renderer,
            scene: scene,
            clock: &clock
        )
        let picture = try draw(renderer, scene: scene, frameTime: clock)

        let lowRow = picture.height / 2
        let highRow = picture.height / 2 - Int(7.0 / 24 * Double(picture.height))
        let nowX = Int(Double(picture.width) * scene.geometry.nowX)
        let recent = (nowX - 50)..<(nowX - 10)
        let earlier = (nowX - 160)..<(nowX - 110)
        XCTAssertGreaterThan(
            (picture.averageLuma(xRange: recent, y: highRow) + picture.averageLuma(xRange: recent, y: highRow + 3)) / 2,
            picture.averageLuma(xRange: recent, y: lowRow)
        )
        XCTAssertGreaterThan(
            picture.averageLuma(xRange: earlier, y: lowRow),
            picture.averageLuma(xRange: earlier, y: highRow)
        )
    }

    /// Runs past the end of the ring texture, where a row-offset error would show as a seam.
    func testSpectrogramSurvivesWrappingTheRingTexture() throws {
        let configuration = AnalysisConfiguration()
        let pipeline = AnalysisPipeline(configuration: configuration)
        let feed = WaterfallFeed(configuration: configuration)
        let renderer = try WaterfallRenderer(device: device, pixelFormat: format, feed: feed)
        let scene = makeScene()
        var clock = 1.0

        let seconds = Double(WaterfallRenderer.historyRows) * configuration.columnSecondsForTesting + 1.5
        try feedTone(
            440,
            seconds: seconds,
            pipeline: pipeline,
            feed: feed,
            renderer: renderer,
            scene: scene,
            clock: &clock
        )
        let picture = try draw(renderer, scene: scene, frameTime: clock)

        let row = picture.height / 2
        let nowX = Int(Double(picture.width) * scene.geometry.nowX)
        var dimmest = 1.0
        for x in stride(from: 12, to: nowX - 8, by: 10) {
            let centre = (row - 4...row + 4).map { picture.luma(x: x, y: $0) }.max() ?? 0
            dimmest = min(dimmest, centre)
        }
        XCTAssertGreaterThan(dimmest, 0.05, "the tone must be unbroken across the wrap")
    }

    /// A long main-thread stall overflows the column ring. Losing columns is fine; losing the
    /// alignment of the ones that follow would shift every later column along the frequency axis.
    func testColumnsStayAlignedAfterARenderStall() throws {
        let configuration = AnalysisConfiguration()
        let pipeline = AnalysisPipeline(configuration: configuration)
        let feed = WaterfallFeed(configuration: configuration)
        let renderer = try WaterfallRenderer(device: device, pixelFormat: format, feed: feed)
        let scene = makeScene()

        let rate = configuration.sampleRate
        let stalled = VoiceSynth.clip(contour: .constant(440), duration: 3, sampleRate: rate, timbre: .sine)
        stalled.withUnsafeBufferPointer { buffer in
            pipeline.process(
                buffer,
                onPitch: { _ in },
                onColumn: { feed.publish(column: $0) }
            )
        }
        feed.publish(streamTime: Double(pipeline.sampleCount) / rate)

        var clock = 1.0
        try feedTone(440, seconds: 2, pipeline: pipeline, feed: feed, renderer: renderer, scene: scene, clock: &clock)
        let picture = try draw(renderer, scene: scene, frameTime: clock)

        // Only the audio after the stall counts: the older part of the picture was never at risk.
        let nowX = Int(Double(picture.width) * scene.geometry.nowX)
        let recent = picture.brightestRow(xRange: (nowX - 60)..<(nowX - 10))
        XCTAssertEqual(Double(recent.row), Double(picture.height) / 2, accuracy: 14)
        XCTAssertGreaterThan(recent.value, 0.25)
    }

    func testTargetBarAndTrailDraw() throws {
        let exercise = Exercise(
            id: "t",
            numeral: "T",
            title: "T",
            summary: "",
            tempo: 60,
            steps: [Exercise.Step(0, beats: 10)]
        )
        let timeline = ExerciseTimeline(exercise: exercise, tonicMidi: 69)
        let configuration = AnalysisConfiguration()
        let feed = WaterfallFeed(configuration: configuration)
        let renderer = try WaterfallRenderer(device: device, pixelFormat: format, feed: feed)
        var scene = makeScene()
        scene.timeline = timeline

        feed.publish(streamTime: 2)
        _ = try draw(renderer, scene: scene, frameTime: 1)
        let picture = try draw(renderer, scene: scene, frameTime: 1 + 1.0 / 60)

        let nowX = Int(Double(picture.width) * scene.geometry.nowX)
        let onBar = picture.averageLuma(xRange: (nowX + 10)..<(nowX + 50), y: picture.height / 2)
        let offBar = picture.averageLuma(xRange: (nowX + 10)..<(nowX + 50), y: picture.height / 5)
        XCTAssertGreaterThan(onBar, offBar + 0.03)

        let frames = (0..<60).map { step -> PitchFrame in
            PitchFrame(
                time: 1.2 + Double(step) * 0.01,
                frequency: 440,
                rawFrequency: 440,
                aperiodicity: 0,
                levelDB: -20
            )
        }
        frames.forEach(feed.publish(frame:))
        let withTrail = try draw(renderer, scene: scene, frameTime: 1 + 2.0 / 60)
        let trailRow = withTrail.brightestRow(xRange: (nowX - 90)..<(nowX - 40))
        XCTAssertEqual(Double(trailRow.row), Double(withTrail.height) / 2, accuracy: 3)
        XCTAssertGreaterThan(trailRow.value, 0.3)
    }

    /// The shader source is compiled at run time, so nothing else ties these structs to the Swift ones.
    func testShaderStructsMatchSwiftLayouts() throws {
        let library = try ShaderLibrary.shared(for: device)
        func reflection(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineReflection {
            let descriptor = ShaderLibrary.pipelineDescriptor(
                library: library,
                vertex: vertex,
                fragment: fragment,
                pixelFormat: format
            )
            var reflection: MTLRenderPipelineReflection?
            _ = try device.makeRenderPipelineState(
                descriptor: descriptor,
                options: .bufferTypeInfo,
                reflection: &reflection
            )
            return try XCTUnwrap(reflection)
        }

        let waterfall = try reflection("waterfall_vertex", "waterfall_fragment")
        let uniforms = try XCTUnwrap(waterfall.fragmentBindings.first { $0.name == "uniforms" } as? MTLBufferBinding)
        XCTAssertEqual(uniforms.bufferDataSize, MemoryLayout<WaterfallUniforms>.stride)

        let overlay = try reflection("overlay_vertex", "overlay_fragment")
        let instances = try XCTUnwrap(overlay.vertexBindings.first { $0.name == "instances" } as? MTLBufferBinding)
        XCTAssertEqual(instances.bufferDataSize, MemoryLayout<OverlayInstance>.stride)
        let instanceFields = try XCTUnwrap(instances.bufferStructType)
        XCTAssertEqual(
            instanceFields.memberByName("softness")?.offset,
            MemoryLayout<OverlayInstance>.offset(of: \.softness)
        )

        let trail = try reflection("trail_vertex", "trail_fragment")
        let vertices = try XCTUnwrap(trail.vertexBindings.first { $0.name == "vertices" } as? MTLBufferBinding)
        XCTAssertEqual(vertices.bufferDataSize, MemoryLayout<TrailVertex>.stride)
        XCTAssertEqual(
            vertices.bufferStructType?.memberByName("color")?.offset,
            MemoryLayout<TrailVertex>.offset(of: \.color)
        )
    }
}

extension AnalysisConfiguration {
    fileprivate var columnSecondsForTesting: Double {
        Double(columnHop) / sampleRate
    }
}
