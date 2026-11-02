import Foundation
import XCTest
@testable import MonitorKitAudio

final class VUOutputRegressionTests: XCTestCase {
  func testFastMovementPublishesCurrentOutputAcrossChunkBoundaries() throws {
    let fs = 8000.0
    let ballistics = VUBallistics(riseTime: 0.001, overshoot: 0.0125)
    let meter = try AudioMeter(configuration: .init(
      sampleRate: fs, channelCount: 1, meters: [.vu], vuReference: .init(dBFS: 0),
      vuBallistics: ballistics, publishInterval: 0))
    let f = vuFilter(ballistics, sampleRate: fs)
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    for count in [1, 3, 257, 2, 511] {
      let input = (0..<count).map { Float(($0 % 7) + 1) / 8 }
      for sample in input {
        let x = Double(sample)
        let y = f.b0 * x + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
      }
      input.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: count) }
      let expected = 20 * log10(max(y1, 0) * Double.pi / 2)
      XCTAssertEqual(Double(meter.snapshot()[0].vu), expected, accuracy: 0.0001)
    }
  }
}
