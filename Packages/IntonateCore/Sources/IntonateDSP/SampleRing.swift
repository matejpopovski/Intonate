import CAtomicShim
import Foundation

/// Single-producer, single-consumer ring of `Float` that the audio thread writes without locking.
///
/// The write path takes no lock and allocates nothing, because a priority inversion on the audio
/// thread is an audible dropout. When the consumer falls behind, new samples are dropped and counted
/// rather than overwriting old ones: overwriting would need the producer to move the consumer's
/// index, which is exactly the shared write this design avoids.
///
/// The indices are free-running 64-bit counters, so `write - read` is always the fill level and the
/// full and empty states need no spare slot.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int

    private let mask: UInt64
    private let storage: UnsafeMutablePointer<Float>
    private let counters: UnsafeMutableRawPointer
    private let writeIndex: UnsafeMutablePointer<UInt64>
    private let readIndex: UnsafeMutablePointer<UInt64>
    private let droppedCount: UnsafeMutablePointer<UInt64>

    /// `minimumCapacity` is rounded up to a power of two so that wrapping is a mask, not a division.
    public init(minimumCapacity: Int) {
        precondition(minimumCapacity > 0)
        var size = 1
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = UInt64(size - 1)
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)

        // One cache line each, so that producer and consumer do not invalidate each other's index
        // on every update. 128 bytes covers the line size on Apple silicon.
        let line = 128
        counters = .allocate(byteCount: line * 3, alignment: line)
        counters.initializeMemory(as: UInt8.self, repeating: 0, count: line * 3)
        writeIndex = counters.bindMemory(to: UInt64.self, capacity: 1)
        readIndex = (counters + line).bindMemory(to: UInt64.self, capacity: 1)
        droppedCount = (counters + line * 2).bindMemory(to: UInt64.self, capacity: 1)
    }

    deinit {
        storage.deallocate()
        counters.deallocate()
    }

    /// Samples the consumer can read right now.
    public var availableToRead: Int {
        Int(intonate_load_acquire(writeIndex) &- intonate_load_acquire(readIndex))
    }

    /// Samples rejected because the ring was full, since the ring was created.
    public var droppedSamples: UInt64 {
        intonate_load_relaxed(droppedCount)
    }

    /// Producer side. Returns how many samples were accepted; the remainder are counted as dropped.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let write = intonate_load_relaxed(writeIndex)
        let read = intonate_load_acquire(readIndex)
        let free = capacity - Int(write &- read)
        let accepted = min(count, free)
        if accepted < count {
            intonate_add_relaxed(droppedCount, UInt64(count - accepted))
        }
        guard accepted > 0 else { return 0 }

        let start = Int(write & mask)
        let firstRun = min(accepted, capacity - start)
        (storage + start).update(from: source, count: firstRun)
        if firstRun < accepted {
            storage.update(from: source + firstRun, count: accepted - firstRun)
        }
        intonate_store_release(writeIndex, write &+ UInt64(accepted))
        return accepted
    }

    /// Consumer side. Returns how many samples were copied into `destination`.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let read = intonate_load_relaxed(readIndex)
        let write = intonate_load_acquire(writeIndex)
        let taken = min(count, Int(write &- read))
        guard taken > 0 else { return 0 }

        let start = Int(read & mask)
        let firstRun = min(taken, capacity - start)
        destination.update(from: storage + start, count: firstRun)
        if firstRun < taken {
            (destination + firstRun).update(from: storage, count: taken - firstRun)
        }
        intonate_store_release(readIndex, read &+ UInt64(taken))
        return taken
    }
}
