// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Metal
import XCTest
@testable import MonitorKit

final class RawFrameDecoderTests: XCTestCase {
  func testEveryVendorByteLayoutRunsThroughGPUAndMonitorDecode() throws {
    let host = try TestMTL4.shared.get()
    let gpu = host.gpu
    let decoder = try MonitorRawFrameDecoder(device: gpu.device)
    for format in MonitorRawPixelFormat.allCases {
      var bytes = [UInt8](repeating: 0xED, count: 256)
      let planar = [.nv12Video, .nv12Full, .p216, .i420, .pa16].contains(format)
      let rgb = [.bgra8, .rgba8, .r210, .r12l].contains(format)
      let signal = SignalDescription(range: rgb || format == .nv12Full || format == .p216 || format == .pa16 ? .full : .legal)
      var expected = [SIMD3<Float>]()
      for row in 0..<2 {
        let start = 16 + row * 32
        switch format {
        case .uyvy8, .uyva:
          bytes.replaceSubrange(start..<start+4, with: [128,16,128,235])
        case .yuyv8:
          bytes.replaceSubrange(start..<start+4, with: [16,128,235,128])
        case .nv12Video, .nv12Full, .i420:
          bytes[start] = format == .nv12Full ? 0 : 16
          bytes[start+1] = format == .nv12Full ? 255 : 235
        case .p216, .pa16:
          bytes[start] = 0; bytes[start+1] = 0
          bytes[start+2] = 255; bytes[start+3] = 255
        case .bgra8, .rgba8:
          bytes.replaceSubrange(start..<start+8, with: [10,20,30,255,40,50,60,255])
        case .r210:
          for (x, codes) in [[100,200,900], [900,50,500]].enumerated() {
            let word = UInt32(codes[0] << 20 | codes[1] << 10 | codes[2])
            for n in 0..<4 { bytes[start+x*4+n] = UInt8(truncatingIfNeeded: word >> ((3-n)*8)) }
          }
        case .r12l:
          for n in 0..<9 { bytes[start+n] = 0 }
          for (index, code) in [1,2050,4094,4000,30,888].enumerated() {
            for bit in 0..<12 where code & (1 << bit) != 0 {
              let position = index * 12 + bit
              bytes[start+position/8] |= UInt8(1 << (position%8))
            }
          }
        }
        if !rgb { expected += [.zero, SIMD3(repeating: 1)] }
        else if format == .r210 { expected += [SIMD3(100,200,900)/1023, SIMD3(900,50,500)/1023] }
        else if format == .r12l { expected += [SIMD3(1,2050,4094)/4095, SIMD3(4000,30,888)/4095] }
        else if format == .bgra8 { expected += [SIMD3(30,20,10)/255, SIMD3(60,50,40)/255] }
        else { expected += [SIMD3(10,20,30)/255, SIMD3(40,50,60)/255] }
      }
      if planar {
        for row in 0..<(format == .p216 || format == .pa16 ? 2 : 1) {
          let start = 96 + row * 16
          if format == .p216 || format == .pa16 { bytes.replaceSubrange(start..<start+4, with: [0,128,0,128]) }
          else { bytes[start] = 128; bytes[start+1] = 128; if format == .i420 { bytes[160] = 128 } }
        }
      }
      let input = try XCTUnwrap(gpu.device.makeBuffer(bytes: bytes, length: bytes.count))
      var encoded: MonitorRawFrameDecoder.Encoding?
      try host.run { submission in
        encoded = try decoder.encode(input: input, format: format, width: 2, height: 2,
          offsets: format == .i420 || format == .pa16 ? [16,96,160] : planar ? [16,96] : [16],
          strides: format == .i420 || format == .pa16 ? [32,16,16] : planar ? [32,16] : [32], signal: signal,
          commandBuffer: submission.commandBuffer, residency: host.host)
        host.host.commit()
      }
      let result = try XCTUnwrap(encoded)
      let pixels = gpu.decode(result.frame)
      for (pixel, reference) in zip(pixels, expected) {
        for channel in 0..<3 { XCTAssertEqual(pixel[channel], reference[channel], accuracy: 0.00002, "\(format)") }
      }
      if format == .r12l { XCTAssertEqual(result.frame.layout, .rgb(bitDepth: 12, float: false)) }
      for allocation in result.allocations { host.host.removeAllocation(allocation) }
      host.host.commit()
    }
  }

  func testExistingCVFormatsMapIntoMonitorTexturesAndDecodeOnGPU() throws {
    let gpu = try requireGPU()
    let cache = MonitorTextureCache(device: gpu.device, residency: gpu.engine.residency)
    let cases: [(PixelLayout, CodeRange)] = [
      (.uyvy8, .legal), (.yuyv8, .legal), (.nv12, .legal), (.nv12, .full), (.bgra8, .full)
    ]
    for (layout, range) in cases {
      let picture = SyntheticFrame.random(layout, width: 48, height: 4, seed: 72)
      let buffer = try XCTUnwrap(picture.pixelBuffer(range: range))
      let signal = SignalDescription(range: range)
      let frame = try cache.frame(buffer, signal: signal)
      let output = gpu.decode(frame)
      for (pixel, reference) in zip(output, picture.reference(signal)) {
        for channel in 0..<3 { XCTAssertEqual(Double(pixel[channel]), reference.rgb[channel], accuracy: 2e-6) }
      }
    }
    var made: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 16, 2, kCVPixelFormatType_32RGBA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
    // This macOS does not expose IOSurface-backed RGBA. Its vendor-memory GPU
    // route is exercised above; never pretend this CV route was qualified.
    if status == kCVReturnInvalidPixelFormat {
      XCTAssertNil(made)
      return
    }
    XCTAssertEqual(status, kCVReturnSuccess)
    let rgba = try XCTUnwrap(made)
    CVPixelBufferLockBaseAddress(rgba, [])
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(rgba)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(rgba)
    for row in 0..<2 { for x in 0..<16 {
      for (c, code) in [31,127,233,255].enumerated() { bytes[row*stride+x*4+c] = UInt8(code) }
    } }
    CVPixelBufferUnlockBaseAddress(rgba, [])
    let frame = try cache.frame(rgba)
    for pixel in gpu.decode(frame) {
      XCTAssertEqual(pixel.x, 31.0/255, accuracy: 2e-6)
      XCTAssertEqual(pixel.y, 127.0/255, accuracy: 2e-6)
      XCTAssertEqual(pixel.z, 233.0/255, accuracy: 2e-6)
    }
  }

  func testTwelveBitRGBRetainsEveryNativeCodeWithoutSubsampling() throws {
    let host = try TestMTL4.shared.get()
    let decoder = try MonitorRawFrameDecoder(device: host.gpu.device)
    let width = 4096
    var bytes = [UInt8](repeating: 0, count: width * 36 / 8)
    for x in 0..<width { for channel in 0..<3 {
      let code = (x + channel * 137) % 4096
      for bit in 0..<12 where code & (1 << bit) != 0 {
        let position = x * 36 + channel * 12 + bit
        bytes[position/8] |= UInt8(1 << (position%8))
      }
    } }
    let input = try XCTUnwrap(host.gpu.device.makeBuffer(bytes: bytes, length: bytes.count))
    var encoded: MonitorRawFrameDecoder.Encoding?
    try host.run { submission in
      encoded = try decoder.encode(input: input, format: .r12l, width: width, height: 1,
        strides: [bytes.count], signal: SignalDescription(range: .full),
        commandBuffer: submission.commandBuffer, residency: host.host)
      host.host.commit()
    }
    let result = try XCTUnwrap(encoded)
    let pixels = host.gpu.decode(result.frame)
    for x in 0..<width { for channel in 0..<3 {
      XCTAssertEqual(Int((pixels[x][channel] * 4095).rounded()), (x + channel * 137) % 4096)
    } }
    for allocation in result.allocations { host.host.removeAllocation(allocation) }
    host.host.commit()
  }

  func testTruncatedRawPlanesFailBeforeEncoding() throws {
    let host = try TestMTL4.shared.get()
    let decoder = try MonitorRawFrameDecoder(device: host.gpu.device)
    let input = try XCTUnwrap(host.gpu.device.makeBuffer(length: 16))
    let command = try XCTUnwrap(host.gpu.device.makeCommandBuffer())
    let allocator = try XCTUnwrap(host.gpu.device.makeCommandAllocator())
    command.beginCommandBuffer(allocator: allocator)
    for format in MonitorRawPixelFormat.allCases {
      XCTAssertThrowsError(try decoder.encode(input: input, format: format, width: 4, height: 4,
        strides: [1], signal: SignalDescription(), commandBuffer: command, residency: host.host))
    }
    command.endCommandBuffer()
  }
}
