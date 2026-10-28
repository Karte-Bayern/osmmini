import Foundation
import Testing

@testable import OSMmini

@Test @MainActor func reversingTheWheelImmediatelyDiscardsUnfinishedZoomInTheOtherDirection() {
  #expect(OfflineMapZoomAnimator.destination(current: 10.5, pending: 12, delta: -0.2) == 10.3)
  #expect(OfflineMapZoomAnimator.destination(current: 10.5, pending: 12, delta: 0.2) == 12.2)
  #expect(OfflineMapZoomAnimator.destination(current: 10.5, pending: 9, delta: 0.2) == 10.7)
  #expect(OfflineMapZoomAnimator.destination(current: 10.5, pending: nil, delta: -0.2) == 10.3)
}

@Test @MainActor func wheelZoomAnimationIsMonotonicAndIndependentOfInputFrequency() {
  for (start, target) in [(10.0, 13.0), (17.0, 12.0)] {
    let once = OfflineMapZoomAnimator.nextZoom(from: start, to: target, elapsed: 0.032, response: 0.06)
    let first = OfflineMapZoomAnimator.nextZoom(from: start, to: target, elapsed: 0.016, response: 0.06)
    let second = OfflineMapZoomAnimator.nextZoom(from: first, to: target, elapsed: 0.016, response: 0.06)
    #expect(abs(once - second) < 1e-12)
    #expect(first > min(start, target) && first < max(start, target))
    #expect(abs(second - target) < abs(first - target))
    #expect(OfflineMapZoomAnimator.nextZoom(from: start, to: target, elapsed: 2, response: 0.06) == target)
  }
  #expect(OfflineMapZoomAnimator.nextZoom(from: 10, to: 12, elapsed: 0, response: 0.06) == 10)
  #expect(OfflineMapZoomAnimator.nextZoom(from: 10, to: .nan, elapsed: 0.016, response: 0.06) == 10)
}

@Test @MainActor func cancellingWheelZoomDiscardsItsPendingTarget() {
  let animator = OfflineMapZoomAnimator()
  animator.animate(
    from: OfflineMapContinuousViewport(center: Coordinate(lat: 48.5, lon: 12.5), zoom: 12),
    to: 14, anchor: CGPoint(x: 100, y: 100), size: CGSize(width: 800, height: 600),
    minZoom: 5, maxZoom: 18
  ) { _ in Issue.record("Cancelled animation updated the map") }
  #expect(animator.targetZoom == 14)
  animator.cancel()
  #expect(animator.targetZoom == nil)
}
