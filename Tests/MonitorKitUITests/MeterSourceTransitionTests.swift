// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitAudio
import XCTest

@testable import MonitorKitUI

final class MeterSourceTransitionTests: XCTestCase {
  @MainActor func testChangingMeterWithEqualSequenceReplacesBarsAndHolds() throws {
    let first = try AudioMeter(sampleRate: 48000, channelCount: 1)
    let second = try AudioMeter(sampleRate: 48000, channelCount: 1)
    let animator = LevelMeterAnimator()
    let scale = MeterScale.expandedPeak()
    var snapshot = AudioMeterSnapshot()
    snapshot.channelCount = 1
    snapshot.sequence = 12
    snapshot.channels[0] = AudioChannelLevels(truePeak: -3, truePeakHold: -3, truePeakMax: -3)
    animator.configure(fallRate: 20 / 1.7, holdTime: 2, meter: first)
    animator.advance(snapshot, channels: 1, scale: scale, at: 100, animate: true)
    // The same sequence belongs to a different meter. Neither a stale bar nor
    // a held peak from the previous source belongs in the new source's display.
    snapshot.channels[0] = AudioChannelLevels(truePeak: -30, truePeakHold: -30, truePeakMax: -30)
    animator.configure(fallRate: 20 / 1.7, holdTime: 2, meter: second)
    animator.advance(snapshot, channels: 1, scale: scale, at: 100, animate: true)
    XCTAssertEqual(animator.layouts[0].bar, scale.position(of: -30), accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(animator.layouts[0].hold), scale.position(of: -30), accuracy: 1e-9)
  }

  @MainActor func testChangingPeakKindReplacesBallisticsWithoutNewSnapshot() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 1)
    let animator = LevelMeterAnimator()
    let scale = MeterScale.expandedPeak()
    var snapshot = AudioMeterSnapshot()
    snapshot.channelCount = 1
    snapshot.sequence = 12
    snapshot.channels[0] = AudioChannelLevels(
      samplePeak: -20, samplePeakHold: -20, truePeak: -3, truePeakHold: -3, truePeakMax: -3)
    animator.configure(fallRate: 20 / 1.7, holdTime: 2, meter: meter, kind: .truePeak)
    animator.advance(snapshot, channels: 1, scale: scale, at: 100, animate: true)
    animator.configure(fallRate: 20 / 1.7, holdTime: 2, meter: meter, kind: .samplePeak)
    animator.advance(snapshot, channels: 1, kind: .samplePeak, scale: scale, at: 100, animate: true)
    XCTAssertEqual(animator.layouts[0].bar, scale.position(of: -20), accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(animator.layouts[0].hold), scale.position(of: -20), accuracy: 1e-9)
  }

  @MainActor func testUnchangedSourceKeepsElapsedFall() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 1)
    let animator = LevelMeterAnimator()
    let scale = MeterScale.expandedPeak()
    var snapshot = AudioMeterSnapshot()
    snapshot.channelCount = 1
    snapshot.sequence = 12
    snapshot.channels[0] = AudioChannelLevels(truePeak: -3, truePeakHold: -3, truePeakMax: -3)
    animator.configure(fallRate: 20 / 1.7, holdTime: 2, meter: meter)
    animator.advance(snapshot, channels: 1, scale: scale, at: 100, animate: true)
    animator.configure(fallRate: 20 / 1.7, holdTime: 2, meter: meter)
    animator.advance(snapshot, channels: 1, scale: scale, at: 101, animate: true)
    // The first snapshot holds for 1.25 default 24 Hz intervals before
    // extrapolated decay begins (MeterDisplayBallistics initial lead).
    let fallenLevel = -3 - (20 / 1.7) * (1 - 1.25 / 24)
    XCTAssertEqual(animator.layouts[0].bar, scale.position(of: fallenLevel), accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(animator.layouts[0].hold), scale.position(of: -3), accuracy: 1e-9)
  }
}
