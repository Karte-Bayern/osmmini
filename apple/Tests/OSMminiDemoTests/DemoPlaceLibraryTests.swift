import Foundation
import OSMmini
import Testing

@testable import OSMminiDemoCLI

@MainActor struct DemoPlaceLibraryTests {
  private func withStore(_ test: (DemoPlaceLibrary, UserDefaults) throws -> Void) throws {
    let suite = "DemoPlaceLibraryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try test(DemoPlaceLibrary(defaults: defaults), defaults)
  }

  private func place(
    _ name: String = "Rathaus", lat: Double = 48.576, lon: Double = 13.465,
    identity: String? = "node/123"
  ) -> DemoPlace {
    DemoPlace(
      coordinate: Coordinate(lat: lat, lon: lon), name: name, category: "townhall", kind: "node",
      sourceIdentity: identity)
  }

  @Test func savedAndRecentPlacesSurviveReopeningAndRemainIndependent() throws {
    try withStore { library, defaults in
      let first = place()
      let second = place("Bahnhof", lat: 48.574, identity: "node/456")
      #expect(library.save(first))
      library.remember(first)
      library.remember(second)
      let reopened = DemoPlaceLibrary(defaults: defaults)
      #expect(reopened.saved == library.saved)
      #expect(reopened.recent == library.recent)
      #expect(reopened.recent.map(\.place.name) == ["Bahnhof", "Rathaus"])
      reopened.clearRecent()
      #expect(reopened.recent.isEmpty)
      #expect(reopened.saved.count == 1)
      let again = DemoPlaceLibrary(defaults: defaults)
      #expect(again.recent.isEmpty && again.saved.count == 1)
      again.removeSaved(id: try #require(again.saved.first).id)
      #expect(DemoPlaceLibrary(defaults: defaults).saved.isEmpty)
    }
  }

  @Test func savedDetailsSurviveRenamingHistoryAndReopening() throws {
    try withStore { library, defaults in
      let details = PlaceDetails(
        address: "Marktplatz 3 · 84130 Dingolfing", openingHours: "Mo-Sa 08:00-18:00",
        phone: "+49 8731 123456", website: "https://example.org/cafe")
      let source = DemoPlace(
        coordinate: Coordinate(lat: 48.576, lon: 13.465), name: "Café am Markt", category: "cafe",
        kind: "node", sourceIdentity: "node/123", details: details)
      #expect(library.save(source))
      library.remember(source)
      let savedID = try #require(library.saved.first).id
      #expect(library.renameSaved(id: savedID, name: "Unser Treffpunkt"))
      let reopened = DemoPlaceLibrary(defaults: defaults)
      #expect(reopened.saved.first?.place.name == "Unser Treffpunkt")
      #expect(reopened.saved.first?.place.details == details)
      #expect(reopened.recent.first?.place.details == details)

      let withoutDetails = DemoPlace(
        coordinate: source.coordinate, name: source.name, category: source.category,
        kind: source.kind, sourceIdentity: source.sourceIdentity)
      reopened.remember(withoutDetails)
      #expect(reopened.recent.first?.place.name == "Unser Treffpunkt")
      #expect(reopened.recent.first?.place.details == nil)
      #expect(DemoPlaceLibrary(defaults: defaults).recent.first?.place.details == nil)
      #expect(reopened.saved.first?.place.details == details)
    }
  }

  @Test func legacyPlacesWithoutDetailsRemainReadableAndEditable() throws {
    try withStore { _, defaults in
      let id = UUID()
      let raw = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "saved": [
          [
            "id": id.uuidString,
            "place": [
              "coordinate": ["lat": 48.576, "lon": 13.465],
              "name": "Rathaus", "category": "townhall", "kind": "node",
              "sourceIdentity": "node/123",
            ],
          ]
        ],
        "recent": [],
      ])
      defaults.set(raw, forKey: DemoPlaceLibrary.storageKey)
      let library = DemoPlaceLibrary(defaults: defaults)
      #expect(!library.needsReset && library.error == nil)
      #expect(library.saved.first?.id == id)
      #expect(library.saved.first?.place.name == "Rathaus")
      #expect(library.saved.first?.place.details == nil)
      #expect(library.renameSaved(id: id, name: "Treffpunkt"))
      let reopened = DemoPlaceLibrary(defaults: defaults)
      #expect(reopened.saved.first?.place.name == "Treffpunkt")
      #expect(reopened.saved.first?.place.details == nil)
    }
  }

  @Test func invalidDetailsCannotReplaceStoredPlacesAndRequireResetWhenLoaded() throws {
    try withStore { library, defaults in
      #expect(library.save(place()))
      let before = defaults.data(forKey: DemoPlaceLibrary.storageKey)
      let invalidDetails = [
        PlaceDetails(address: String(repeating: "a", count: 1025)),
        PlaceDetails(openingHours: String(repeating: "a", count: 1025)),
        PlaceDetails(phone: String(repeating: "1", count: 129)),
        PlaceDetails(website: String(repeating: "a", count: 2049)),
        PlaceDetails(address: "Adresse\nZweite Zeile"),
        PlaceDetails(openingHours: "Mo-Fr\t08:00-17:00"),
        PlaceDetails(phone: "+49\u{0000}1234"),
        PlaceDetails(website: "https://example.org/\rpath"),
        PlaceDetails(address: String(repeating: "ä", count: 513)),
      ]
      for details in invalidDetails {
        let invalid = DemoPlace(
          coordinate: Coordinate(lat: 48.576, lon: 13.465), name: "Anderer Ort", category: "cafe",
          kind: "node", sourceIdentity: "node/456", details: details)
        #expect(!library.save(invalid))
        library.remember(invalid)
        #expect(library.error != nil)
        #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == before)

        let entry = DemoPlaceLibrary.Entry(id: UUID(), place: invalid)
        let raw = try JSONSerialization.data(withJSONObject: [
          "version": 1,
          "saved": try JSONSerialization.jsonObject(with: JSONEncoder().encode([entry])),
          "recent": [],
        ])
        defaults.set(raw, forKey: DemoPlaceLibrary.storageKey)
        let restored = DemoPlaceLibrary(defaults: defaults)
        #expect(restored.needsReset && restored.error != nil)
        #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == raw)
        defaults.set(before, forKey: DemoPlaceLibrary.storageKey)
      }
    }
  }

  @Test func favoriteNamesSurviveRepeatedSearchResultsAndRecentRenaming() throws {
    try withStore { library, defaults in
      let source = place()
      #expect(library.save(source))
      library.remember(source)
      let savedID = try #require(library.saved.first).id
      let recentID = try #require(library.recent.first).id
      #expect(library.renameSaved(id: savedID, name: "  Treffpunkt  "))
      #expect(library.saved.first?.place.name == "Treffpunkt")
      #expect(library.recent.first?.place.name == "Treffpunkt")
      #expect(library.save(source))
      library.remember(place("Neuer OSM-Name", lat: 48.575, identity: source.sourceIdentity))
      #expect(library.saved.count == 1 && library.recent.count == 1)
      #expect(library.saved.first?.id == savedID && library.recent.first?.id == recentID)
      #expect(library.saved.first?.place.name == "Treffpunkt")
      #expect(library.recent.first?.place.name == "Treffpunkt")
      #expect(library.recent.first?.place.coordinate.lat == 48.575)
      #expect(DemoPlaceLibrary(defaults: defaults).saved == library.saved)
    }
  }

  @Test func identitiesDistinguishCoincidentObjectsAndCoordinatesDeduplicateMapPoints() throws {
    try withStore { library, _ in
      #expect(library.save(place(identity: "node/1")))
      #expect(library.save(place("Brunnen", identity: "node/2")))
      #expect(library.saved.count == 2)
      #expect(library.save(place("Kartenpunkt", lat: 48.57600001, identity: nil)))
      #expect(library.saved.count == 2)
      #expect(library.savedEntry(for: place("Anderer Name", identity: "node/1")) != nil)
      #expect(library.savedEntry(for: place("Anderer Ort", identity: "node/3")) == nil)
      #expect(library.save(place("Datumsgrenze", lat: 0, lon: 180, identity: nil)))
      #expect(
        library.savedEntry(for: place("Datumsgrenze", lat: 0, lon: -180, identity: nil)) != nil)
    }
  }

  @Test func recentPlacesHaveBoundedDeterministicOrderAndCanBeRemovedIndividually() throws {
    try withStore { library, defaults in
      for index in 0..<25 {
        library.remember(place("Ort \(index)", identity: "node/\(index)"))
      }
      #expect(library.recent.count == DemoPlaceLibrary.recentLimit)
      #expect(library.recent.first?.place.name == "Ort 24")
      #expect(library.recent.last?.place.name == "Ort 5")
      let previousID = try #require(library.recent.first { $0.place.name == "Ort 10" }).id
      library.remember(place("Ort 10", identity: "node/10"))
      #expect(library.recent.first?.id == previousID)
      #expect(library.recent[1].place.name == "Ort 24")
      library.removeRecent(id: previousID)
      #expect(library.recent.count == 19)
      #expect(!library.recent.contains { $0.id == previousID })
      #expect(DemoPlaceLibrary(defaults: defaults).recent == library.recent)
    }
  }

  @Test func savedLimitRejectsNewEntriesButAllowsExistingOnesAndDeletion() throws {
    try withStore { library, defaults in
      let entries = (0..<DemoPlaceLibrary.savedLimit).map {
        DemoPlaceLibrary.Entry(id: UUID(), place: place("Ort \($0)", identity: "node/\($0)"))
      }
      let snapshot = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "saved": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)),
        "recent": [],
      ])
      defaults.set(snapshot, forKey: DemoPlaceLibrary.storageKey)
      let full = DemoPlaceLibrary(defaults: defaults)
      #expect(!full.needsReset && full.saved.count == 500)
      #expect(full.save(entries[0].place))
      #expect(!full.save(place("Ein Ort zu viel", identity: "node/1000")))
      #expect(full.error != nil)
      #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == snapshot)
      full.removeSaved(id: entries[0].id)
      #expect(full.save(place("Neuer Ort", identity: "node/1000")))
      #expect(full.saved.count == 500 && full.error == nil)
      #expect(library.saved.isEmpty)
    }
  }

  @Test func invalidPlacesAndNamesDoNotChangePreviouslyStoredData() throws {
    try withStore { library, defaults in
      #expect(library.save(place()))
      let before = defaults.data(forKey: DemoPlaceLibrary.storageKey)
      for invalid in [
        place(" "), place("Zeile\nZwei"), place(String(repeating: "a", count: 201)),
        place(lat: .nan), place(lon: .infinity), place(lat: 91), place(lon: -181),
        place(identity: ""), place(identity: String(repeating: "a", count: 513)),
      ] {
        #expect(!library.save(invalid))
        library.remember(invalid)
        #expect(library.error != nil)
        #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == before)
      }
      let savedID = try #require(library.saved.first).id
      #expect(!library.renameSaved(id: savedID, name: ""))
      #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == before)
      library.dismissError()
      #expect(library.error == nil)
    }
  }

  @Test func corruptUnsupportedAndOversizedDataStayIntactUntilExplicitReset() throws {
    try withStore { _, defaults in
      let invalidSnapshots: [Any] = [
        Data("broken".utf8),
        Data("{\"version\":2,\"saved\":[],\"recent\":[]}".utf8),
        Data(repeating: 32, count: 2 * 1024 * 1024 + 1),
        "wrong storage type",
      ]
      for raw in invalidSnapshots {
        defaults.set(raw, forKey: DemoPlaceLibrary.storageKey)
        let library = DemoPlaceLibrary(defaults: defaults)
        #expect(library.needsReset && library.error != nil)
        library.dismissError()
        #expect(library.needsReset && library.error == nil)
        #expect(!library.save(place()))
        #expect(!library.renameSaved(id: UUID(), name: "Neuer Name"))
        library.remember(place())
        library.removeRecent(id: UUID())
        library.removeSaved(id: UUID())
        library.clearRecent()
        #expect(library.saved.isEmpty && library.recent.isEmpty)
        if let data = raw as? Data {
          #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == data)
        } else {
          #expect(defaults.string(forKey: DemoPlaceLibrary.storageKey) == (raw as? String))
        }
        library.reset()
        #expect(!library.needsReset && library.error == nil)
        #expect(defaults.object(forKey: DemoPlaceLibrary.storageKey) == nil)
        #expect(library.save(place()))
        #expect(DemoPlaceLibrary(defaults: defaults).saved.count == 1)
      }
    }
  }

  @Test func invalidStoredCoordinatesDuplicateIdentitiesAndDuplicateEntryIDsRequireReset() throws {
    try withStore { _, defaults in
      let first = DemoPlaceLibrary.Entry(id: UUID(), place: place())
      let duplicateIdentity = DemoPlaceLibrary.Entry(id: UUID(), place: place("Auch Rathaus"))
      let duplicateID = DemoPlaceLibrary.Entry(id: first.id, place: place(identity: "node/456"))
      let invalid = DemoPlaceLibrary.Entry(id: UUID(), place: place(lat: 91))
      for entries in [[first, duplicateIdentity], [first, duplicateID], [invalid]] {
        let raw = try JSONSerialization.data(withJSONObject: [
          "version": 1,
          "saved": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)),
          "recent": [],
        ])
        defaults.set(raw, forKey: DemoPlaceLibrary.storageKey)
        let library = DemoPlaceLibrary(defaults: defaults)
        #expect(library.needsReset)
        #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == raw)
      }
    }
  }
}
