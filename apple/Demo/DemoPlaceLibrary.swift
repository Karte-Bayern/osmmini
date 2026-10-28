import Foundation
import OSMmini
import Observation

@MainActor @Observable final class DemoPlaceLibrary {
  struct Entry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let place: DemoPlace
  }

  struct Matches: Equatable, Sendable {
    let saved: [Entry]
    let recent: [Entry]
  }

  static let storageKey = "personalPlaces"
  static let savedLimit = 500
  static let recentLimit = 20
  static let nameLimit = 200

  private struct Snapshot: Codable {
    let version: Int
    let saved: [Entry]
    let recent: [Entry]
  }

  private struct CoordinateKey: Hashable {
    let latitude: Int64
    let longitude: Int64

    init(_ coordinate: Coordinate) {
      latitude = Int64((coordinate.lat * 1_000_000).rounded())
      let rounded = Int64((coordinate.lon * 1_000_000).rounded())
      longitude = rounded == 180_000_000 ? -180_000_000 : rounded
    }
  }

  // Matching is deliberately not transitive: two source objects at one point
  // differ, while an anonymous map point can match either. Keep first positions
  // for each case instead of treating a coordinate as a universal identity.
  private struct SavedIndex {
    private var identities: [String: Int] = [:]
    private var coordinates: [CoordinateKey: Int] = [:]
    private var anonymousCoordinates: [CoordinateKey: Int] = [:]

    init(_ entries: [Entry] = []) {
      for (position, entry) in entries.enumerated() { add(entry.place, at: position) }
    }

    mutating func add(_ place: DemoPlace, at position: Int) {
      let coordinate = CoordinateKey(place.coordinate)
      if coordinates[coordinate] == nil { coordinates[coordinate] = position }
      if let identity = place.sourceIdentity {
        if identities[identity] == nil { identities[identity] = position }
      } else if anonymousCoordinates[coordinate] == nil {
        anonymousCoordinates[coordinate] = position
      }
    }

    func first(for place: DemoPlace) -> Int? {
      let coordinate = CoordinateKey(place.coordinate)
      guard let identity = place.sourceIdentity else { return coordinates[coordinate] }
      let exact = identities[identity]
      let anonymous = anonymousCoordinates[coordinate]
      if let exact, let anonymous { return min(exact, anonymous) }
      return exact ?? anonymous
    }
  }

  private struct SearchRecord {
    let entry: Entry
    let text: String

    init(_ entry: Entry) {
      self.entry = entry
      let place = entry.place
      text = "\(place.name) \(DemoPlaceText.category(place.category, kind: place.kind)) \(place.details?.address ?? "")"
    }
  }

  private struct PreparedSearch {
    let saved: [SearchRecord]
    let recent: [SearchRecord]
  }

  private struct SearchCache {
    let query: String
    let locale: Locale
    let matches: Matches
  }

  private(set) var saved: [Entry] = [] {
    didSet {
      savedIndex = SavedIndex(saved)
      invalidateSearch()
    }
  }
  private(set) var recent: [Entry] = [] { didSet { invalidateSearch() } }
  private(set) var error: String?
  private(set) var needsReset = false
  @ObservationIgnored private var savedIndex = SavedIndex()
  @ObservationIgnored private var preparedSearch: PreparedSearch?
  @ObservationIgnored private var searchCache: SearchCache?
  private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    guard let stored = defaults.object(forKey: Self.storageKey) else { return }
    guard let data = stored as? Data, data.count <= 2 * 1024 * 1024,
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    else {
      rejectStoredData()
      return
    }
    guard snapshot.version == 1 else {
      needsReset = true
      error =
        "Diese Ortsliste hat eine nicht unterstützte Version. Die Daten bleiben erhalten. Öffne sie mit einer passenden App-Version oder setze die Ortsliste zurück."
      return
    }
    guard let saved = Self.validated(snapshot.saved, limit: Self.savedLimit),
      let recent = Self.validated(snapshot.recent, limit: Self.recentLimit)
    else {
      rejectStoredData()
      return
    }
    self.saved = saved
    self.recent = recent
    savedIndex = SavedIndex(saved)
  }

  func savedEntry(for place: DemoPlace) -> Entry? {
    let entries = saved
    guard let place = Self.validated(place) else { return nil }
    guard let position = savedIndex.first(for: place) else { return nil }
    return entries[position]
  }

  func personalMatches(query: String) -> Matches {
    // Read the published arrays even on a cache hit so SwiftUI observes changes.
    let saved = self.saved
    let recent = self.recent
    let locale = Locale.current
    if let searchCache, searchCache.query == query, searchCache.locale == locale {
      return searchCache.matches
    }
    let prepared: PreparedSearch
    if let preparedSearch {
      prepared = preparedSearch
    } else {
      prepared = PreparedSearch(
        saved: saved.map(SearchRecord.init),
        recent: recent.filter { savedIndex.first(for: $0.place) == nil }.map(SearchRecord.init))
      preparedSearch = prepared
    }
    let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace).map(String.init)
    func filter(_ records: [SearchRecord]) -> [Entry] {
      records.compactMap { record in
        words.allSatisfy { record.text.localizedStandardContains($0) } ? record.entry : nil
      }
    }
    let matches = Matches(saved: filter(prepared.saved), recent: filter(prepared.recent))
    searchCache = SearchCache(query: query, locale: locale, matches: matches)
    return matches
  }

  private func invalidateSearch() {
    preparedSearch = nil
    searchCache = nil
  }

  @discardableResult func save(_ place: DemoPlace) -> Bool {
    guard canChange() else { return false }
    guard let place = Self.validated(place) else {
      error = "Dieser Ort enthält ungültige oder zu lange Ortsdaten."
      return false
    }
    if savedIndex.first(for: place) != nil {
      error = nil
      return true
    }
    guard saved.count < Self.savedLimit else {
      error = "Du kannst bis zu 500 Orte speichern. Entferne zuerst einen gespeicherten Ort."
      return false
    }
    var updated = saved
    updated.append(Entry(id: UUID(), place: place))
    return persist(saved: updated, recent: recent)
  }

  @discardableResult func renameSaved(id: UUID, name: String) -> Bool {
    guard canChange() else { return false }
    guard let index = saved.firstIndex(where: { $0.id == id }) else { return false }
    guard let name = Self.validatedName(name) else {
      error = "Bitte einen Namen mit 1 bis 200 Zeichen ohne Zeilenumbrüche eingeben."
      return false
    }
    let previous = saved[index]
    var updated = saved
    updated[index] = Entry(id: previous.id, place: Self.named(previous.place, name))
    let recent = recent.map { entry in
      Self.matches(entry.place, previous.place)
        ? Entry(id: entry.id, place: Self.named(entry.place, name)) : entry
    }
    return persist(saved: updated, recent: recent)
  }

  func removeSaved(id: UUID) {
    guard canChange() else { return }
    _ = persist(saved: saved.filter { $0.id != id }, recent: recent)
  }

  func remember(_ place: DemoPlace) {
    guard canChange() else { return }
    guard var place = Self.validated(place) else {
      error = "Dieser Ort enthält ungültige oder zu lange Ortsdaten."
      return
    }
    if let position = savedIndex.first(for: place) {
      let favorite = saved[position]
      place = Self.named(place, favorite.place.name, fallback: favorite.place)
    }
    let previous = recent.first { Self.matches($0.place, place) }
    var updated = recent.filter { !Self.matches($0.place, place) }
    updated.insert(Entry(id: previous?.id ?? UUID(), place: place), at: 0)
    updated = Array(updated.prefix(Self.recentLimit))
    guard updated != recent else { return }
    _ = persist(saved: saved, recent: updated)
  }

  func removeRecent(id: UUID) {
    guard canChange() else { return }
    _ = persist(saved: saved, recent: recent.filter { $0.id != id })
  }

  func clearRecent() {
    guard canChange() else { return }
    _ = persist(saved: saved, recent: [])
  }

  func dismissError() { error = nil }

  func reset() {
    defaults.removeObject(forKey: Self.storageKey)
    saved = []
    recent = []
    error = nil
    needsReset = false
  }

  private func canChange() -> Bool {
    guard !needsReset else {
      error = "Die vorhandene Ortsliste kann nicht geändert werden. Setze sie zuerst zurück."
      return false
    }
    return true
  }

  private func rejectStoredData() {
    needsReset = true
    error =
      "Gespeicherte Orte konnten nicht gelesen werden. Die vorhandenen Daten bleiben erhalten. Setze die Ortsliste zurück, um sie wieder zu verwenden."
  }

  private func persist(saved: [Entry], recent: [Entry]) -> Bool {
    do {
      let data = try JSONEncoder().encode(Snapshot(version: 1, saved: saved, recent: recent))
      guard data.count <= 2 * 1024 * 1024 else {
        error = "Die Ortsliste ist zu groß. Entferne zuerst einen gespeicherten Ort."
        return false
      }
      defaults.set(data, forKey: Self.storageKey)
      self.saved = saved
      self.recent = recent
      error = nil
      return true
    } catch {
      self.error = "Die Ortsliste konnte nicht gespeichert werden. Versuche es erneut."
      return false
    }
  }

  private static func validated(_ entries: [Entry], limit: Int) -> [Entry]? {
    guard entries.count <= limit, Set(entries.map(\.id)).count == entries.count else { return nil }
    var result: [Entry] = []
    var index = SavedIndex()
    for entry in entries {
      guard let place = validated(entry.place),
        index.first(for: place) == nil
      else { return nil }
      index.add(place, at: result.count)
      result.append(Entry(id: entry.id, place: place))
    }
    return result
  }

  private static func validated(_ place: DemoPlace) -> DemoPlace? {
    let coordinate = place.coordinate
    guard coordinate.lat.isFinite, coordinate.lon.isFinite,
      (-90...90).contains(coordinate.lat), (-180...180).contains(coordinate.lon),
      let name = validatedName(place.name),
      [place.category, place.kind, place.sourceIdentity].allSatisfy({
        $0.map { $0.utf8.count <= 512 } ?? true
      }),
      place.sourceIdentity?.isEmpty != true,
      validDetails(place.details)
    else { return nil }
    return named(place, name)
  }

  private static func validDetails(_ details: PlaceDetails?) -> Bool {
    guard let details else { return true }
    let values: [(String?, Int)] = [
      (details.address, 1024), (details.openingHours, 1024), (details.phone, 128),
      (details.website, 2048),
      (details.emergency?.reference, 256), (details.emergency?.hydrantType, 256),
      (details.emergency?.diameter, 256), (details.emergency?.pressure, 256),
      (details.emergency?.waterSource, 256), (details.emergency?.waterVolume, 256),
    ]
    return values.allSatisfy { value, limit in
      guard let value else { return true }
      return value.utf8.count <= limit
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
  }

  private static func validatedName(_ name: String) -> String? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= nameLimit, name.utf8.count <= 2048,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return name
  }

  private static func named(_ place: DemoPlace, _ name: String, fallback: DemoPlace? = nil)
    -> DemoPlace
  {
    DemoPlace(
      coordinate: place.coordinate, name: name, category: place.category ?? fallback?.category,
      kind: place.kind ?? fallback?.kind,
      sourceIdentity: place.sourceIdentity ?? fallback?.sourceIdentity, details: place.details)
  }

  private static func matches(_ lhs: DemoPlace, _ rhs: DemoPlace) -> Bool {
    if let left = lhs.sourceIdentity, let right = rhs.sourceIdentity { return left == right }
    return CoordinateKey(lhs.coordinate) == CoordinateKey(rhs.coordinate)
  }
}
