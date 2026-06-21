import XCTest
@testable import MaxMailCore

final class ResilientStreamTests: XCTestCase {

    /// One transient open() failure followed by a stream that emits
    /// three events. The wrapper must absorb the failure, retry with
    /// the configured backoff, and pass the events through.
    func testWrapperAbsorbsTransientErrorAndRecovers() async throws {
        actor State {
            var openCalls = 0
            var retries: [TimeInterval] = []
            func open() -> Int { openCalls += 1; return openCalls }
            func recordRetry(_ d: TimeInterval) { retries.append(d) }
        }
        let state = State()

        let stream = resilientStream(
            backoff: Backoff(initial: 0.01, maximum: 0.02, multiplier: 2, jitter: 0),
            onRetry: { delay, _ in await state.recordRetry(delay) },
            open: {
                let call = await state.open()
                if call == 1 {
                    throw FakeError.transient
                }
                return AsyncThrowingStream { cont in
                    cont.yield(10)
                    cont.yield(20)
                    cont.yield(30)
                    cont.finish()
                }
            }
        )

        var received: [Int] = []
        for try await event in stream {
            received.append(event)
            if received.count == 3 { break }
        }
        XCTAssertEqual(received, [10, 20, 30])
        let retries = await state.retries
        XCTAssertEqual(retries.count, 1, "should have one backoff sleep before the retry")
    }

    /// The first stream produces events successfully then finishes
    /// cleanly. The wrapper re-opens (idle reconnect contract). On the
    /// second open, simulate a permanent failure for two more attempts
    /// then yield. The successful first burst should have reset the
    /// backoff so the second wave starts from `initial` again.
    func testHealthyStreamResetsBackoff() async throws {
        actor State {
            var openCalls = 0
            var sleeps: [TimeInterval] = []
            func openCall() -> Int { openCalls += 1; return openCalls }
            func recordRetry(_ d: TimeInterval) { sleeps.append(d) }
        }
        let state = State()

        let stream = resilientStream(
            backoff: Backoff(initial: 0.01, maximum: 0.04, multiplier: 2, jitter: 0),
            onRetry: { delay, _ in await state.recordRetry(delay) },
            open: {
                let call = await state.openCall()
                switch call {
                case 1:
                    return AsyncThrowingStream { cont in
                        cont.yield(1)
                        cont.finish()
                    }
                case 2, 3:
                    throw FakeError.transient
                default:
                    return AsyncThrowingStream { cont in
                        cont.yield(2)
                        cont.finish()
                    }
                }
            }
        )

        var received: [Int] = []
        for try await event in stream {
            received.append(event)
            if received == [1, 2] { break }
        }
        XCTAssertEqual(received, [1, 2])
        let sleeps = await state.sleeps
        // Two retries between the two healthy streams; the first must
        // be the `initial` (0.01) because the previous successful
        // burst reset the backoff.
        XCTAssertEqual(sleeps.first, 0.01)
        XCTAssertEqual(sleeps.count, 2)
    }

    enum FakeError: Error { case transient }
}
