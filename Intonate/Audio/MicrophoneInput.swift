import AVFoundation
import IntonateDSP
import IntonateSynth

enum MicrophoneError: LocalizedError {
    case permissionDenied
    case noInput

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Intonate cannot hear you. Allow the microphone in Settings, or use the demo voice."
        case .noInput:
            return "No audio input is available on this device."
        }
    }
}

/// Live capture through AVAudioEngine.
///
/// It uses an `AVAudioSinkNode` and not `installTap`. A tap delivers large buffers on a secondary
/// thread, which adds tens of milliseconds a pitch display cannot afford; the sink runs on the audio
/// I/O thread at the hardware buffer size. The price is that its block must be real-time safe, so it
/// does nothing but copy into the ring.
final class MicrophoneInput: AudioInput, @unchecked Sendable {
    private(set) var sampleRate: Double

    private let engine = AVAudioEngine()
    private var sink: AVAudioSinkNode?
    private var toneNode: AVAudioSourceNode?
    private var tone: ToneGenerator?

    init() {
        sampleRate = AVAudioSession.sharedInstance().sampleRate
    }

    /// Asks for the session and reads the real rate, since the analysis has to be built for it.
    static func prepareSession() async throws -> Double {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw MicrophoneError.permissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        // .measurement turns off automatic gain and voice processing, which would otherwise bend
        // the spectrum and pump the noise floor that the voicing gate depends on.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        guard session.isInputAvailable else { throw MicrophoneError.noInput }
        return session.sampleRate
    }

    func start(writingTo ring: SampleRing) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw MicrophoneError.noInput }
        sampleRate = format.sampleRate

        let sink = AVAudioSinkNode { _, frames, audioBufferList in
            Self.deliver(audioBufferList, frames: Int(frames), to: ring)
            ring.stampWrite(hostTime: mach_continuous_time())
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        self.sink = sink

        let generator = ToneGenerator(sampleRate: format.sampleRate)
        let monoOutput = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)
        let toneNode = AVAudioSourceNode(format: monoOutput!) { _, _, frames, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let channel = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                generator.render(into: channel, count: Int(frames))
            }
            return noErr
        }
        engine.attach(toneNode)
        engine.connect(toneNode, to: engine.mainMixerNode, format: monoOutput)
        self.toneNode = toneNode
        tone = generator

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if let sink {
            engine.disconnectNodeInput(sink)
            engine.detach(sink)
        }
        if let toneNode {
            engine.detach(toneNode)
        }
        sink = nil
        toneNode = nil
        tone = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setReferenceTone(_ frequency: Double?) {
        tone?.setFrequency(frequency)
    }

    /// Copies the first channel of a callback's buffers into the ring. Inputs arrive as one
    /// non-interleaved buffer per channel on iOS, but a stride covers an interleaved route anyway.
    /// Static so that tests can call it with synthesized buffers, without a microphone.
    static func deliver(_ list: UnsafePointer<AudioBufferList>, frames: Int, to ring: SampleRing) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let stride = Int(first.mNumberChannels)
        if stride <= 1 {
            ring.write(samples, count: frames)
        } else {
            for frame in 0..<frames {
                var sample = samples[frame * stride]
                ring.write(&sample, count: 1)
            }
        }
    }
}
