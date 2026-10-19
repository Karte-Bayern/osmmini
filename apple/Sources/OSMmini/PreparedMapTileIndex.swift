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
    var buckets = Array(repeating: [UInt32](), count: Self.cells.count)
    for (index, feature) in features.enumerated() {
      if index.isMultiple(of: 256) { try Task.checkCancellation() }
      buckets[Self.cell(containing: feature.path.boundingRect)].append(UInt32(index))
    }
    // A tile made entirely of broad paths cannot benefit from this index.
    guard buckets[0].count < features.count else { return nil }
    var offsets: [UInt32] = []
    var indices: [UInt32] = []
    offsets.reserveCapacity(buckets.count + 1)
    indices.reserveCapacity(features.count)
    for bucket in buckets {
      try Task.checkCancellation()
      offsets.append(UInt32(indices.count))
      indices.append(contentsOf: bucket)
    }
    offsets.append(UInt32(indices.count))
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
    for (cell, bounds) in Self.cells.enumerated() where bounds.intersects(rect) {
      selected.append(contentsOf: indices[Int(offsets[cell])..<Int(offsets[cell + 1])])
    }
    if selected.count == indices.count { return PreparedMapFeatureIndices(count: indices.count) }
    selected.sort()
    return PreparedMapFeatureIndices(selected)
  }
}
