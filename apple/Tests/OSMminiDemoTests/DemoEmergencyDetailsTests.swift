import Foundation
import OSMmini
import Testing

@testable import OSMminiDemoCLI

struct DemoEmergencyDetailsTests {
  @Test func emergencyCategoriesHaveReadableGermanNamesWithoutChangingNamedPlaces() {
    let names = [
      "fire_hydrant": "Hydrant", "suction_point": "Saugstelle",
      "fire_water_pond": "Löschwasserteich", "water_tank": "Löschwassertank",
      "fire_station": "Feuerwehr", "ambulance_station": "Rettungswache",
      "defibrillator": "Defibrillator", "access_point": "Rettungspunkt",
      "assembly_point": "Sammelstelle", "police": "Polizei",
      "fire_service_inlet": "Löschwassereinspeisung", "fire_hose": "Feuerlöschschlauch",
      "fire_extinguisher": "Feuerlöscher", "first_aid": "Erste Hilfe",
      "siren": "Sirene", "phone": "Notruftelefon",
    ]
    for (category, label) in names {
      let coordinate = Coordinate(lat: 48.5, lon: 12.5)
      #expect(DemoPlaceText.category(category, kind: "node") == label)
      let source = MapFeature(name: category, kind: "node", category: category)
      #expect(DemoPlace(MapSelection(coordinate: coordinate, feature: source)).name == label)
      let named = MapFeature(name: "Standort 12", kind: "node", category: category)
      #expect(DemoPlace(MapSelection(coordinate: coordinate, feature: named)).name == "Standort 12")
    }
  }

  @Test func technicalDetailsPreserveSourceUnitsAndDoNotInventMissingValues() {
    let details = EmergencyDetails(
      reference: " H-12 ", hydrantType: "underground", diameter: "100", pressure: "6",
      waterSource: "main", waterVolume: "50 m³")
    let rows = DemoPlaceText.emergencyDetails(details)
    #expect(rows.map(\.title) == [
      "Kennung", "Bauart", "Durchmesser (OSM)", "Druck (OSM)", "Wasserquelle", "Wasservolumen (OSM)",
    ])
    #expect(rows.map(\.value) == ["H-12", "Unterflurhydrant", "100", "6", "Wassernetz", "50 m³"])
    #expect(DemoPlaceText.emergencyDetails(nil).isEmpty)
    #expect(DemoPlaceText.emergencyDetails(EmergencyDetails(reference: " ")).isEmpty)
    let unusual = DemoPlaceText.emergencyDetails(
      EmergencyDetails(hydrantType: "custom", pressure: "suction", waterSource: "custom-source"))
    #expect(unusual.map(\.value) == ["custom", "suction", "custom-source"])
    for (type, expected) in [
      ("pillar", "Überflurhydrant"), ("wall", "Wandhydrant"), ("pipe", "Rohranschluss"),
      ("pond", "Teichanschluss"),
    ] {
      #expect(DemoPlaceText.emergencyDetails(EmergencyDetails(hydrantType: type)).first?.value == expected)
    }
  }

  @Test @MainActor func savedTechnicalDetailsSurviveReopeningAndRejectMalformedSourceValues() throws {
    let suite = "DemoEmergencyDetailsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = DemoPlaceLibrary(defaults: defaults)
    let details = PlaceDetails(emergency: EmergencyDetails(
      reference: "H-12", hydrantType: "pillar", diameter: "DN 100", pressure: "6 bar",
      waterSource: "pond", waterVolume: "50"))
    let source = DemoPlace(
      coordinate: Coordinate(lat: 48.5, lon: 12.5), name: "Hydrant H-12", category: "fire_hydrant",
      kind: "node", sourceIdentity: "node/123", details: details)
    #expect(library.save(source))
    library.remember(source)
    let savedID = try #require(library.saved.first).id
    #expect(library.renameSaved(id: savedID, name: "Hydrant am Gerätehaus"))
    let reopened = DemoPlaceLibrary(defaults: defaults)
    #expect(reopened.saved.first?.place.details == details)
    #expect(reopened.recent.first?.place.details == details)
    let before = defaults.data(forKey: DemoPlaceLibrary.storageKey)
    for emergency in [
      EmergencyDetails(reference: String(repeating: "a", count: 257)),
      EmergencyDetails(hydrantType: "pillar\nwall"),
      EmergencyDetails(diameter: String(repeating: "ä", count: 129)),
      EmergencyDetails(pressure: "6\u{0000}bar"),
      EmergencyDetails(waterSource: String(repeating: "a", count: 257)),
      EmergencyDetails(waterVolume: "50\r100"),
    ] {
      let invalid = DemoPlace(
        coordinate: source.coordinate, name: "Invalid", category: "fire_hydrant", kind: "node",
        sourceIdentity: "node/456", details: PlaceDetails(emergency: emergency))
      #expect(!reopened.save(invalid))
      reopened.remember(invalid)
      #expect(defaults.data(forKey: DemoPlaceLibrary.storageKey) == before)
    }
  }
}
