import AVFoundation
import IntonateDSP
import IntonateSynth
import IntonateTraining
import XCTest

@testable import Intonate

final class AudioInputTests: XCTestCase {
    /// Calls the capture path the way the audio thread does, with an AudioBufferList.
    private func deliver(_ samples: [Float], channels: UInt32, frames: Int, to ring: SampleRing) {
        var copy = samples
        copy.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels,
                    mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress
                )
            )
            MicrophoneInput.deliver(&list, frames: frames, to: ring)
        }
    }

    func testMonoBuffersReachTheRingUnchanged() {
        let ring = SampleRing(minimumCapacity: 16)
        deliver([0.1, 0.2, 0.3, 0.4], channels: 1, frames: 4, to: ring)
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(ring.read(into: &output, count: 4), 4)
        XCTAssertEqual(output, [0.1, 0.2, 0.3, 0.4])
    }

    func testInterleavedBuffersKeepTheFirstChannelOnly() {
        let ring = SampleRing(minimumCapacity: 16)
        deliver([0.1, 9, 0.2, 9, 0.3, 9], channels: 2, frames: 3, to: ring)
        var output = [Float](repeating: 0, count: 3)
        XCTAssertEqual(ring.read(into: &output, count: 3), 3)
        XCTAssertEqual(output, [0.1, 0.2, 0.3])
    }

    func testDemoInputProducesAudioPacedByTheClock() throws {
        let exercise = try XCTUnwrap(Exercise.programme.first)
        let timeline = ExerciseTimeline(exercise: exercise, tonicMidi: 52)
        let input = DemoInput(timeline: timeline, leadIn: 0, sampleRate: 44_100)
        let ring = SampleRing(minimumCapacity: 1 << 18)
        try input.start(writingTo: ring)
        addTeardownBlock { input.stop() }

        let enough = expectation(description: "samples arrive")
        DispatchQueue.global().async {
            while ring.availableToRead < 22_050 { usleep(2_000) }
            enough.fulfill()
        }
        wait(for: [enough], timeout: 60)
        XCTAssertEqual(ring.droppedSamples, 0)
    }

    /// AVAudioEngine's offline mode needs no audio hardware, so the source-node wiring of the
    /// reference tone can run for real here: engine, mixer and render callback included.
    func testReferenceToneThroughAVAudioEngineHasThePitchRequested() throws {
        let rate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let tone = ToneGenerator(sampleRate: rate)
        tone.setFrequency(233.08)
        let source = AVAudioSourceNode(format: format) { _, _, frames, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let channel = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                tone.render(into: channel, count: Int(frames))
            }
            return noErr
        }

        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }

        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        var rendered: [Float] = []
        while rendered.count < 8_192 {
            let status = try engine.renderOffline(1_024, to: buffer)
            XCTAssertEqual(status, .success)
            rendered += UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength))
        }

        let detector = YINDetector()
        let tail = Array(rendered.suffix(detector.configuration.requiredSamples))
        let estimate = try XCTUnwrap(tail.withUnsafeBufferPointer { detector.estimate($0) })
        XCTAssertEqual(cents(estimate.frequency, relativeTo: 233.08), 0, accuracy: 1)
    }
}
