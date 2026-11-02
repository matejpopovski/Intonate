import IntonateDSP
import IntonateTraining
import Observation
import SwiftUI

enum InputMode: String {
    case demo
    case microphone
}

enum Route: Hashable {
    case stage(Exercise?)
    case review(Exercise, PerformanceReport)
}

/// Best score per exercise and voice. A plain dictionary in `UserDefaults` is all this needs.
struct BestScores {
    private let defaults: UserDefaults
    private static let key = "intonate.bestScores"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ exercise: Exercise, _ voice: VoiceRange) -> String {
        "\(exercise.id)/\(voice.rawValue)"
    }

    func best(for exercise: Exercise, voice: VoiceRange) -> Double? {
        let scores = defaults.dictionary(forKey: Self.key) as? [String: Double]
        return scores?[key(exercise, voice)]
    }

    /// Records a score if it beats the previous best, and says whether it did.
    @discardableResult
    func record(_ score: Double, for exercise: Exercise, voice: VoiceRange) -> Bool {
        var scores = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        let id = key(exercise, voice)
        guard score > (scores[id] ?? -1) else { return false }
        scores[id] = score
        defaults.set(scores, forKey: Self.key)
        return true
    }
}

@MainActor
@Observable
final class AppModel {
    var path: [Route] = []
    var voice: VoiceRange {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: "intonate.voice") }
    }
    var input: InputMode
    private(set) var scoresVersion = 0

    let options: LaunchOptions
    let scores = BestScores()

    /// The Simulator has no microphone to rely on, so demo is its only mode.
    static var microphoneAvailable: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            return true
        #endif
    }

    init(options: LaunchOptions = .current) {
        self.options = options
        let saved = UserDefaults.standard.string(forKey: "intonate.voice").flatMap(VoiceRange.init(rawValue:))
        voice = options.voice ?? saved ?? .tenor
        input = Self.microphoneAvailable && !options.forceDemo ? .microphone : .demo

        if let id = options.exerciseID {
            let exercise = Exercise.programme.first { $0.id == id }
            path = [.stage(exercise)]
        }
    }

    func finish(_ exercise: Exercise, report: PerformanceReport) {
        scores.record(report.score, for: exercise, voice: voice)
        scoresVersion += 1
        path = [.review(exercise, report)]
    }

    func bestScore(for exercise: Exercise) -> Double? {
        _ = scoresVersion
        return scores.best(for: exercise, voice: voice)
    }
}
