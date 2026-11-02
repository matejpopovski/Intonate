import Foundation
import IntonateDSP
import IntonateSynth
import IntonateTraining
import QuartzCore

/// A scripted singer in place of the microphone. It touches no audio hardware and no permissions,
/// so it works in the Simulator, in CI and on a device with the microphone denied. Everything after
/// the ring is the real pipeline; only the origin of the samples is synthetic.
final class DemoInput: AudioInput, @unchecked Sendable {
    let sampleRate: Double

    private let timeline: ExerciseTimeline
    private let profile: SingerProfile
    private let leadIn: Double
    private let loops: Bool
    private let queue = DispatchQueue(label: "intonate.demo-input", qos: .userInteractive)

    private var timer: DispatchSourceTimer?
    private var singer: DemoSinger
    private var noiseRng: SplitMix64
    private let noiseGain: Float
    private var started: CFTimeInterval = 0
    private var produced: Int64 = 0
    private var singerStart: Int64
    private var take: UInt64 = 0

    init(
        timeline: ExerciseTimeline,
        leadIn: Double,
        sampleRate: Double,
        profile: SingerProfile = .demo,
        loops: Bool = false
    ) {
        self.timeline = timeline
        self.profile = profile
        self.leadIn = leadIn
        self.sampleRate = sampleRate
        self.loops = loops
        singer = DemoSinger(timeline: timeline, profile: profile, sampleRate: sampleRate)
        noiseRng = SplitMix64(seed: profile.seed &+ 99)
        noiseGain = Float(pow(10, (profile.levelDB - profile.noiseSNR) / 20))
        singerStart = Int64(leadIn * sampleRate)
    }

    func start(writingTo ring: SampleRing) throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        started = CACurrentMediaTime()
        timer.setEventHandler { [weak self] in
            self?.produce(into: ring)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func produce(into ring: SampleRing) {
        let elapsed = CACurrentMediaTime() - started
        var due = Int(elapsed * sampleRate) - Int(produced)
        var block = [Float](repeating: 0, count: 1_024)
        while due > 0 {
            let count = min(due, block.count)
            render(into: &block, count: count)
            ring.write(block, count: count)
            ring.stampWrite(hostTime: mach_continuous_time())
            produced += Int64(count)
            due -= count
        }
    }

    private func render(into block: UnsafeMutablePointer<Float>, count: Int) {
        if produced < singerStart {
            for index in 0..<count {
                block[index] = Float(noiseRng.gaussian()) * noiseGain
            }
            return
        }
        if loops, Double(produced - singerStart) / sampleRate > timeline.duration + 0.5 {
            take += 1
            var variation = profile
            variation.seed = profile.seed &+ take
            singer = DemoSinger(timeline: timeline, profile: variation, sampleRate: sampleRate)
            singerStart = produced
        }
        singer.render(into: block, count: count)
    }
}
