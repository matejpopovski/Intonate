import Foundation
import IntonateDSP

public struct ScoringRules: Sendable, Equatable {
    /// Scoring starts this long after a note begins, since nobody lands a note on the beat and
    /// the attack is not what intonation training is about.
    public var attackGrace: Double
    /// Scoring stops this long before a note ends, so that moving early to the next note costs nothing.
    public var releaseGrace: Double
    /// Within this error a frame earns full marks. Sung vibrato and detector noise both live here.
    public var fullMarksCents: Double
    /// At this error a frame earns nothing. Half a semitone is by definition the wrong note.
    public var zeroMarksCents: Double
    /// The "in tune" line reported to the singer.
    public var inTuneCents: Double

    public init(
        attackGrace: Double = 0.15,
        releaseGrace: Double = 0.05,
        fullMarksCents: Double = 15,
        zeroMarksCents: Double = 50,
        inTuneCents: Double = 25
    ) {
        self.attackGrace = attackGrace
        self.releaseGrace = releaseGrace
        self.fullMarksCents = fullMarksCents
        self.zeroMarksCents = zeroMarksCents
        self.inTuneCents = inTuneCents
    }

    func marks(forError absoluteCents: Double) -> Double {
        if absoluteCents <= fullMarksCents { return 1 }
        if absoluteCents >= zeroMarksCents { return 0 }
        return (zeroMarksCents - absoluteCents) / (zeroMarksCents - fullMarksCents)
    }
}

public struct NoteResult: Hashable, Sendable {
    public let note: TimedNote
    /// Share of the scored window where a voiced pitch was heard.
    public let voicedFraction: Double
    /// Signed mean error in cents; negative is flat. Nil if the note was not sung at all.
    public let meanCents: Double?
    public let meanAbsoluteCents: Double?
    /// Standard deviation of the error, which is what a long-tone exercise cares about.
    public let spreadCents: Double?
    public let inTuneFraction: Double
    /// 0...100, with unvoiced frames counted as zero marks.
    public let score: Double
}

public struct PerformanceReport: Hashable, Sendable {
    public let notes: [NoteResult]
    /// Duration-weighted mean of the note scores.
    public let score: Double
    public let meanAbsoluteCents: Double?
    /// Mean signed error over sung frames, so a singer learns they run flat or sharp overall.
    public let tendencyCents: Double?
    public let inTuneFraction: Double
}

/// Compares a pitch stream with an exercise timeline. It sees only `PitchFrame`s, so the same scorer
/// runs behind the microphone, the demo voice and the tests.
public struct PerformanceScorer {
    public let timeline: ExerciseTimeline
    public let rules: ScoringRules

    private struct Accumulator {
        var frames = 0
        var voiced = 0
        var inTune = 0
        var marks = 0.0
        var sum = 0.0
        var sumAbsolute = 0.0
        var sumSquares = 0.0
    }

    private var accumulators: [Accumulator]

    public init(timeline: ExerciseTimeline, rules: ScoringRules = ScoringRules()) {
        self.timeline = timeline
        self.rules = rules
        accumulators = Array(repeating: Accumulator(), count: timeline.notes.count)
    }

    /// `time` is seconds since the first note. Frames outside any scored window are ignored.
    public mutating func add(_ frame: PitchFrame, at time: Double) {
        guard let note = timeline.note(at: time),
            time >= note.start + rules.attackGrace,
            time < note.end - rules.releaseGrace
        else { return }

        accumulators[note.index].frames += 1
        guard let frequency = frame.frequency else { return }

        let error = cents(frequency, relativeTo: timeline.frequency(of: note))
        let absolute = abs(error)
        accumulators[note.index].voiced += 1
        accumulators[note.index].marks += rules.marks(forError: absolute)
        accumulators[note.index].sum += error
        accumulators[note.index].sumAbsolute += absolute
        accumulators[note.index].sumSquares += error * error
        if absolute <= rules.inTuneCents {
            accumulators[note.index].inTune += 1
        }
    }

    public func report() -> PerformanceReport {
        let results = zip(timeline.notes, accumulators).map { note, tally -> NoteResult in
            let frames = Double(max(tally.frames, 1))
            let voiced = Double(tally.voiced)
            let mean = tally.voiced > 0 ? tally.sum / voiced : nil
            let spread = mean.map { sqrt(max(0, tally.sumSquares / voiced - $0 * $0)) }
            return NoteResult(
                note: note,
                voicedFraction: voiced / frames,
                meanCents: mean,
                meanAbsoluteCents: tally.voiced > 0 ? tally.sumAbsolute / voiced : nil,
                spreadCents: spread,
                inTuneFraction: Double(tally.inTune) / frames,
                score: 100 * tally.marks / frames
            )
        }

        let totalDuration = timeline.notes.reduce(0) { $0 + ($1.end - $1.start) }
        let weighted = results.reduce(0) { $0 + $1.score * ($1.note.end - $1.note.start) }
        let voicedFrames = accumulators.reduce(0) { $0 + $1.voiced }
        let scoredFrames = accumulators.reduce(0) { $0 + $1.frames }
        let inTuneFrames = accumulators.reduce(0) { $0 + $1.inTune }
        let sum = accumulators.reduce(0) { $0 + $1.sum }
        let sumAbsolute = accumulators.reduce(0) { $0 + $1.sumAbsolute }

        return PerformanceReport(
            notes: results,
            score: totalDuration > 0 ? weighted / totalDuration : 0,
            meanAbsoluteCents: voicedFrames > 0 ? sumAbsolute / Double(voicedFrames) : nil,
            tendencyCents: voicedFrames > 0 ? sum / Double(voicedFrames) : nil,
            inTuneFraction: scoredFrames > 0 ? Double(inTuneFrames) / Double(scoredFrames) : 0
        )
    }
}
