// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import MonitorKitCore

final class Fresh02FalseColorBoundaryTests: XCTestCase {
  func testNormalizedNeutralRGBHonorsEveryARRITableBoundary() throws {
    // ARRI False Color specification 2025-02-04 eqs. (1)/(2), Tables 9/25.
    // Exercise the RGB entry point, not just the direct code classifier.
    for profile in ARRIFalseColorProfile.allCases {
      for range in [CodeRange.legal, .full] {
        for zone in profile.zones(range: range) {
          let lower = try XCTUnwrap(range.normalizeLuma(code: zone.lower, bitDepth: 10))
          let upper = try XCTUnwrap(range.normalizeLuma(code: zone.upper, bitDepth: 10))
          for value in [lower, upper.nextDown] {
            let neutral = ColorRGB(r: value, g: value, b: value)
            XCTAssertEqual(profile.color(rgb: neutral, range: range), zone.category.color,
                           "\(profile) \(range) \(zone.category) at \(value)")
          }
          for value in [lower.nextDown, upper] {
            let neutral = ColorRGB(r: value, g: value, b: value)
            XCTAssertNotEqual(profile.color(rgb: neutral, range: range), zone.category.color,
                              "\(profile) \(range) \(zone.category) at \(value)")
          }
        }
      }
    }
  }

  func testNeutralARRIFallbackRetainsExactInputOutsideTables() {
    for profile in ARRIFalseColorProfile.allCases {
      for range in [CodeRange.legal, .full] {
        for value in [-0.1, 1.0, 1.1] {
          let neutral = ColorRGB(r: value, g: value, b: value)
          XCTAssertEqual(profile.color(rgb: neutral, range: range), neutral)
        }
      }
    }
  }
}
