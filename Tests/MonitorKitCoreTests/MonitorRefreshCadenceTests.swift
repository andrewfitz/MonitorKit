// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import MonitorKitCore

final class MonitorRefreshCadenceTests: XCTestCase {
  func testHighRateVideoKeepsScopesWithinSavedCeiling() {
    for hz in [10, 15, 30, 60, 120] {
      var cadence = MonitorRefreshCadence()
      var refreshes: [Double] = []
      for frame in 0..<1200 {
        let now = Double(frame) / 120
        if cadence.isDue(at: now, maximumHz: hz) {
          cadence.didRefresh(at: now)
          refreshes.append(now)
        }
      }
      XCTAssertEqual(refreshes.count, hz * 10)
      for (previous, next) in zip(refreshes, refreshes.dropFirst()) {
        XCTAssertGreaterThanOrEqual(next - previous + 1e-9, 1 / Double(hz))
      }
    }
  }

  /// A ceiling equal to the display's rate takes every frame even when timestamps jitter
  /// by tens of microseconds, as a display link's do.
  func testACeilingAtTheDisplayRateKeepsEveryJitteredFrame() {
    for hz in [60, 120] {
      var cadence = MonitorRefreshCadence()
      var count = 0
      for frame in 0..<(hz * 10) {
        let jitter = (frame % 3 == 0 ? -1.0 : frame % 3 == 1 ? 1.0 : 0.0) * 0.00005
        let now = Double(frame) / Double(hz) + jitter
        if cadence.isDue(at: now, maximumHz: hz) { cadence.didRefresh(at: now); count += 1 }
      }
      XCTAssertEqual(count, hz * 10, "\(hz) Hz on a \(hz) Hz display")
    }
  }

  func testPauseClockResetAndRateChangesDoNotCatchUp() {
    var cadence = MonitorRefreshCadence()
    XCTAssertTrue(cadence.isDue(at: 10, maximumHz: 15))
    cadence.didRefresh(at: 10)
    XCTAssertFalse(cadence.isDue(at: 10.02, maximumHz: 30))
    XCTAssertTrue(cadence.isDue(at: 10.04, maximumHz: 30))
    XCTAssertFalse(cadence.isDue(at: 10.04, maximumHz: 10))
    XCTAssertTrue(cadence.isDue(at: 100, maximumHz: 15))
    cadence.didRefresh(at: 100)
    XCTAssertFalse(cadence.isDue(at: 100.001, maximumHz: 15))
    XCTAssertTrue(cadence.isDue(at: 0, maximumHz: 15))
    XCTAssertFalse(cadence.isDue(at: .nan, maximumHz: 15))
  }
}
