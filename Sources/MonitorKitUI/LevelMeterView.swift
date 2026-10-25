// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import MonitorKitAudio
import SwiftUI

/// How a `LevelMeterView` is laid out.
public enum LevelMeterStyle: String, Sendable, Hashable, CaseIterable {
  /// About 56 pt wide: thin stacked rows with zones and a hold tick, and an
  /// over dot. No numbers: the tooltip and VoiceOver carry them.
  case compact
  /// Stacked full-width rows over a tick ruler, each channel's held maximum
  /// in dBTP underneath and the over latch at the right.
  case strip
  /// Vertical bars beside a ruler with the reference line, each channel's
  /// held maximum under its bar and the over latch above.
  case full
}

/// What one rectangle of a level meter shows.
public enum LevelMeterPart: Equatable, Sendable {
  /// A channel's empty well.
  case well
  /// A zone's stretch above the bar, dimmed, so the scale's zones show without signal.
  case unlit(MeterZoneKind)
  /// A zone's stretch up to the bar.
  case lit(MeterZoneKind)
  /// The peak-hold line, coloured by its level's zone.
  case hold(MeterZoneKind?)
  /// The reference level's line across every channel.
  case reference
}

/// A broadcast level meter for 1 to 16 channels: true-peak bars (instant
/// attack, IEC 60268-18 fall of 20 dB in 1.7 s), a hold line (2 s, then the
/// same fall), hard colour zones fixed in dB on `MeterScale.expandedPeak()`
/// (green below −9, amber to −1, red from −1 dBTP) and an over latch that
/// lights on a clipped sample or a true-peak maximum at −1 dBTP or above and
/// stays lit until clicked.
///
/// One `TimelineView(.animation(paused:))` draws every channel in one Canvas
/// from one `snapshot()` per frame; between snapshots the fall is
/// extrapolated from elapsed time (`MeterDisplayBallistics`), so bars move
/// smoothly at the display rate when audio arrives once per video frame.
/// Readouts refresh at 10 Hz and format a string only when a digit moves.
/// VoiceOver sees one element whose value (refreshed once a second) reads,
/// for example, "left max −6.2 dBTP, right −7.0, over", with a Reset Peaks
/// action; the compact style shows the same text as its tooltip.
public struct LevelMeterView: View {
  let source: LevelMeterSource
  let style: LevelMeterStyle
  let present: Bool
  let name: String?
  let labels: [String]
  let scale: MeterScale
  let spans: [MeterZoneSpan]
  let reference: Double?
  let palette: MeterPalette

  /// A live meter. `present` false (no audio on the input) pauses and dims
  /// the meter and prints "No audio"; present but silent reads "−∞". `name`
  /// leads the accessibility label ("Camera 1 audio").
  public init(
    meter: AudioMeter, style: LevelMeterStyle = .strip, present: Bool = true, name: String? = nil,
    channelLabels: [String]? = nil, scale: MeterScale = .expandedPeak(), palette: MeterPalette = .standard
  ) {
    self.init(
      source: LevelMeterSource(meter: meter, fixed: AudioMeterSnapshot()), style: style, present: present, name: name,
      channelLabels: channelLabels, scale: scale, palette: palette)
  }

  /// Fixed readings, for a host that measures elsewhere (or a preview): the
  /// bars show `snapshot`'s true peak and hold, without ballistics or reset.
  public init(
    snapshot: AudioMeterSnapshot, style: LevelMeterStyle = .strip, present: Bool = true, name: String? = nil,
    channelLabels: [String]? = nil, scale: MeterScale = .expandedPeak(), palette: MeterPalette = .standard
  ) {
    self.init(
      source: LevelMeterSource(meter: nil, fixed: snapshot), style: style, present: present, name: name,
      channelLabels: channelLabels, scale: scale, palette: palette)
  }

  init(
    source: LevelMeterSource, style: LevelMeterStyle, present: Bool, name: String?, channelLabels: [String]?,
    scale: MeterScale, palette: MeterPalette
  ) {
    self.source = source
    self.style = style
    self.present = present
    self.name = name
    labels = Self.labels(channelLabels, channelCount: source.channelCount)
    self.scale = scale
    spans = scale.zoneSpans
    reference = scale.alignment.map { scale.position(of: $0) }
    self.palette = palette
  }

  /// One label per channel: the host's, then numbers for any it left out;
  /// L and R for a pair, 1 to n otherwise.
  nonisolated static func labels(_ given: [String]?, channelCount n: Int) -> [String] {
    var out = Array((given ?? (n == 2 ? ["L", "R"] : [])).prefix(n))
    while out.count < n { out.append(String(out.count + 1)) }
    return out
  }

  public var body: some View {
    // VoiceOver and the tooltip read a summary refreshed once a second, not per frame.
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      let summary = MeterText.peakSummary(source.read(), channels: labels.count, present: present)
      LevelMeterBody(
        source: source, style: style, present: present, labels: labels, scale: scale, spans: spans,
        reference: reference, palette: palette
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(name.map { "\($0) audio" } ?? "Audio levels")
      .accessibilityValue(summary)
      .accessibilityAction(named: "Reset Peaks") { source.meter?.resetPeaks() }
      .modifier(LevelMeterTooltip(text: style == .compact ? (name.map { "\($0): " } ?? "") + summary : nil))
    }
  }

  // MARK: Layout

  /// Every rectangle of one frame of bars, in drawing order: the Canvas body
  /// without the drawing, so a test can measure it. `axis` is the travel's
  /// direction: horizontal rows (compact, strip) or vertical bars (full).
  /// `reference` is the reference line's position on the travel.
  nonisolated public static func layout(
    _ channels: [MeterChannelLayout], spans: [MeterZoneSpan], reference: Double?, axis: Axis, size: CGSize,
    gap: CGFloat = 2, holdWidth: CGFloat = 2, _ emit: (CGRect, LevelMeterPart) -> Void
  ) {
    let n = channels.count
    guard n > 0, size.width > 0, size.height > 0 else { return }
    let across = axis == .horizontal ? size.height : size.width
    let along = axis == .horizontal ? size.width : size.height
    let thickness = max(0.5, (across - gap * CGFloat(n - 1)) / CGFloat(n))
    // A stretch of the travel (0…1) of the channel at `offset` across.
    func rect(_ offset: CGFloat, _ p0: Double, _ p1: Double) -> CGRect {
      let a = CGFloat(p0) * along, b = CGFloat(p1) * along
      return axis == .horizontal
        ? CGRect(x: a, y: offset, width: b - a, height: thickness)
        : CGRect(x: offset, y: along - b, width: thickness, height: b - a)
    }
    var c = 0
    while c < n {
      let offset = CGFloat(c) * (thickness + gap)
      let channel = channels[c]
      emit(rect(offset, 0, 1), .well)
      var z = 0
      while z < spans.count {
        let span = spans[z]
        let top = min(span.upper, channel.bar)
        if top > span.lower { emit(rect(offset, span.lower, top), .lit(span.kind)) }
        let bottom = max(span.lower, channel.bar)
        if span.upper > bottom { emit(rect(offset, bottom, span.upper), .unlit(span.kind)) }
        z += 1
      }
      if let hold = channel.hold {
        let half = Double(holdWidth / 2 / along)
        let p = min(max(hold, half), 1 - half)
        emit(rect(offset, p - half, p + half), .hold(channel.holdZone))
      }
      c += 1
    }
    if let reference, reference > 0, reference < 1 {
      let p = CGFloat(reference) * along
      emit(
        axis == .horizontal
          ? CGRect(x: p - 0.5, y: 0, width: 1, height: size.height)
          : CGRect(x: 0, y: along - p - 0.5, width: size.width, height: 1),
        .reference)
    }
  }

  /// Row thickness and gap for `channels` rows in a style.
  nonisolated static func rows(_ style: LevelMeterStyle, channels n: Int) -> (thickness: CGFloat, gap: CGFloat) {
    switch style {
    case .compact: return n <= 2 ? (3, 1.5) : n <= 4 ? (2, 1) : (1.5, 0.75)
    case .strip: return n <= 2 ? (5, 2) : n <= 4 ? (4, 2) : (3, 1)
    case .full: return (0, n <= 2 ? 4 : 2)
    }
  }

  /// The height of `n` rows in a horizontal style.
  nonisolated static func rowsHeight(_ style: LevelMeterStyle, channels n: Int) -> CGFloat {
    let r = rows(style, channels: n)
    return r.thickness * CGFloat(n) + r.gap * CGFloat(max(0, n - 1))
  }
}

/// Where a meter's readings come from: a live meter, or fixed readings.
struct LevelMeterSource {
  let meter: AudioMeter?
  let fixed: AudioMeterSnapshot

  var channelCount: Int { min(max(meter?.configuration.channelCount ?? fixed.channelCount, 1), 16) }
  var isLive: Bool { meter != nil }
  var fallRate: Double { meter?.configuration.peakDecayRate ?? 20 / 1.7 }
  var holdTime: Double { meter?.configuration.peakHoldTime ?? 2 }

  func read() -> AudioMeterSnapshot { meter?.snapshot() ?? fixed }
}

/// The display state between frames: each channel's ballistics, hold line
/// and layout, updated in place (no allocation per frame). Held in `@State`
/// and mutated while drawing, so a frame never invalidates the view.
@MainActor final class LevelMeterAnimator {
  /// One per channel drawn; resized only when the channel count changes.
  private(set) var layouts: [MeterChannelLayout] = []
  private var bars: [MeterDisplayBallistics]
  private var holds: [MeterHoldLine]
  private var sequence: UInt64?
  private(set) var isOver = false

  init(fallRate: Double = 20 / 1.7, holdTime: Double = 2) {
    bars = Array(repeating: MeterDisplayBallistics(fallRate: fallRate), count: 16)
    holds = Array(repeating: MeterHoldLine(holdTime: holdTime, fallRate: fallRate), count: 16)
  }

  /// Follows the meter's own fall rate and hold time (its configuration); a no-op when unchanged.
  func configure(fallRate: Double, holdTime: Double) {
    guard fallRate != bars[0].fallRate || holdTime != holds[0].holdTime else { return }
    bars = Array(repeating: MeterDisplayBallistics(fallRate: fallRate), count: 16)
    holds = Array(repeating: MeterHoldLine(holdTime: holdTime, fallRate: fallRate), count: 16)
    sequence = nil
  }

  /// Advances to `time` (seconds) from the snapshot read this frame. Peak
  /// kinds animate (`animate`); other kinds, and fixed readings, show the
  /// snapshot as it is.
  func advance(
    _ s: AudioMeterSnapshot, channels n: Int, kind: AudioMeterBarKind = .truePeak, scale: MeterScale, at time: Double,
    animate: Bool
  ) {
    let n = min(max(n, 0), 16)
    if layouts.count != n { layouts = Array(repeating: MeterChannelLayout(), count: n) }
    let fresh = s.sequence != sequence
    sequence = s.sequence
    let peakKind = kind == .truePeak || kind == .samplePeak
    var c = 0
    while c < n {
      let levels = c < s.channelCount ? s.channels[c] : AudioChannelLevels()
      if !peakKind {
        let r = MeterBarReading(levels: levels, kind: kind, scale: scale)
        layouts[c] = scale.layout(level: r.value, hold: r.holdValue)
      } else {
        let bar = Double(kind == .truePeak ? levels.truePeak : levels.samplePeak)
        let hold = Double(kind == .truePeak ? levels.truePeakHold : levels.samplePeakHold)
        if !animate {
          layouts[c] = scale.layout(level: scale.value(forReading: bar), hold: scale.value(forReading: hold))
        } else {
          if fresh {
            bars[c].ingest(bar, at: time)
            // A peak reset (here or by the host) clears the maximum: start the line over.
            if kind == .truePeak && levels.truePeakMax == -.infinity { holds[c].reset() }
            holds[c].offer(hold, at: time)
          }
          let shown = bars[c].value(at: time)
          holds[c].offer(shown, at: time)
          let held = holds[c].value(at: time)
          layouts[c] = scale.layout(
            level: scale.value(forReading: shown), hold: held.isFinite ? scale.value(forReading: held) : nil)
        }
      }
      c += 1
    }
    isOver = s.isOver()
  }

  /// Empty wells: no audio on the input.
  func showNothing(channels n: Int) {
    let n = min(max(n, 0), 16)
    if layouts.count != n { layouts = Array(repeating: MeterChannelLayout(), count: n) }
    var c = 0
    while c < n {
      layouts[c] = MeterChannelLayout()
      c += 1
    }
    isOver = false
  }

  func resetHolds() {
    var c = 0
    while c < holds.count {
      holds[c].reset()
      c += 1
    }
  }
}

/// The readouts' cached strings: one per channel, rebuilt only when a digit moves.
@MainActor final class LevelMeterTexts {
  let maxima: [ReadoutText] = (0..<16).map { _ in ReadoutText { MeterText.level($0) } }
}

/// The meter's three layouts.
struct LevelMeterBody: View {
  let source: LevelMeterSource
  let style: LevelMeterStyle
  let present: Bool
  let labels: [String]
  let scale: MeterScale
  let spans: [MeterZoneSpan]
  let reference: Double?
  let palette: MeterPalette
  /// False inside a host that offers its own menu (`AudioMeterView`: Reset Peaks and Reset Loudness).
  var showsContextMenu = true
  @State private var animator = LevelMeterAnimator()
  @State private var texts = LevelMeterTexts()
  @Environment(\.colorScheme) private var scheme

  private var n: Int { labels.count }
  private var paused: Bool { !present || !source.isLive }

  var body: some View {
    Group {
      switch style {
      case .compact: compact
      case .strip: strip
      case .full: full
      }
    }
    .contextMenu {
      if source.isLive && showsContextMenu { Button("Reset Peaks") { resetPeaks() } }
    }
  }

  private func resetPeaks() {
    source.meter?.resetPeaks()
    animator.resetHolds()
  }

  /// The animated bars: one TimelineView, one Canvas, one snapshot per frame.
  private func bars(_ axis: Axis, gap: CGFloat, holdWidth: CGFloat, overDot: CGFloat = 0) -> some View {
    TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        let state = animator
        state.configure(fallRate: source.fallRate, holdTime: source.holdTime)
        if present {
          state.advance(source.read(), channels: n, scale: scale, at: time, animate: source.isLive)
        } else {
          state.showNothing(channels: n)
        }
        let barsSize = CGSize(width: size.width - (overDot > 0 ? overDot + 3 : 0), height: size.height)
        LevelMeterView.layout(
          state.layouts, spans: spans, reference: reference, axis: axis, size: barsSize, gap: gap,
          holdWidth: holdWidth
        ) { rect, part in
          context.fill(Path(rect), with: .color(palette.color(part, scheme: scheme)))
        }
        if overDot > 0 {
          let d = min(overDot, size.height)
          let dot = CGRect(x: size.width - d, y: (size.height - d) / 2, width: d, height: d)
          if state.isOver {
            context.fill(Path(ellipseIn: dot), with: .color(palette.over))
          } else {
            context.stroke(Path(ellipseIn: dot.insetBy(dx: 0.5, dy: 0.5)), with: .color(.secondary.opacity(0.7)), lineWidth: 1)
          }
        }
      }
    }
  }

  // MARK: Compact

  private var compact: some View {
    let r = LevelMeterView.rows(.compact, channels: n)
    return bars(.horizontal, gap: r.gap, holdWidth: 1.5, overDot: 6)
      .frame(width: 56, height: max(6, LevelMeterView.rowsHeight(.compact, channels: n)))
      .opacity(present ? 1 : 0.4)
      .contentShape(Rectangle())
      .onTapGesture { resetPeaks() }
  }

  // MARK: Strip

  private var strip: some View {
    let r = LevelMeterView.rows(.strip, channels: n)
    let height = LevelMeterView.rowsHeight(.strip, channels: n)
    return VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .top, spacing: 4) {
        // Row labels while they fit their rows (up to four channels); the readouts name every channel.
        if n <= 4 {
          VStack(spacing: r.gap) {
            ForEach(0..<n, id: \.self) { c in
              Text(labels[c]).font(.system(size: n <= 2 ? 8 : 6.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(height: r.thickness)
            }
          }
          .frame(minWidth: 9)
        }
        VStack(spacing: 2) {
          bars(.horizontal, gap: r.gap, holdWidth: 2).frame(height: height)
          LevelMeterRuler(ticks: scale.ticks, axis: .horizontal).frame(height: 14)
        }
      }
      .opacity(present ? 1 : 0.4)
      TimelineView(.periodic(from: .now, by: 0.1)) { _ in
        let s = source.read()
        HStack(alignment: .top, spacing: 8) {
          if present {
            // Four channels to a line.
            VStack(alignment: .leading, spacing: 2) {
              ForEach(0..<(n + 3) / 4, id: \.self) { line in
                HStack(spacing: 8) {
                  ForEach(line * 4..<min(n, line * 4 + 4), id: \.self) { c in
                    HStack(spacing: 3) {
                      Text(labels[c]).foregroundStyle(.secondary)
                      maximum(s, c)
                    }
                    .fixedSize()
                  }
                  if line == (n - 1) / 4 { Text("dBTP").foregroundStyle(.secondary).fixedSize() }
                }
              }
            }
          } else {
            Text("No audio").foregroundStyle(.secondary)
          }
          Spacer(minLength: 4)
          OverLatch(lit: present && s.isOver(), palette: palette, action: source.isLive ? { resetPeaks() } : nil)
            .fixedSize()
        }
        .font(.system(size: 10).monospacedDigit())
        .lineLimit(1)
      }
    }
  }

  /// A channel's held maximum, red at or above −1 dBTP.
  private func maximum(_ s: AudioMeterSnapshot, _ c: Int) -> some View {
    let value = c < s.channelCount ? Double(s.channels[c].truePeakMax) : -.infinity
    return Text(texts.maxima[c](value))
      .foregroundStyle(value >= -1 ? AnyShapeStyle(palette.over) : AnyShapeStyle(.primary))
  }

  // MARK: Full

  private var full: some View {
    let gap = LevelMeterView.rows(.full, channels: n).gap
    let ruler: CGFloat = 26
    return VStack(alignment: .leading, spacing: 4) {
      TimelineView(.periodic(from: .now, by: 0.1)) { _ in
        HStack {
          Text("dBTP").font(.system(size: 9)).foregroundStyle(.secondary)
          Spacer(minLength: 4)
          OverLatch(lit: present && source.read().isOver(), palette: palette, action: source.isLive ? { resetPeaks() } : nil)
        }
      }
      HStack(alignment: .top, spacing: 3) {
        LevelMeterRuler(ticks: scale.ticks, axis: .vertical, inset: 5).frame(width: ruler)
        bars(.vertical, gap: gap, holdWidth: 2).padding(.vertical, 5)
          .opacity(present ? 1 : 0.4)
          .overlay {
            if !present {
              Text("No audio").font(.caption).foregroundStyle(.secondary).padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
          }
      }
      .frame(maxHeight: .infinity)
      HStack(spacing: 3) {
        Color.clear.frame(width: ruler, height: 1)
        HStack(spacing: gap) {
          ForEach(0..<n, id: \.self) { c in
            Text(labels[c]).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
              .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
          }
        }
      }
      HStack(spacing: 3) {
        Color.clear.frame(width: ruler, height: 1)
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
          let s = source.read()
          HStack(spacing: gap) {
            ForEach(0..<n, id: \.self) { c in
              Group { if present { maximum(s, c) } else { Text("—").foregroundStyle(.secondary) } }
                .font(.system(size: 9).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
            }
          }
        }
      }
    }
  }
}

/// The over latch: "OVER" in red while lit, an outline otherwise. Clicking resets the peaks.
struct OverLatch: View {
  let lit: Bool
  let palette: MeterPalette
  let action: (() -> Void)?

  var body: some View {
    Button {
      action?()
    } label: {
      Text("OVER")
        .font(.system(size: 9, weight: .heavy))
        .tracking(0.5)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(lit ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tertiary))
        .background(RoundedRectangle(cornerRadius: 3).fill(lit ? palette.latch : .clear))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lit ? .clear : Color.secondary.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .help(
      lit
        ? "An over since the last reset: a sample clipped or the true peak reached −1 dBTP. Click to reset the peaks."
        : "Lights on a clipped sample or a true peak at −1 dBTP or above, and stays lit until clicked.")
    .accessibilityLabel(lit ? "Over" : "No over")
  }
}

/// A scale's ticks and labels beside the bars. Static: redrawn only on a size change.
struct LevelMeterRuler: View {
  let ticks: [MeterTick]
  let axis: Axis
  /// Space kept at both ends of the travel for the end labels (vertical).
  var inset: CGFloat = 0

  var body: some View {
    Canvas { context, size in
      let along = (axis == .horizontal ? size.width : size.height) - 2 * inset
      var lastLabel = -CGFloat.infinity
      // Labels from the top down, so the top of the scale keeps its labels when they crowd.
      for tick in ticks.reversed() {
        let p = CGFloat(tick.position) * along
        let length: CGFloat = tick.isReference ? 4 : tick.isMajor ? 3 : 2
        let shading: GraphicsContext.Shading = .color(tick.isReference ? .primary : .secondary)
        var line = Path()
        if axis == .horizontal {
          line.move(to: CGPoint(x: inset + p, y: 0))
          line.addLine(to: CGPoint(x: inset + p, y: length))
        } else {
          let y = inset + along - p
          line.move(to: CGPoint(x: size.width - length, y: y))
          line.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(line, with: shading, lineWidth: tick.isReference ? 1.5 : 1)
        guard let label = tick.label else { continue }
        let text = context.resolve(
          Text(label).font(.system(size: 8, weight: tick.isReference ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(tick.isReference ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
        let measured = text.measure(in: size)
        if axis == .horizontal {
          let x = min(max(inset + p - measured.width / 2, 0), size.width - measured.width)
          // Right to left: skip a label that would touch the one to its right.
          if lastLabel.isFinite && x + measured.width + 3 > lastLabel { continue }
          context.draw(text, in: CGRect(x: x, y: 4, width: measured.width, height: measured.height))
          lastLabel = x
        } else {
          let y = min(max(inset + along - p - measured.height / 2, 0), size.height - measured.height)
          if lastLabel.isFinite && y < lastLabel + 1 { continue }
          context.draw(
            text, in: CGRect(x: size.width - length - 2 - measured.width, y: y, width: measured.width, height: measured.height))
          lastLabel = y + measured.height
        }
      }
    }
    .accessibilityHidden(true)
  }
}

/// The compact style's tooltip; no tooltip for the other styles, which print their numbers.
struct LevelMeterTooltip: ViewModifier {
  let text: String?

  func body(content: Content) -> some View {
    if let text { content.help(text) } else { content }
  }
}
