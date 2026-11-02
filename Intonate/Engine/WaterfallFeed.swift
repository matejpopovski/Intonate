import IntonateDSP
import QuartzCore
import os

/// Hands analysis output to the render loop. Columns go through a lock-free ring because there are
/// about 86 of them a second, each several hundred floats; pitch frames are small and rare enough for
/// a short lock, and neither side here is the real-time audio thread.
final class WaterfallFeed: @unchecked Sendable {
    let bandCount: Int
    /// Seconds between consecutive columns.
    let columnSeconds: Double
    /// Stream time of column zero: the centre of the first FFT window.
    let firstColumnTime: Double
    let bandMap: LogBandMap
    let columns: SampleRing

    private struct Shared {
        var pendingFrames: [PitchFrame] = []
        var oldestPending: CFTimeInterval?
        var streamTime = 0.0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    /// Written by the analysis queue only.
    private let droppedColumns = AtomicWord()
    /// Touched by the render loop only.
    private var reportedDrops: UInt64 = 0

    init(configuration: AnalysisConfiguration) {
        bandCount = configuration.bandMap.bandCount
        bandMap = configuration.bandMap
        columnSeconds = Double(configuration.columnHop) / configuration.sampleRate
        firstColumnTime = Double(configuration.fftSize) / 2 / configuration.sampleRate
        // Half a second of columns: longer than any stall the renderer should try to recover from.
        columns = SampleRing(minimumCapacity: configuration.bandMap.bandCount * 64)
    }

    /// A column is written whole or not at all. A partial write would leave every later column
    /// out of step with the row boundaries, which reads as the spectrum sliding off in frequency.
    func publish(column: UnsafeBufferPointer<Float>) {
        if !columns.writeRecord(column.baseAddress!, count: column.count) {
            droppedColumns.store(droppedColumns.load() + 1)
        }
    }

    /// Columns lost to a full ring since the last call. The renderer skips that many rows, so that
    /// rows stay tied to stream time and later audio lines up with the pitch trail.
    func takeDroppedColumns() -> Int {
        let total = droppedColumns.load()
        defer { reportedDrops = total }
        return Int(total - reportedDrops)
    }

    func publish(frame: PitchFrame) {
        let now = CACurrentMediaTime()
        shared.withLock { state in
            state.pendingFrames.append(frame)
            if state.oldestPending == nil { state.oldestPending = now }
        }
    }

    func publish(streamTime: Double) {
        shared.withLock { $0.streamTime = streamTime }
    }

    /// Empties the pending frames and reports how far the stream has reached. `oldestPublish` is when
    /// the oldest of those frames left the analysis, for measuring the wait until it reaches a frame.
    func collect() -> (frames: [PitchFrame], streamTime: Double, oldestPublish: CFTimeInterval?) {
        shared.withLock { state in
            let frames = state.pendingFrames
            let oldest = state.oldestPending
            state.pendingFrames.removeAll(keepingCapacity: true)
            state.oldestPending = nil
            return (frames, state.streamTime, oldest)
        }
    }
}
