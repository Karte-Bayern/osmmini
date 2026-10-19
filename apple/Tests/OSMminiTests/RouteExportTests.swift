import Foundation
import Testing

@testable import OSMmini

struct RouteExportTests {
  private func route(
    path: [Coordinate] = [Coordinate(lat: 48.1, lon: 12.2), Coordinate(lat: -0.5, lon: -179.75)],
    distance: Double = 1234.5, duration: Double = 90
  ) -> Route {
    Route(
      path: path, distanceM: distance, durationS: duration, fromSnapM: 1, toSnapM: 2,
      steps: [Maneuver(instruction: "Test", lat: 48.1, lon: 12.2)])
  }

  @Test func geoJSONRetainsTheFeatureSchemaAndSortedKeys() throws {
    let route = route()
    let data = try route.geoJSON()
    #expect(
      String(decoding: data, as: UTF8.self)
        == """
        {"geometry":{"coordinates":[[12.2,48.1],[-179.75,-0.5]],"type":"LineString"},"properties":{"distance_m":1234.5,"duration_s":90},"type":"Feature"}
        """)
    let feature = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(feature.keys) == ["type", "properties", "geometry"])
    #expect(feature["type"] as? String == "Feature")
    let properties = try #require(feature["properties"] as? [String: Double])
    #expect(properties == ["distance_m": 1234.5, "duration_s": 90])
    let geometry = try #require(feature["geometry"] as? [String: Any])
    #expect(Set(geometry.keys) == ["type", "coordinates"])
    #expect(geometry["type"] as? String == "LineString")
    #expect(geometry["coordinates"] as? [[Double]] == [[12.2, 48.1], [-179.75, -0.5]])
  }

  @Test func emptyRouteExportsAnEmptyCoordinateArray() throws {
    let data = try route(path: []).geoJSON()
    let feature = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let geometry = try #require(feature["geometry"] as? [String: Any])
    let coordinates = try #require(geometry["coordinates"] as? [[Double]])
    #expect(coordinates.isEmpty)
    #expect(geometry["type"] as? String == "LineString")
  }

  @Test func nonFiniteCoordinatesThrowEncodingErrors() {
    for value in [Double.nan, .infinity, -.infinity] {
      for coordinate in [Coordinate(lat: value, lon: 12), Coordinate(lat: 48, lon: value)] {
        #expect(throws: EncodingError.self) { try route(path: [coordinate]).geoJSON() }
      }
    }
  }

  @Test func nonFiniteExportedMetricsThrowEncodingErrors() {
    for value in [Double.nan, .infinity, -.infinity] {
      #expect(throws: EncodingError.self) { try route(distance: value).geoJSON() }
      #expect(throws: EncodingError.self) { try route(duration: value).geoJSON() }
    }
  }
}
