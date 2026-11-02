import Foundation

/// One step of the tracker's output. `time` is on the audio stream's clock, not the wall clock.
public struct PitchFrame: Sendable, Equatable {
    /// The moment in stream seconds that `frequency` describes. For a voiced frame this is the middle
    /// of the median window, not the newest analysis window, or vibrato would read as a timing error.
    public var time: Double
    /// Tracked fundamental, or nil when the frame is treated as unvoiced.
    public var frequency: Double?
    /// The detector's unfiltered output, kept for diagnostics and the raw measurements.
    public var rawFrequency: Double?
    public var aperiodicity: Float
    public var levelDB: Float

    public init(time: Double, frequency: Double?, rawFrequency: Double?, aperiodicity: Float, levelDB: Float) {
        self.time = time
        self.frequency = frequency
        self.rawFrequency = rawFrequency
        self.aperiodicity = aperiodicity
        self.levelDB = levelDB
    }
}

public struct PitchTrackerConfiguration: Sendable, Equatable {
    /// Frames quieter than this are unvoiced whatever the detector says.
    public var silenceFloorDB: Float
    /// Frames more aperiodic than this are unvoiced. It sits above the detector's dip threshold on
    /// purpose: that threshold decides which lag to trust and a low value avoids octave errors, while
    /// this one decides whether anyone is singing, and held-out recordings favour a looser value.
    public var maxAperiodicity: Float
    /// Consecutive voiced frames needed before pitch is reported. Rejects single-frame flukes in noise.
    public var onsetFrames: Int
    /// Odd median length over the voiced run, which removes isolated octave jumps.
    public var medianFrames: Int

    public init(
        silenceFloorDB: Float = -50,
        maxAperiodicity: Float = 0.3,
        onsetFrames: Int = 2,
        medianFrames: Int = 5
    ) {
        precondition(medianFrames % 2 == 1)
        self.silenceFloorDB = silenceFloorDB
        self.maxAperiodicity = maxAperiodicity
        self.onsetFrames = onsetFrames
        self.medianFrames = medianFrames
    }
}

/// Turns frame-by-frame detector output into a contour a singer can look at. YIN alone has no memory,
/// so a single frame with a strong formant can read an octave off; a singer does not jump an octave
/// for 6 ms. The median runs on log frequency because intervals, not hertz, are what should average.
public struct PitchTracker {
    public let configuration: PitchTrackerConfiguration

    private var history: [Double]
    private var times: [Double]
    private var sorted: [Double]
    private var historyCount = 0
    private var historyNext = 0
    private var voicedRun = 0

    public init(configuration: PitchTrackerConfiguration = PitchTrackerConfiguration()) {
        self.configuration = configuration
        history = [Double](repeating: 0, count: configuration.medianFrames)
        times = history
        sorted = history
    }

    public mutating func reset() {
        historyCount = 0
        historyNext = 0
        voicedRun = 0
    }

    public mutating func push(estimate: PitchEstimate?, time: Double, levelDB: Float) -> PitchFrame {
        guard let estimate, levelDB >= configuration.silenceFloorDB,
            estimate.aperiodicity <= configuration.maxAperiodicity
        else {
            reset()
            return PitchFrame(
                time: time,
                frequency: nil,
                rawFrequency: estimate?.frequency,
                aperiodicity: estimate?.aperiodicity ?? 1,
                levelDB: levelDB
            )
        }

        voicedRun += 1
        history[historyNext] = log2(estimate.frequency)
        times[historyNext] = time
        historyNext = (historyNext + 1) % configuration.medianFrames
        historyCount = min(historyCount + 1, configuration.medianFrames)

        let frequency = voicedRun >= configuration.onsetFrames ? pow(2, median()) : nil
        let window = configuration.medianFrames
        let middle = (historyNext + window - 1 - (historyCount - 1) / 2) % window
        return PitchFrame(
            time: times[middle],
            frequency: frequency,
            rawFrequency: estimate.frequency,
            aperiodicity: estimate.aperiodicity,
            levelDB: levelDB
        )
    }

    /// Insertion sort into a fixed buffer: at five elements it beats a general sort and never allocates.
    private mutating func median() -> Double {
        for index in 0..<historyCount {
            let value = history[index]
            var slot = index
            while slot > 0, sorted[slot - 1] > value {
                sorted[slot] = sorted[slot - 1]
                slot -= 1
            }
            sorted[slot] = value
        }
        return sorted[(historyCount - 1) / 2]
    }
}
