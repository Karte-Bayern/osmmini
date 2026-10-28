import Foundation

/// Retarget one running animation instead of restarting it for every wheel event.
/// Projection happens at each frame so the point under the pointer stays fixed.
@MainActor final class OfflineMapZoomAnimator {
  private(set) var targetZoom: Double?
  private var task: Task<Void, Never>?
  private var viewport: OfflineMapContinuousViewport?
  private var anchor = CGPoint.zero
  private var size = CGSize.zero
  private var minZoom = 0
  private var maxZoom = 30
  private var response = 0.06
  private var update: (@MainActor (OfflineMapContinuousViewport) -> Void)?

  func destination(adding delta: Double, to current: Double) -> Double {
    Self.destination(current: current, pending: targetZoom, delta: delta)
  }

  static func destination(current: Double, pending: Double?, delta: Double) -> Double {
    guard let pending, (pending - current) * delta >= 0 else { return current + delta }
    return pending + delta
  }

  func animate(
    from viewport: OfflineMapContinuousViewport, to zoom: Double,
    anchor: CGPoint, size: CGSize, minZoom: Int, maxZoom: Int,
    response: Double = 0.06,
    update: @escaping @MainActor (OfflineMapContinuousViewport) -> Void
  ) {
    guard OfflineMapContinuousViewport.zooming(
      center: viewport.center, from: viewport.zoom, to: zoom, at: anchor, size: size,
      minZoom: minZoom, maxZoom: maxZoom) != nil
    else { return }
    if task == nil { self.viewport = viewport }
    self.targetZoom = max(Double(minZoom), min(Double(maxZoom), zoom))
    self.anchor = anchor
    self.size = size
    self.minZoom = minZoom
    self.maxZoom = maxZoom
    self.response = max(0.01, response)
    self.update = update
    guard task == nil else { return }
    task = Task { [weak self] in
      let clock = ContinuousClock()
      var previous = clock.now
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        guard let self, let viewport = self.viewport, let target = self.targetZoom else { return }
        let now = clock.now
        let elapsed = previous.duration(to: now).components
        previous = now
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let nextZoom = Self.nextZoom(
          from: viewport.zoom, to: target, elapsed: seconds, response: self.response)
        guard let next = OfflineMapContinuousViewport.zooming(
          center: viewport.center, from: viewport.zoom, to: nextZoom,
          at: self.anchor, size: self.size, minZoom: self.minZoom, maxZoom: self.maxZoom)
        else { self.cancel(); return }
        self.viewport = next
        self.update?(next)
        if nextZoom == target {
          self.task = nil
          self.targetZoom = nil
          self.update = nil
          return
        }
      }
    }
  }

  static func nextZoom(from current: Double, to target: Double, elapsed: Double, response: Double)
    -> Double
  {
    guard current.isFinite, target.isFinite, elapsed.isFinite, elapsed > 0,
      response.isFinite, response > 0
    else { return current }
    let next = target + (current - target) * exp(-elapsed / response)
    return abs(next - target) < 0.0001 ? target : next
  }

  func cancel() {
    task?.cancel()
    task = nil
    targetZoom = nil
    viewport = nil
    update = nil
  }

  deinit { task?.cancel() }
}
