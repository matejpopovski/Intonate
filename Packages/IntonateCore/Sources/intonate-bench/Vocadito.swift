import AVFoundation
import Foundation
import IntonateDSP

/// Measurement against recorded singing. Everything else in this benchmark uses synthesized signals
/// with exact ground truth; this uses people, with ground truth that is itself an annotation.
struct VocaditoRow: Encodable {
    let label: String
    let tracks: Int
    let referenceFrames: Int
    let voicedFrames: Int
    let rawPitchAccuracy50: Double
    let rawPitchAccuracy25: Double
    let rawChromaAccuracy50: Double
    let voicingRecall: Double
    let voicingFalseAlarm: Double
    let overallAccuracy: Double
    let medianAbsCentsWithin50: Double
    let octaveErrorShareOfVoiced: Double
}

struct VocaditoReport: Encodable {
    let host: HostInfo
    let dataset: String
    let metricNote: String
    let splitNote: String
    let shippedOnTuningSingers: VocaditoRow
    let shippedOnHeldOutSingers: VocaditoRow
    let shippedOnAllTracks: VocaditoRow
    let detectorWithoutTrackerOnAllTracks: VocaditoRow
    let tuningGridBestFirst: [VocaditoRow]
    let tuningWindowSweep: [VocaditoRow]
    let tuningFallbackMarginSweep: [VocaditoRow]
    let tuningMedianSweep: [VocaditoRow]
    let worstTracks: [VocaditoTrackRow]
}

struct VocaditoTrackRow: Encodable {
    let track: String
    let rawPitchAccuracy50: Double
    let voicingRecall: Double
}

private struct Track {
    let name: String
    let singer: String
    let samples: [Float]
    let times: [Double]
    let f0: [Double]
}

private func loadTrack(name: String, singer: String, root: URL) throws -> Track {
    let audio = root.appendingPathComponent("Audio/\(name).wav")
    let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { throw CocoaError(.fileReadUnknown) }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

    let text = try String(contentsOf: root.appendingPathComponent("Annotations/F0/\(name)_f0.csv"), encoding: .utf8)
    var times: [Double] = []
    var f0: [Double] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: ",")
        guard fields.count >= 2, let time = Double(fields[0]), let value = Double(fields[1]) else { continue }
        times.append(time)
        f0.append(value)
    }
    return Track(name: name, singer: singer, samples: samples, times: times, f0: f0)
}

private struct Counts {
    var frames = 0
    var voiced = 0
    var correctRaw = 0
    var correctRaw25 = 0
    var correctChroma = 0
    var voicedDetected = 0
    var unvoicedFrames = 0
    var falseAlarms = 0
    var overallCorrect = 0
    var octave = 0
    var fine: [Double] = []

    mutating func merge(_ other: Counts) {
        frames += other.frames
        voiced += other.voiced
        correctRaw += other.correctRaw
        correctRaw25 += other.correctRaw25
        correctChroma += other.correctChroma
        voicedDetected += other.voicedDetected
        unvoicedFrames += other.unvoicedFrames
        falseAlarms += other.falseAlarms
        overallCorrect += other.overallCorrect
        octave += other.octave
        fine += other.fine
    }

    func row(label: String, tracks: Int) -> VocaditoRow {
        let sorted = fine.sorted()
        let voicedCount = Double(max(voiced, 1))
        return VocaditoRow(
            label: label,
            tracks: tracks,
            referenceFrames: frames,
            voicedFrames: voiced,
            rawPitchAccuracy50: rounded(Double(correctRaw) / voicedCount, 4),
            rawPitchAccuracy25: rounded(Double(correctRaw25) / voicedCount, 4),
            rawChromaAccuracy50: rounded(Double(correctChroma) / voicedCount, 4),
            voicingRecall: rounded(Double(voicedDetected) / voicedCount, 4),
            voicingFalseAlarm: rounded(Double(falseAlarms) / Double(max(unvoicedFrames, 1)), 4),
            overallAccuracy: rounded(Double(overallCorrect) / Double(max(frames, 1)), 4),
            medianAbsCentsWithin50: rounded(percentile(sorted, 0.5), 2),
            octaveErrorShareOfVoiced: rounded(Double(octave) / voicedCount, 4)
        )
    }
}

/// Scores one track. `useRaw` reads the detector's frame-by-frame output for the pitch metrics, so
/// the effect of the tracker's median and voicing decision can be separated from YIN itself.
private func evaluate(track: Track, configuration: AnalysisConfiguration, useRaw: Bool) -> Counts {
    // Reference frames are 256 samples apart; a matching hop gives one estimate per reference frame.
    var frames: [PitchFrame] = []
    let pipeline = AnalysisPipeline(configuration: configuration)
    track.samples.withUnsafeBufferPointer { buffer in
        pipeline.process(buffer, onPitch: { frames.append($0) }, onColumn: { _ in })
    }
    // A frame's time depends on the period it found, so neighbouring frames can swap order by a
    // few samples. The walk below assumes order.
    frames.sort { $0.time < $1.time }

    var counts = Counts()
    var cursor = 0
    for (time, reference) in zip(track.times, track.f0) {
        while cursor + 1 < frames.count, frames[cursor + 1].time <= time {
            cursor += 1
        }
        var frame = frames.isEmpty ? nil : frames[cursor]
        if cursor + 1 < frames.count, abs(frames[cursor + 1].time - time) < abs(frames[cursor].time - time) {
            frame = frames[cursor + 1]
        }
        let isClose = frame.map { abs($0.time - time) <= 0.02 } ?? false
        let voicedOut = isClose && frame?.frequency != nil
        let pitch = isClose ? (useRaw ? frame?.rawFrequency : frame?.frequency) : nil

        counts.frames += 1
        if reference > 0 {
            counts.voiced += 1
            if voicedOut { counts.voicedDetected += 1 }
            if let pitch {
                let error = cents(pitch, relativeTo: reference)
                let absolute = abs(error)
                if absolute <= 50 {
                    counts.correctRaw += 1
                    counts.fine.append(absolute)
                    if voicedOut { counts.overallCorrect += 1 }
                }
                if absolute <= 25 { counts.correctRaw25 += 1 }
                let folded = abs(error - 1200 * (error / 1200).rounded())
                if folded <= 50 { counts.correctChroma += 1 }
                if ErrorClass(cents: error) == .octave { counts.octave += 1 }
            }
        } else {
            counts.unvoicedFrames += 1
            if voicedOut {
                counts.falseAlarms += 1
            } else {
                counts.overallCorrect += 1
            }
        }
    }
    return counts
}

/// Reads `track_id,singer_id,...` so that the tuning split can separate people, not clips.
private func singers(root: URL) throws -> [String: String] {
    let text = try String(contentsOf: root.appendingPathComponent("vocadito_metadata.csv"), encoding: .utf8)
    var result: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline).dropFirst() {
        let fields = line.split(separator: ",")
        if fields.count >= 2 { result["vocadito_\(fields[0])"] = String(fields[1]) }
    }
    return result
}

/// One estimate per reference frame: the reference has a value every 256 samples.
private func configuration(
    dip: Float = 0.15,
    voicing: Float = 0.3,
    windowLength: Int? = nil,
    medianFrames: Int = 5
) -> AnalysisConfiguration {
    var value = AnalysisConfiguration(
        yin: YINConfiguration(windowLength: windowLength, threshold: dip),
        tracker: PitchTrackerConfiguration(maxAperiodicity: voicing, medianFrames: medianFrames)
    )
    value.pitchHop = 256
    return value
}

func runVocadito(root: URL, output: URL) throws {
    let audioFolder = root.appendingPathComponent("Audio")
    let singerOf = try singers(root: root)
    let names = try FileManager.default.contentsOfDirectory(atPath: audioFolder.path)
        .filter { $0.hasSuffix(".wav") && !$0.hasPrefix(".") }
        .map { String($0.dropLast(4)) }
        .sorted { (Int($0.split(separator: "_").last ?? "") ?? 0) < (Int($1.split(separator: "_").last ?? "") ?? 0) }
    let tracks = try names.map { try loadTrack(name: $0, singer: singerOf[$0] ?? "unknown", root: root) }
    print("loaded \(tracks.count) tracks")

    // Alternate through the singers so that no voice is on both sides of the split.
    let singerOrder = Array(Set(tracks.map(\.singer))).sorted {
        (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0)
    }
    let tuningSingers = Set(singerOrder.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
    let tuning = tracks.filter { tuningSingers.contains($0.singer) }
    let heldOut = tracks.filter { !tuningSingers.contains($0.singer) }
    print("\(singerOrder.count) singers: \(tuning.count) tracks to tune on, \(heldOut.count) held out")

    func score(_ subset: [Track], _ settings: AnalysisConfiguration, useRaw: Bool = false) -> [Counts] {
        let shared = UncheckedArray(storage: subset)
        return parallelMap(shared.count) { index in
            evaluate(track: shared[index], configuration: settings, useRaw: useRaw)
        }
    }
    func merged(_ counts: [Counts]) -> Counts {
        counts.reduce(into: Counts()) { $0.merge($1) }
    }

    var grid: [VocaditoRow] = []
    for dip in [Float(0.05), 0.10, 0.15, 0.20, 0.30] {
        for voicing in [Float(0.10), 0.15, 0.20, 0.25, 0.30, 0.40, 0.50] where voicing >= dip {
            let label = "dip \(dip), voicing \(voicing)"
            print(label)
            grid.append(
                merged(score(tuning, configuration(dip: dip, voicing: voicing))).row(label: label, tracks: tuning.count)
            )
        }
    }
    grid.sort { $0.overallAccuracy > $1.overallAccuracy }

    let windowRows = [512, 768, 1_024, 2_048].map { (samples: Int) in
        merged(score(tuning, configuration(windowLength: samples))).row(label: "W = \(samples)", tracks: tuning.count)
    }
    let marginRows = [Float(0), 0.05, 0.1, 0.15, 0.2].map { margin -> VocaditoRow in
        var settings = configuration()
        settings.yin.fallbackMargin = margin
        return merged(score(tuning, settings)).row(label: "fallback margin \(margin)", tracks: tuning.count)
    }
    let medianRows = [1, 3, 5, 9].map { frames in
        merged(score(tuning, configuration(medianFrames: frames)))
            .row(label: "median of \(frames)", tracks: tuning.count)
    }

    var shippedSettings = AnalysisConfiguration()
    shippedSettings.pitchHop = 256
    let shippedAll = score(tracks, shippedSettings)

    // A median of one, an onset of one and a gate that accepts everything leave the bare detector in
    // `rawFrequency`, time-aligned with the frame.
    var bare = shippedSettings
    bare.tracker = PitchTrackerConfiguration(maxAperiodicity: 1, onsetFrames: 1, medianFrames: 1)

    let perTrack = zip(tracks, shippedAll).map { track, counts -> VocaditoTrackRow in
        let row = counts.row(label: track.name, tracks: 1)
        return VocaditoTrackRow(
            track: track.name,
            rawPitchAccuracy50: row.rawPitchAccuracy50,
            voicingRecall: row.voicingRecall
        )
    }
    let worst = perTrack.sorted { $0.rawPitchAccuracy50 < $1.rawPitchAccuracy50 }.prefix(5)

    try writeJSON(
        VocaditoReport(
            host: .current(note: "accuracy figures are machine independent"),
            dataset:
                "vocadito (Bittner et al., ISMIR 2021 LBD), 40 solo vocal excerpts, CC BY 4.0, "
                + "https://zenodo.org/records/5578807. Not redistributed; fetched by scripts/fetch-vocadito.sh",
            metricNote:
                "Definitions follow MIREX melody extraction. Accuracy figures are over reference-voiced frames, "
                + "and a frame the tracker calls unvoiced counts as a miss.",
            splitNote:
                "Singers alternate into a tuning set and a held-out set, so no voice is on both sides. The grid "
                + "ran on the tuning set only. The shipped defaults were chosen from it, then measured on held-out.",
            shippedOnTuningSingers: merged(score(tuning, shippedSettings)).row(label: "shipped", tracks: tuning.count),
            shippedOnHeldOutSingers: merged(score(heldOut, shippedSettings)).row(
                label: "shipped",
                tracks: heldOut.count
            ),
            shippedOnAllTracks: merged(shippedAll).row(label: "shipped", tracks: tracks.count),
            detectorWithoutTrackerOnAllTracks: merged(score(tracks, bare, useRaw: true))
                .row(label: "YIN best guess on every frame", tracks: tracks.count),
            tuningGridBestFirst: grid,
            tuningWindowSweep: windowRows,
            tuningFallbackMarginSweep: marginRows,
            tuningMedianSweep: medianRows,
            worstTracks: Array(worst)
        ),
        to: output.appendingPathComponent("vocadito.json")
    )
}

/// `[Track]` holds only value types and is never mutated while workers read it.
private struct UncheckedArray<Element>: @unchecked Sendable {
    let storage: [Element]
    var count: Int { storage.count }
    subscript(index: Int) -> Element { storage[index] }
}
