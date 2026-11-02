import Foundation
import IntonateDSP
import IntonateTraining
import os

/// Runs the analysis pipeline on its own queue, between the input's ring and the display.
///
/// The queue polls the ring on a short timer. Signalling it from the audio callback would add a
/// system call to the real-time thread, and at a 5 ms poll the audio is never waiting long.
final class AnalysisEngine: @unchecked Sendable {
    struct Plan {
        /// Nil is free singing: analysis with nothing to score.
        var timeline: ExerciseTimeline?
        /// Stream time at which the first note starts.
        var leadIn: Double
    }

    struct Snapshot: Equatable {
        var streamTime = 0.0
        var frame: PitchFrame?
        var report: PerformanceReport?
    }

    let configuration: AnalysisConfiguration
    let ring: SampleRing
    let feed: WaterfallFeed

    private let monitor: PipelineMonitor?
    private let pipeline: AnalysisPipeline
    private let queue = DispatchQueue(label: "intonate.analysis", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var scratch: [Float]
    private var scorer: PerformanceScorer?
    private var plan = Plan(timeline: nil, leadIn: 0)
    private let snapshotLock = OSAllocatedUnfairLock(initialState: Snapshot())

    /// Audio analysed past the last note, so that frames centred inside it have been emitted.
    private static let tailSeconds = 0.25

    init(configuration: AnalysisConfiguration, monitor: PipelineMonitor? = nil) {
        self.configuration = configuration
        self.monitor = monitor
        // A full second of audio, far more than any scheduling hiccup, so that a stall costs latency
        // before it costs samples.
        ring = SampleRing(minimumCapacity: Int(configuration.sampleRate))
        feed = WaterfallFeed(configuration: configuration)
        pipeline = AnalysisPipeline(configuration: configuration)
        scratch = [Float](repeating: 0, count: 4_096)
    }

    func start(plan: Plan) {
        queue.sync {
            self.plan = plan
            scorer = plan.timeline.map { PerformanceScorer(timeline: $0) }
            snapshotLock.withLock { $0 = Snapshot() }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    var snapshot: Snapshot {
        snapshotLock.withLock { $0 }
    }

    private func drain() {
        var latest: PitchFrame?
        // Only what is here now. If the input outruns the analysis, an open-ended loop would never
        // come up for air, and neither the display nor the end of the exercise would ever be reached.
        var remaining = ring.availableToRead
        while remaining > 0 {
            let began = monitor == nil ? 0 : mach_continuous_time()
            let wanted = min(remaining, scratch.count)
            let count = scratch.withUnsafeMutableBufferPointer { buffer in
                ring.read(into: buffer.baseAddress!, count: wanted)
            }
            remaining -= count

            var frames = 0
            scratch.withUnsafeBufferPointer { buffer in
                pipeline.process(
                    UnsafeBufferPointer(rebasing: buffer[0..<count]),
                    onPitch: { frame in
                        frames += 1
                        latest = frame
                        feed.publish(frame: frame)
                        scorer?.add(frame, at: frame.time - plan.leadIn)
                    },
                    onColumn: { column in
                        feed.publish(column: column)
                    }
                )
            }

            if let monitor {
                let ended = mach_continuous_time()
                monitor.recordAnalysis(
                    chunkMs: HostClock.milliseconds(from: began, to: ended),
                    frames: frames,
                    ringWaitMs: HostClock.milliseconds(from: ring.lastWriteHostTime, to: began)
                )
            }
        }

        let streamTime = Double(pipeline.sampleCount) / configuration.sampleRate
        feed.publish(streamTime: streamTime)
        let report = finishedReport(at: streamTime)
        let newest = latest
        snapshotLock.withLock { state in
            state.streamTime = streamTime
            if let newest { state.frame = newest }
            if let report { state.report = report }
        }
    }

    private func finishedReport(at streamTime: Double) -> PerformanceReport? {
        guard let timeline = plan.timeline, let scorer,
            streamTime >= plan.leadIn + timeline.duration + Self.tailSeconds
        else { return nil }
        return scorer.report()
    }
}

/// Converts mach ticks, which are not nanoseconds on Apple silicon.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }
}
