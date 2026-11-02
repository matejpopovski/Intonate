import Foundation
import IntonateDSP

/// One entry in the programme: a shape in semitones above a tonic, independent of any voice.
public struct Exercise: Identifiable, Hashable, Sendable {
    public struct Step: Hashable, Sendable {
        public let semitones: Int
        public let beats: Double

        public init(_ semitones: Int, beats: Double = 1) {
            self.semitones = semitones
            self.beats = beats
        }
    }

    public let id: String
    public let numeral: String
    public let title: String
    public let summary: String
    public let tempo: Double
    public let steps: [Step]

    public init(id: String, numeral: String, title: String, summary: String, tempo: Double, steps: [Step]) {
        self.id = id
        self.numeral = numeral
        self.title = title
        self.summary = summary
        self.tempo = tempo
        self.steps = steps
    }

    private static func melody(_ semitones: [Int], beats: Double = 1) -> [Step] {
        semitones.map { Step($0, beats: beats) }
    }

    public static let programme: [Exercise] = [
        Exercise(
            id: "long-tones",
            numeral: "I",
            title: "Long Tones",
            summary: "Hold each note steady. Scores stability more than agility.",
            tempo: 60,
            steps: melody([0, 4, 7, 4, 0], beats: 3)
        ),
        Exercise(
            id: "five-note-scale",
            numeral: "II",
            title: "Five-Note Scale",
            summary: "Up and down the first five degrees of the major scale.",
            tempo: 76,
            steps: melody([0, 2, 4, 5, 7, 5, 4, 2, 0], beats: 2)
        ),
        Exercise(
            id: "arpeggio",
            numeral: "III",
            title: "Major Arpeggio",
            summary: "Root, third, fifth, octave. Listen for sagging thirds.",
            tempo: 72,
            steps: melody([0, 4, 7, 12, 7, 4, 0], beats: 2)
        ),
        Exercise(
            id: "octave-leaps",
            numeral: "IV",
            title: "Octave Leaps",
            summary: "Land the top note cleanly instead of sliding up to it.",
            tempo: 66,
            steps: melody([0, 12, 0, 12, 0], beats: 2)
        ),
        Exercise(
            id: "chromatic-ladder",
            numeral: "V",
            title: "Chromatic Ladder",
            summary: "Semitone steps, where small intonation errors change the note.",
            tempo: 80,
            steps: melody([0, 1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1, 0], beats: 2)
        ),
    ]
}

/// Sets the tonic so that every exercise, which spans at most an octave, sits inside a comfortable range.
public enum VoiceRange: String, CaseIterable, Identifiable, Sendable {
    case bass, baritone, tenor, alto, mezzo, soprano

    public var id: String { rawValue }

    public var displayName: String { rawValue.capitalized }

    public var tonicMidi: Int {
        switch self {
        case .bass: return 43
        case .baritone: return 48
        case .tenor: return 52
        case .alto: return 55
        case .mezzo: return 57
        case .soprano: return 60
        }
    }
}

public struct TimedNote: Hashable, Sendable {
    public let index: Int
    public let midi: Int
    public let start: Double
    public let end: Double
}

/// An exercise laid out in seconds for one voice. Time zero is the first note, after any count-in.
public struct ExerciseTimeline: Hashable, Sendable {
    public let notes: [TimedNote]
    public let duration: Double
    public let tuning: Tuning

    public init(exercise: Exercise, tonicMidi: Int, tuning: Tuning = .standard) {
        let secondsPerBeat = 60 / exercise.tempo
        var cursor = 0.0
        var laidOut: [TimedNote] = []
        for (index, step) in exercise.steps.enumerated() {
            let end = cursor + step.beats * secondsPerBeat
            laidOut.append(TimedNote(index: index, midi: tonicMidi + step.semitones, start: cursor, end: end))
            cursor = end
        }
        notes = laidOut
        duration = cursor
        self.tuning = tuning
    }

    public func note(at time: Double) -> TimedNote? {
        guard time >= 0, time < duration else { return nil }
        var low = 0
        var high = notes.count - 1
        while low < high {
            let middle = (low + high) / 2
            if time >= notes[middle].end {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return notes[low]
    }

    public func frequency(of note: TimedNote) -> Double {
        tuning.frequency(midi: Double(note.midi))
    }
}
