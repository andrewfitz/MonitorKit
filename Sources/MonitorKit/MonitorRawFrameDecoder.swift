// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal

/// SDK byte layouts which cannot all be represented by Core Video texture views.
public enum MonitorRawPixelFormat: UInt32, Sendable, CaseIterable {
  case uyvy8, yuyv8, uyva, nv12Video, nv12Full, bgra8, rgba8, r210, r12l, p216, i420, pa16
}

/// GPU-only unpacking of a borrowed vendor buffer into MonitorKit's native
/// texture layouts. No matrix, transfer or gamut conversion is performed.
public final class MonitorRawFrameDecoder {
  private let device: MTLDevice
  private let packedPipeline: MTLComputePipelineState
  private let planarPipeline: MTLComputePipelineState
  private let rgbPipeline: MTLComputePipelineState

  public init(device: MTLDevice) throws {
    guard device.supportsFamily(.metal4) else { throw MonitorKitError.gpu("Raw monitor frames require Metal 4.") }
    self.device = device
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor()
    libraryDescriptor.source = Self.shader
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    func pipeline(_ name: String) throws -> MTLComputePipelineState {
      let function = MTL4LibraryFunctionDescriptor()
      function.library = library; function.name = name
      let descriptor = MTL4ComputePipelineDescriptor(); descriptor.computeFunctionDescriptor = function
      return try compiler.makeComputePipelineState(descriptor: descriptor)
    }
    packedPipeline = try pipeline("mk_rawPacked")
    planarPipeline = try pipeline("mk_rawPlanar")
    rgbPipeline = try pipeline("mk_rawRGB")
  }

  /// Retain this value and the vendor allocation owner through GPU feedback.
  /// Remove its allocations from the caller's residency set only after feedback.
  public struct Encoding {
    public let frame: MonitorFrame
    public let allocations: [any MTLAllocation]
    public let arguments: MTL4ArgumentTable
  }

  /// Plane offsets/strides are explicit byte counts; NV12/P216 have two planes.
  /// UYVA's alpha plane is ignored. The input must cover every declared plane.
  public func encode(
    input: MTLBuffer, format: MonitorRawPixelFormat, width: Int, height: Int,
    offsets: [Int] = [0], strides: [Int], signal: SignalDescription,
    commandBuffer: MTL4CommandBuffer, residency: MTLResidencySet
  ) throws -> Encoding {
    guard input.device.registryID == device.registryID, width > 0, height > 0,
      width <= Int(UInt32.max) / 8, height <= Int(UInt32.max) else {
      throw MonitorKitError.invalidFrame("Invalid raw monitor dimensions or device.")
    }
    let deep = format == .p216 || format == .pa16
    let planar = format == .nv12Video || format == .nv12Full || deep || format == .i420
    let packed = format == .uyvy8 || format == .yuyv8 || format == .uyva
    let count = format == .i420 || format == .pa16 ? 3 : planar ? 2 : 1
    guard offsets.count == count, strides.count == count else {
      throw MonitorKitError.invalidFrame("Raw monitor plane count does not match the format.")
    }
    if (packed || deep) && !width.isMultiple(of: 2) {
      throw MonitorKitError.invalidFrame("Raw 4:2:2 frames require an even width.")
    }
    let cw = (width + 1) / 2
    let ch = deep ? height : (height + 1) / 2
    var minimum: [Int] = planar ? [width * (deep ? 2 : 1), cw * (deep ? 4 : format == .i420 ? 1 : 2)]
      : [packed ? width * 2 : format == .r12l ? (width * 36 + 7) / 8 : width * 4]
    if count == 3 { minimum.append(format == .pa16 ? width * 2 : cw) }
    for index in 0..<count {
      let rows = index == 0 || (index == 2 && format == .pa16) ? height : ch
      // The final row needs its pixels only. Its trailing padding may belong to another allocation.
      let (lastRow, overflow) = strides[index].multipliedReportingOverflow(by: rows - 1)
      guard !overflow, offsets[index] >= 0, strides[index] >= minimum[index],
        strides[index] <= Int(UInt32.max), offsets[index] <= Int(UInt32.max),
        offsets[index] <= input.length, lastRow <= input.length - offsets[index],
        minimum[index] <= input.length - offsets[index] - lastRow else {
        throw MonitorKitError.invalidFrame("Raw monitor plane storage is truncated or overflows.")
      }
    }
    func texture(_ pixelFormat: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
      descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
      guard let result = device.makeTexture(descriptor: descriptor) else { throw MonitorKitError.gpu("Raw monitor texture allocation failed.") }
      return result
    }
    let layout: PixelLayout
    var packedTexture: MTLTexture?, luma: MTLTexture?, chroma: MTLTexture?
    if packed {
      layout = format == .yuyv8 ? .yuyv8 : .uyvy8
      packedTexture = try texture(.rgba8Uint, width / 2, height)
    } else if planar {
      let depth = deep ? 16 : 8
      layout = .biplanar(deep ? .s422 : .s420, bitDepth: depth)
      luma = try texture(depth == 8 ? .r8Unorm : .r16Unorm, width, height)
      chroma = try texture(depth == 8 ? .rg8Unorm : .rg16Unorm, cw, ch)
    } else {
      let depth = format == .r210 ? 10 : format == .r12l ? 12 : 8
      layout = .rgb(bitDepth: depth, float: false)
      luma = try texture(depth == 10 ? .rgb10a2Unorm : depth == 12 ? .rgba16Unorm : .rgba8Unorm, width, height)
    }
    let values: [UInt32] = [UInt32(width), UInt32(height), format.rawValue, 0,
      UInt32(offsets[0]), UInt32(strides[0]), UInt32(planar ? offsets[1] : 0), UInt32(planar ? strides[1] : 0),
      UInt32(count == 3 ? offsets[2] : 0), UInt32(count == 3 ? strides[2] : 0), 0, 0]
    guard let parameters = device.makeBuffer(bytes: values, length: 48) else { throw MonitorKitError.gpu("Raw monitor uniform allocation failed.") }
    let descriptor = MTL4ArgumentTableDescriptor(); descriptor.maxBufferBindCount = 2; descriptor.maxTextureBindCount = 3
    let table = try device.makeArgumentTable(descriptor: descriptor)
    table.setAddress(input.gpuAddress, index: 0); table.setAddress(parameters.gpuAddress, index: 1)
    if let packedTexture { table.setTexture(packedTexture.gpuResourceID, index: 0) }
    if let luma { table.setTexture(luma.gpuResourceID, index: 1) }
    if let chroma { table.setTexture(chroma.gpuResourceID, index: 2) }
    let frame = try MonitorFrame(layout: layout, width: width, height: height, packed: packedTexture, luma: luma, chroma: chroma, signal: signal)
    let allocations: [any MTLAllocation] = [input, parameters] + [packedTexture, luma, chroma].compactMap { $0 }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MonitorKitError.gpu("Raw monitor compute encoder unavailable.") }
    for allocation in allocations { residency.addAllocation(allocation) }
    // Inputs may have been produced by an IOSurface-to-buffer GPU copy in a
    // preceding encoder. Metal 4 does not infer this producer/consumer edge.
    encoder.barrier(afterQueueStages: [.blit, .dispatch], beforeStages: .dispatch, visibilityOptions: .device)
    encoder.setComputePipelineState(packed ? packedPipeline : planar ? planarPipeline : rgbPipeline)
    encoder.setArgumentTable(table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
    // Publish native texture writes to subsequent monitor/scopes passes.
    encoder.barrier(afterStages: .dispatch, beforeQueueStages: [.dispatch, .fragment, .blit], visibilityOptions: .device)
    encoder.endEncoding()
    return Encoding(frame: frame, allocations: allocations, arguments: table)
  }

  private static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  struct RawParams { uint4 shape; uint4 planes; uint4 third; };
  uint mk_raw16(device const uchar *p) { return uint(p[0]) | uint(p[1]) << 8; }
  kernel void mk_rawPacked(device const uchar *bytes [[buffer(0)]], constant RawParams &p [[buffer(1)]],
    texture2d<uint, access::write> packed [[texture(0)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.shape.x / 2 || xy.y >= p.shape.y) return;
    device const uchar *q = bytes + p.planes.x + ulong(xy.y) * p.planes.y + xy.x * 4;
    packed.write(uint4(q[0], q[1], q[2], q[3]), xy);
  }
  kernel void mk_rawPlanar(device const uchar *bytes [[buffer(0)]], constant RawParams &p [[buffer(1)]],
    texture2d<float, access::write> y [[texture(1)]], texture2d<float, access::write> uv [[texture(2)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.shape.x || xy.y >= p.shape.y) return;
    bool deep = p.shape.z == 9 || p.shape.z == 11;
    device const uchar *q = bytes + p.planes.x + ulong(xy.y) * p.planes.y + xy.x * (deep ? 2 : 1);
    y.write(float4(float(deep ? mk_raw16(q) : uint(q[0])) / (deep ? 65535.0f : 255.0f)), xy);
    if (xy.x < uv.get_width() && xy.y < uv.get_height()) {
      q = bytes + p.planes.z + ulong(xy.y) * p.planes.w + xy.x * (deep ? 4 : 2);
      float2 c;
      if (deep) c = float2(mk_raw16(q), mk_raw16(q+2)) / 65535.0f;
      else if (p.shape.z == 10) {
        q = bytes + p.planes.z + ulong(xy.y) * p.planes.w + xy.x;
        device const uchar *v = bytes + p.third.x + ulong(xy.y) * p.third.y + xy.x;
        c = float2(q[0], v[0]) / 255.0f;
      } else c = float2(q[0], q[1]) / 255.0f;
      uv.write(float4(c, 0, 1), xy);
    }
  }
  kernel void mk_rawRGB(device const uchar *bytes [[buffer(0)]], constant RawParams &p [[buffer(1)]],
    texture2d<float, access::write> rgb [[texture(1)]], uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p.shape.x || xy.y >= p.shape.y) return;
    device const uchar *row = bytes + p.planes.x + ulong(xy.y) * p.planes.y;
    float3 c;
    if (p.shape.z == 8) {
      ulong bit = ulong(xy.x) * 36; uint3 code;
      for (uint channel = 0; channel < 3; ++channel) {
        ulong b = bit + channel * 12; ulong i = b >> 3; uint shift = uint(b & 7);
        code[channel] = ((uint(row[i]) | uint(row[i+1]) << 8) >> shift) & 4095;
      }
      c = float3(code) / 4095.0f;
    } else {
      device const uchar *q = row + xy.x * 4;
      if (p.shape.z == 7) {
        uint word = uint(q[0]) << 24 | uint(q[1]) << 16 | uint(q[2]) << 8 | uint(q[3]);
        c = float3((word >> 20) & 1023, (word >> 10) & 1023, word & 1023) / 1023.0f;
      } else {
        c = float3(q[0], q[1], q[2]) / 255.0f;
        if (p.shape.z == 5) c = c.bgr;
      }
    }
    rgb.write(float4(c, 1), xy);
  }
  """
}
