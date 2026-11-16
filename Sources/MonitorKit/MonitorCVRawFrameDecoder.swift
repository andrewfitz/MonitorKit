// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import IOSurface
import Metal

/// Render-queue adapter for raw SDK layouts delivered in immutable IOSurface CV
/// envelopes. Native texture views are copied on the GPU into owned byte storage;
/// no CPU pixel access or VM-page overreach is needed.
public final class MonitorCVRawFrameDecoder {
  public let device: MTLDevice
  public let residency: MonitorResidency
  private let decoder: MonitorRawFrameDecoder

  public init(device: MTLDevice, residency: MonitorResidency) throws {
    self.device = device; self.residency = residency
    decoder = try MonitorRawFrameDecoder(device: device)
  }

  public static func format(for type: OSType) -> MonitorRawPixelFormat? {
    switch type {
    case 0x72323130: return .r210
    case 0x5231324c: return .r12l
    case 0x50323136: return .p216
    case 0x55595641: return .uyva
    case 0x49343230: return .i420
    case 0x50413136: return .pa16
    default: return nil
    }
  }

  /// Encodes unpacking before the monitor's next pass in the same submission.
  /// Keep the returned frame through feedback; it owns the CV envelope, whose
  /// capture storage attachment owns the vendor lease. A held frame remains
  /// resident until its last user drops it, then retires after observed GPU use.
  public func frame(
    _ image: CVPixelBuffer, signal: SignalDescription, geometry: MonitorFrameGeometry? = nil,
    submission: MonitorSubmission
  ) throws -> MonitorFrame {
    let type = CVPixelBufferGetPixelFormatType(image)
    guard let format = Self.format(for: type) else { throw MonitorKitError.unsupportedPixelFormat(type) }
    guard let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
      throw MonitorKitError.invalidFrame("Raw monitor input requires an owned IOSurface.")
    }
    let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
    if let geometry, geometry.width != width || geometry.height != height {
      throw MonitorKitError.invalidFrame(
        "the geometry is \(geometry.width)×\(geometry.height), the pixel buffer \(width)×\(height)")
    }
    guard width > 0, height > 0, width <= Int(UInt32.max) / 8, height <= Int(UInt32.max) else {
      throw MonitorKitError.invalidFrame("Invalid raw monitor dimensions.")
    }
    let planar = CVPixelBufferIsPlanar(image)
    let count = CVPixelBufferGetPlaneCount(image)
    let expected = format == .i420 || format == .pa16 ? 3 : format == .p216 || format == .uyva ? 2 : 0
    guard count == expected, planar == (expected > 0) else {
      throw MonitorKitError.invalidFrame("Raw monitor CV plane declaration does not match its FourCC.")
    }
    var sources = [MTLTexture](), offsets = [Int](), strides = [Int]()
    var total = 0
    for plane in 0..<max(1, count) {
      let pixelFormat: MTLPixelFormat
      let texWidth: Int, rows: Int, bytesPerPixel: Int
      switch format {
      case .r210: pixelFormat = .rgba8Uint; texWidth = width; rows = height; bytesPerPixel = 4
      case .r12l:
        // Eight unchanged packed bytes per texel keep every admitted video
        // width (through 16,384) below the 16,384-texel limit. Copy the padded
        // final texel; unpacking reads only ceil(width*36/8) native bytes.
        pixelFormat = .rgba16Uint; texWidth = ((width * 36 + 7) / 8 + 7) / 8
        rows = height; bytesPerPixel = 8
      case .uyva:
        pixelFormat = plane == 0 ? .rgba8Uint : .r8Uint
        texWidth = plane == 0 ? width / 2 : width; rows = height; bytesPerPixel = plane == 0 ? 4 : 1
      case .i420:
        pixelFormat = .r8Uint; texWidth = plane == 0 ? width : (width + 1) / 2
        rows = plane == 0 ? height : (height + 1) / 2; bytesPerPixel = 1
      case .p216, .pa16:
        pixelFormat = plane == 1 ? .rg16Uint : .r16Uint
        texWidth = plane == 1 ? (width + 1) / 2 : width; rows = height; bytesPerPixel = plane == 1 ? 4 : 2
      default: throw MonitorKitError.unsupportedPixelFormat(type)
      }
      let physicalStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, plane) : CVPixelBufferGetBytesPerRow(image)
      let logicalBytes = texWidth * bytesPerPixel
      guard logicalBytes <= physicalStride else { throw MonitorKitError.invalidFrame("Raw monitor CV row is truncated.") }
      if planar {
        let cvWidth = format == .uyva && plane == 0 ? width : texWidth
        guard CVPixelBufferGetWidthOfPlane(image, plane) == cvWidth,
          CVPixelBufferGetHeightOfPlane(image, plane) == rows else {
          throw MonitorKitError.invalidFrame("Raw monitor CV plane dimensions are inconsistent.")
        }
      }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: texWidth, height: rows, mipmapped: false)
      descriptor.storageMode = .shared; descriptor.usage = .shaderRead
      guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane) else {
        throw MonitorKitError.invalidFrame("Raw monitor IOSurface does not support its native texture view.")
      }
      let stride = ((logicalBytes + 255) / 256) * 256
      let (bytes, overflow) = stride.multipliedReportingOverflow(by: rows)
      guard !overflow, bytes <= Int(UInt32.max), total <= Int(UInt32.max) - bytes else {
        throw MonitorKitError.invalidFrame("Raw monitor GPU staging size overflows.")
      }
      sources.append(texture); offsets.append(total); strides.append(stride); total += bytes
    }
    guard let input = device.makeBuffer(length: total, options: .storageModePrivate),
      let copy = submission.commandBuffer.makeComputeCommandEncoder() else {
      throw MonitorKitError.gpu("Raw monitor GPU staging allocation or encoder unavailable.")
    }
    residency.observe(submission)
    // Under the residency's lock: a completion on another thread removes from the same set.
    residency.withSet { set in
      set.addAllocation(input)
      for source in sources { set.addAllocation(source) }
      set.commit()
    }
    for (plane, source) in sources.enumerated() {
      copy.copy(sourceTexture: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: source.width, height: source.height, depth: 1), destinationBuffer: input,
        destinationOffset: offsets[plane], destinationBytesPerRow: strides[plane], destinationBytesPerImage: 0)
    }
    copy.endEncoding()
    // Alpha storage remains retained and validated even though v1 ignores it.
    if format == .uyva { offsets.removeLast(); strides.removeLast() }
    var made: MonitorRawFrameDecoder.Encoding?
    var failure: (any Error)?
    // The decoder adds its own allocations to the set, so its encode holds the lock too.
    residency.withSet { set in
      do {
        made = try decoder.encode(input: input, format: format, width: width, height: height,
          offsets: offsets, strides: strides, signal: signal, commandBuffer: submission.commandBuffer, residency: set)
        set.commit()
      } catch {
        failure = error
      }
    }
    guard let encoded = made else {
      residency.retire(image, resident: nil)
      residency.retire(input, resident: input)
      for source in sources { residency.retire(source, resident: source) }
      throw failure ?? MonitorKitError.gpu("Raw monitor decode failed.")
    }
    let owner = Ownership(image: image, encoded: encoded, sources: sources, residency: residency)
    let g = geometry ?? MonitorFrame.geometry(of: image)
    return try MonitorFrame(layout: encoded.frame.layout, width: width, height: height,
      packed: encoded.frame.packed, luma: encoded.frame.luma, chroma: encoded.frame.chroma,
      signal: signal, pixelAspectRatio: g.pixelAspectRatio, retained: (owner, nil), cleanAperture: g.cleanAperture)
  }

  private final class Ownership {
    let image: CVPixelBuffer
    let encoded: MonitorRawFrameDecoder.Encoding
    let sources: [MTLTexture]
    let residency: MonitorResidency
    init(image: CVPixelBuffer, encoded: MonitorRawFrameDecoder.Encoding, sources: [MTLTexture], residency: MonitorResidency) {
      self.image = image; self.encoded = encoded; self.sources = sources; self.residency = residency
    }
    deinit {
      residency.retire(image, resident: nil)
      for source in sources { residency.retire(source, resident: source) }
      for allocation in encoded.allocations { residency.retire(allocation, resident: allocation) }
      residency.retire(encoded.arguments, resident: nil)
    }
  }
}
