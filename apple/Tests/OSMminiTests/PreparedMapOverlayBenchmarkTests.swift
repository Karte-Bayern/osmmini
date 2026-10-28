import Foundation
import Testing

@testable import OSMmini

/// Replays the same taps before and after changes without timing XML parsing or
/// projection. Opt in with OSMMINI_MAP_BENCHMARK=1 and use a release build.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_MAP_BENCHMARK"] == "1"))
func importedOverlaySelectionBenchmark() throws {
  let center = Coordinate(lat: 48.5, lon: 12.5)
  let zoom = 14.5
  let size = CGSize(width: 1_000, height: 700)
  let origin = WebMercator.world(center, displayZoom: zoom)
  func position(_ x: Double, _ y: Double) -> String {
    let coordinate = WebMercator.coordinate(
      CGPoint(x: origin.x + x, y: origin.y + y), displayZoom: zoom)
    return "\(coordinate.lon),\(coordinate.lat)"
  }
  let clock = ContinuousClock()
  for lines in [false, true] {
    let count = lines ? 1_000 : 5_000
    let columns = lines ? 40 : 100
    let spacingX = lines ? 20.0 : 8.0
    let spacingY = lines ? 20.0 : 10.0
    var placemarks: [String] = []
    var anchors: [CGPoint] = []
    for index in 0..<count {
      let x = -396 + Double(index % columns) * spacingX
      let y = -245 + Double(index / columns) * spacingY
      let geometry: String
      if lines {
        let coordinates = (0..<100).map { point in
          position(x + Double(point) * 16 / 99, y)
        }.joined(separator: " ")
        geometry = "<LineString><coordinates>\(coordinates)</coordinates></LineString>"
      } else {
        geometry = "<Point><coordinates>\(position(x, y))</coordinates></Point>"
      }
      placemarks.append("<Placemark><name>\(index)</name>\(geometry)</Placemark>")
      anchors.append(CGPoint(x: size.width / 2 + x + (lines ? 8 : 0), y: size.height / 2 + y))
    }
    let document = try KMLDocument(data: Data("<kml>\(placemarks.joined())</kml>".utf8))
    let overlay = try PreparedMapOverlay(document)
    let taps = (0..<50).map { anchors[($0 * 97) % count] }
    var samples: [Duration] = []
    for _ in 0..<3 {
      var hits = 0
      let start = clock.now
      for _ in 0..<10 {
        for tap in taps {
          if overlay.select(at: tap, center: center, displayZoom: zoom, size: size) != nil {
            hits += 1
          }
        }
      }
      samples.append(start.duration(to: clock.now))
      #expect(hits == 500)
    }
    print("KML selection, \(lines ? "1000 lines / 100000 positions" : "5000 points"), 500 taps: \(samples.sorted()[1])")
  }
}
