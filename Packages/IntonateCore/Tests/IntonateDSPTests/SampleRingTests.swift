import XCTest

@testable import IntonateDSP

final class SampleRingTests: XCTestCase {
    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(SampleRing(minimumCapacity: 1000).capacity, 1024)
        XCTAssertEqual(SampleRing(minimumCapacity: 1024).capacity, 1024)
    }

    func testDataSurvivesWrapAround() {
        let ring = SampleRing(minimumCapacity: 8)
        var output = [Float](repeating: 0, count: 6)
        let first: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(ring.write(first, count: 6), 6)
        XCTAssertEqual(ring.read(into: &output, count: 6), 6)

        // The next six straddle the end of the storage.
        let second: [Float] = [7, 8, 9, 10, 11, 12]
        XCTAssertEqual(ring.write(second, count: 6), 6)
        XCTAssertEqual(ring.availableToRead, 6)
        XCTAssertEqual(ring.read(into: &output, count: 6), 6)
        XCTAssertEqual(output, second)
    }

    func testOverflowRejectsNewSamplesAndCountsThem() {
        let ring = SampleRing(minimumCapacity: 4)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(ring.write(input, count: 6), 4)
        XCTAssertEqual(ring.droppedSamples, 2)

        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(ring.read(into: &output, count: 4), 4)
        XCTAssertEqual(output, [1, 2, 3, 4], "what was accepted must stay intact")
    }

    func testReadFromEmptyRingReturnsNothing() {
        let ring = SampleRing(minimumCapacity: 4)
        var output: [Float] = [9]
        XCTAssertEqual(ring.read(into: &output, count: 1), 0)
        XCTAssertEqual(output, [9])
    }

    /// Runs a real producer and consumer. A torn index shows up as a wrong sample in the sequence.
    /// The assertion is on content and never on timing, so a slow runner only takes longer.
    func testConcurrentProducerAndConsumerKeepOrder() {
        let total = 2_000_000
        let ring = SampleRing(minimumCapacity: 4096)
        let finished = expectation(description: "consumer saw every sample")

        DispatchQueue.global(qos: .userInitiated).async {
            var next = 0
            var chunk = [Float](repeating: 0, count: 257)
            while next < total {
                let count = min(chunk.count, total - next)
                for index in 0..<count {
                    chunk[index] = Float((next + index) % 8192)
                }
                var written = 0
                while written < count {
                    written += chunk.withUnsafeBufferPointer {
                        ring.write(
                            $0.baseAddress! + written,
                            count: min(count - written, ring.capacity - ring.availableToRead)
                        )
                    }
                }
                next += count
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var expected = 0
            var chunk = [Float](repeating: 0, count: 311)
            var mismatches = 0
            while expected < total {
                let count = ring.read(into: &chunk, count: chunk.count)
                for index in 0..<count where chunk[index] != Float((expected + index) % 8192) {
                    mismatches += 1
                }
                expected += count
            }
            XCTAssertEqual(mismatches, 0)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 120)
        XCTAssertEqual(ring.droppedSamples, 0)
    }
}
