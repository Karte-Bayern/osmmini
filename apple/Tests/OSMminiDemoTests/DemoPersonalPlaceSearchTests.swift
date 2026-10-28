import Foundation
import Observation
import Testing

@testable import OSMmini
@testable import OSMminiDemoCLI

private final class PersonalPlaceChangeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@MainActor struct DemoPersonalPlaceSearchTests {
  private let suite: String
  private let defaults: UserDefaults

  init() throws {
    suite = "DemoPersonalPlaceSearchTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
  }

  private func place(
    _ name: String, lat: Double = 48.5, lon: Double = 12.5,
    identity: String? = nil, category: String? = nil, address: String? = nil
  ) -> DemoPlace {
    DemoPlace(
      coordinate: Coordinate(lat: lat, lon: lon), name: name, category: category,
      kind: identity == nil ? nil : "node", sourceIdentity: identity,
      details: address.map { PlaceDetails(address: $0) })
  }

  private func library(saved: [DemoPlace], recent: [DemoPlace] = []) throws -> DemoPlaceLibrary {
    let entries: ([DemoPlace]) -> [DemoPlaceLibrary.Entry] = {
      $0.map { DemoPlaceLibrary.Entry(id: UUID(), place: $0) }
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "version": 1,
      "saved": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries(saved))),
      "recent": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries(recent))),
    ])
    defaults.set(data, forKey: DemoPlaceLibrary.storageKey)
    let result = DemoPlaceLibrary(defaults: defaults)
    try #require(!result.needsReset)
    return result
  }

  private func referenceMatch(_ lhs: DemoPlace, _ rhs: DemoPlace) -> Bool {
    if let left = lhs.sourceIdentity, let right = rhs.sourceIdentity { return left == right }
    func rounded(_ value: Double) -> Int64 { Int64((value * 1_000_000).rounded()) }
    func longitude(_ value: Double) -> Int64 {
      let result = rounded(value)
      return result == 180_000_000 ? -180_000_000 : result
    }
    return rounded(lhs.coordinate.lat) == rounded(rhs.coordinate.lat)
      && longitude(lhs.coordinate.lon) == longitude(rhs.coordinate.lon)
  }

  private func referenceProjection(_ library: DemoPlaceLibrary, query: String) -> DemoPlaceLibrary.Matches {
    func matches(_ entry: DemoPlaceLibrary.Entry) -> Bool {
      let place = entry.place
      let text = "\(place.name) \(DemoPlaceText.category(place.category, kind: place.kind)) \(place.details?.address ?? "")"
      return query.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: \.isWhitespace).allSatisfy {
          text.localizedStandardContains(String($0))
        }
    }
    return DemoPlaceLibrary.Matches(
      saved: library.saved.filter(matches),
      recent: library.recent.filter { entry in
        !library.saved.contains { referenceMatch($0.place, entry.place) } && matches(entry)
      })
  }

  @Test func savedLookupKeepsFirstMatchAcrossSourceConflictsAndCoordinateFallbacks() throws {
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try library(saved: [
      place("Datumsgrenze", lat: 0, lon: 180),
      place("Verschobenes Objekt", lat: 1, lon: 10, identity: "node/moved"),
      place("Erstes Objekt", identity: "node/first"),
      place("Zweites Objekt", identity: "node/second"),
      place("Gerundeter Punkt", lat: 49.00000049, lon: 13.00000049),
    ])
    let queries = [
      place("Nur ID", lat: 80, lon: 80, identity: "node/moved"),
      place("Frühere Koordinate gewinnt", lat: 0, lon: -180, identity: "node/moved"),
      place("Datumsgrenze", lat: 0, lon: -179.9999996),
      place("Anonymes Duplikat", lat: 48.50000001, lon: 12.50000001),
      place("Anderes Quellobjekt", identity: "node/missing"),
      place("Zweites Quellobjekt", lat: 70, lon: 70, identity: "node/second"),
      place("Gerundet", lat: 49.0000004, lon: 13.0000004),
      place("Andere Rundung", lat: 49.0000006, lon: 13.0000006),
    ]
    for query in queries {
      let expected = store.saved.first { referenceMatch($0.place, query) }
      #expect(store.savedEntry(for: query) == expected)
    }
    #expect(store.savedEntry(for: queries[1])?.place.name == "Datumsgrenze")
    #expect(store.savedEntry(for: queries[3])?.place.name == "Erstes Objekt")
    #expect(store.savedEntry(for: queries[4]) == nil)
    store.removeSaved(id: try #require(store.saved.first).id)
    #expect(store.savedEntry(for: queries[1])?.place.name == "Verschobenes Objekt")
  }

  @Test func preparedProjectionPreservesLocaleMatchingOrderingAndRecentIdentityRules() throws {
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try library(
      saved: [
        place("Café München", lat: 48, lon: 12, identity: "node/a", category: "cafe", address: "Hauptstraße 17"),
        place("École Zürich", lat: 49, lon: 13, identity: "node/b", category: "school"),
        place("São Paulo", lat: 50, lon: 14),
        place("東京", lat: 51, lon: 15, identity: "node/d", category: "museum"),
      ],
      recent: [
        place("Neuer Café-Name", lat: 48.1, lon: 12.1, identity: "node/a"),
        place("Museum München", lat: 48, lon: 12, identity: "node/other", category: "museum"),
        place("Anonymer Schulpunkt", lat: 49, lon: 13),
        place("Benanntes Duplikat", lat: 50, lon: 14, identity: "node/c"),
        place("Reise ＡＢＣ", lat: 52, lon: 16, identity: "kml/point", address: "Marktplatz 42"),
      ])
    for query in ["", "  ", "cafe", "CAFE MUNCHEN", "école", "Zurich", "SÃO", "東京", "ABC", "hauptstrasse 17", "museum", "München Museum", "  Marktplatz\t42  ", "missing"] {
      let expected = referenceProjection(store, query: query)
      #expect(store.personalMatches(query: query) == expected, "query: \(query)")
      #expect(store.personalMatches(query: query) == expected, "cached query: \(query)")
    }
    #expect(store.personalMatches(query: "").recent.map(\.place.name) == ["Museum München", "Reise ＡＢＣ"])
  }

  @Test func libraryMutationsInvalidatePreparedResultsAndRemainObservableOnCacheHits() throws {
    defer { defaults.removePersistentDomain(forName: suite) }
    let initial = place("Zuhause", identity: "node/home")
    let recent = place("Museum", lat: 49, lon: 13, identity: "node/museum", category: "museum")
    let store = try library(saved: [initial], recent: [recent])
    #expect(store.personalMatches(query: "Zuhause").saved.count == 1)
    let changes = PersonalPlaceChangeCounter()
    withObservationTracking {
      _ = store.personalMatches(query: "Zuhause")
    } onChange: { changes.increment() }
    #expect(store.renameSaved(id: try #require(store.saved.first).id, name: "Arbeit"))
    #expect(changes.count == 1)
    #expect(store.personalMatches(query: "Zuhause").saved.isEmpty)
    #expect(store.personalMatches(query: "Arbeit").saved.count == 1)
    #expect(store.personalMatches(query: "museum").recent.count == 1)
    #expect(store.save(recent))
    #expect(store.personalMatches(query: "museum").recent.isEmpty)
    #expect(store.personalMatches(query: "museum").saved.count == 1)
    store.removeSaved(id: try #require(store.savedEntry(for: recent)).id)
    #expect(store.personalMatches(query: "museum").recent.count == 1)

    let newPlace = place("Neuer Punkt", lat: 53, lon: 17, identity: "node/new")
    let lookupChanges = PersonalPlaceChangeCounter()
    withObservationTracking {
      #expect(store.savedEntry(for: newPlace) == nil)
    } onChange: { lookupChanges.increment() }
    #expect(store.save(newPlace))
    #expect(lookupChanges.count == 1)
    #expect(store.savedEntry(for: newPlace)?.place.name == newPlace.name)
    store.remember(newPlace)
    #expect(store.personalMatches(query: "Neuer").recent.isEmpty)
    store.clearRecent()
    #expect(store.personalMatches(query: "museum").recent.isEmpty)
    store.reset()
    #expect(store.personalMatches(query: "").saved.isEmpty)
    #expect(store.personalMatches(query: "").recent.isEmpty)
    #expect(store.savedEntry(for: initial) == nil)
  }
}
