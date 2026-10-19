import Foundation
import OSMmini
import Testing

@testable import OSMminiDemoCLI

private typealias CatalogRow = (id: String, name: String, parent: String?)

private func catalogRegions(_ rows: [CatalogRow]) throws -> [GeofabrikRegion] {
  let features = rows.map { row -> [String: Any] in
    var properties: [String: Any] = [
      "id": row.id, "name": row.name,
      "urls": ["pbf": "https://download.geofabrik.de/\(row.id).osm.pbf"],
    ]
    if let parent = row.parent { properties["parent"] = parent }
    return ["properties": properties]
  }
  return try Geofabrik.decodeCatalog(JSONSerialization.data(withJSONObject: ["features": features]))
}

// Preserve the previous algorithm as the behavioral and timing reference.
private func referenceCatalogMatches(
  _ regions: [GeofabrikRegion], byID: [String: GeofabrikRegion], query: String
) -> (regions: [GeofabrikRegion], count: Int) {
  func normalizedWords(_ value: String) -> [String] {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }
  func context(_ region: GeofabrikRegion) -> String {
    var names: [String] = []
    var visited: Set<String> = [region.id]
    var parent = region.parent
    while let id = parent, names.count < 16, visited.insert(id).inserted,
      let ancestor = byID[id]
    {
      names.append(ancestor.name)
      parent = ancestor.parent
    }
    return names.reversed().joined(separator: " · ")
  }
  let words = normalizedWords(query)
  let query = words.joined(separator: " ")
  let matches = regions.compactMap { region -> (GeofabrikRegion, Int)? in
    let name = normalizedWords(region.name).joined(separator: " ")
    let id = normalizedWords(region.id).joined(separator: " ")
    let context = name + " " + id + " " + normalizedWords(context(region)).joined(separator: " ")
    guard words.allSatisfy({ context.contains($0) }) else { return nil }
    let rank = !query.isEmpty && (name == query || id == query) ? 0 : 1
    return (region, rank)
  }.sorted {
    if $0.1 != $1.1 { return $0.1 < $1.1 }
    let order = $0.0.name.localizedStandardCompare($1.0.name)
    return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
  }
  return (matches.prefix(50).map(\.0), matches.count)
}

@Test func preparedCatalogSearchPreservesLegacyRankingAndFullMatchCounts() throws {
  var rows: [CatalogRow] = [
    ("europe", "Europa", nil), ("germany", "Deutschland", "europe"),
    ("bayern", "Bayern", "germany"), ("oberbayern", "Oberbayern", "bayern"),
    ("accent", "Baden-Württemberg", "germany"), ("width", "Ｂａｙｅｒｎ", "europe"),
    ("cycle-a", "Kreis A", "cycle-b"), ("cycle-b", "Kreis B", "cycle-a"),
    ("orphan", "Ohne Eltern", "missing"),
  ]
  rows += (0..<75).map { ("exact-\($0)", "Region", "bayern") }
  rows += (0..<75).map { ("other-\($0)", "Andere Region \($0)", "germany") }
  rows += (0..<20).map { index in
    ("depth-\(index)", "Tiefe \(index)", index == 0 ? "europe" : "depth-\(index - 1)")
  }
  let regions = try catalogRegions(rows)
  let byID = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  let search = try DemoCatalogSearch(regions)
  for query in [
    "", "  / · ", "BAYERN", "niederbayern", "Europa bayern", "baden wurttemberg", "Kreis A",
    "Ohne Eltern", "region", "region deutschland", "tiefe 0", "depth 19", "not present",
  ] {
    let reference = referenceCatalogMatches(regions, byID: byID, query: query)
    let prepared = search.matches(query)
    #expect(prepared.count == reference.count, "query: \(query)")
    #expect(prepared.regions == reference.regions, "query: \(query)")
  }
  let exact = search.matches("region")
  #expect(exact.count == 150)
  #expect(exact.regions.count == 50)
  #expect(exact.regions.allSatisfy { $0.name == "Region" })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["OSMMINI_BENCHMARKS"] == "1"))
func catalogPreparedSearchBenchmark() throws {
  let continents: [CatalogRow] = [
    ("europe", "Europa", nil), ("north-america", "Nordamerika", nil),
    ("south-america", "Südamerika", nil), ("africa", "Afrika", nil),
    ("asia", "Asien", nil), ("australia-oceania", "Ozeanien", nil),
  ]
  let countries: [CatalogRow] = [
    ("germany", "Deutschland", "europe"), ("austria", "Österreich", "europe"),
    ("france", "Frankreich", "europe"), ("poland", "Polen", "europe"),
    ("canada", "Kanada", "north-america"), ("us", "USA", "north-america"),
    ("mexico", "Mexiko", "north-america"), ("cuba", "Kuba", "north-america"),
    ("brazil", "Brasilien", "south-america"), ("argentina", "Argentinien", "south-america"),
    ("chile", "Chile", "south-america"), ("peru", "Peru", "south-america"),
    ("egypt", "Ägypten", "africa"), ("kenya", "Kenia", "africa"),
    ("morocco", "Marokko", "africa"), ("south-africa", "Südafrika", "africa"),
    ("japan", "Japan", "asia"), ("india", "Indien", "asia"),
    ("china", "China", "asia"), ("thailand", "Thailand", "asia"),
    ("australia", "Australien", "australia-oceania"),
    ("new-zealand", "Neuseeland", "australia-oceania"),
    ("fiji", "Fidschi", "australia-oceania"), ("samoa", "Samoa", "australia-oceania"),
  ]
  let names = [
    "Bayern", "Île de France", "Łódź", "Québec", "Baden-Württemberg", "São Paulo", "New York",
    "München", "東京", "Kärnten", "Region", "Bayern", "Región Central",
  ]
  let subdivisions: [CatalogRow] = (0..<970).map { index in
    let country = countries[index % countries.count]
    return (
      country.id + "/region-\(index)", "\(names[index % names.count]) \(index / names.count)",
      country.id
    )
  }
  let regions = try catalogRegions(continents + countries + subdivisions)
  let byID = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  let queries = [
    "", "europe", "bayern deutschland", "baden wurttemberg", "québec", "new york", "東京",
    "region 10", "europe region 3", "not present",
  ]
  let clock = ContinuousClock()
  var search = DemoCatalogSearch()
  let preparation = try clock.measure { search = try DemoCatalogSearch(regions) }
  for query in queries {
    let reference = referenceCatalogMatches(regions, byID: byID, query: query)
    let prepared = search.matches(query)
    #expect(prepared.count == reference.count)
    #expect(prepared.regions == reference.regions)
  }
  let iterations = 15
  #expect(regions.count == 1000)
  for pass in 0..<3 {
    var reference = Duration.zero
    var prepared = Duration.zero
    var referenceCount = 0
    var preparedCount = 0
    for optimized in (pass.isMultiple(of: 2) ? [false, true] : [true, false]) {
      var count = 0
      let elapsed = clock.measure {
        for _ in 0..<iterations {
          for query in queries {
            if optimized {
              let found = search.matches(query)
              count += found.count + found.regions.count
            } else {
              let found = referenceCatalogMatches(regions, byID: byID, query: query)
              count += found.count + found.regions.count
            }
          }
        }
      }
      if optimized {
        prepared = elapsed
        preparedCount = count
      } else {
        reference = elapsed
        referenceCount = count
      }
    }
    #expect(referenceCount == preparedCount)
    print(
      "Catalog search pass \(pass + 1) (1000 regions × \(queries.count * iterations) queries): repeated normalization/sort \(reference), prepared records \(prepared), one-time preparation \(preparation)"
    )
  }
}
