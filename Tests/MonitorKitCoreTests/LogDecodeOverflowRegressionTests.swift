import XCTest

@testable import MonitorKitCore

final class LogDecodeOverflowRegressionTests: XCTestCase {
  func testLogDecodersRejectNonfiniteResultsFromFiniteSignals() {
    for curve in LogCurve.allCases {
      XCTAssertNil(curve.decode(Double.greatestFiniteMagnitude), "\(curve)")
      XCTAssertNil(curve.decode(.infinity), "\(curve)")
      XCTAssertNil(curve.decode(-.infinity), "\(curve)")
      XCTAssertNil(curve.decode(.nan), "\(curve)")
      XCTAssertTrue(curve.decode(0)?.isFinite == true, "\(curve)")
      XCTAssertTrue(curve.decode(1)?.isFinite == true, "\(curve)")
    }
  }
}
