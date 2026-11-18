// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

/// A time-based ceiling for optional monitor work. Picture delivery is independent.
public struct MonitorRefreshCadence: Sendable {
  private var lastRefresh: Double?

  public init() {}

  /// The next permitted refresh, measured on the display link's clock. A clock
  /// reset starts a new interval; a long pause never creates catch-up work.
  public func nextRefresh(at timestamp: Double, maximumHz: Int) -> Double {
    guard timestamp.isFinite, let lastRefresh, timestamp >= lastRefresh else { return timestamp }
    return max(timestamp, lastRefresh + 1 / Double(max(1, maximumHz)))
  }

  /// Due within a millisecond (a tenth of the interval at most). Display link timestamps
  /// come in host-clock ticks and jitter slightly, so a ceiling equal to the display's
  /// rate (60 on 60, 120 on 120) would otherwise miss every other frame and run at half.
  public func isDue(at timestamp: Double, maximumHz: Int) -> Bool {
    let slack = min(0.001, 0.1 / Double(max(1, maximumHz)))
    return timestamp.isFinite && nextRefresh(at: timestamp, maximumHz: maximumHz) <= timestamp + slack
  }

  /// Call only after submitting the optional work successfully.
  public mutating func didRefresh(at timestamp: Double) {
    if timestamp.isFinite { lastRefresh = timestamp }
  }
}
