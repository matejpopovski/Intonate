import Foundation
import IntonateDSP

/// Machine description stored with every result file. A number without its hardware means little.
struct HostInfo: Encodable {
    let cpu: String
    let memoryGB: Int
    let os: String
    let note: String

    static func current(note: String) -> HostInfo {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let cpu = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let memory = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return HostInfo(
            cpu: cpu,
            memoryGB: memory,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            note: note
        )
    }
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (data + Data("\n".utf8)).write(to: url)
    print("wrote \(url.path)")
}

func rounded(_ value: Double, _ places: Int = 3) -> Double {
    let scale = pow(10, Double(places))
    return (value * scale).rounded() / scale
}

/// Linear-interpolated percentile of an ascending array.
func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
    guard let first = sorted.first else { return .nan }
    guard sorted.count > 1 else { return first }
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(position)
    let upper = min(lower + 1, sorted.count - 1)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
}

/// Runs `body` for each index with at most `workers` threads, and returns the results in order.
/// Other jobs share this machine, so the benches take a fixed slice of it rather than every core.
func parallelMap<T>(_ count: Int, workers: Int = 6, _ body: @escaping @Sendable (Int) -> T) -> [T] {
    let lock = NSLock()
    nonisolated(unsafe) var results = [T?](repeating: nil, count: count)
    nonisolated(unsafe) var next = 0
    let group = DispatchGroup()
    for _ in 0..<min(workers, count) {
        group.enter()
        Thread.detachNewThread {
            while true {
                lock.lock()
                let index = next
                next += 1
                lock.unlock()
                if index >= count { break }
                let value = body(index)
                lock.lock()
                results[index] = value
                lock.unlock()
            }
            group.leave()
        }
    }
    group.wait()
    return results.map { $0! }
}

/// Classifies a pitch error the way the literature does: octave errors are near a multiple of 1200
/// cents, and gross errors are any other miss wider than a quarter tone.
enum ErrorClass {
    case fine, octave, gross

    init(cents: Double) {
        if abs(cents) <= 50 {
            self = .fine
            return
        }
        let octaves = (cents / 1200).rounded()
        self = octaves != 0 && abs(cents - octaves * 1200) <= 100 ? .octave : .gross
    }
}

/// Accumulates frames for one experimental condition.
struct Tally {
    var frames = 0
    var voiced = 0
    var fine: [Double] = []
    var octave = 0
    var gross = 0

    mutating func add(estimate: Double?, isVoiced: Bool, truth: Double) {
        frames += 1
        guard isVoiced, let estimate else { return }
        voiced += 1
        let error = cents(estimate, relativeTo: truth)
        switch ErrorClass(cents: error) {
        case .fine: fine.append(abs(error))
        case .octave: octave += 1
        case .gross: gross += 1
        }
    }

    mutating func merge(_ other: Tally) {
        frames += other.frames
        voiced += other.voiced
        fine += other.fine
        octave += other.octave
        gross += other.gross
    }

    func summary(label: String) -> ConditionResult {
        let sorted = fine.sorted()
        let voicedCount = max(voiced, 1)
        return ConditionResult(
            label: label,
            frames: frames,
            voicedRate: rounded(Double(voiced) / Double(max(frames, 1)), 4),
            rawPitchAccuracy50: rounded(Double(fine.count) / Double(max(frames, 1)), 4),
            meanAbsCents: rounded(sorted.isEmpty ? .nan : sorted.reduce(0, +) / Double(sorted.count)),
            medianAbsCents: rounded(percentile(sorted, 0.5)),
            p95AbsCents: rounded(percentile(sorted, 0.95)),
            maxAbsCents: rounded(sorted.last ?? .nan),
            octaveErrorRate: rounded(Double(octave) / Double(voicedCount), 5),
            grossErrorRate: rounded(Double(gross) / Double(voicedCount), 5)
        )
    }
}

/// `meanAbsCents` and the other cent figures cover frames within 50 cents of the truth, so one octave
/// error cannot hide the fine accuracy, nor can fine accuracy hide it: the error rates report those
/// frames separately. Rates are over voiced frames, and `rawPitchAccuracy50` is over all frames.
struct ConditionResult: Encodable {
    let label: String
    let frames: Int
    let voicedRate: Double
    let rawPitchAccuracy50: Double
    let meanAbsCents: Double
    let medianAbsCents: Double
    let p95AbsCents: Double
    let maxAbsCents: Double
    let octaveErrorRate: Double
    let grossErrorRate: Double

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(frames, forKey: .frames)
        try container.encode(voicedRate, forKey: .voicedRate)
        try container.encode(rawPitchAccuracy50, forKey: .rawPitchAccuracy50)
        try container.encodeIfPresent(meanAbsCents.isNaN ? nil : meanAbsCents, forKey: .meanAbsCents)
        try container.encodeIfPresent(medianAbsCents.isNaN ? nil : medianAbsCents, forKey: .medianAbsCents)
        try container.encodeIfPresent(p95AbsCents.isNaN ? nil : p95AbsCents, forKey: .p95AbsCents)
        try container.encodeIfPresent(maxAbsCents.isNaN ? nil : maxAbsCents, forKey: .maxAbsCents)
        try container.encode(octaveErrorRate, forKey: .octaveErrorRate)
        try container.encode(grossErrorRate, forKey: .grossErrorRate)
    }

    private enum CodingKeys: String, CodingKey {
        case label, frames, voicedRate, rawPitchAccuracy50, meanAbsCents, medianAbsCents, p95AbsCents
        case maxAbsCents, octaveErrorRate, grossErrorRate
    }
}
