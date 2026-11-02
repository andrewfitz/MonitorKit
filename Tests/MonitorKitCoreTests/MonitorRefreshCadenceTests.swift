// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import MonitorKitCore

final class MonitorRefreshCadenceTests: XCTestCase {
  func testHighRateVideoKeepsScopesWithinSavedCeiling() {
    for hz in [10, 15, 30] {
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
