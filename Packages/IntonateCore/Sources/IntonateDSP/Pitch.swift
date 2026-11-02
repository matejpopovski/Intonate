import Foundation

/// Equal temperament around a configurable A4, since not every ensemble tunes to 440 Hz.
public struct Tuning: Sendable, Hashable, Codable {
    public var concertA: Double

    public init(concertA: Double = 440) {
        self.concertA = concertA
    }

    public static let standard = Tuning()

    public func frequency(midi: Double) -> Double {
        concertA * pow(2, (midi - 69) / 12)
    }

    public func midi(frequency: Double) -> Double {
        69 + 12 * log2(frequency / concertA)
    }
}

/// Interval in cents from `reference` up to `frequency`.
public func cents(_ frequency: Double, relativeTo reference: Double) -> Double {
    1200 * log2(frequency / reference)
}

public struct NoteName: Sendable, Equatable, CustomStringConvertible {
    public let midi: Int

    public init(midi: Int) {
        self.midi = midi
    }

    private static let letters = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    public var letter: String {
        Self.letters[((midi % 12) + 12) % 12]
    }

    /// Scientific pitch notation, where middle C (MIDI 60) is C4.
    public var octave: Int {
        Int(floor(Double(midi) / 12)) - 1
    }

    public var description: String {
        "\(letter)\(octave)"
    }
}
