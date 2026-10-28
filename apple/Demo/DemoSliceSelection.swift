import Foundation
import OSMmini
import Observation

/// A single location request for an extract, independent of the map's GPS session.
@MainActor @Observable final class DemoSliceSelection {
  enum Radius: Int, CaseIterable, Identifiable, Sendable {
    case km30 = 30, km60 = 60, km90 = 90, km120 = 120, km150 = 150
    var id: Int { rawValue }
  }

  private struct Center {
    let coordinate: Coordinate
    let horizontalAccuracy: Double?
    let precise: Bool
  }

  let location: DemoLocation
  var radius = Radius.km30
  private var center: Center?

  var radiusKM: Int { radius.rawValue }
  var coordinate: Coordinate? { center?.coordinate }
  var horizontalAccuracy: Double? { center?.horizontalAccuracy }
  var hasPreciseLocation: Bool { center?.precise ?? location.hasPreciseLocation }
  var isLocating: Bool { location.isLocating }
  var error: String? { center == nil ? location.error : nil }

  var status: String {
    guard let center else {
      return location.state == .idle ? "Noch kein Standort gewählt." : location.status
    }
    let title = center.precise ? "Standort übernommen." : "Ungefährer Standort übernommen."
    guard let accuracy = center.horizontalAccuracy else { return title }
    let meters = accuracy.formatted(.number.precision(.fractionLength(0)))
    return "\(title) Genauigkeit: etwa \(meters) m."
  }

  init(location: DemoLocation = DemoLocation()) {
    self.location = location
  }

  func requestLocation() {
    guard !location.isLocating else { return }
    center = nil
    location.stop()
    location.start()
    captureLocationIfReady()
  }

  /// Called when the location state changes. Copy the fix before `stop()` clears it.
  func captureLocationIfReady() {
    guard center == nil, location.state == .ready, let coordinate = location.coordinate else {
      return
    }
    center = Center(
      coordinate: coordinate, horizontalAccuracy: location.horizontalAccuracy,
      precise: location.hasPreciseLocation)
    location.stop()
  }

  /// Closing the sheet or entering the background stops only this request.
  func stopLocating() {
    location.stop()
  }
}
