// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Metal
import Synchronization
import XCTest
@testable import MonitorKit

final class RawCVFrameDecoderTests: XCTestCase {
  private func buffer(_ type: OSType, width: Int = 16) throws -> CVPixelBuffer {
    try RawCVFixtureRegistration.ensure(type)
    var result: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, 2, type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
    return try XCTUnwrap(result)
  }

  func testRegisteredCaptureCVEnvelopesReachMonitorOutputOnMetal4() throws {
    let host = try TestMTL4.shared.get()
    let decoder = try MonitorCVRawFrameDecoder(device: host.gpu.device, residency: host.gpu.engine.residency)
    for type: OSType in [0x72323130, 0x5231324c, 0x50323136, 0x55595641, 0x49343230, 0x50413136] {
      let image = try buffer(type)
      CVPixelBufferLockBaseAddress(image, [])
      let planar = CVPixelBufferIsPlanar(image)
      let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0)! : CVPixelBufferGetBaseAddress(image)!
      let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
      for row in 0..<2 {
        let bytes = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<16 {
          switch type {
          case 0x72323130:
            // Legal-range neutral 10-bit RGB, black then white.
            let c: UInt32 = x < 8 ? 64 : 940
            let word = c << 20 | c << 10 | c
            for n in 0..<4 { bytes[x*4+n] = UInt8(truncatingIfNeeded: word >> ((3-n)*8)) }
          case 0x5231324c:
            // Full-range R12l, dense 36-bit pixels; alternating extremes.
            let code = x < 8 ? 0 : 4095
            for c in 0..<3 { for bit in 0..<12 {
              let position = x * 36 + c * 12 + bit
              let mask = UInt8(1 << (position%8))
              if code & (1 << bit) != 0 { bytes[position/8] |= mask }
              else { bytes[position/8] &= ~mask }
            } }
          case 0x50323136, 0x50413136:
            let code: UInt16 = x < 8 ? 4096 : 60160
            bytes[x*2] = UInt8(truncatingIfNeeded: code); bytes[x*2+1] = UInt8(code >> 8)
          case 0x55595641:
            bytes[x*2] = 128; bytes[x*2+1] = x < 8 ? 16 : 235
          default: bytes[x] = x < 8 ? 16 : 235
          }
        }
      }
      if planar {
        for plane in 1..<CVPixelBufferGetPlaneCount(image) {
          let pointer = CVPixelBufferGetBaseAddressOfPlane(image, plane)!.assumingMemoryBound(to: UInt8.self)
          let rows = CVPixelBufferGetHeightOfPlane(image, plane)
          let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
          for row in 0..<rows { for byte in 0..<rowBytes {
            pointer[row*rowBytes+byte] = type == 0x50323136 || type == 0x50413136 ? (byte.isMultiple(of: 2) ? 0 : 128) : 128
          } }
        }
      }
      CVPixelBufferUnlockBaseAddress(image, [])
      let signal = SignalDescription(range: type == 0x5231324c ? .full : .legal)
      let target = host.target(16, 2, usage: [.shaderWrite, .shaderRead])
      let pass = host.gpu.engine.makePass(), feed = host.gpu.engine.makeFeed()
      var frame: MonitorFrame?
      try host.run { submission in
        frame = try decoder.frame(image, signal: signal, submission: submission)
        try pass.encodeCompute(frame: frame!, feed: feed, state: MonitorState(), target: target, into: submission)
      }
      var pixels = [SIMD4<Float>](repeating: .zero, count: 32)
      pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16*16,
        from: MTLRegionMake2D(0, 0, 16, 2), mipmapLevel: 0) }
      for x in 0..<16 {
        for channel in 0..<3 { XCTAssertEqual(pixels[x][channel], x < 8 ? 0 : 1, accuracy: 0.00003, "\(type)") }
      }
      frame = nil
      host.gpu.engine.residency.release(through: host.completedIndex)
    }
  }

  func testDecodedPlaneStaysResidentUntilBothOwnersRetire() throws {
    let host = try requireMTL4()
    let residency = try MonitorResidency(device: host.gpu.device)
    host.queue.addResidencySet(residency.set)
    defer { host.queue.removeResidencySet(residency.set) }
    let decoder = try MonitorCVRawFrameDecoder(device: host.gpu.device, residency: residency)
    let image = try buffer(0x72323130)
    var frame: MonitorFrame?
    try host.run { frame = try decoder.frame(image, signal: .rec709, submission: $0) }
    let plane = try XCTUnwrap(frame?.luma)
    XCTAssertTrue(residency.contains(plane))
    XCTAssertEqual(residency.commitCount, 1)
    residency.add(plane)
    frame = nil
    residency.release(through: host.completedIndex)
    XCTAssertTrue(residency.contains(plane))
    XCTAssertEqual(residency.set.allocationCount, 1, "copy and decoder staging have retired")
    residency.retire(plane, resident: plane)
    XCTAssertEqual(residency.set.allocationCount, 0)
  }

  func testOddPacked422IsRejectedBeforeStaging() throws {
    let host = try requireMTL4()
    let residency = try MonitorResidency(device: host.gpu.device)
    let decoder = try MonitorCVRawFrameDecoder(device: host.gpu.device, residency: residency)
    for width in [1, 3] {
      let image = try buffer(0x55595641, width: width)
      XCTAssertEqual(CVPixelBufferGetWidth(image), width)
      try host.run { submission in
        XCTAssertThrowsError(try decoder.frame(image, signal: .rec709, submission: submission)) { error in
          XCTAssertEqual(error as? MonitorKitError, .invalidFrame("Raw 4:2:2 frames require an even width."))
        }
      }
      XCTAssertEqual(residency.latestSubmission, 0)
      XCTAssertEqual(residency.commitCount, 0)
    }
  }

  func testGeometryFromAnotherFormatIsRejectedBeforeEncoding() throws {
    let host = try TestMTL4.shared.get()
    let decoder = try MonitorCVRawFrameDecoder(device: host.gpu.device, residency: host.gpu.engine.residency)
    let image = try buffer(0x72323130)
    try host.run { submission in
      for (width, height) in [(8, 2), (16, 4)] {
        XCTAssertThrowsError(try decoder.frame(image, signal: .rec709,
          geometry: MonitorFrameGeometry(width: width, height: height), submission: submission)) { error in
          guard case MonitorKitError.invalidFrame(let reason) = error else {
            return XCTFail("Unexpected error: \(error)")
          }
          XCTAssertTrue(reason.contains("geometry"))
        }
      }
      // A rejected geometry must leave the submission usable for its actual frame.
      let frame = try decoder.frame(image, signal: .rec709,
        geometry: MonitorFrameGeometry(width: 16, height: 2), submission: submission)
      XCTAssertEqual(frame.width, 16)
      XCTAssertEqual(frame.height, 2)
    }
  }

  func testBackToBackGPUCopiesAndMonitorPassesSeeEachFramesColour() throws {
    let host = try TestMTL4.shared.get()
    let decoder = try MonitorCVRawFrameDecoder(device: host.gpu.device, residency: host.gpu.engine.residency)
    let pass = host.gpu.engine.makePass(), feed = host.gpu.engine.makeFeed()
    var images = [CVPixelBuffer](), targets = [MTLTexture](), frames = [MonitorFrame]()
    for index in 0..<16 {
      let image = try buffer(0x72323130)
      CVPixelBufferLockBaseAddress(image, [])
      let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(image)
      let r = UInt32(50 + index*37), g = UInt32(900 - index*29), b = UInt32(100 + index*19)
      let word = r << 20 | g << 10 | b
      for row in 0..<2 { for x in 0..<16 { for byte in 0..<4 {
        base[row*stride+x*4+byte] = UInt8(truncatingIfNeeded: word >> ((3-byte)*8))
      } } }
      CVPixelBufferUnlockBaseAddress(image, [])
      images.append(image); targets.append(host.target(16, 2, usage: [.shaderWrite, .shaderRead]))
    }
    try host.run { submission in
      for (image, target) in zip(images, targets) {
        let frame = try decoder.frame(image, signal: SignalDescription(range: .full), submission: submission)
        frames.append(frame)
        try pass.encodeCompute(frame: frame, feed: feed, state: MonitorState(), target: target, into: submission)
      }
    }
    for (index, target) in targets.enumerated() {
      var output = SIMD4<Float>.zero
      target.getBytes(&output, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
      XCTAssertEqual(output.x, Float(50 + index*37)/1023, accuracy: 2e-6)
      XCTAssertEqual(output.y, Float(900 - index*29)/1023, accuracy: 2e-6)
      XCTAssertEqual(output.z, Float(100 + index*19)/1023, accuracy: 2e-6)
    }
    frames.removeAll()
    host.gpu.engine.residency.release(through: host.completedIndex)
  }

  func testR12L4K8KAndMaximumWidthEdgesAndOddTailReachMonitorOutput() throws {
    let host = try TestMTL4.shared.get()
    let residency = host.gpu.engine.residency
    let decoder = try MonitorCVRawFrameDecoder(device: host.gpu.device, residency: residency)
    for (width, height) in [(3840,2160), (4096,2160), (7680,4320), (8192,4320), (16_384,2), (16_383,2), (8191,2), (1,2)] {
      var made: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, width, height, 0x5231324c,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made), kCVReturnSuccess)
      let image = try XCTUnwrap(made)
      let logicalBytes = (width * 36 + 7) / 8
      XCTAssertLessThanOrEqual((logicalBytes + 7) / 8, 16_384)
      CVPixelBufferLockBaseAddress(image, [])
      let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(image)
      base.initialize(repeating: 0, count: stride * height)
      let xs = Set([0,1,width/2,width-2,width-1].filter { $0 >= 0 && $0 < width })
      let ys = Set([0,height/2,height-1])
      func codes(_ x: Int, _ y: Int) -> [Int] {
        [(x*17+y*13+1)%4096, (x*31+y*7+2047)%4096, (x*19+y*5+4094)%4096]
      }
      for y in ys { for x in xs { for (channel, code) in codes(x,y).enumerated() {
        for bit in 0..<12 where code & (1 << bit) != 0 {
          let position = x*36 + channel*12 + bit
          base[y*stride+position/8] |= UInt8(1 << (position%8))
        }
      } } }
      CVPixelBufferUnlockBaseAddress(image, [])
      let target = host.target(width, height, usage: [.shaderRead, .shaderWrite])
      let pass = host.gpu.engine.makePass(), feed = host.gpu.engine.makeFeed()
      var frame: MonitorFrame?
      try host.run { submission in
        frame = try decoder.frame(image, signal: SignalDescription(range: .full), submission: submission)
        try pass.encodeCompute(frame: frame!, feed: feed, state: MonitorState(), target: target, into: submission)
      }
      for y in ys { for x in xs {
        var output = SIMD4<Float>.zero
        target.getBytes(&output, bytesPerRow: 16, from: MTLRegionMake2D(x,y,1,1), mipmapLevel: 0)
        for (channel, code) in codes(x,y).enumerated() {
          XCTAssertEqual(Int((output[channel]*4095).rounded()), code, "R12l \(width)x\(height) edge \(x),\(y) channel \(channel)")
        }
      } }
      frame = nil
      residency.release(through: host.completedIndex)
      host.host.removeAllocation(target)
      host.host.commit()
    }
  }

  private final class ReleaseState: Sendable { let value = Mutex(false) }
  private final class ReleaseProbe {
    let released: ReleaseState
    init(_ released: ReleaseState) { self.released = released }
    deinit { released.value.withLock { $0 = true } }
  }

  func testCaptureStorageOwnerSurvivesFrameDropUntilGPUFeedback() throws {
    let host = try TestMTL4.shared.get()
    let residency = host.gpu.engine.residency
    let decoder = try MonitorCVRawFrameDecoder(device: host.gpu.device, residency: residency)
    let released = ReleaseState()
    var image: CVPixelBuffer? = try buffer(0x72323130)
    CVBufferSetAttachment(image!, "raw-owner-test" as CFString, ReleaseProbe(released), .shouldNotPropagate)
    let pending = host.begin()
    var frame: MonitorFrame? = try decoder.frame(image!, signal: SignalDescription(), submission: pending.submission)
    XCTAssertNotNil(frame)
    image = nil
    frame = nil
    XCTAssertFalse(released.value.withLock { $0 })
    let done = DispatchSemaphore(value: 0)
    host.commit(pending) { _ in done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    residency.release(through: host.completedIndex)
    XCTAssertTrue(released.value.withLock { $0 })
  }
}
