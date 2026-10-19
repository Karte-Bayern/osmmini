import Foundation
import Testing

@testable import OSMmini

private struct RegionalCity {
  let name: String
  let center: Coordinate
}

private let regionalCities = [
  RegionalCity(name: "Passau", center: Coordinate(lat: 48.574, lon: 13.450)),
  RegionalCity(name: "Landshut", center: Coordinate(lat: 48.549, lon: 12.137)),
  RegionalCity(name: "Deggendorf", center: Coordinate(lat: 48.832, lon: 12.960)),
  RegionalCity(name: "Straubing", center: Coordinate(lat: 48.881, lon: 12.573)),
]

private func regionalDistance(_ a: Coordinate, _ b: Coordinate) -> Double {
  let radians = Double.pi / 180
  let lat = sin((b.lat - a.lat) * radians / 2)
  let lon = sin((b.lon - a.lon) * radians / 2)
  let haversine = lat * lat + cos(a.lat * radians) * cos(b.lat * radians) * lon * lon
  return 12_742_000 * asin(sqrt(min(1, max(0, haversine))))
}

private func regionalCoordinateIsValid(_ coordinate: Coordinate, bounds: RegionBounds) -> Bool {
  coordinate.lat.isFinite && coordinate.lon.isFinite
    && (-90...90).contains(coordinate.lat) && (-180...180).contains(coordinate.lon)
    && coordinate.lat >= bounds.minLat - 0.000001 && coordinate.lat <= bounds.maxLat + 0.000001
    && coordinate.lon >= bounds.minLon - 0.000001 && coordinate.lon <= bounds.maxLon + 0.000001
}

private func regionalMedian(_ samples: [Duration]) -> Duration {
  samples.sorted()[samples.count / 2]
}

private func verifyRegionalSearch(_ engine: OfflineEngine) async throws {
  let clock = ContinuousClock()
  for city in regionalCities {
    let best = try #require(try await engine.search(city.name, limit: 1).first)
    #expect(
      best.label.compare(city.name, options: [.caseInsensitive, .diacriticInsensitive])
        == .orderedSame)
    #expect(regionalDistance(best.coordinate, city.center) < 20_000)
    var samples: [Duration] = []
    var count = 0
    for _ in 0..<3 {
      let start = clock.now
      let results = try await engine.search(city.name, limit: 100)
      samples.append(start.duration(to: clock.now))
      count = results.count
      #expect(!results.isEmpty, "No search results for \(city.name)")
      #expect(
        results.allSatisfy {
          regionalCoordinateIsValid($0.coordinate, bounds: engine.manifest.bounds)
        })
      #expect(
        results.contains {
          $0.label.localizedCaseInsensitiveContains(city.name)
            && regionalDistance($0.coordinate, city.center) < 20_000
        }, "No geographically plausible search result for \(city.name)")
    }
    print(
      "Real search \(city.name): first \(samples[0]), median/3 \(regionalMedian(samples)), results \(count)"
    )
  }
}

private func verifyRegionalRoutes(_ engine: OfflineEngine) async throws {
  let clock = ContinuousClock()
  let passau = try #require(try await engine.search("Passau", limit: 1).first)
  let landshut = try #require(try await engine.search("Landshut", limit: 1).first)
  var cityOptions = RouteOptions()
  cityOptions.profile = .car
  let cityStart = clock.now
  let cityRoute = try await engine.route(
    RouteRequest(from: passau.coordinate, to: landshut.coordinate, options: cityOptions))
  #expect(cityRoute.path.count > 1)
  #expect((50_000...200_000).contains(cityRoute.distanceM))
  #expect((0...250).contains(cityRoute.fromSnapM))
  #expect((0...250).contains(cityRoute.toSnapM))
  #expect(
    cityRoute.path.allSatisfy { regionalCoordinateIsValid($0, bounds: engine.manifest.bounds) })
  if let first = cityRoute.path.first, let last = cityRoute.path.last {
    #expect(regionalDistance(first, passau.coordinate) <= 250)
    #expect(regionalDistance(last, landshut.coordinate) <= 250)
  }
  print(
    "Real route between city search results: \(cityStart.duration(to: clock.now)), \(Int(cityRoute.distanceM)) m, snaps \(Int(cityRoute.fromSnapM))/\(Int(cityRoute.toSnapM)) m"
  )
  let from = regionalCities[0].center
  let to = regionalCities[1].center
  for objective in [RouteObjective.distance, .duration] {
    var options = RouteOptions()
    options.profile = .car
    options.objective = objective
    var samples: [Duration] = []
    var measured: Route?
    for _ in 0..<3 {
      let start = clock.now
      let route = try await engine.route(RouteRequest(from: from, to: to, options: options))
      samples.append(start.duration(to: clock.now))
      #expect(route.path.count > 1)
      #expect(
        route.path.allSatisfy { regionalCoordinateIsValid($0, bounds: engine.manifest.bounds) })
      #expect(route.distanceM.isFinite && (50_000...300_000).contains(route.distanceM))
      #expect(route.durationS.isFinite && (900...18_000).contains(route.durationS))
      #expect(route.fromSnapM.isFinite && (0...5_000).contains(route.fromSnapM))
      #expect(route.toSnapM.isFinite && (0...5_000).contains(route.toSnapM))
      #expect(!route.steps.isEmpty)
      if let first = route.path.first, let last = route.path.last {
        #expect(regionalDistance(first, from) < 5_000)
        #expect(regionalDistance(last, to) < 5_000)
      }
      measured = route
    }
    let route = try #require(measured)
    let distance = String(format: "%.1f", route.distanceM / 1000)
    let duration = String(format: "%.1f", route.durationS / 60)
    print(
      "Real route Passau–Landshut \(objective.rawValue): first \(samples[0]), median/3 \(regionalMedian(samples)), \(distance) km, \(duration) min, points \(route.path.count), snaps \(Int(route.fromSnapM))/\(Int(route.toSnapM)) m"
    )
  }
}

private func verifyRegionalTiles(_ engine: OfflineEngine) async throws {
  let clock = ContinuousClock()
  let viewport = CGSize(width: 390, height: 600)
  for city in regionalCities {
    for displayZoom in [12, 14, 18] {
      // Deliberately use z14 for the overzoom case, including regions that
      // happen to contain finer source tiles than the demo's default import.
      let sourceZoom = min(displayZoom, 14, engine.manifest.maxZoom)
      let placements = OfflineMapTilePlacement.visible(
        center: city.center, zoom: displayZoom, size: viewport, tileZoom: sourceZoom)
      let keys = OfflineMapTilePlacement.loadingKeys(in: placements, center: city.center)
      #expect(!keys.isEmpty)
      var prepared: [MapTileKey: PreparedMapTile] = [:]
      var fetching = Duration.zero
      var preparation = Duration.zero
      var rawFeatures = 0
      var vertices = 0
      for key in keys {
        let fetchStart = clock.now
        let tile = try await engine.tile(z: key.z, x: key.x, y: key.y)
        fetching += fetchStart.duration(to: clock.now)
        rawFeatures += tile.features.count
        vertices += tile.features.reduce(0) { total, feature in
          total + feature.paths.reduce(0) { $0 + $1.count }
        }
        let prepareStart = clock.now
        prepared[key] = try await PreparedMapTile.prepare(tile)
        preparation += prepareStart.duration(to: clock.now)
      }
      let featureCount = prepared.values.reduce(0) { $0 + $1.features.count }
      let labelCount = prepared.values.reduce(0) { $0 + $1.labels.count }
      let indexBytes = prepared.values.reduce(0) { $0 + ($1.spatialIndex?.storageBytes ?? 0) }
      #expect(rawFeatures > 0, "Empty real map around \(city.name), z\(sourceZoom)")
      #expect(featureCount > 0)
      #expect(vertices > 0)
      var selected = 0
      var visibleLabels = 0
      for placement in placements {
        let tile = try #require(prepared[placement.key])
        let origin = placement.origin(center: city.center, zoom: displayZoom, size: viewport)
        let scale = placement.scale(at: displayZoom)
        let visible = CGRect(
          x: -origin.x / scale, y: -origin.y / scale,
          width: viewport.width / scale, height: viewport.height / scale)
        let width = PreparedMapTile.roadWidth(major: true, overzoom: displayZoom - sourceZoom)
        selected += tile.featureIndices(in: visible, padding: ((width + 1) / 2 + 1) / scale).count
        visibleLabels +=
          tile.labels.filter {
            let point = CGPoint(x: origin.x + $0.point.x * scale, y: origin.y + $0.point.y * scale)
            return CGRect(origin: .zero, size: viewport).contains(point)
          }.count
      }
      // Measure only repeated CPU feature selection over retained geometry;
      // this is not a Canvas/GPU drawing or text-measurement benchmark.
      let frames = 120
      var replayedFeatures = 0
      let replay = clock.measure {
        for frame in 0..<frames {
          let drag = CGFloat(frame % 25) - 12
          for placement in placements {
            guard let tile = prepared[placement.key] else { continue }
            let origin = placement.origin(center: city.center, zoom: displayZoom, size: viewport)
            let scale = placement.scale(at: displayZoom)
            let visible = CGRect(
              x: -(origin.x + drag) / scale, y: -origin.y / scale,
              width: viewport.width / scale, height: viewport.height / scale)
            let width = PreparedMapTile.roadWidth(major: true, overzoom: displayZoom - sourceZoom)
            replayedFeatures +=
              tile.featureIndices(
                in: visible, padding: ((width + 1) / 2 + 1) / scale
              ).count
          }
        }
      }
      #expect(replayedFeatures > 0)
      print(
        "Real map \(city.name) z\(displayZoom)/source\(sourceZoom): tiles \(keys.count), fetch \(fetching), prepare \(preparation), raw/prepared/visible \(rawFeatures)/\(featureCount)/\(selected), vertices \(vertices), labels visible/all \(visibleLabels)/\(labelCount), index \(indexBytes) B, select/\(frames) frames \(replay)"
      )
    }
  }
}

/// Set OSMMINI_REAL_REGION to an already imported Niederbayern directory.
/// This opt-in check performs no download or import and does not reset OS caches.
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"] != nil))
func niederbayernRealRegionIntegration() async throws {
  let path = try #require(ProcessInfo.processInfo.environment["OSMMINI_REAL_REGION"])
  let clock = ContinuousClock()
  let start = clock.now
  let engine = try await OfflineEngine.open(URL(fileURLWithPath: path, isDirectory: true))
  do {
    print(
      "Real region \(engine.manifest.name): open \(start.duration(to: clock.now)), format \(engine.manifest.format), nodes \(engine.manifest.nodes), edges \(engine.manifest.edges), zooms \(engine.manifest.minZoom)...\(engine.manifest.maxZoom); existing files, OS caches retained"
    )
    #expect(engine.manifest.nodes > 1000 && engine.manifest.edges > 1000)
    #expect(engine.manifest.minZoom <= 12 && engine.manifest.maxZoom >= 14)
    try await verifyRegionalSearch(engine)
    try await verifyRegionalRoutes(engine)
    try await verifyRegionalTiles(engine)
    await engine.close()
  } catch {
    await engine.close()
    throw error
  }
}
