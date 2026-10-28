import Foundation

/// Normalize device input to logarithmic zoom steps before it reaches the camera.
enum OfflineMapInputDelta {
  static func scroll(_ delta: Double, precise: Bool) -> Double {
    guard delta.isFinite else { return 0 }
    let steps = delta * (precise ? 1 / 240 : 1 / 5)
    return max(-0.5, min(0.5, steps))
  }

  static func magnification(_ delta: Double) -> Double {
    guard delta.isFinite, delta > -1 else { return 0 }
    return max(-0.5, min(0.5, log2(1 + delta)))
  }
}

#if os(macOS)
  import AppKit
  import SwiftUI

  /// Observe native input without installing a hit-testing layer above the map.
  /// Exclusions use the same top-left coordinate space as the SwiftUI canvas.
  struct OfflineMapMacInput: NSViewRepresentable {
    var excluding: [CGRect] = []
    let onScrollZoom: (Double, CGPoint) -> Void
    let onMagnify: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> InputView {
      let view = InputView()
      updateNSView(view, context: context)
      return view
    }

    func updateNSView(_ view: InputView, context: Context) {
      view.excluding = excluding
      view.onScrollZoom = onScrollZoom
      view.onMagnify = onMagnify
    }

    static func dismantleNSView(_ view: InputView, coordinator: ()) {
      view.stopMonitoring()
    }

    final class InputView: NSView {
      var excluding: [CGRect] = []
      var onScrollZoom: ((Double, CGPoint) -> Void)?
      var onMagnify: ((Double, CGPoint) -> Void)?
      private var monitor: Any?

      override var isFlipped: Bool { true }
      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) {
          [weak self] event in
          let consumed = MainActor.assumeIsolated { self?.receive(event) ?? false }
          return consumed ? nil : event
        }
      }

      func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }

      private func receive(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
          !isHiddenOrHasHiddenAncestor,
          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(point), !excluding.contains(where: { $0.contains(point) }),
          !isOverNativeControl(event.locationInWindow, in: window)
        else { return false }

        guard !event.phase.contains(.cancelled) else { return false }
        let delta: Double
        switch event.type {
        case .scrollWheel:
          // Preserve the system's scroll direction and its native momentum tail.
          guard !event.momentumPhase.contains(.cancelled),
            abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
          else { return false }
          delta = OfflineMapInputDelta.scroll(
            Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
        case .magnify:
          delta = OfflineMapInputDelta.magnification(Double(event.magnification))
        default:
          return false
        }

        guard delta != 0 else { return false }
        if event.type == .magnify {
          onMagnify?(delta, point)
        } else {
          onScrollZoom?(delta, point)
        }
        return true
      }

      private func isOverNativeControl(_ point: CGPoint, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        var view = content.hitTest(content.convert(point, from: nil))
        while let candidate = view {
          // An enclosing SwiftUI scroll container may also contain the map.
          // Only controls/scroll views hit independently above or beside this
          // background view should keep the event for their own interaction.
          if (candidate is NSControl || candidate is NSScrollView),
            !isDescendant(of: candidate)
          { return true }
          view = candidate.superview
        }
        return false
      }
    }
  }
#endif
