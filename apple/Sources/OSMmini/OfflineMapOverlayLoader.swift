import Foundation
import Observation

struct OfflineMapOverlayFocusRequest: Equatable {
  let document: KMLDocument?
  let id: UUID?
}

@MainActor @Observable final class OfflineMapOverlayLoader {
  private struct Entry {
    let document: KMLDocument
    let prepared: PreparedMapOverlay
  }
  private var entries: [Entry] = []
  private var revision: UInt64 = 0

  func prepared(for documents: [KMLDocument]) -> [PreparedMapOverlay] {
    documents.compactMap { document in entries.first { $0.document == document }?.prepared }
  }

  func load(_ documents: [KMLDocument]) async {
    guard !Task.isCancelled else { return }
    revision &+= 1
    let current = revision
    entries.removeAll { entry in !documents.contains(entry.document) }
    for document in documents {
      guard !Task.isCancelled, revision == current else { return }
      guard !entries.contains(where: { $0.document == document }) else { continue }
      do {
        let prepared = try await PreparedMapOverlay.prepare(document)
        guard !Task.isCancelled, revision == current else { return }
        entries.append(Entry(document: document, prepared: prepared))
      } catch {
        // Cancelled or replaced documents never publish geometry into a new selection.
        if Task.isCancelled || revision != current { return }
      }
    }
  }
}
