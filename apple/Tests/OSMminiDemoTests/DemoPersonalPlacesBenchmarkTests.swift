import Foundation
import Testing

@testable import OSMmini
@testable import OSMminiDemoCLI

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_BENCHMARKS"] == "1"))
func personalPlacesSearchBenchmark() throws {
  let suite = "DemoPersonalPlacesBenchmark.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  func entry(_ index: Int, saved: Bool) -> DemoPlaceLibrary.Entry {
    let name = ["Café München", "École Zürich", "Apotheke Berlin", "Museum São Paulo"][index % 4]
    return DemoPlaceLibrary.Entry(
      id: UUID(),
      place: DemoPlace(
        coordinate: Coordinate(lat: 48.5, lon: 12.5), name: "\(name) \(index)",
        category: index % 4 == 0 ? "cafe" : "museum", kind: "node",
        sourceIdentity: "node/\(saved ? index : 10_000 + index)",
        details: PlaceDetails(address: "Marktplatz \(index), München")))
  }
  let saved = (0..<500).map { entry($0, saved: true) }
  let recent = (0..<20).map { entry($0, saved: false) }
  let snapshot = try JSONSerialization.data(withJSONObject: [
    "version": 1,
    "saved": try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)),
    "recent": try JSONSerialization.jsonObject(with: JSONEncoder().encode(recent)),
  ])
  defaults.set(snapshot, forKey: DemoPlaceLibrary.storageKey)
  let library = DemoPlaceLibrary(defaults: defaults)
  #expect(library.saved.count == 500 && library.recent.count == 20 && !library.needsReset)
  let queries = ["", "cafe", "MUNCHEN", "ÉCOLE", "São museum", "marktplatz 42", "Berlin", "missing"]
  let clock = ContinuousClock()
  for pass in 0..<3 {
    var count = 0
    let changing = clock.measure {
      for _ in 0..<10 {
        for query in queries {
          let found = library.personalMatches(query: query)
          count += found.saved.count + found.recent.count
        }
      }
    }
    _ = library.personalMatches(query: "cafe")
    let repeated = clock.measure {
      for _ in 0..<500 {
        let found = library.personalMatches(query: "cafe")
        count += found.saved.count + found.recent.count
      }
    }
    let lookups = clock.measure {
      for _ in 0..<100 {
        for entry in recent {
          #expect(library.savedEntry(for: entry.place) == nil)
        }
      }
    }
    #expect(count > 0)
    print(
      "Personal places pass \(pass + 1) (500 saved +20 recent):80 changing queries \(changing),500 repeated projections \(repeated),2000 saved lookups \(lookups)")
  }
}
