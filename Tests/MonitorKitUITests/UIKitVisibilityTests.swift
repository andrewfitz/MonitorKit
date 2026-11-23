// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

#if canImport(UIKit) && !canImport(AppKit)
  import Metal
  import MonitorKit
  import UIKit
  import XCTest

  @testable import MonitorKitUI

  @MainActor final class UIKitVisibilityTests: XCTestCase {
    func testDisabledMonitorGesturesAndAncestorVisibility() throws {
      let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
      let engine = try MonitorEngine(device: device)
      let view = MonitorMetalView(engine: engine, configuration: .init(gesturesEnabled: false))
      XCTAssertTrue(view.gestureRecognizers?.isEmpty ?? true)
      let meter = MeterLayerView(frame: view.frame)
      meter.isLive = true
      guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }) else {
        throw XCTSkip("Requires a foreground UIKit test host")
      }
      let window = UIWindow(windowScene: scene)
      let container = UIView(frame: view.frame)
      let parent = UIView(frame: view.frame)
      window.addSubview(container)
      container.addSubview(parent)
      parent.addSubview(view)
      parent.addSubview(meter)
      window.isHidden = false
      defer { window.isHidden = true }
      func check(_ running: Bool) {
        XCTAssertEqual(view.isDisplayLinkRunning, running)
        XCTAssertEqual(view.headroomTimer != nil, running)
        XCTAssertEqual(meter.isLinkRunning, running)
      }
      check(true)
      container.isHidden = true
      check(false)
      container.isHidden = false
      check(true)
      window.isHidden = true
      check(false)
      window.isHidden = false
      check(true)
    }
  }
#endif
