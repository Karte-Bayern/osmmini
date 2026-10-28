import Foundation
import OSMmini
import Observation

@MainActor @Observable final class DemoPlaceLibrary {
  struct Entry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let place: DemoPlace
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

  private(set) var saved: [Entry] = []
  private(set) var recent: [Entry] = []
  private(set) var error: String?
  private(set) var needsReset = false
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
  }

  func savedEntry(for place: DemoPlace) -> Entry? {
    guard let place = Self.validated(place) else { return nil }
    return saved.first { Self.matches($0.place, place) }
  }

  @discardableResult func save(_ place: DemoPlace) -> Bool {
    guard canChange() else { return false }
    guard let place = Self.validated(place) else {
      error = "Dieser Ort enthält ungültige oder zu lange Ortsdaten."
      return false
    }
    if savedEntry(for: place) != nil {
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
    if let favorite = savedEntry(for: place) {
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
    for entry in entries {
      guard let place = validated(entry.place),
        !result.contains(where: { matches($0.place, place) })
      else { return nil }
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
    // About eleven centimetres at the equator: merge coordinate round trips,
    // while distinct OSM objects at the same position retain their identity.
    func rounded(_ value: Double) -> Int64 { Int64((value * 1_000_000).rounded()) }
    func longitude(_ value: Double) -> Int64 {
      let value = rounded(value)
      return value == 180_000_000 ? -180_000_000 : value
    }
    return rounded(lhs.coordinate.lat) == rounded(rhs.coordinate.lat)
      && longitude(lhs.coordinate.lon) == longitude(rhs.coordinate.lon)
  }
}
