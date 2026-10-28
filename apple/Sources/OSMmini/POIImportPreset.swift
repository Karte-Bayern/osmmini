import Foundation

/// Selects which points of interest enter a newly prepared region's search and map.
/// Routing roads, addresses, settlements and basemap geometry remain available.
public enum POIImportPreset: String, Codable, CaseIterable, Identifiable, Sendable {
  case everyday, firefighting, outdoor, cycling, travel, all

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .everyday: "Alltag"
    case .firefighting: "Feuerwehr"
    case .outdoor: "Outdoor"
    case .cycling: "Radfahren"
    case .travel: "Reisen"
    case .all: "Alle POIs"
    }
  }

  public var summary: String {
    switch self {
    case .everyday:
      "Geschäfte, Gastronomie, Gesundheit, Freizeit und öffentliche Einrichtungen. Technische Einsatzobjekte werden ausgelassen."
    case .firefighting:
      "Hydranten, Löschwasserstellen, Rettungspunkte und einsatzrelevante Einrichtungen."
    case .outdoor:
      "Trinkwasser, Toiletten, Schutzhütten, Campingplätze, Aussichtspunkte und Orientierung in der Natur."
    case .cycling:
      "Fahrradgeschäfte, Reparaturstationen, Verleih und Stellplätze sowie Trinkwasser, Rastplätze und Versorgung unterwegs."
    case .travel:
      "Unterkünfte, Sehenswürdigkeiten, Gastronomie und wichtige Anlaufstellen für die An- und Weiterreise."
    case .all:
      "Alle unterstützten POI-Kategorien einschließlich technischer Einsatzobjekte."
    }
  }
}
