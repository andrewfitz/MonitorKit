// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import MonitorKitScopes

/// `ScopeSettings.atNativeResolution`: bins follow the plot's pixels, measured with the
/// same graticule plot and pixel bounds the renderer draws with, so every binned axis
/// is drawn reduced (one or more bins per pixel), never stretched.
final class ScopeNativeResolutionTests: XCTestCase {
  private let viewports = [(120, 40), (767, 255), (768, 256), (1001, 333), (1601, 801), (640, 640), (300, 900),
    (2400, 1200)]

  private func plotPixels(_ s: ScopeSettings, _ width: Int, _ height: Int) -> (Int, Int) {
    let w = Double(width), h = Double(height)
    let plot = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: w, viewportHeight: h).plot
    let bounds = ScopeRenderer.pixelBounds(SIMD4(plot.x * w, plot.y * h, plot.z * w, plot.w * h))
    return (Int(bounds.z) - Int(bounds.x), Int(bounds.w) - Int(bounds.y))
  }

  func testWaveformsHaveABinPerPlotPixel() {
    for mode in [WaveformMode.luma, .rgbOverlay, .rgbParade, .ycbcrParade] {
      for (width, height) in viewports {
        var base = ScopeSettings(kind: .waveform)
        base.waveformMode = mode
        let s = base.atNativeResolution(viewportWidth: width, viewportHeight: height)
        let (columns, rows) = plotPixels(s, width, height)
        let across = mode.isParade ? ScopeRenderer.maximumPanelPixels(columns) : columns
        let perChannel = s.waveformColumnsPerChannel
        XCTAssertGreaterThanOrEqual(perChannel, min(across, mode.isParade ? 1364 : 4096), "\(mode) \(width)×\(height)")
        if width <= 2048 { XCTAssertLessThanOrEqual(perChannel, across + 2, "\(mode) \(width)×\(height)") }
        XCTAssertEqual(s.waveformLevels, min(max(rows, 64), 2048), "\(mode) \(width)×\(height)")
        XCTAssertEqual(s, s.normalized(), "Already normalized")
      }
    }
  }

  func testHistogramHasABinPerPixelColumn() {
    for (width, height) in viewports {
      let s = ScopeSettings(kind: .histogram).atNativeResolution(viewportWidth: width, viewportHeight: height)
      let (columns, _) = plotPixels(s, width, height)
      XCTAssertGreaterThanOrEqual(s.histogramBins, max(64, columns))
      XCTAssertLessThanOrEqual(s.histogramBins, max(64, columns + 1))
    }
  }

  func testVectorscopeBinsFillItsSquarePlot() {
    for (width, height) in viewports {
      let s = ScopeSettings(kind: .vectorscope).atNativeResolution(viewportWidth: width, viewportHeight: height)
      let (columns, rows) = plotPixels(s, width, height)
      let side = max(columns, rows)
      XCTAssertGreaterThanOrEqual(s.vectorscopeSize, min(max(64, side), 2048), "\(width)×\(height)")
      XCTAssertLessThanOrEqual(s.vectorscopeSize, max(64, side + 2), "\(width)×\(height)")
    }
  }

  func testOnlyTheBinsChange() {
    var base = ScopeSettings.plainWaveform(mode: .luma)
    base.display.gain = 2
    base.clipHighPercent = 95
    var s = base.atNativeResolution(viewportWidth: 1500, viewportHeight: 500)
    s.waveformColumns = base.waveformColumns
    s.waveformLevels = base.waveformLevels
    XCTAssertEqual(s, base.normalized())
    XCTAssertEqual(ScopeSettings(kind: .waveform).atNativeResolution(viewportWidth: 0, viewportHeight: -3),
      ScopeSettings(kind: .waveform).atNativeResolution(viewportWidth: 1, viewportHeight: 1), "Degenerate sizes clamp")
  }
}
