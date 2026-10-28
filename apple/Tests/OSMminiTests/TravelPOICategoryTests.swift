import Testing

@testable import OSMmini

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

@Test @MainActor func outdoorCyclingAndTravelPOIsHaveAvailableNativeSymbols() {
  let symbols = [
    "peak": "mountain.2.fill", "saddle": "mountain.2.fill",
    "spring": "drop.fill", "cave_entrance": "mountain.2.fill",
    "shelter": "house.fill", "bench": "chair.fill", "bbq": "flame.fill",
    "picnic_table": "basket.fill", "nature_reserve": "leaf.fill",
    "alpine_hut": "house.fill", "wilderness_hut": "house.fill",
    "caravan_site": "tent.fill", "information": "info.circle.fill",
    "guidepost": "signpost.right.fill", "bicycle_shop": "bicycle", "bicycle": "bicycle",
    "bicycle_repair_station": "wrench.and.screwdriver.fill", "bicycle_rental": "bicycle",
    "tram_stop": "tram.fill", "public_transport_stop": "bus.fill",
    "ferry_terminal": "ferry.fill", "aerodrome": "airplane", "airport_terminal": "airplane",
    "parking_entrance": "parkingsign",
  ]
  for (category, symbol) in symbols {
    #expect(POICategory.symbolName(for: category) == symbol)
    #if os(macOS)
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    #elseif os(iOS)
      #expect(UIImage(systemName: symbol) != nil)
    #endif
  }
  #expect(POICategory.symbolName(for: "unclassified_outdoor_object") == "mappin")
  #expect(POICategory.symbolName(for: "fire_hydrant") == "drop.fill")
}

@Test func newTravelPOIsUseTheirRelevantVisualGroups() {
  for category in [
    "peak", "saddle", "spring", "cave_entrance", "shelter", "bench", "bbq", "picnic_table",
    "nature_reserve", "information", "guidepost",
  ] {
    guard case .outdoors = POICategory(category) else {
      Issue.record("\(category) has no outdoor visual category")
      continue
    }
  }
  for category in ["alpine_hut", "wilderness_hut", "caravan_site"] {
    guard case .lodging = POICategory(category) else {
      Issue.record("\(category) has no lodging visual category")
      continue
    }
  }
  for category in [
    "bicycle_repair_station", "bicycle_rental", "tram_stop", "public_transport_stop",
    "ferry_terminal", "aerodrome", "airport_terminal", "parking_entrance",
  ] {
    guard case .transport = POICategory(category) else {
      Issue.record("\(category) has no transport visual category")
      continue
    }
  }
  for category in ["bicycle", "bicycle_shop"] {
    guard case .shopping = POICategory(category) else {
      Issue.record("\(category) has no shopping visual category")
      continue
    }
  }
}
