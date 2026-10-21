import SwiftUI

/// Shared visual categories for offline map symbols and place inspectors.
/// Unknown OSM categories keep a neutral marker rather than an inferred type.
public enum POICategory: Sendable {
  case food, shopping, health, transport, lodging, culture, outdoors, services, other

  public init(_ category: String?) {
    switch category {
    case "cafe", "restaurant", "fast_food", "bar", "pub", "ice_cream": self = .food
    case "supermarket", "bakery", "convenience", "mall", "clothes", "books": self = .shopping
    case "pharmacy", "hospital", "doctors", "dentist", "clinic": self = .health
    case "parking", "fuel", "charging_station", "station", "bus_stop", "bicycle_parking":
      self = .transport
    case "hotel", "hostel", "guest_house", "motel", "camp_site": self = .lodging
    case "museum", "attraction", "cinema", "theatre", "library", "place_of_worship":
      self = .culture
    case "park", "playground", "viewpoint", "picnic_site", "drinking_water": self = .outdoors
    case "bank", "atm", "post_office", "toilets", "school", "kindergarten": self = .services
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
    case .other: "mappin"
    }
  }

  /// Familiar symbols for common POIs, falling back to their category group.
  public static func symbolName(for category: String?) -> String {
    switch category {
    case "cafe": "cup.and.saucer.fill"
    case "parking": "parkingsign"
    case "fuel": "fuelpump.fill"
    case "charging_station": "bolt.car.fill"
    case "station": "tram.fill"
    case "bus_stop": "bus.fill"
    case "bicycle_parking": "bicycle"
    case "drinking_water": "drop.fill"
    case "viewpoint": "binoculars.fill"
    case "bank", "atm": "banknote.fill"
    case "post_office": "envelope.fill"
    case "library", "books": "books.vertical.fill"
    case "school", "kindergarten": "graduationcap.fill"
    case "toilets": "figure.dress.line.vertical.figure"
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
    case .other: Color(red: 0.35, green: 0.34, blue: 0.55)
    }
  }
}
