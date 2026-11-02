// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import MonitorKit
import MonitorKitCore

final class ColourCurveMetadataTests: XCTestCase {
  func testLogCurveShaderMetadataRoundTripsEverySupportedCurve() {
    for curve in LogCurve.allCases {
      XCTAssertEqual(MonitorPass.logCurve(MonitorPass.logCurveCode(curve)), curve)
    }
  }

  func testDisplayTransferShaderMetadataRoundTripsEverySupportedTransfer() {
    for transfer in DisplayTransfer.allCases {
      XCTAssertEqual(MonitorPass.displayTransfer(MonitorPass.transferCode(.display(transfer))), transfer)
    }
  }

  func testUnknownCurveMetadataIsRejected() {
    XCTAssertNil(MonitorPass.logCurve(0))
    XCTAssertNil(MonitorPass.logCurve(10))
    XCTAssertNil(MonitorPass.logCurve(UInt32.max))
  }

  func testLogEncodingProfileRoundTripsCurveAndTransport() throws {
    let original = LogEncoding(curve: .arriLogC4, gamut: .arriWideGamut4, transport: .fullRescaledToLegal)
    let data = try JSONEncoder().encode(original)
    XCTAssertEqual(try JSONDecoder().decode(LogEncoding.self, from: data), original)
    XCTAssertEqual(try XCTUnwrap(LogEncoding(profileID: XCTUnwrap(original.profileID), transport: original.transport)), original)
  }
}
