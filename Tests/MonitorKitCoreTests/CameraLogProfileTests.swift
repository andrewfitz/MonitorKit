import XCTest
@testable import MonitorKitCore

final class CameraLogProfileTests: XCTestCase {
  func testPublishedREDMappingValues() throws {
    // RED 915-0187 Rev C p.5; codes rounded to six decimals.
    for (code, linear) in [(0.0, -0.01), (0.091551, 0.0), (0.333333, 0.18), (0.493449, 1.0)] {
      XCTAssertEqual(try XCTUnwrap(LogCurve.redLog3G10.decode(code)), linear, accuracy: 0.00001)
    }
    XCTAssertEqual(try XCTUnwrap(LogCurve.redLog3G10.decode(-0.151927)), -0.02, accuracy: 1e-10)
  }
  func testPublishedBlackmagicMappingValues() throws {
    // Blackmagic Generation 5 Color Science, May 2021 p.3.
    for (code, linear) in [(0.0924657534246575, 0.0), (0.3835616438356165, 0.18),
                            (0.5304896249573048, 1.0), (0.7302219538415439, 10.0),
                            (0.9303398518999735, 100.0)] {
      XCTAssertEqual(try XCTUnwrap(LogCurve.blackmagicFilmGen5.decode(code)), linear, accuracy: 1e-10)
    }
  }
  func testPublishedPanasonicMappingValues() throws {
    // V-Log/V-Gamut Reference Manual rev1 p.3: 128,433,602 at 0,18,90%.
    for (code, reflection) in [(128.0, 0.0), (433.0, 0.18), (602.0, 0.90)] {
      XCTAssertEqual(try XCTUnwrap(LogCurve.vLog.decode(code / 1023)), reflection, accuracy: 0.004)
    }
  }
  func testPublishedCanonGreyAndWhite() throws {
    // Canon Appendix [4], full 10-bit codes rounded to integers; reflection is
    // 0.9 × Canon's scene-linear exposure, so its 20% means an 18% grey card.
    for (curve, grey, white) in [(LogCurve.canonLog, 351.0, 614.0), (.canonLog2, 407, 575), (.canonLog3, 351, 577)] {
      XCTAssertEqual(try XCTUnwrap(curve.decode(grey / 1023)), 0.18, accuracy: 0.002)
      XCTAssertEqual(try XCTUnwrap(curve.decode(white / 1023)), 0.90, accuracy: 0.006)
      XCTAssertNil(curve.decode(.nan))
    }
  }
  func testProfileRoundTripsAndUnknownProfileRefusal() throws {
    let ids = ["canon-log-cinemagamut", "canon-log2-cinemagamut", "canon-log3-cinemagamut",
      "panasonic-vlog-vgamut", "blackmagic-film-gen5-widegamut", "red-log3g10-widegamutrgb"]
    for id in ids {
      let profile = try XCTUnwrap(LogEncoding(profileID: id))
      XCTAssertEqual(profile.profileID, id)
      XCTAssertEqual(try JSONDecoder().decode(LogEncoding.self, from: JSONEncoder().encode(profile)), profile)
    }
    XCTAssertNil(LogEncoding(profileID: "future-unknown-log"))
    XCTAssertNil(LogEncoding(curve: .arriLogC3, gamut: .rec709).profileID)
  }
  func testPublishedGamutMatrixVectors() {
    // Primary-document XYZ columns, rounded to six decimals.
    let vectors: [(ColorGamut, ColorRGB)] = [
      (.vGamut, ColorRGB(r: 0.679644, g: 0.260686, b: -0.009310)),
      (.redWideGamutRGB, ColorRGB(r: 0.735275, g: 0.286694, b: -0.079681)),
      (.blackmagicWideGamutGen5, ColorRGB(r: 0.606530, g: 0.267989, b: -0.029442))]
    for (gamut, expected) in vectors {
      let actual = gamut.toXYZ.apply(ColorRGB(r: 1, g: 0, b: 0))
      XCTAssertEqual(actual.r, expected.r, accuracy: 1e-6)
      XCTAssertEqual(actual.g, expected.g, accuracy: 1e-6)
      XCTAssertEqual(actual.b, expected.b, accuracy: 1e-6)
    }
  }
}
