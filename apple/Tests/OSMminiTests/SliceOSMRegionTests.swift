import Foundation
import Testing

@testable import OSMmini

@Test func sliceRegionUsesTheRequestedGeodesicRadiusAndClosedCounterClockwiseRing() throws {
  for center in [
    Coordinate(lat: 48.5, lon: 12.5), Coordinate(lat: 0, lon: 0),
    Coordinate(lat: -35, lon: 151), Coordinate(lat: 85, lon: 0),
  ] {
    for radius in SliceOSMRegion.supportedRadiiKM {
      let region = try SliceOSMRegion(center: center, radiusKM: radius, name: " Umkreis ")
      #expect(region.center == center)
      #expect(region.radiusKM == radius)
      #expect(region.name == "Umkreis")
      #expect(region.boundary.count == 73)
      #expect(region.boundary.first == region.boundary.last)
      for point in region.boundary {
        #expect(point.lat.isFinite && (-90...90).contains(point.lat))
        #expect(point.lon.isFinite && (-180...180).contains(point.lon))
        #expect(abs(sliceDistanceKM(center, point) - Double(radius)) < 0.000_001)
      }
      let signedArea = zip(region.boundary, region.boundary.dropFirst()).reduce(0.0) {
        $0 + $1.0.lon * $1.1.lat - $1.1.lon * $1.0.lat
      }
      #expect(signedArea > 0)
      let north = try #require(region.boundary.first)
      #expect(north.lat > center.lat)
      #expect(abs(north.lon - center.lon) < 0.000_001)
    }
  }
}

@Test func sliceRegionRejectsInvalidCoordinatesRadiusAndNames() {
  let center = Coordinate(lat: 48.5, lon: 12.5)
  for invalid in [
    Coordinate(lat: .nan, lon: 0), Coordinate(lat: 0, lon: .infinity),
    Coordinate(lat: 90.1, lon: 0), Coordinate(lat: -90.1, lon: 0),
    Coordinate(lat: 0, lon: 180.1), Coordinate(lat: 0, lon: -180.1),
  ] {
    #expect(throws: (any Error).self) {
      try SliceOSMRegion(center: invalid, radiusKM: 30, name: "Umkreis")
    }
  }
  for radius in [-30, 0, 1, 29, 31, 180, Int.max] {
    #expect(throws: (any Error).self) {
      try SliceOSMRegion(center: center, radiusKM: radius, name: "Umkreis")
    }
  }
  for name in ["", " \n ", String(repeating: "a", count: 81), "Ort\u{0000}Name"] {
    #expect(throws: (any Error).self) {
      try SliceOSMRegion(center: center, radiusKM: 30, name: name)
    }
  }
}

@Test func sliceRegionRejectsCirclesThatCrossPolesOrTheDateLine() throws {
  for center in [
    Coordinate(lat: 89, lon: 0), Coordinate(lat: -89, lon: 0),
    Coordinate(lat: 0, lon: 179), Coordinate(lat: 0, lon: -179),
    Coordinate(lat: 85, lon: 175), Coordinate(lat: 85, lon: -175),
  ] {
    #expect(throws: (any Error).self) {
      try SliceOSMRegion(center: center, radiusKM: 150, name: "Umkreis")
    }
  }
  for center in [Coordinate(lat: 0, lon: 178), Coordinate(lat: 0, lon: -178)] {
    let region = try SliceOSMRegion(center: center, radiusKM: 150, name: "Umkreis")
    #expect(region.boundary.count == 73)
  }
}

private func sliceDistanceKM(_ from: Coordinate, _ to: Coordinate) -> Double {
  let radians = Double.pi / 180
  let latitude = (to.lat - from.lat) * radians
  let longitude = (to.lon - from.lon) * radians
  let haversine = pow(sin(latitude / 2), 2)
    + cos(from.lat * radians) * cos(to.lat * radians) * pow(sin(longitude / 2), 2)
  return 2 * 6371.0088 * asin(sqrt(min(1, max(0, haversine))))
}
