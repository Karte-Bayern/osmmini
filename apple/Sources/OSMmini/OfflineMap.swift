import SwiftUI

enum WebMercator {
  static let maximumLatitude = 85.0511

  static func world(_ coordinate: Coordinate, zoom: Int) -> CGPoint {
    let scale = exp2(Double(zoom)) * 256
    let latitude = max(-maximumLatitude, min(maximumLatitude, coordinate.lat)) * .pi / 180
    return CGPoint(
      x: (coordinate.lon + 180) / 360 * scale,
      y: (1 - asinh(tan(latitude)) / .pi) / 2 * scale)
  }

  static func coordinate(_ point: CGPoint, zoom: Int) -> Coordinate {
    let scale = exp2(Double(zoom)) * 256
    let latitude = atan(sinh(.pi * (1 - 2 * point.y / scale))) * 180 / .pi
    // World x starts at -180 degrees. Wrap x before subtracting that offset.
    let longitude =
      ((point.x / scale * 360).truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360) - 180
    return Coordinate(lat: max(-maximumLatitude, min(maximumLatitude, latitude)), lon: longitude)
  }
}

/// A small native, offline vector renderer shared by iOS and macOS. No Apple
/// basemap, web view, HTTP server, external fonts or network requests are used.
/// It renders the layers produced by tinyTiles' built-in regional generator.
public struct OfflineMap: View {
  public let engine: OfflineEngine
  public var route: Route?
  public var onSelect: ((Coordinate) -> Void)?
  public var markers: [Coordinate]
  public var focus: Coordinate?
  @State private var center: Coordinate
  @State private var zoom: Int
  @State private var tiles = PreparedMapTileCache()
  @State private var error: String?
  @GestureState private var drag = CGSize.zero
  private struct TileRequest: Equatable {
    let owner: ObjectIdentifier
    let keys: [MapTileKey]
  }
  public init(
    engine: OfflineEngine, route: Route? = nil, center: Coordinate? = nil,
    markers: [Coordinate] = [], focus: Coordinate? = nil, onSelect: ((Coordinate) -> Void)? = nil
  ) {
    self.engine = engine
    self.route = route
    self.onSelect = onSelect
    self.markers = markers
    self.focus = focus
    _center = State(initialValue: center ?? engine.manifest.bounds.center)
    _zoom = State(initialValue: max(engine.manifest.minZoom, min(11, engine.manifest.maxZoom)))
  }
  public var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let keys = visibleTiles(size)
      let request = TileRequest(owner: ObjectIdentifier(engine), keys: keys)
      Canvas { context, canvasSize in
        context.fill(
          Path(CGRect(origin: .zero, size: canvasSize)),
          with: .color(Color(red: 0.96, green: 0.95, blue: 0.92)))
        let origin = world(center)
        for key in keys {
          guard let tile = tiles.tile(for: key, owner: request.owner) else { continue }
          let offset = CGPoint(
            x: Double(key.x) * 256 - origin.x + canvasSize.width / 2 + drag.width,
            y: Double(key.y) * 256 - origin.y + canvasSize.height / 2 + drag.height)
          var tileContext = context
          tileContext.translateBy(x: offset.x, y: offset.y)
          tileContext.clip(to: Path(CGRect(x: 0, y: 0, width: 256, height: 256)))
          for feature in tile.features {
            switch feature.style {
            case .water:
              tileContext.fill(
                feature.path, with: .color(Color(red: 0.66, green: 0.82, blue: 0.88)),
                style: FillStyle(eoFill: true))
            case .forest, .landcover:
              tileContext.fill(
                feature.path,
                with: .color(
                  feature.style == .forest
                    ? Color(red: 0.77, green: 0.85, blue: 0.72)
                    : Color(red: 0.89, green: 0.90, blue: 0.79)), style: FillStyle(eoFill: true))
            case .building:
              tileContext.fill(
                feature.path, with: .color(Color(red: 0.83, green: 0.79, blue: 0.75)),
                style: FillStyle(eoFill: true))
            case .road(let major):
              let width = major ? 3.5 : 1.8
              tileContext.stroke(
                feature.path, with: .color(.gray.opacity(0.45)),
                style: StrokeStyle(lineWidth: width + 1, lineCap: .round, lineJoin: .round))
              tileContext.stroke(
                feature.path,
                with: .color(major ? Color(red: 0.96, green: 0.79, blue: 0.51) : .white),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
              if zoom >= 13, let name = feature.name, let p = feature.labelPoint {
                tileContext.draw(Text(name).font(.system(size: 10)).foregroundColor(.black), at: p)
              }
            }
          }
        }
        if let route {
          var path = Path()
          for (i, coordinate) in route.path.enumerated() {
            let p = screen(coordinate, size: canvasSize)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
          }
          context.stroke(
            path, with: .color(.blue),
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        for coordinate in markers {
          let p = screen(coordinate, size: canvasSize)
          context.fill(
            Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
            with: .color(.red))
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded {
          value in
          let p = world(center)
          center = coordinate(
            CGPoint(x: p.x - value.translation.width, y: p.y - value.translation.height))
        }
      )
      .simultaneousGesture(
        SpatialTapGesture().onEnded { tap in
          let p = world(center)
          let selected = coordinate(
            CGPoint(
              x: p.x + tap.location.x - size.width / 2, y: p.y + tap.location.y - size.height / 2))
          onSelect?(selected)
        }
      )
      .simultaneousGesture(
        MagnifyGesture().onEnded { value in
          let delta = Int(log2(value.magnification).rounded())
          zoom = max(engine.manifest.minZoom, min(engine.manifest.maxZoom, zoom + delta))
        }
      )
      .overlay(alignment: .topTrailing) {
        VStack {
          Button {
            zoom = min(engine.manifest.maxZoom, zoom + 1)
          } label: {
            Image(systemName: "plus")
          }.accessibilityLabel("Vergrößern")
          Button {
            zoom = max(engine.manifest.minZoom, zoom - 1)
          } label: {
            Image(systemName: "minus")
          }.accessibilityLabel("Verkleinern")
          Button {
            center = engine.manifest.bounds.center
          } label: {
            Image(systemName: "scope")
          }.accessibilityLabel("Region zentrieren")
        }.buttonStyle(.borderedProminent).padding()
      }
      .overlay(alignment: .bottomLeading) {
        VStack(alignment: .leading) {
          if let error { Text(error).foregroundStyle(.red) }
          Link(
            "© OpenStreetMap contributors · ODbL",
            destination: URL(string: "https://www.openstreetmap.org/copyright")!
          ).font(.caption2)
        }.padding(6).background(.regularMaterial)
      }
      .task(id: request) { await load(request) }
      .onChange(of: focus) { _, coordinate in if let coordinate { center = coordinate } }
      .accessibilityLabel(
        "Offline-Karte von \(engine.manifest.name). Mit Plus und Minus zoomen; zwei Punkte für eine Route auswählen."
      )
    }
  }
  private func world(_ c: Coordinate) -> CGPoint {
    WebMercator.world(c, zoom: zoom)
  }
  private func coordinate(_ p: CGPoint) -> Coordinate {
    WebMercator.coordinate(p, zoom: zoom)
  }
  private func screen(_ c: Coordinate, size: CGSize) -> CGPoint {
    let p = world(c)
    let origin = world(center)
    return CGPoint(
      x: p.x - origin.x + size.width / 2 + drag.width,
      y: p.y - origin.y + size.height / 2 + drag.height)
  }
  private func visibleTiles(_ size: CGSize) -> [MapTileKey] {
    let p = world(center)
    let count = Int(exp2(Double(zoom)))
    let minX = max(0, Int(floor((p.x - size.width / 2) / 256)))
    let maxX = min(count - 1, Int(floor((p.x + size.width / 2) / 256)))
    let minY = max(0, Int(floor((p.y - size.height / 2) / 256)))
    let maxY = min(count - 1, Int(floor((p.y + size.height / 2) / 256)))
    guard minX <= maxX, minY <= maxY else { return [] }
    var keys: [MapTileKey] = []
    for y in minY...maxY {
      for x in minX...maxX {
        if keys.count < PreparedMapTileCache.capacity {
          keys.append(MapTileKey(z: zoom, x: x, y: y))
        }
      }
    }
    return keys
  }
  @MainActor private func load(_ request: TileRequest) async {
    guard !Task.isCancelled else { return }
    tiles.updateViewport(owner: request.owner, keys: request.keys)
    error = nil
    // Bound in-flight work and the prepared geometry cache to the viewport.
    for key in request.keys where tiles.tile(for: key, owner: request.owner) == nil {
      if Task.isCancelled { return }
      do {
        let tile = try await PreparedMapTile.prepare(engine.tile(z: key.z, x: key.x, y: key.y))
        try Task.checkCancellation()
        tiles.insert(tile, for: key, owner: request.owner)
      } catch is CancellationError { return } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
        return
      }
    }
  }
}
