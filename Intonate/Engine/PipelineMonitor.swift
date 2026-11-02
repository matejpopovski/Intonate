import Foundation
import os

/// Timing of the live path, collected only when measuring. On the app's hot paths this costs one
/// branch when off; when on, it takes a short lock, which is why it never runs on the audio thread.
final class PipelineMonitor: @unchecked Sendable {
    struct Report: Encodable {
        struct Distribution: Encodable {
            let count: Int
            let p50: Double
            let p95: Double
            let p99: Double
            let max: Double
        }

        var build: String
        var device: String
        var runtime: String
        var host: String
        var seconds: Double
        var analysisPerChunkMs: Distribution
        var analysisPerPitchFrameMs: Distribution
        var ringWaitMs: Distribution
        var frameWaitMs: Distribution
        var frameIntervalMs: Distribution
        var encodeMs: Distribution
        var gpuMs: Distribution?
        var droppedSamples: UInt64
        var droppedDrawables: Int
        var rendererSetupMs: Double?
        var note: String
    }

    private struct Samples {
        var analysisChunk: [Double] = []
        var analysisFrame: [Double] = []
        var ringWait: [Double] = []
        var frameWait: [Double] = []
        var frameInterval: [Double] = []
        var encode: [Double] = []
        var gpu: [Double] = []
        var droppedDrawables = 0
    }

    private let samples = OSAllocatedUnfairLock(initialState: Samples())

    func recordAnalysis(chunkMs: Double, frames: Int, ringWaitMs: Double) {
        samples.withLock {
            $0.analysisChunk.append(chunkMs)
            if frames > 0 { $0.analysisFrame.append(chunkMs / Double(frames)) }
            $0.ringWait.append(ringWaitMs)
        }
    }

    func recordFrame(intervalMs: Double?, encodeMs: Double, frameWaitMs: Double?) {
        samples.withLock {
            if let intervalMs { $0.frameInterval.append(intervalMs) }
            $0.encode.append(encodeMs)
            if let frameWaitMs { $0.frameWait.append(frameWaitMs) }
        }
    }

    func recordGPU(ms: Double) {
        samples.withLock { $0.gpu.append(ms) }
    }

    func recordDroppedDrawable() {
        samples.withLock { $0.droppedDrawables += 1 }
    }

    private static func distribution(_ values: [Double]) -> Report.Distribution {
        let sorted = values.sorted()
        func at(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let value = sorted[min(sorted.count - 1, Int(fraction * Double(sorted.count)))]
            return (value * 1_000).rounded() / 1_000
        }
        return Report.Distribution(
            count: sorted.count,
            p50: at(0.5),
            p95: at(0.95),
            p99: at(0.99),
            max: ((sorted.last ?? 0) * 1_000).rounded() / 1_000
        )
    }

    func report(
        build: String,
        device: String,
        runtime: String,
        host: String,
        seconds: Double,
        droppedSamples: UInt64,
        rendererSetupMs: Double?,
        note: String
    ) -> Report {
        samples.withLock { state in
            Report(
                build: build,
                device: device,
                runtime: runtime,
                host: host,
                seconds: seconds,
                analysisPerChunkMs: Self.distribution(state.analysisChunk),
                analysisPerPitchFrameMs: Self.distribution(state.analysisFrame),
                ringWaitMs: Self.distribution(state.ringWait),
                frameWaitMs: Self.distribution(state.frameWait),
                frameIntervalMs: Self.distribution(state.frameInterval),
                encodeMs: Self.distribution(state.encode),
                gpuMs: state.gpu.isEmpty ? nil : Self.distribution(state.gpu),
                droppedSamples: droppedSamples,
                droppedDrawables: state.droppedDrawables,
                rendererSetupMs: rendererSetupMs,
                note: note
            )
        }
    }
}
