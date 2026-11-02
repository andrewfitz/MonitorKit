// Fixture uses the capture envelope registration schema from CPUMemoryPixelFormatRegistration.
import CoreVideo
import Foundation
import MonitorKit

/// Process-wide Core Video registration is serialized and only fills missing
/// descriptions. An existing incompatible physical layout is an explicit error.
enum RawCVFixtureRegistration {
  private static let lock = NSLock()
  static func ensure(_ type: OSType) throws {
    try lock.withLock {
      let baseType: OSType
      switch type {
      case 0x49343230: baseType = kCVPixelFormatType_420YpCbCr8Planar
      case 0x50323136, 0x50413136: baseType = kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
      case 0x55595641: baseType = kCVPixelFormatType_422YpCbCr8
      default: return
      }
      guard let base = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, baseType) as? [String: Any] else { throw MonitorKitError.invalidFrame("Unsupported test CV registration") }
      var expected = base
      expected[kCVPixelFormatConstant as String] = type
      if type == 0x50413136 {
        var planes = base[kCVPixelFormatPlanes as String] as! [[String: Any]]
        planes.append([kCVPixelFormatBitsPerBlock as String: 16,
          kCVPixelFormatBlackBlock as String: Data([255, 255])])
        expected[kCVPixelFormatPlanes as String] = planes
        expected[kCVPixelFormatContainsAlpha as String] = true
      } else if type == 0x55595641 {
        // UYVY packed pairs followed by a full-resolution byte alpha plane.
        expected[kCVPixelFormatPlanes as String] = [
          [kCVPixelFormatBitsPerBlock as String: 32, kCVPixelFormatBlockWidth as String: 2,
           kCVPixelFormatHorizontalSubsampling as String: 1, kCVPixelFormatVerticalSubsampling as String: 1,
           kCVPixelFormatBlackBlock as String: Data([128, 16, 128, 16])],
          [kCVPixelFormatBitsPerBlock as String: 8, kCVPixelFormatBlackBlock as String: Data([255])]]
        for key in [kCVPixelFormatBitsPerBlock, kCVPixelFormatBlockWidth,
          kCVPixelFormatHorizontalSubsampling, kCVPixelFormatVerticalSubsampling, kCVPixelFormatBlackBlock] {
          expected.removeValue(forKey: key as String)
        }
        expected[kCVPixelFormatContainsAlpha as String] = true
      }
      if let existing = CVPixelFormatDescriptionCreateWithPixelFormatType(nil, type) as? [String: Any] {
        // Compatibility is structural: ignore optional platform rendering hints.
        for key in [kCVPixelFormatBitsPerComponent, kCVPixelFormatContainsAlpha, kCVPixelFormatPlanes] {
          guard NSDictionary(dictionary: ["v": existing[key as String] ?? NSNull()]) ==
            NSDictionary(dictionary: ["v": expected[key as String] ?? NSNull()]) else {
            throw MonitorKitError.invalidFrame("Unsupported test CV registration")
          }
        }
        return
      }
      CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(expected as CFDictionary, type)
    }
  }
}
