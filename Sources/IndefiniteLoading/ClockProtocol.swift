import Foundation

/// The source of time an ``IndefiniteLoader`` reads and sleeps on.
///
/// The loader never calls `Date()` or `Task.sleep` directly. It asks its clock, so the grace delay
/// and the minimum duration can be driven from a test instead of measured against wall time. Pass
/// ``SystemClock`` in production and ``MockClock`` in tests.
public protocol ClockProtocol: Sendable {
  /// The current instant according to this clock.
  ///
  /// - Returns: The clock's reading.
  func now() -> Date

  /// Suspends the calling task for `duration`.
  ///
  /// - Parameter duration: How long to suspend.
  /// - Throws: `CancellationError` when the calling task is cancelled while suspended.
  func sleep(for duration: Duration) async throws
}

/// The production ``ClockProtocol``, backed by Foundation's `Date` and `Task.sleep(for:)`.
public struct SystemClock: ClockProtocol {
  /// Creates a system clock.
  public init() {}

  /// The current date.
  ///
  /// - Returns: `Date()`.
  public func now() -> Date {
    Date()
  }

  /// Suspends the calling task for `duration` on the continuous clock.
  ///
  /// - Parameter duration: How long to suspend.
  /// - Throws: `CancellationError` when the calling task is cancelled while suspended.
  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}
