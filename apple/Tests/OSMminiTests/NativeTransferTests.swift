import Darwin
import Foundation
import Testing

@testable import OSMmini

@Test func nativeRequestPreservesWireKeysAndIntegerHandles() throws {
  let handle = UInt64.max - 3
  let route = RouteRequest(
    from: Coordinate(lat: 48.1, lon: 12.2), to: Coordinate(lat: 48.3, lon: 12.4))
  let encoded = try JSONEncoder().encode(
    NativeRequest(action: "route", engine: handle, route: route))
  struct Wire: Decodable {
    let action: String
    let engine: UInt64
    let route: RouteRequest
  }
  let wire = try JSONDecoder().decode(Wire.self, from: encoded)
  #expect(wire.engine == handle)
  #expect(wire.action == "route")
  #expect(wire.route.from == route.from)
  let options = ImportOptions(
    pbf: URL(fileURLWithPath: "/tmp/region.osm.pbf"),
    destination: URL(fileURLWithPath: "/tmp/region"), name: "Café München")
  let imported = try JSONEncoder().encode(NativeRequest(action: "import", importOptions: options))
  let object = try #require(JSONSerialization.jsonObject(with: imported) as? [String: Any])
  #expect(object["import"] is [String: Any])
  #expect(object["importOptions"] == nil)
  #expect(object["engine"] == nil)
}

@Test func nativeBufferRemainsValidWhileDataOwnsIt() throws {
  struct Response: Codable, Equatable {
    let label: String
  }
  for label in ["a", "Café München · Straße", String(repeating: "長い Straße 🚲", count: 2048)] {
    let expected = Response(label: label)
    let encoded = try JSONEncoder().encode(expected)
    let string = String(decoding: encoded, as: UTF8.self)
    let data = try NativeJSONBuffer.take(strdup(string))
    #expect(try JSONDecoder().decode(Response.self, from: data) == expected)
    let retained = [data]
    #expect(try JSONDecoder().decode(Response.self, from: retained[0]) == expected)
  }
  #expect(throws: OSMminiError.self) { try NativeJSONBuffer.take(nil) }
}

@Test func gpxExportKeepsCoordinatesAndEmptyRouteFormat() {
  for path in [[], [Coordinate(lat: 48.1, lon: 12.2), Coordinate(lat: -0.5, lon: -179.75)]] {
    let route = Route(path: path, distanceM: 0, durationS: 0, fromSnapM: 0, toSnapM: 0, steps: [])
    let expected =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"OSMmini\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>OSMmini route</name><trkseg>"
      + path.map { "<trkpt lat=\"\($0.lat)\" lon=\"\($0.lon)\"/>" }.joined()
      + "</trkseg></trk></gpx>"
    #expect(route.gpx() == Data(expected.utf8))
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_BENCHMARKS"] == "1"))
func nativeBufferTransferBenchmark() throws {
  let payload = "{\"label\":\"" + String(repeating: "Straße", count: 16384) + "\"}"
  let iterations = 200
  var bytes = 0
  let clock = ContinuousClock()
  let copying = try clock.measure {
    for _ in 0..<iterations {
      guard let pointer = strdup(payload) else { throw OSMminiError.invalidResponse }
      let data = Data(String(cString: pointer).utf8)
      free(pointer)
      bytes += data.count
    }
  }
  let transferring = try clock.measure {
    for _ in 0..<iterations {
      let data = try NativeJSONBuffer.take(strdup(payload))
      bytes += data.count
    }
  }
  #expect(bytes == payload.utf8.count * iterations * 2)
  print(
    "Native JSON buffer (\(payload.utf8.count) bytes × \(iterations)): copying \(copying), ownership transfer \(transferring)"
  )
}
