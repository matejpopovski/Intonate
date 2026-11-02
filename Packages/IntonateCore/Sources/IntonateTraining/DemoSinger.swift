import Foundation
import IntonateDSP
import IntonateSynth

/// How the scripted singer behaves. Each field is a habit a real voice has and a perfect oscillator
/// does not, so that the demo exercises the same scoring paths a person would.
public struct SingerProfile: Sendable, Equatable {
    /// Standard deviation of the per-note pitch centre.
    public var intonationSpreadCents: Double
    /// Mean flatness, added to every note.
    public var biasCents: Double
    /// How far under the note the attack starts.
    public var scoopCents: Double
    public var scoopSeconds: Double
    public var vibratoDepthCents: Double
    public var vibratoRate: Double
    /// Seconds into a note before vibrato starts.
    public var vibratoDelay: Double
    /// Seconds of late entrance on each note.
    public var entranceDelay: Double
    public var levelDB: Double
    /// Breath and room noise, relative to the voice.
    public var noiseSNR: Double
    public var timbre: Timbre
    public var seed: UInt64

    public init(
        intonationSpreadCents: Double,
        biasCents: Double,
        scoopCents: Double,
        scoopSeconds: Double,
        vibratoDepthCents: Double,
        vibratoRate: Double,
        vibratoDelay: Double,
        entranceDelay: Double,
        levelDB: Double,
        noiseSNR: Double,
        timbre: Timbre,
        seed: UInt64
    ) {
        self.intonationSpreadCents = intonationSpreadCents
        self.biasCents = biasCents
        self.scoopCents = scoopCents
        self.scoopSeconds = scoopSeconds
        self.vibratoDepthCents = vibratoDepthCents
        self.vibratoRate = vibratoRate
        self.vibratoDelay = vibratoDelay
        self.entranceDelay = entranceDelay
        self.levelDB = levelDB
        self.noiseSNR = noiseSNR
        self.timbre = timbre
        self.seed = seed
    }

    /// A capable amateur: slightly flat, audible vibrato, some wobble between notes.
    public static let demo = SingerProfile(
        intonationSpreadCents: 11,
        biasCents: -5,
        scoopCents: 80,
        scoopSeconds: 0.07,
        vibratoDepthCents: 18,
        vibratoRate: 5.6,
        vibratoDelay: 0.35,
        entranceDelay: 0.02,
        levelDB: -20,
        noiseSNR: 32,
        timbre: .vowelAh,
        seed: 2_026
    )

    /// No errors at all, used to show that the scoring top end is reachable.
    public static let exact = SingerProfile(
        intonationSpreadCents: 0,
        biasCents: 0,
        scoopCents: 0,
        scoopSeconds: 0.05,
        vibratoDepthCents: 0,
        vibratoRate: 5.6,
        vibratoDelay: 0,
        entranceDelay: 0,
        levelDB: -20,
        noiseSNR: 60,
        timbre: .vowelAh,
        seed: 1
    )
}

/// A deterministic singer that performs a timeline as audio. Its samples enter the same input as the
/// microphone's, which is the point of the demo: only the source of the audio is synthetic. All
/// choices derive from the seed, so a given exercise is sung identically on every run.
public struct DemoSinger {
    /// The intended performance as a function of time, immutable once built so that the render
    /// closures can read it while the voice state mutates.
    public struct Score: Sendable {
        public let timeline: ExerciseTimeline
        public let profile: SingerProfile
        private let noteCentres: [Double]

        init(timeline: ExerciseTimeline, profile: SingerProfile, mistakes: [Int: Double]) {
            self.timeline = timeline
            self.profile = profile
            var rng = SplitMix64(seed: profile.seed &+ 2)
            noteCentres = timeline.notes.map { note in
                let wobble = max(-2.5, min(2.5, rng.gaussian())) * profile.intonationSpreadCents
                return profile.biasCents + wobble + (mistakes[note.index] ?? 0)
            }
        }

        /// The f0 this singer intends at `time`, or nil in a rest.
        public func frequency(at time: Double) -> Double? {
            guard let note = timeline.note(at: time) else { return nil }
            let intoNote = time - note.start - profile.entranceDelay
            guard intoNote >= 0, time < note.end - DemoSinger.breathGap else { return nil }
            let scoop = -profile.scoopCents * exp(-intoNote / profile.scoopSeconds)
            var vibrato = 0.0
            if intoNote > profile.vibratoDelay {
                let fadeIn = min(1, (intoNote - profile.vibratoDelay) / 0.25)
                vibrato = fadeIn * profile.vibratoDepthCents * sin(2 * .pi * profile.vibratoRate * intoNote)
            }
            let target = timeline.frequency(of: note)
            return target * pow(2, (noteCentres[note.index] + scoop + vibrato) / 1200)
        }

        func envelope(at time: Double) -> Double {
            guard let note = timeline.note(at: time) else { return 0 }
            let intoNote = time - note.start - profile.entranceDelay
            let untilEnd = note.end - DemoSinger.breathGap - time
            guard intoNote >= 0, untilEnd > 0 else { return 0 }
            return min(1, intoNote / 0.025) * min(1, untilEnd / 0.02)
        }
    }

    /// Silence left at the end of each note, the length of a quick breath between notes.
    static let breathGap = 0.03

    public let score: Score
    public let sampleRate: Double

    private var voice: VoiceSynth
    private var noiseRng: SplitMix64
    private let noiseGain: Float

    /// `mistakes` bends particular notes by a number of cents, keyed by note index, for the scorer to catch.
    public init(
        timeline: ExerciseTimeline,
        profile: SingerProfile = .demo,
        sampleRate: Double,
        mistakes: [Int: Double] = [:]
    ) {
        score = Score(timeline: timeline, profile: profile, mistakes: mistakes)
        self.sampleRate = sampleRate
        voice = VoiceSynth(sampleRate: sampleRate, timbre: profile.timbre, seed: profile.seed)
        noiseRng = SplitMix64(seed: profile.seed &+ 1)
        noiseGain = Float(pow(10, (profile.levelDB - profile.noiseSNR) / 20))
    }

    /// Writes the next `count` samples. Past the end of the timeline this is the noise floor alone.
    public mutating func render(into output: UnsafeMutablePointer<Float>, count: Int) {
        let script = score
        let level = pow(10, script.profile.levelDB / 20)
        voice.render(
            into: output,
            count: count,
            frequency: { script.frequency(at: $0) ?? 440 },
            amplitude: { script.envelope(at: $0) * level }
        )
        for index in 0..<count {
            output[index] += Float(noiseRng.gaussian()) * noiseGain
        }
    }
}
