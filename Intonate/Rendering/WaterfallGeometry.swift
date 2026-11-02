import IntonateDSP
import IntonateTraining

/// Places time and pitch on the view. Pure arithmetic, so the mapping can be tested without a GPU.
struct WaterfallGeometry: Equatable {
    /// Horizontal position of the present moment, leaving room for upcoming notes on the right.
    var nowX: Double = 0.72
    /// Seconds of history between the left edge and the now line.
    var pastSeconds: Double = 4.5
    var lowMidi: Double
    var highMidi: Double

    /// Seconds of future visible to the right of the now line.
    var futureSeconds: Double {
        pastSeconds * (1 - nowX) / nowX
    }

    /// x in 0...1 for a stream time, given the time at the now line. May fall outside the view.
    func x(time: Double, now: Double) -> Double {
        nowX + (time - now) / pastSeconds * nowX
    }

    /// y in 0...1, bottom up, for a fractional MIDI note.
    func y(midi: Double) -> Double {
        (midi - lowMidi) / (highMidi - lowMidi)
    }

    /// A window around the notes of an exercise: wide enough to see a wrong note, tight enough that
    /// a quarter tone is visible. Free singing gets a span that covers most voices.
    static func range(for timeline: ExerciseTimeline?) -> (low: Double, high: Double) {
        guard let timeline, let lowest = timeline.notes.map(\.midi).min(),
            let highest = timeline.notes.map(\.midi).max()
        else { return (45, 81) }
        let padding = 5.0
        let span = Double(highest - lowest) + 2 * padding
        let minimumSpan = 18.0
        let extra = max(0, minimumSpan - span) / 2
        return (Double(lowest) - padding - extra, Double(highest) + padding + extra)
    }
}
