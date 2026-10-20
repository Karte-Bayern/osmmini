import Foundation

/// Full-tile drawing uses a range without allocating an index array. Partial
/// views return unique indices in their original paint order.
struct PreparedMapFeatureIndices: RandomAccessCollection {
  let count: Int
  private let selected: [UInt32]?
  var startIndex: Int { 0 }
  var endIndex: Int { count }

  init(count: Int) {
    self.count = count
    selected = nil
  }

  init(_ selected: [UInt32]) {
    count = selected.count
    self.selected = selected
  }

  subscript(position: Int) -> Int {
    selected.map { Int($0[position]) } ?? position
  }
}

/// A feature lives in the smallest grid cell that contains its entire path.
/// Crossing geometry stays in a coarser cell instead of being duplicated or
/// clipped. Only four bytes per feature and 86 offsets are retained per tile.
struct PreparedMapTileIndex: Sendable {
  static let tileBounds = CGRect(x: 0, y: 0, width: 256, height: 256)
  private static let levels = [(side: 1, offset: 0), (2, 1), (4, 5), (8, 21)]
  private static let cellCount = levels.reduce(0) { $0 + $1.0 * $1.0 }
  private static let cells: [CGRect] = levels.flatMap { side, _ in
    let width = 256 / Double(side)
    return (0..<side).flatMap { y in
      (0..<side).map { x in
        CGRect(x: Double(x) * width, y: Double(y) * width, width: width, height: width)
      }
    }
  }

  private let offsets: [UInt32]
  private let indices: [UInt32]
  var storageBytes: Int { (offsets.count + indices.count) * MemoryLayout<UInt32>.stride }

  init?(_ features: [PreparedMapTile.Feature]) throws {
    guard features.count >= 128, features.count <= UInt32.max else { return nil }
    // Record each cell once, then scatter into one allocation in source order.
    // Separate bucket arrays would grow and copy their storage independently.
    var cells: [UInt8] = []
    cells.reserveCapacity(features.count)
    var counts = Array(repeating: UInt32(0), count: Self.cellCount)
    for (index, feature) in features.enumerated() {
      if index.isMultiple(of: 256) { try Task.checkCancellation() }
      let cell = Self.cell(containing: feature.path.boundingRect)
      cells.append(UInt8(cell))
      counts[cell] += 1
    }
    // A tile made entirely of broad paths cannot benefit from this index.
    guard counts[0] < features.count else { return nil }
    var offsets: [UInt32] = []
    offsets.reserveCapacity(counts.count + 1)
    var total: UInt32 = 0
    for count in counts {
      offsets.append(total)
      total += count
    }
    offsets.append(total)
    for cell in counts.indices { counts[cell] = offsets[cell] }
    var indices = Array(repeating: UInt32(0), count: features.count)
    for (index, cellID) in cells.enumerated() {
      if index.isMultiple(of: 256) { try Task.checkCancellation() }
      let cell = Int(cellID)
      indices[Int(counts[cell])] = UInt32(index)
      counts[cell] += 1
    }
    self.offsets = offsets
    self.indices = indices
  }

  private static func cell(containing bounds: CGRect) -> Int {
    guard !bounds.isNull, tileBounds.contains(bounds) else { return 0 }
    for (side, offset) in levels.reversed() {
      let width = 256 / Double(side)
      let minX = min(side - 1, Int(bounds.minX / width))
      let minY = min(side - 1, Int(bounds.minY / width))
      let maxX = min(side - 1, Int(bounds.maxX / width))
      let maxY = min(side - 1, Int(bounds.maxY / width))
      if minX == maxX, minY == maxY { return offset + minY * side + minX }
    }
    return 0
  }

  func featureIndices(in rect: CGRect) -> PreparedMapFeatureIndices {
    var selected: [UInt32] = []
    if rect.isEmpty {
      // CoreGraphics permits a zero-width rectangle inside a cell to intersect
      // it. Retain that behavior for direct callers with degenerate viewports.
      for (cell, bounds) in Self.cells.enumerated() where bounds.intersects(rect) {
        selected.append(contentsOf: indices[Int(offsets[cell])..<Int(offsets[cell + 1])])
      }
    } else if Self.tileBounds.intersects(rect) {
      let visible = rect.intersection(Self.tileBounds)
      for (side, offset) in Self.levels {
        let width = 256 / Double(side)
        let minX = min(side - 1, Int(visible.minX / width))
        let minY = min(side - 1, Int(visible.minY / width))
        let maxX = min(side - 1, max(0, Int(ceil(visible.maxX / width)) - 1))
        let maxY = min(side - 1, max(0, Int(ceil(visible.maxY / width)) - 1))
        for y in minY...maxY {
          let row = offset + y * side
          let first = row + minX
          let last = row + maxX + 1
          // Neighboring cells occupy one contiguous slice of the index.
          selected.append(contentsOf: indices[Int(offsets[first])..<Int(offsets[last])])
        }
      }
    }
    if selected.count == indices.count { return PreparedMapFeatureIndices(count: indices.count) }
    selected.sort()
    return PreparedMapFeatureIndices(selected)
  }
}
