import SwiftUI

/// Shared visual categories for offline map symbols and place inspectors.
/// Unknown OSM categories keep a neutral marker rather than an inferred type.
public enum POICategory: Sendable {
  case food, shopping, health, transport, lodging, culture, outdoors, services, emergency, other

  public init(_ category: String?) {
    switch category {
    case "cafe", "restaurant", "fast_food", "bar", "pub", "ice_cream": self = .food
    case "supermarket", "bakery", "convenience", "mall", "clothes", "books", "bicycle_shop",
      "bicycle":
      self = .shopping
    case "pharmacy", "hospital", "doctors", "dentist", "clinic": self = .health
    case "parking", "parking_entrance", "fuel", "charging_station", "station", "bus_stop",
      "bicycle_parking",
      "bicycle_repair_station", "bicycle_rental", "ferry_terminal", "aerodrome",
      "airport_terminal", "tram_stop", "public_transport_stop":
      self = .transport
    case "hotel", "hostel", "guest_house", "motel", "camp_site", "caravan_site", "alpine_hut",
      "wilderness_hut": self = .lodging
    case "museum", "attraction", "cinema", "theatre", "library", "place_of_worship":
      self = .culture
    case "park", "playground", "viewpoint", "picnic_site", "drinking_water", "peak", "saddle",
      "spring", "cave_entrance", "shelter", "bench", "picnic_table", "guidepost",
      "information", "nature_reserve", "bbq": self = .outdoors
    case "bank", "atm", "post_office", "toilets", "school", "kindergarten": self = .services
    case "fire_hydrant", "suction_point", "fire_water_pond", "water_tank", "fire_station",
      "ambulance_station", "defibrillator", "access_point", "assembly_point", "police",
      "fire_service_inlet", "fire_hose", "fire_extinguisher", "first_aid", "siren", "phone":
      self = .emergency
    default: self = .other
    }
  }

  public var symbolName: String {
    switch self {
    case .food: "fork.knife"
    case .shopping: "basket.fill"
    case .health: "cross.case.fill"
    case .transport: "car.fill"
    case .lodging: "bed.double.fill"
    case .culture: "building.columns.fill"
    case .outdoors: "leaf.fill"
    case .services: "building.2.fill"
    case .emergency: "cross.case.fill"
    case .other: "mappin"
    }
  }

  /// Familiar symbols for common POIs, falling back to their category group.
  public static func symbolName(for category: String?) -> String {
    switch category {
    case "cafe": "cup.and.saucer.fill"
    case "parking", "parking_entrance": "parkingsign"
    case "fuel": "fuelpump.fill"
    case "charging_station": "bolt.car.fill"
    case "station", "tram_stop": "tram.fill"
    case "bus_stop", "public_transport_stop": "bus.fill"
    case "bicycle_parking", "bicycle_rental", "bicycle_shop", "bicycle": "bicycle"
    case "bicycle_repair_station": "wrench.and.screwdriver.fill"
    case "ferry_terminal": "ferry.fill"
    case "aerodrome", "airport_terminal": "airplane"
    case "drinking_water", "spring": "drop.fill"
    case "viewpoint": "binoculars.fill"
    case "peak", "saddle", "cave_entrance": "mountain.2.fill"
    case "shelter", "alpine_hut", "wilderness_hut": "house.fill"
    case "bench": "chair.fill"
    case "picnic_site", "picnic_table": "basket.fill"
    case "bbq": "flame.fill"
    case "camp_site", "caravan_site": "tent.fill"
    case "guidepost": "signpost.right.fill"
    case "information": "info.circle.fill"
    case "nature_reserve": "leaf.fill"
    case "bank", "atm": "banknote.fill"
    case "post_office": "envelope.fill"
    case "library", "books": "books.vertical.fill"
    case "school", "kindergarten": "graduationcap.fill"
    case "toilets": "figure.dress.line.vertical.figure"
    case "fire_hydrant": "drop.fill"
    case "suction_point", "fire_water_pond", "water_tank": "drop.circle.fill"
    case "fire_station", "fire_service_inlet", "fire_hose", "fire_extinguisher": "flame.fill"
    case "ambulance_station", "first_aid": "cross.case.fill"
    case "defibrillator": "heart.fill"
    case "access_point": "mappin.and.ellipse"
    case "assembly_point": "person.3.fill"
    case "police": "shield.fill"
    case "siren": "speaker.wave.2.fill"
    case "phone": "phone.fill"
    default: POICategory(category).symbolName
    }
  }

  /// Dark enough for white symbols and readable on the light offline basemap.
  public var tint: Color {
    switch self {
    case .food: Color(red: 0.65, green: 0.29, blue: 0.08)
    case .shopping: Color(red: 0.24, green: 0.35, blue: 0.68)
    case .health: Color(red: 0.70, green: 0.19, blue: 0.28)
    case .transport: Color(red: 0.18, green: 0.37, blue: 0.53)
    case .lodging: Color(red: 0.48, green: 0.28, blue: 0.62)
    case .culture: Color(red: 0.52, green: 0.31, blue: 0.43)
    case .outdoors: Color(red: 0.20, green: 0.43, blue: 0.27)
    case .services: Color(red: 0.37, green: 0.39, blue: 0.43)
    case .emergency: Color(red: 0.72, green: 0.19, blue: 0.16)
    case .other: Color(red: 0.35, green: 0.34, blue: 0.55)
    }
  }
}
