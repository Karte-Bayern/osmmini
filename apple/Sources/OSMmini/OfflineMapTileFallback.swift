import Foundation

/// Previously loaded geometry covers only missing basemap tiles while the new
/// zoom level arrives. Labels and POIs still use the current tile plan.
enum OfflineMapTileFallback {
  struct Region {
    let placement: OfflineMapTilePlacement
    let clips: [CGRect]
  }

  static func regions(
    for requested: [OfflineMapTilePlacement], cache: PreparedMapTileCache,
    owner: ObjectIdentifier, center: Coordinate, displayZoom: Double, size: CGSize
  ) -> [Region] {
    guard displayZoom.isFinite, (0...30).contains(displayZoom),
      center.lat.isFinite, abs(center.lat) <= 90, center.lon.isFinite,
      size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
    else { return [] }
    let missing = requested.filter { cache.tile(for: $0.key, owner: owner) == nil }
    guard !missing.isEmpty else { return [] }
    let available = cache.tiles.keys.filter {
      (0...30).contains($0.z) && cache.tile(for: $0, owner: owner) != nil
    }
    guard !available.isEmpty else { return [] }
    let viewport = CGRect(origin: .zero, size: size)
    var clips: [OfflineMapTilePlacement: [CGRect]] = [:]
    for target in missing {
      let missingFrame = frame(target, center: center, zoom: displayZoom, size: size)
        .intersection(viewport)
      guard !missingFrame.isEmpty, !missingFrame.isNull else { continue }
      for key in available {
        guard let placement = relatedPlacement(key, covering: target) else { continue }
        let clip = frame(placement, center: center, zoom: displayZoom, size: size)
          .intersection(missingFrame)
        guard !clip.isEmpty, !clip.isNull else { continue }
        clips[placement, default: []].append(clip)
      }
    }
    // Coarse geometry is painted first; any retained finer tiles fill their
    // own part of the missing area without drawing over a completed new tile.
    return clips.keys.sorted {
      if $0.key.z != $1.key.z { return $0.key.z < $1.key.z }
      if $0.key.y != $1.key.y { return $0.key.y < $1.key.y }
      return $0.worldX < $1.worldX
    }.map { Region(placement: $0, clips: clips[$0]!) }
  }

  private static func relatedPlacement(
    _ key: MapTileKey, covering target: OfflineMapTilePlacement
  ) -> OfflineMapTilePlacement? {
    guard (0...30).contains(target.key.z) else { return nil }
    if key.z <= target.key.z {
      let difference = target.key.z - key.z
      guard target.key.x >> difference == key.x, target.key.y >> difference == key.y else {
        return nil
      }
      let factor = 1 << difference
      // Swift integer division truncates toward zero; world copies west of
      // the dateline need floor division to keep their parent in that copy.
      let worldX = target.worldX >= 0
        ? target.worldX / factor : (target.worldX - factor + 1) / factor
      return OfflineMapTilePlacement(key: key, worldX: worldX)
    }
    let difference = key.z - target.key.z
    guard key.x >> difference == target.key.x, key.y >> difference == target.key.y else {
      return nil
    }
    let factor = 1 << difference
    return OfflineMapTilePlacement(
      key: key, worldX: target.worldX * factor + key.x % factor)
  }

  private static func frame(
    _ placement: OfflineMapTilePlacement, center: Coordinate, zoom: Double, size: CGSize
  ) -> CGRect {
    let scale = exp2(zoom)
    let origin = WebMercator.world(
      Coordinate(lat: center.lat, lon: center.lon.truncatingRemainder(dividingBy: 360)), zoom: 0)
    let tileSize = 256 * exp2(zoom - Double(placement.key.z))
    return CGRect(
      x: Double(placement.worldX) * tileSize - origin.x * scale + size.width / 2,
      y: Double(placement.key.y) * tileSize - origin.y * scale + size.height / 2,
      width: tileSize, height: tileSize)
  }
}
