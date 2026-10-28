import OSMmini
import Testing

@testable import OSMminiDemoCLI

@Test func outdoorCyclingAndTravelCategoriesHaveReadableGermanNames() {
  let names = [
    "peak": "Gipfel", "saddle": "Bergsattel", "spring": "Quelle",
    "cave_entrance": "Höhleneingang", "shelter": "Unterstand", "bench": "Sitzbank",
    "bbq": "Grillplatz", "picnic_table": "Picknicktisch", "nature_reserve": "Naturschutzgebiet",
    "alpine_hut": "Berghütte", "wilderness_hut": "Wildnishütte",
    "caravan_site": "Wohnmobilstellplatz", "information": "Information",
    "guidepost": "Wegweiser", "bicycle_shop": "Fahrradgeschäft", "bicycle": "Fahrradgeschäft",
    "bicycle_repair_station": "Fahrrad-Reparaturstation", "bicycle_rental": "Fahrradverleih",
    "tram_stop": "Straßenbahnhaltestelle", "public_transport_stop": "Haltestelle",
    "ferry_terminal": "Fähranleger", "aerodrome": "Flugplatz",
    "airport_terminal": "Flughafenterminal",
    "parking_entrance": "Parkhauseinfahrt",
  ]
  for (category, label) in names {
    #expect(DemoPlaceText.category(category, kind: "node") == label)
    let coordinate = Coordinate(lat: 48.5, lon: 12.5)
    let source = MapFeature(name: category, kind: "node", category: category)
    #expect(DemoPlace(MapSelection(coordinate: coordinate, feature: source)).name == label)
    let named = MapFeature(name: "Standort 12", kind: "node", category: category)
    #expect(DemoPlace(MapSelection(coordinate: coordinate, feature: named)).name == "Standort 12")
  }
  #expect(DemoPlaceText.category("cycleway", kind: "street") == "Radweg")
  #expect(DemoPlaceText.category("fire_hydrant", kind: "node") == "Hydrant")
}
