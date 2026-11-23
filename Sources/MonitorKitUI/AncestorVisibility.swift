// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  /// Tracks the ancestors of a monitor or meter while it belongs to a window.
  /// Hidden views receive no display callbacks to tell them when to restart.
  @MainActor final class AncestorVisibility {
    private var observations: [NSKeyValueObservation] = []
    private var windowNotifications: [NSObjectProtocol] = []

    isolated deinit {
      for token in windowNotifications { NotificationCenter.default.removeObserver(token) }
    }

    static func isHidden(_ view: UIView) -> Bool {
      var node: UIView? = view
      while let ancestor = node {
        if ancestor.isHidden { return true }
        node = ancestor.superview
      }
      return false
    }

    func observe(_ view: UIView, changed: @escaping @MainActor @Sendable () -> Void) {
      observations.removeAll()
      let center = NotificationCenter.default
      for token in windowNotifications { center.removeObserver(token) }
      windowNotifications.removeAll()
      guard let window = view.window else { return }
      for name in [UIWindow.didBecomeHiddenNotification, UIWindow.didBecomeVisibleNotification] {
        windowNotifications.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
          MainActor.assumeIsolated { changed() }
        })
      }
      var node = view.superview
      while let ancestor = node {
        observations.append(ancestor.observe(\.isHidden) { _, _ in
          MainActor.assumeIsolated { changed() }
        })
        // A whole container can move within the same window while the
        // monitor's immediate parent stays the same. Rebind after the move.
        observations.append(ancestor.observe(\.superview) { [weak self, weak view] _, _ in
          DispatchQueue.main.async {
            guard let self, let view else { return }
            self.observe(view, changed: changed)
            changed()
          }
        })
        node = ancestor.superview
      }
    }
  }
#endif
