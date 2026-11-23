// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MonitorKitAudio
import XCTest

final class AudioMeterBoundaryRegressionTests: XCTestCase {
  func testOutOfRangeProgrammePairDoesNotOverflow() {
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: 2, first: .max), [.excluded, .excluded])
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: 2, first: .min), [.excluded, .excluded])
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: 2), LoudnessChannel.stereo)
    XCTAssertEqual(LoudnessChannel.programmePair(channelCount: .min), [])
  }

  func testHoldDecaysOnlyAfterItsBoundary() throws {
    let meter = try AudioMeter(configuration: .init(
      sampleRate: 48000, channelCount: 1, meters: [.samplePeak],
      peakHoldTime: 300.0 / 48000, peakDecayRate: 480,
      publishInterval: 0))
    func feed(_ value: Float, count: Int) {
      let samples = [Float](repeating: value, count: count)
      samples.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: count) }
    }
    feed(1, count: 1)
    feed(0, count: 256)
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, 0, accuracy: 0.00001)
    feed(0, count: 44)
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, 0, accuracy: 0.00001)
    feed(0, count: 100)
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, -1, accuracy: 0.00001)
  }

  func testPartChunkHoldExpirationUsesOnlyReleasedFrames() throws {
    let meter = try AudioMeter(configuration: .init(
      sampleRate: 48000, channelCount: 1, meters: [.samplePeak],
      peakHoldTime: 300.0 / 48000, peakDecayRate: 480,
      publishInterval: 0))
    let crest: [Float] = [1]
    crest.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: 1) }
    let silence = [Float](repeating: 0, count: 400)
    silence.withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress!, frameCount: 400) }
    XCTAssertEqual(meter.snapshot()[0].samplePeakHold, -1, accuracy: 0.00001)
  }

  func testFinishStreamIncludesTheLastIntersampleOverExactlyOnce() throws {
    let input: [Float] = Array(repeating: 0, count: 50) + [-0.83, 0.83, 0.83, -0.83, 0]
    for fs in [48000.0, 96000] {
      let meter = try AudioMeter(sampleRate: fs, channelCount: 1)
      meter.feed(Signal(sampleRate: fs, channels: [input]), blockSize: 13)
      let live = meter.snapshot()
      XCTAssertFalse(live.isOver(maximumTruePeak: 0))
      meter.finishStream()
      let final = meter.snapshot()
      let reference = Reference.truePeak(input + Array(repeating: 0, count: 5), sampleRate: fs)
      XCTAssertTrue(final.isOver(maximumTruePeak: 0))
      XCTAssertEqual(final[0].truePeakMax, Float(dB(reference)), accuracy: 1e-5)
      XCTAssertEqual(final[0].truePeakHold, final[0].truePeakMax)
      XCTAssertEqual(final[0].clipCount, 0)
      XCTAssertEqual(final[0].ppm, live[0].ppm)
      XCTAssertEqual(final[0].samplePeak, live[0].samplePeak)
      XCTAssertEqual(final.loudness, live.loudness)
      XCTAssertEqual(final.frameCount, UInt64(input.count))
      meter.finishStream()
      XCTAssertEqual(meter.snapshot().sequence, final.sequence)
      meter.resetPeaks()
      meter.finishStream()
      XCTAssertEqual(meter.snapshot()[0].truePeakMax, -.infinity)
    }
  }

  func testSingleSampleHasNoPendingInStreamReconstructionInstants() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 1)
    meter.feed(Signal(sampleRate: 48000, channels: [[0.95]]))
    let live = meter.snapshot()
    meter.finishStream()
    XCTAssertEqual(meter.snapshot()[0], live[0])
    XCTAssertEqual(meter.snapshot().sequence, live.sequence)
  }

  func testFractionalFrameTicksCloseAtTheLoudnessAndRMSWindowBoundaries() throws {
    let fs = 11025.0
    let signal = Signal.tone(frequency: 997, dBFS: -12, seconds: 3, sampleRate: fs, channels: 1)
    let meter = try AudioMeter(configuration: .init(
      sampleRate: fs, channelCount: 1, meters: [.rms, .loudness],
      rmsWindow: 0.010, rmsScale: .unscaled, publishInterval: 0))
    func feed(_ from: Int, _ to: Int) {
      signal.channels[0].withUnsafeBufferPointer { meter.process(interleaved: $0.baseAddress! + from, frameCount: to - from) }
    }
    // The first four 5 ms ticks end at frames 55, 110, 165 and 221.
    feed(0, 221)
    let recent = signal.channels[0][110..<221]
    let energy = recent.reduce(0.0) { $0 + Double($1) * Double($1) }
    XCTAssertEqual(meter.snapshot()[0].rms, Float(10 * log10(energy / Double(recent.count))), accuracy: 1e-5)
    feed(221, 4409)
    XCTAssertEqual(meter.snapshot().loudness.momentary, -.infinity)
    feed(4409, 4410)
    let loudness = meter.snapshot().loudness
    XCTAssertTrue(loudness.momentary.isFinite)
    XCTAssertEqual(loudness.integrated, loudness.momentary, accuracy: 1e-5)
    feed(4410, 33074)
    XCTAssertEqual(meter.snapshot().loudness.shortTerm, -.infinity)
    feed(33074, 33075)
    XCTAssertTrue(meter.snapshot().loudness.shortTerm.isFinite)

    let standalone = try LoudnessMeter(sampleRate: fs, channelCount: 1)
    signal.channels[0].withUnsafeBufferPointer {
      standalone.process(interleaved: $0.baseAddress!, frameCount: 1)
      standalone.pauseMeasurement()
      standalone.process(interleaved: $0.baseAddress! + 1, frameCount: 1102)
    }
    XCTAssertEqual(standalone.snapshot().duration, 55 / fs, accuracy: 1e-12)
  }

  func testPausedFractionalRateGateWeightsTheMeasuredFrames() throws {
    let fs = 11025.0
    let input = Signal.noise(amplitude: 0.5, frames: 35280, seed: 72)
    let (shelf, highPass) = KWeighting.filters(sampleRate: fs)
    let weighted = Reference.filter(highPass, Reference.filter(shelf, input.map(Double.init)))
    let meter = try LoudnessMeter(sampleRate: fs, channelCount: 1)
    var frames = 0
    var energy = 0.0
    var start = 0
    // Keep only the long ticks. A 400 ms gate then contains 80 * 56
    // measured frames, unlike a continuous programme's 4410 frames.
    input.withUnsafeBufferPointer { samples in
      for tick in 1...640 {
        let end = Int((fs * Double(tick) / 200).rounded())
        if end - start == 56 {
          meter.resumeMeasurement()
          energy += weighted[start..<end].reduce(0) { $0 + $1 * $1 }
          frames += end - start
        } else {
          meter.pauseMeasurement()
        }
        meter.process(interleaved: samples.baseAddress! + start, frameCount: end - start)
        start = end
      }
    }
    XCTAssertEqual(frames, 80 * 56)
    XCTAssertEqual(meter.snapshot().duration, Double(frames) / fs, accuracy: 1e-12)
    XCTAssertEqual(Double(meter.snapshot().integrated), -0.691 + 10 * log10(energy / Double(frames)), accuracy: 1e-5)
  }

  func testPeakReturnAndHoldFollowSamplePositionsAcrossCallbackSplits() throws {
    let fs = 48000.0
    // The later, lower pulse catches the returning bar and the short hold.
    var x = Array(repeating: Float(0), count: 256)
    x[0] = -1
    x[190] = 0.9
    x[195] = -0.9
    for hold in [0, 40, 500] {
      var results: [AudioChannelLevels] = []
      for partition in [256, 37, 1] {
        let meter = try AudioMeter(configuration: .init(
          sampleRate: fs, channelCount: 1, meters: [.samplePeak, .truePeak],
          peakHoldTime: Double(hold) / fs, peakDecayRate: 480, publishInterval: 0))
        meter.feed(Signal(sampleRate: fs, channels: [x]), blockSize: partition)
        results.append(meter.snapshot()[0])
      }
      let reference = results.last!
      XCTAssertEqual(reference.samplePeak, Float(dB(0.9) - 0.60), accuracy: 1e-5)
      for result in results {
        XCTAssertEqual(result.samplePeak, reference.samplePeak, accuracy: 1e-5)
        XCTAssertEqual(result.samplePeakHold, reference.samplePeakHold, accuracy: 1e-5)
        XCTAssertEqual(result.truePeak, reference.truePeak, accuracy: 1e-5)
        XCTAssertEqual(result.truePeakHold, reference.truePeakHold, accuracy: 1e-5)
      }
    }
  }

  func testUnrepresentableCalibrationsAreRejected() {
    var configuration = AudioMeterConfiguration(sampleRate: 48000, channelCount: 1)
    for value in [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude] {
      configuration.clipLevelDBFS = value
      XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    }
    configuration.clipLevelDBFS = -0.01
    configuration.vuReference = .init(dBFS: -Double.greatestFiniteMagnitude)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    configuration.vuReference = .ebu
    configuration.ppmAlignment = .init(dBFS: Double.greatestFiniteMagnitude)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    configuration.ppmAlignment = .ebu
    for riseTime in [Double.leastNonzeroMagnitude, 1e-200, Double.greatestFiniteMagnitude] {
      configuration.vuBallistics.riseTime = riseTime
      XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    }
    configuration.vuBallistics = .iec60268_17
    // A tiny positive overshoot still has representable, stable damping;
    // it is valid even though extreme rise times above are not.
    configuration.vuBallistics.overshoot = Double.leastNonzeroMagnitude
    XCTAssertNoThrow(try AudioMeter(configuration: configuration))
  }
  func testExtremeScaleInputsHaveBoundedMarks() {
    let wide = MeterScale.digitalPeak(range: -1e20...0)
    XCTAssertLessThanOrEqual(wide.marks.count, 1026)
    let enormous = MeterScale.digitalPeak(range: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
    XCTAssertLessThanOrEqual(enormous.marks.count, 1026)
    let infinite = MeterScale.digitalPeak(range: -Double.infinity...Double.infinity)
    XCTAssertLessThanOrEqual(infinite.marks.count, 1026)
    XCTAssertFalse(MeterScale.loudness(target: Double.greatestFiniteMagnitude).marks.isEmpty)
  }

  func testUnrepresentablePPMCoefficientsAreRejected() {
    var configuration = AudioMeterConfiguration(sampleRate: 48000, channelCount: 1)
    configuration.customPPMBallistics = .init(
      fastTimeConstant: Double.greatestFiniteMagnitude,
      slowTimeConstant: Double.greatestFiniteMagnitude, fastWeight: 0.5, returnRate: 10)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    configuration.customPPMBallistics = .init(
      fastTimeConstant: 0.001, slowTimeConstant: 0.005, fastWeight: 0.5,
      returnRate: Double.greatestFiniteMagnitude)
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
    configuration.customPPMBallistics?.returnRate = Double.leastNonzeroMagnitude
    XCTAssertThrowsError(try AudioMeter(configuration: configuration))
  }

}
