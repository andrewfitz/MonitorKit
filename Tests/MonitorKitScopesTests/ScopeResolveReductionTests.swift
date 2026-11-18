// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// Freeze the original order: curve each source bin, then take the footprint maximum.
/// Compare float output exactly, before trace texture quantization or fragment shading.
final class ScopeResolveReductionTests: XCTestCase {
  func testResolveMatchesPerBinCurveReference() throws {
    let (device, _, engine) = try GPU.require()
    let library = try MonitorShaders.makeLibrary(
      device: device, parts: [.lut, .decode], prefix: ScopeEngine.specializationPrefix,
      extra: ScopeEngine.scopeSource() + Self.referenceSource)
    let reference = try device.makeComputePipelineState(
      function: XCTUnwrap(library.makeFunction(name: "mk_referenceScopeResolve")))
    var random = SeededRandom(81)
    let counts = (0..<(3 * 64 * 64)).map { i -> UInt32 in
      i % 11 == 0 ? 0 : (i % 13 == 0 ? 65535 : UInt32(random.int(0...17000)))
    }
    let packed = stride(from: 0, to: counts.count, by: 2).map { counts[$0] | (counts[$0 + 1] << 16) }
    let bins = try counts.withUnsafeBytes {
      try XCTUnwrap(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared))
    }
    let packedBins = try packed.withUnsafeBytes {
      try XCTUnwrap(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared))
    }
    var statistics = [UInt32](repeating: 0, count: ScopeStatisticsWord.slotWords)
    statistics[ScopeStatisticsWord.peakAll] = counts.max()!
    let stats = try statistics.withUnsafeBytes {
      try XCTUnwrap(device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared))
    }
    for kind in UInt32(0)...2 {
      for curve in UInt32(0)...1 {
        for gain in [Float(0.0001), 0.05, 1, 20] {
          for variant in 0..<6 {
            let channels: UInt32 = kind == 1 ? 1 : 3
            let sourceRows: UInt32 = kind == 2 ? 1 : 64
            let reduced = variant < 4
            let sourceColumns: UInt32 = kind == 0 && variant % 2 != 0 ? 37 : 64
            let width: UInt32 = reduced ? 13 : sourceColumns
            let height: UInt32 = reduced ? min(7, sourceRows) : sourceRows
            var p = ScopeResolveParameters()
            p.shape = SIMD4(kind, channels, kind == 0 && variant % 2 == 0 ? 1 : 0, 0)
            p.bins = SIMD4(64, sourceRows, kind == 0 ? (variant % 2 == 0 ? 197 : 37) : 0, 103)
            p.size = SIMD4(width, height, sourceColumns, sourceRows)
            p.intensity = SIMD4(gain, Float(curve), gain, Float(curve))
            p.reduce = SIMD4(reduced ? width : 0, reduced && sourceRows > 1 ? height : 0,
              kind == 0 && variant >= 2 && reduced ? 3 : 1, kind == 1 ? 1 : 0)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
              pixelFormat: .rgba32Float, width: Int(width), height: Int(height), mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            let actual = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let expected = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            try GPU.run { cb in
              for (pipeline, texture) in [(engine.resolvePipeline, actual), (reference, expected)] {
                let encoder = try XCTUnwrap(cb.makeComputeCommandEncoder())
                encoder.setComputePipelineState(pipeline)
                encoder.setBytes(&p, length: MemoryLayout<ScopeResolveParameters>.stride, index: 0)
                encoder.setBuffer(p.shape.z != 0 ? packedBins : bins, offset: 0, index: 1)
                encoder.setBuffer(stats, offset: 0, index: 2)
                encoder.setTexture(texture, index: 0)
                encoder.dispatchThreads(MTLSize(width: Int(width), height: Int(height), depth: 1),
                  threadsPerThreadgroup: MTLSize(width: 8, height: 4, depth: 1))
                encoder.endEncoding()
              }
            }
            XCTAssertTrue(rawBytes(actual) == rawBytes(expected),
              "kind \(kind), curve \(curve), gain \(gain), variant \(variant)")
          }
        }
      }
    }
  }

  private static let referenceSource = """
    inline float4 mk_referenceTraceTexel(constant mk_ScopeResolve& r, device const uint* bins, float peak, uint2 xy, uint k0,
                                uint k1) {
      uint columns = r.bins.x, rows = r.bins.y;
      float4 v = float4(0);
      if (r.shape.x == MK_SCOPE_HISTOGRAM) {
        for (uint k = k0; k < k1; k++) {
          float count = float(bins[k * columns + xy.x]);
          float h = r.intensity.w != 0 ? log(1 + count) / log(1 + peak) : count / peak;
          v[k] = min(1.0f, h * r.intensity.z);
        }
        return v;
      }
      uint column = xy.x;
      float weight = 1;
      uint fw = r.bins.z;
      if (fw != 0 && fw < columns) {
        column = xy.x * columns / fw;
      } else if (fw != 0) {
        weight = 1.0f / float(max(mk_frameColumns(column, columns, fw), 1u));
      }
      bool packed = r.shape.z != 0;
      for (uint k = k0; k < k1; k++) {
        float count = float(mk_binCount(bins, (k * rows + xy.y) * columns + column, packed));
        v[k] = mk_scopeIntensity(count * weight * r.intensity.x, uint(r.intensity.y));
      }
      return v;
    }

    kernel void mk_referenceScopeResolve(constant mk_ScopeResolve& r [[buffer(0)]], device const uint* bins [[buffer(1)]],
                                device const uint* stats [[buffer(2)]],
                                texture2d<float, access::write> trace [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= r.size.x || gid.y >= r.size.y) return;
      // One scale for every histogram channel, so their heights compare.
      float peak = r.shape.x == MK_SCOPE_HISTOGRAM ? float(max(stats[r.shape.w + MK_ST_PEAK_ALL], 1u)) : 1;
      uint2 n = r.size.zw;
      uint W = r.reduce.x, centred = r.reduce.w;
      uint2 ry = r.reduce.y != 0 ? mk_footprint(gid.y, r.reduce.y, n.y, centred) : uint2(gid.y, gid.y + 1);
      float4 v = float4(0);
      if (W != 0 && r.reduce.z == 3) {
        for (uint k = 0; k < 3; k++) {
          uint start = mk_panelStart(k, W), P = (k == 2 ? W : mk_panelStart(k + 1, W)) - start;
          if (gid.x >= P) continue;
          uint2 rx = mk_footprint(gid.x, P, n.x, centred);
          for (uint y = ry.x; y < ry.y; y++)
            for (uint x = rx.x; x < rx.y; x++) v[k] = max(v[k], mk_referenceTraceTexel(r, bins, peak, uint2(x, y), k, k + 1)[k]);
        }
      } else {
        uint2 rx = W != 0 ? mk_footprint(gid.x, W, n.x, centred) : uint2(gid.x, gid.x + 1);
        for (uint y = ry.x; y < ry.y; y++)
          for (uint x = rx.x; x < rx.y; x++) v = max(v, mk_referenceTraceTexel(r, bins, peak, uint2(x, y), 0, r.shape.y));
      }
      trace.write(v, gid);
    }

    """
}
