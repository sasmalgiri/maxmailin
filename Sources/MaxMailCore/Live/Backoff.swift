import Foundation

/// Exponential backoff with jitter for live-connection retry loops.
/// Bounded so a permanently-broken endpoint doesn't burn CPU
/// reconnecting, and reset on every success so a transient drop
/// doesn't carry penalty into the next normal session.
///
/// Default schedule: 1s → 2s → 4s → 8s → 16s → 32s → 60s (cap).
/// Jitter is ±20% of the current delay so a fleet of clients
/// reconnecting after a server outage doesn't synchronize-attack
/// the box that just came back online.
public struct Backoff: Sendable {

    public let initial: TimeInterval
    public let maximum: TimeInterval
    public let multiplier: Double
    public let jitter: Double

    private var attempts: Int = 0

    public init(
        initial: TimeInterval = 1,
        maximum: TimeInterval = 60,
        multiplier: Double = 2,
        jitter: Double = 0.2
    ) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// Next delay to wait before retrying. Advances internal state —
    /// call `reset()` after a successful operation so the next failure
    /// starts back at `initial`.
    public mutating func nextDelay() -> TimeInterval {
        defer { attempts += 1 }
        let base = min(initial * pow(multiplier, Double(attempts)), maximum)
        guard jitter > 0 else { return base }
        let span = base * jitter
        let offset = Double.random(in: -span...span)
        return max(0, base + offset)
    }

    public mutating func reset() { attempts = 0 }

    public var currentAttempts: Int { attempts }
}
