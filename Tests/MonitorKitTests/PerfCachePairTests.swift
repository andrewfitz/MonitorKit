// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import IOSurface
import Metal
import Synchronization
import XCTest

@testable import MonitorKit

final class PerfCachePairTests: XCTestCase {
  func testPairLookupFindsSeparatedPlanesAndRetagsBoth() throws {
    let gpu = try requireGPU()
    let cache = MonitorTextureCache(device: gpu.device, residency: gpu.engine.residency)
    let buffer = try XCTUnwrap(PictureTests.picture(.nv12, width: 66, height: 38).pixelBuffer(range: .legal))
    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
    let luma = try cache.makeTexture(iosurface: surface, plane: 0, format: .r8Unorm, width: 66, height: 38, now: 1)
    let other = try XCTUnwrap(PictureTests.picture(.bgra8, width: 66, height: 38).pixelBuffer(range: .full))
    _ = try cache.frame(other, owner: 9, now: 1)
    let first = try cache.frame(buffer, owner: 1, now: 1)
    XCTAssertTrue(first.luma === luma)
    let made = cache.texturesMade, commits = gpu.engine.residency.commitCount
    let next = try cache.frame(buffer, owner: 2, now: 1)
    XCTAssertTrue(next.luma === first.luma)
    XCTAssertTrue(next.chroma === first.chroma)
    XCTAssertTrue(next.frozenPlanes === first.frozenPlanes)
    XCTAssertTrue(next.secondPlanes === first.secondPlanes)
    XCTAssertEqual(cache.count(owner: 1), 0)
    XCTAssertEqual(cache.count(owner: 2), 2)
    XCTAssertEqual(cache.texturesMade, made)
    XCTAssertEqual(gpu.engine.residency.commitCount, commits)
    cache.flush(owner: 9)
    let reordered = try cache.frame(buffer, owner: 2, now: 1)
    XCTAssertTrue(reordered.luma === first.luma)
    XCTAssertTrue(reordered.chroma === first.chroma)
  }

  func testDueSweepTouchesBothHitPlanesBeforeRemovingIdleEntries() throws {
    let gpu = try requireGPU()
    let cache = MonitorTextureCache(device: gpu.device, residency: gpu.engine.residency)
    let buffer = try XCTUnwrap(PictureTests.picture(.p010, width: 66, height: 38).pixelBuffer(range: .legal))
    let other = try XCTUnwrap(PictureTests.picture(.bgra8, width: 66, height: 38).pixelBuffer(range: .full))
    let first = try cache.frame(buffer, owner: 1, now: 1)
    _ = try cache.frame(other, owner: 9, now: 1)
    let made = cache.texturesMade
    let next = try cache.frame(buffer, owner: 2, now: 4)
    XCTAssertEqual(cache.count, 2)
    XCTAssertEqual(cache.count(owner: 2), 2)
    XCTAssertEqual(cache.texturesMade, made)
    XCTAssertTrue(next.luma === first.luma)
    XCTAssertTrue(next.chroma === first.chroma)
    XCTAssertFalse(try XCTUnwrap(first.frozenPlanes).released.load(ordering: .sequentiallyConsistent))
    XCTAssertFalse(try XCTUnwrap(first.secondPlanes).released.load(ordering: .sequentiallyConsistent))
    cache.flush(owner: 2)
    XCTAssertTrue(try XCTUnwrap(next.frozenPlanes).released.load(ordering: .sequentiallyConsistent))
    XCTAssertTrue(try XCTUnwrap(next.secondPlanes).released.load(ordering: .sequentiallyConsistent))
  }
}
