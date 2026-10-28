import Foundation

/// A circular SliceOSM request, sampled as a closed counter-clockwise GeoJSON ring.
public struct SliceOSMRegion: Sendable, Equatable {
  public static let supportedRadiiKM = [30, 60, 90, 120, 150]

  public let center: Coordinate
  public let radiusKM: Int
  public let name: String
  public let boundary: [Coordinate]

  public init(center: Coordinate, radiusKM: Int, name: String) throws {
    guard center.lat.isFinite, center.lon.isFinite,
      (-90...90).contains(center.lat), (-180...180).contains(center.lon)
    else { throw OSMminiError.native("Der Mittelpunkt enthält keinen gültigen Standort.") }
    guard Self.supportedRadiiKM.contains(radiusKM) else {
      throw OSMminiError.native("Wähle einen Umkreis von 30, 60, 90, 120 oder 150 km.")
    }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 80,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw OSMminiError.native("Der Regionsname muss 1 bis 80 Zeichen enthalten.") }

    let radians = Double.pi / 180
    let latitude = center.lat * radians
    let longitude = center.lon * radians
    let distance = Double(radiusKM) / 6371.0088
    guard abs(latitude) + distance < .pi / 2 else {
      throw OSMminiError.native("Dieser Umkreis berührt einen Pol. Wähle einen anderen Mittelpunkt.")
    }
    // Check the continuous circle's longitude extent, rather than only its
    // sampled vertices: a crossing can otherwise fall between two samples.
    let longitudeExtent = asin(min(1, sin(distance) / cos(latitude)))
    guard abs(longitude) + longitudeExtent < .pi else {
      throw OSMminiError.native(
        "Dieser Umkreis überschreitet die Datumsgrenze. Wähle einen anderen Mittelpunkt.")
    }

    let sineLatitude = sin(latitude)
    let cosineLatitude = cos(latitude)
    let sineDistance = sin(distance)
    let cosineDistance = cos(distance)
    let segments = 72
    var boundary: [Coordinate] = []
    boundary.reserveCapacity(segments + 1)
    for index in 0..<segments {
      let bearing = -Double(index) * 2 * .pi / Double(segments)
      let sine = sineLatitude * cosineDistance + cosineLatitude * sineDistance * cos(bearing)
      let targetLatitude = asin(max(-1, min(1, sine)))
      let targetLongitude = longitude + atan2(
        sin(bearing) * sineDistance * cosineLatitude,
        cosineDistance - sineLatitude * sin(targetLatitude))
      boundary.append(Coordinate(lat: targetLatitude / radians, lon: targetLongitude / radians))
    }
    boundary.append(boundary[0])
    self.center = center
    self.radiusKM = radiusKM
    self.name = name
    self.boundary = boundary
  }
}
