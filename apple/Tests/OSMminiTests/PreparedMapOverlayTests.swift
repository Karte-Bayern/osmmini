import Foundation
import Testing

@testable import OSMmini

private func overlayDocument(_ placemarks: String) throws -> KMLDocument {
  try KMLDocument(
    data: Data(
      "<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\(placemarks)</Document></kml>".utf8),
    name: "Imported overlay")
}

private func overlayScreen(_ coordinate: Coordinate, center: Coordinate, zoom: Double, size: CGSize)
  -> CGPoint
{
  let offset = WebMercator.offset(coordinate, from: center, displayZoom: zoom)
  return CGPoint(x: size.width / 2 + offset.x, y: size.height / 2 + offset.y)
}

@Test func importedOverlayPointsKeepTheirCoordinatesAndPhysicalHitTargetsAcrossZoomAndDateline()
  throws
{
  let point = Coordinate(lat: 0, lon: 179.999)
  let document = try overlayDocument(
    """
    <Placemark><name>A &amp; B</name><Point><coordinates>179.999,0</coordinates></Point></Placemark>
    """)
  let overlay = try PreparedMapOverlay(document)
  let size = CGSize(width: 800, height: 600)
  for center in [Coordinate(lat: 0, lon: 179.999), Coordinate(lat: 0, lon: -179.999)] {
    for zoom in [10.25, 14.5, 16.875] {
      let screen = overlayScreen(point, center: center, zoom: zoom, size: size)
      guard CGRect(origin: .zero, size: size).contains(screen) else { continue }
      let selected = try #require(
        overlay.select(at: screen, center: center, displayZoom: zoom, size: size))
      #expect(selected.coordinate == point)
      #expect(selected.feature?.name == "A & B")
      #expect(selected.feature?.sourceIdentity?.hasPrefix("kml/") == true)
      #expect(
        overlay.select(
          at: CGPoint(x: screen.x + 17, y: screen.y), center: center, displayZoom: zoom, size: size)
          != nil)
      #expect(
        overlay.select(
          at: CGPoint(x: screen.x + 19, y: screen.y), center: center, displayZoom: zoom, size: size)
          == nil)
    }
  }
}

@Test func importedOverlayLinesCrossTheDateLineLocallyAndKeepScreenPointTolerance() throws {
  let document = try overlayDocument(
    """
    <Placemark><name>Crossing</name><LineString><coordinates>179.98,0 -179.98,0</coordinates></LineString></Placemark>
    """)
  let overlay = try PreparedMapOverlay(document)
  let size = CGSize(width: 800, height: 600)
  for center in [Coordinate(lat: 0, lon: 179.999), Coordinate(lat: 0, lon: -179.999)] {
    for zoom in [10.25, 14.5, 16.875] {
      let selected = try #require(
        overlay.select(
          at: CGPoint(x: 400, y: 317), center: center, displayZoom: zoom, size: size))
      #expect(selected.feature?.name == "Crossing")
      #expect(abs(selected.coordinate.lat) < 0.000_001)
      #expect(abs(selected.coordinate.lon - center.lon) < 0.000_001)
      #expect(
        overlay.select(at: CGPoint(x: 400, y: 319), center: center, displayZoom: zoom, size: size)
          == nil)
    }
  }
  #expect(
    overlay.select(
      at: CGPoint(x: 400, y: 300), center: Coordinate(lat: 0, lon: 0), displayZoom: 10, size: size)
      == nil)
}

@Test func importedPolygonHolesRemainEmptyAcrossTheDateLine() throws {
  let document = try overlayDocument(
    """
    <Placemark><name>Area</name><Polygon>
      <outerBoundaryIs><LinearRing><coordinates>
        179.98,-0.02 -179.98,-0.02 -179.98,0.02 179.98,0.02 179.98,-0.02
      </coordinates></LinearRing></outerBoundaryIs>
      <innerBoundaryIs><LinearRing><coordinates>
        179.995,-0.005 -179.995,-0.005 -179.995,0.005 179.995,0.005 179.995,-0.005
      </coordinates></LinearRing></innerBoundaryIs>
    </Polygon></Placemark>
    """)
  let overlay = try PreparedMapOverlay(document)
  let center = Coordinate(lat: 0, lon: 179.999)
  let size = CGSize(width: 800, height: 600)
  let zoom = 12.5
  #expect(
    overlay.select(at: CGPoint(x: 400, y: 300), center: center, displayZoom: zoom, size: size)
      == nil)
  let within = overlayScreen(
    Coordinate(lat: 0, lon: 179.99), center: center, zoom: zoom, size: size)
  #expect(
    overlay.select(at: within, center: center, displayZoom: zoom, size: size)?.feature?.name
      == "Area")
  let outside = overlayScreen(
    Coordinate(lat: 0, lon: 179.96), center: center, zoom: zoom, size: size)
  #expect(overlay.select(at: outside, center: center, displayZoom: zoom, size: size) == nil)
}

@Test func overlayPointSelectionTakesPriorityOverItsContainingPolygon() throws {
  let document = try overlayDocument(
    """
    <Placemark><name>Point</name><Point><coordinates>12.5,48.5</coordinates></Point></Placemark>
    <Placemark><name>Area</name><Polygon><outerBoundaryIs><LinearRing><coordinates>
      12.49,48.49 12.51,48.49 12.51,48.51 12.49,48.51 12.49,48.49
    </coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
    """)
  let overlay = try PreparedMapOverlay(document)
  #expect(
    overlay.select(
      at: CGPoint(x: 400, y: 300), center: Coordinate(lat: 48.5, lon: 12.5), displayZoom: 14.5,
      size: CGSize(width: 800, height: 600))?.feature?.name == "Point")
}

@Test func overlayLineSelectionKeepsViewportClippingNearTheScreenEdges() throws {
  let center = Coordinate(lat: 0, lon: 0)
  let zoom = 10.5
  let size = CGSize(width: 100, height: 100)
  let origin = WebMercator.world(center, displayZoom: zoom)
  func position(x: CGFloat, y: CGFloat) -> String {
    let coordinate = WebMercator.coordinate(
      CGPoint(x: origin.x + x - 50, y: origin.y + y - 50), displayZoom: zoom)
    return "\(coordinate.lon),\(coordinate.lat)"
  }
  let document = try overlayDocument(
    """
    <Placemark><name>Outside</name><LineString><coordinates>
      \(position(x: -10, y: 20)) \(position(x: -10, y: 80))
    </coordinates></LineString></Placemark>
    <Placemark><name>Visible</name><LineString><coordinates>
      \(position(x: 98, y: 20)) \(position(x: 98, y: 80))
    </coordinates></LineString></Placemark>
    """)
  let overlay = try PreparedMapOverlay(document)
  #expect(
    overlay.select(at: CGPoint(x: 5, y: 50), center: center, displayZoom: zoom, size: size) == nil)
  #expect(
    overlay.select(at: CGPoint(x: 85, y: 50), center: center, displayZoom: zoom, size: size)?
      .feature?.name == "Visible")
}

@Test func overlaySelectionFindsEachVisibleWorldCopyAtOverviewZoom() throws {
  let center = Coordinate(lat: 0, lon: 0)
  let document = try overlayDocument(
    """
    <Placemark><name>Point</name><Point><coordinates>0,0</coordinates></Point></Placemark>
    <Placemark><name>Line</name><LineString><coordinates>-10,20 10,20</coordinates></LineString></Placemark>
    """)
  let overlay = try PreparedMapOverlay(document)
  let size = CGSize(width: 1_000, height: 400)
  for copy in -1...1 {
    let tap = CGPoint(x: size.width / 2 + CGFloat(copy) * 256, y: size.height / 2)
    let selection = try #require(
      overlay.select(at: tap, center: center, displayZoom: 0, size: size))
    #expect(selection.feature?.name == "Point")
    #expect(selection.coordinate == center)
    let lineOffset = WebMercator.offset(Coordinate(lat: 20, lon: 0), from: center, zoom: 0)
    let lineTap = CGPoint(x: tap.x, y: tap.y + lineOffset.y - 17)
    #expect(
      overlay.select(at: lineTap, center: center, displayZoom: 0, size: size)?.feature?.name
        == "Line")
  }
}

@Test func importedOverlayPreparationHonorsCancellation() async throws {
  let document = try overlayDocument(
    "<Placemark><Point><coordinates>12.5,48.5</coordinates></Point></Placemark>")
  let task = Task { try await PreparedMapOverlay.prepare(document) }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}
