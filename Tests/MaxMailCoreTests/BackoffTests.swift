import XCTest
@testable import MaxMailCore

final class BackoffTests: XCTestCase {

    func testWithoutJitterDoublesEachStepUpToCap() {
        var b = Backoff(initial: 1, maximum: 30, multiplier: 2, jitter: 0)
        XCTAssertEqual(b.nextDelay(), 1)
        XCTAssertEqual(b.nextDelay(), 2)
        XCTAssertEqual(b.nextDelay(), 4)
        XCTAssertEqual(b.nextDelay(), 8)
        XCTAssertEqual(b.nextDelay(), 16)
        // Cap kicks in: 32 → 30.
        XCTAssertEqual(b.nextDelay(), 30)
        // Stays at the cap from now on.
        XCTAssertEqual(b.nextDelay(), 30)
    }

    func testResetGoesBackToInitial() {
        var b = Backoff(initial: 1, maximum: 60, multiplier: 2, jitter: 0)
        _ = b.nextDelay(); _ = b.nextDelay(); _ = b.nextDelay()
        XCTAssertEqual(b.currentAttempts, 3)
        b.reset()
        XCTAssertEqual(b.currentAttempts, 0)
        XCTAssertEqual(b.nextDelay(), 1)
    }

    func testJitterStaysWithinSpecifiedSpan() {
        var b = Backoff(initial: 10, maximum: 60, multiplier: 2, jitter: 0.2)
        for _ in 0..<200 {
            let saved = b
            let d = b.nextDelay()
            // base for step 0 = 10; ±20% → [8, 12].
            if saved.currentAttempts == 0 {
                XCTAssertGreaterThanOrEqual(d, 8)
                XCTAssertLessThanOrEqual(d, 12)
            }
            b = saved
            b.reset()
        }
    }

    func testDelayNeverNegativeEvenWithLargeJitter() {
        // Pathological config — jitter wider than the base. Still must
        // not return negative sleeps.
        var b = Backoff(initial: 1, maximum: 60, multiplier: 2, jitter: 5)
        for _ in 0..<50 {
            XCTAssertGreaterThanOrEqual(b.nextDelay(), 0)
        }
    }
}
