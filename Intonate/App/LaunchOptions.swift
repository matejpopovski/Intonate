import Foundation
import IntonateTraining

/// Launch arguments that let scripts drive the real app: straight to an exercise for screenshots,
/// or into a measuring run that writes its timings to a file.
struct LaunchOptions: Equatable {
    /// Exercise to open at launch. "free" opens free singing.
    var exerciseID: String?
    var voice: VoiceRange?
    /// Seconds of free singing to measure before writing the report.
    var measureSeconds: Double?
    var forceDemo = false

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        exerciseID = value(after: "--exercise")
        voice = value(after: "--voice").flatMap(VoiceRange.init(rawValue:))
        measureSeconds = value(after: "--measure").flatMap(Double.init)
        forceDemo = arguments.contains("--demo")
        if measureSeconds != nil {
            exerciseID = "free"
            forceDemo = true
        }
    }

    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
}
