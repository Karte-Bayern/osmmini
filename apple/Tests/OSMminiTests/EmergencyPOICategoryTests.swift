import Testing

@testable import OSMmini

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

@Test @MainActor func emergencyResourcesHaveRecognizableNativeSymbols() throws {
  let symbols = [
    "fire_hydrant": "drop.fill", "suction_point": "drop.circle.fill",
    "fire_water_pond": "drop.circle.fill", "water_tank": "drop.circle.fill",
    "fire_station": "flame.fill", "ambulance_station": "cross.case.fill",
    "defibrillator": "heart.fill", "access_point": "mappin.and.ellipse",
    "assembly_point": "person.3.fill", "police": "shield.fill",
    "fire_service_inlet": "flame.fill", "fire_hose": "flame.fill",
    "fire_extinguisher": "flame.fill", "first_aid": "cross.case.fill",
    "siren": "speaker.wave.2.fill", "phone": "phone.fill",
  ]
  for (category, symbol) in symbols {
    guard case .emergency = POICategory(category) else {
      Issue.record("\(category) has no emergency visual category")
      continue
    }
    #expect(POICategory.symbolName(for: category) == symbol)
    #if os(macOS)
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    #elseif os(iOS)
      #expect(UIImage(systemName: symbol) != nil)
    #endif
  }
  #expect(POICategory.symbolName(for: "unknown_emergency") == "mappin")
  #expect(POICategory.symbolName(for: "drinking_water") == "drop.fill")
  #expect(POICategory.symbolName(for: "pharmacy") == "cross.case.fill")
}
