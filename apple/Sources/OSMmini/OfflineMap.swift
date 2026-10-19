import SwiftUI

/// A small native, offline vector renderer shared by iOS and macOS. No Apple
/// basemap, web view, HTTP server, external fonts or network requests are used.
/// It renders the layers produced by tinyTiles' built-in regional generator.
public struct OfflineMap: View {
  public let engine: OfflineEngine
  public var route: Route?
  public var onSelect: ((Coordinate) -> Void)?
  public var markers: [Coordinate]
  public var focus: Coordinate?
  /// Change this identifier to repeat a focus request at the same coordinate.
  public var focusRequest: UUID?
  /// Explicit route endpoints retain their A/B identity when only one is set.
  /// Supplying either endpoint replaces the legacy `markers` array.
  public var routeStart: Coordinate?
  public var routeDestination: Coordinate?
  /// An optional preview point, independent of the route's start and destination.
  public var selection: Coordinate?
  /// A location supplied by the host app; the renderer never requests permissions.
  public var userLocation: Coordinate?
  /// Horizontal accuracy in meters, used only when a valid user location exists.
  public var userLocationAccuracy: Double?
  private let initialCenter: Coordinate?
  @State private var center: Coordinate
  @State private var zoom: Int
  @State private var tileLoader = OfflineMapTileLoader()
  @State private var viewportFitter = OfflineMapViewportFitter()
  @State private var routeLoader = OfflineMapRouteLoader()
  @State private var cameraIntent = OfflineMapCameraIntent()
  @State private var retry = 0
  @GestureState private var drag = CGSize.zero
  private var maximumDisplayZoom: Int { max(18, engine.manifest.maxZoom) }
  private var displayedMarkers: [OfflineMapMarker] {
    OfflineMapMarker.make(legacy: markers, start: routeStart, destination: routeDestination)
  }
  private struct TileRequest: Equatable {
    let owner: ObjectIdentifier
    let keys: [MapTileKey]
    let retry: Int
  }
  private struct RouteViewportRequest: Equatable {
    let owner: ObjectIdentifier
    let path: [Coordinate]?
  }
  public init(
    engine: OfflineEngine, route: Route? = nil, center: Coordinate? = nil,
    markers: [Coordinate] = [], focus: Coordinate? = nil, focusRequest: UUID? = nil,
    routeStart: Coordinate? = nil, routeDestination: Coordinate? = nil,
    selection: Coordinate? = nil,
    userLocation: Coordinate? = nil, userLocationAccuracy: Double? = nil,
    onSelect: ((Coordinate) -> Void)? = nil
  ) {
    self.engine = engine
    self.route = route
    self.onSelect = onSelect
    self.markers = markers
    self.focus = focus
    self.focusRequest = focusRequest
    self.routeStart = routeStart
    self.routeDestination = routeDestination
    self.selection = selection
    self.userLocation = userLocation
    self.userLocationAccuracy = userLocationAccuracy
    initialCenter = center
    _center = State(initialValue: focus ?? center ?? engine.manifest.bounds.center)
    _zoom = State(initialValue: max(engine.manifest.minZoom, min(11, engine.manifest.maxZoom)))
  }
  public var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let placements = OfflineMapTilePlacement.visible(
        center: center, zoom: zoom, size: size, tileZoom: engine.manifest.maxZoom)
      let keys = OfflineMapTilePlacement.keys(in: placements)
      let request = TileRequest(owner: ObjectIdentifier(engine), keys: keys, retry: retry)
      let routeRequest = RouteViewportRequest(owner: ObjectIdentifier(engine), path: route?.path)
      Canvas { context, canvasSize in
        context.fill(
          Path(CGRect(origin: .zero, size: canvasSize)),
          with: .color(Color(red: 0.96, green: 0.95, blue: 0.92)))
        var labels: [MapLabel] = []
        for placement in placements {
          let key = placement.key
          guard let tile = tileLoader.cache.tile(for: key, owner: request.owner) else { continue }
          let scale = placement.scale(at: zoom)
          let tileOrigin = placement.origin(center: center, zoom: zoom, size: canvasSize)
          let offset = CGPoint(x: tileOrigin.x + drag.width, y: tileOrigin.y + drag.height)
          var tileContext = context
          tileContext.translateBy(x: offset.x, y: offset.y)
          tileContext.scaleBy(x: scale, y: scale)
          tileContext.clip(to: Path(CGRect(x: 0, y: 0, width: 256, height: 256)))
          let visible = CGRect(
            x: -offset.x / scale, y: -offset.y / scale,
            width: canvasSize.width / scale, height: canvasSize.height / scale)
          let maximumRoadWidth = PreparedMapTile.roadWidth(major: true, overzoom: zoom - key.z)
          let padding = ((maximumRoadWidth + 1) / 2 + 1) / scale
          for index in tile.featureIndices(in: visible, padding: padding) {
            let feature = tile.features[index]
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
              let width = PreparedMapTile.roadWidth(major: major, overzoom: zoom - key.z)
              tileContext.stroke(
                feature.path, with: .color(.gray.opacity(0.45)),
                style: StrokeStyle(
                  lineWidth: (width + 1) / scale, lineCap: .round, lineJoin: .round))
              tileContext.stroke(
                feature.path,
                with: .color(major ? Color(red: 0.96, green: 0.79, blue: 0.51) : .white),
                style: StrokeStyle(lineWidth: width / scale, lineCap: .round, lineJoin: .round))
            }
          }
          for label in tile.labels {
            guard let style = labelStyle(for: label.style) else { continue }
            let point = CGPoint(
              x: label.point.x * scale + offset.x, y: label.point.y * scale + offset.y)
            guard CGRect(origin: .zero, size: canvasSize).contains(point) else { continue }
            labels.append(
              MapLabel(
                name: label.name, point: point,
                size: style.size, priority: style.priority, bold: style.bold))
          }
        }
        if let userLocation, userLocation.lon.isFinite,
          let accuracyRadius = OfflineMapLocationAccuracy.radius(
            userLocationAccuracy, latitude: userLocation.lat, zoom: zoom)
        {
          let radius = min(accuracyRadius, hypot(canvasSize.width, canvasSize.height) * 2)
          let point = screen(userLocation, size: canvasSize)
          let accuracy = Path(
            ellipseIn: CGRect(
              x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
          context.fill(accuracy, with: .color(.blue.opacity(0.12)))
          context.stroke(accuracy, with: .color(.blue.opacity(0.35)), lineWidth: 1)
        }
        if let preparedRoute = routeLoader.route(owner: request.owner, coordinates: route?.path) {
          for placement in preparedRoute.visible(
            center: center, zoom: zoom, size: canvasSize, translation: drag)
          {
            var routeContext = context
            routeContext.translateBy(x: placement.origin.x, y: placement.origin.y)
            routeContext.scaleBy(x: placement.scale, y: placement.scale)
            routeContext.stroke(
              preparedRoute.chunks[placement.index].path, with: .color(.blue),
              style: StrokeStyle(
                lineWidth: 5 / placement.scale, lineCap: .round, lineJoin: .round))
          }
        }
        drawLabels(labels, context: &context, size: canvasSize)
        if let selection, selection.lat.isFinite, selection.lon.isFinite {
          let point = screen(selection, size: canvasSize)
          let pin = Path(
            ellipseIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
          context.fill(pin, with: .color(.orange))
          context.stroke(pin, with: .color(.white), lineWidth: 3)
          context.fill(
            Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
            with: .color(.white))
        }
        for marker in displayedMarkers {
          let p = screen(marker.coordinate, size: canvasSize)
          let path = Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
          let color: Color =
            switch marker.role {
            case .start: Color(red: 0.08, green: 0.4, blue: 0.2)
            case .destination: Color(red: 0.7, green: 0.1, blue: 0.1)
            case .other: .blue
            }
          context.fill(
            path, with: .color(color))
          context.stroke(path, with: .color(.white), lineWidth: 2)
          context.draw(
            Text(marker.label)
              .font(.system(size: 12, weight: .bold)).foregroundStyle(.white), at: p)
        }
        if let userLocation, userLocation.lat.isFinite, userLocation.lon.isFinite {
          let point = screen(userLocation, size: canvasSize)
          let dot = Path(
            ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
          context.fill(dot, with: .color(.blue))
          context.stroke(dot, with: .color(.white), lineWidth: 3)
        }
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture().updating($drag) { value, state, _ in state = value.translation }
          .onChanged { _ in navigate() }.onEnded {
            value in
            navigate()
            let p = world(center)
            center = coordinate(
              CGPoint(x: p.x - value.translation.width, y: p.y - value.translation.height))
          }
          .exclusively(
            before: SpatialTapGesture(count: 2).onEnded { tap in
              navigate()
              guard zoom < maximumDisplayZoom,
                let viewport = OfflineMapViewport.zooming(
                  center: center, from: zoom, to: zoom + 1, at: tap.location, size: size)
              else { return }
              center = viewport.center
              zoom = viewport.zoom
            }.exclusively(
              before: SpatialTapGesture().onEnded { tap in
                guard let onSelect else { return }
                navigate()
                let p = world(center)
                let selected = coordinate(
                  CGPoint(
                    x: p.x + tap.location.x - size.width / 2,
                    y: p.y + tap.location.y - size.height / 2))
                onSelect(selected)
              })
          )
      )
      .simultaneousGesture(
        MagnifyGesture().onChanged { _ in navigate() }.onEnded { value in
          navigate()
          let delta = Int(log2(value.magnification).rounded())
          zoom = max(engine.manifest.minZoom, min(maximumDisplayZoom, zoom + delta))
        }
      )
      .overlay(alignment: .topTrailing) {
        ViewThatFits(in: .vertical) {
          VStack(spacing: 8) { controls(size: size) }
          HStack(spacing: 8) { controls(size: size) }
        }.buttonStyle(MapControlStyle()).padding()
      }
      .overlay(alignment: .topLeading) {
        if tileLoader.isLoading,
          !keys.contains(where: { tileLoader.cache.tile(for: $0, owner: request.owner) != nil })
        {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Karte wird geladen …").font(.caption)
          }
          .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
          .padding()
          .accessibilityElement(children: .combine)
          .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .bottomLeading) {
        VStack(alignment: .leading, spacing: 6) {
          if let scale = OfflineMapScale.make(latitude: center.lat, zoom: zoom) {
            VStack(alignment: .leading, spacing: 2) {
              Text(scale.label).font(.caption2.monospacedDigit())
              Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: scale.width, y: 4))
                path.addLine(to: CGPoint(x: scale.width, y: 0))
              }.stroke(lineWidth: 1.5).frame(width: scale.width, height: 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Maßstab: \(scale.label)")
          }
          let failed = tileLoader.failures(owner: request.owner, keys: keys)
          if failed > 0 {
            Text(failed == 1 ? "Eine Kartenkachel fehlt." : "\(failed) Kartenkacheln fehlen.")
              .font(.caption)
            Button("Erneut laden", systemImage: "arrow.clockwise") { retry += 1 }
              .frame(minHeight: 44)
              .disabled(tileLoader.isLoading)
          }
          Link(
            "© OpenStreetMap contributors · ODbL",
            destination: URL(string: "https://www.openstreetmap.org/copyright")!
          ).font(.caption2)
        }.padding(6).background(.regularMaterial)
      }
      .task(id: request) {
        let loadingKeys = OfflineMapTilePlacement.loadingKeys(in: placements, center: center)
        await tileLoader.load(owner: request.owner, keys: loadingKeys) { [engine] key in
          try await PreparedMapTile.prepare(engine.tile(z: key.z, x: key.x, y: key.y))
        }
      }
      .task(id: routeRequest) {
        await routeLoader.load(owner: routeRequest.owner, coordinates: routeRequest.path)
      }
      .onChange(of: OfflineMapFocusRequest(coordinate: focus, id: focusRequest)) { _, request in
        navigate()
        if let coordinate = request.coordinate { center = coordinate }
      }
      .onChange(
        of: RouteViewportRequest(owner: ObjectIdentifier(engine), path: route?.path), initial: true
      ) { _, request in
        let update = cameraIntent.update(
          owner: request.owner, path: request.path,
          hasExplicitCenter: initialCenter != nil || focus != nil)
        viewportFitter.cancel()
        if update == .engine {
          center = focus ?? initialCenter ?? engine.manifest.bounds.center
          zoom = max(engine.manifest.minZoom, min(11, engine.manifest.maxZoom))
        }
        updateViewport(size: size)
      }
      .onChange(of: size) { _, _ in updateViewport(size: size) }
      .onDisappear { viewportFitter.cancel() }
      .accessibilityLabel(
        "Offline-Karte von \(engine.manifest.name)"
      )
      .accessibilityHint(
        onSelect == nil
          ? "Doppeltippen oder mit Plus und Minus zoomen. Mit dem Regionsknopf die ganze Region anzeigen."
          : "Doppeltippen oder mit Plus und Minus zoomen. Antippen wählt einen Ort. A markiert den Start, B das Ziel."
      )
    }
  }
  private func world(_ c: Coordinate) -> CGPoint {
    WebMercator.world(c, zoom: zoom)
  }
  private struct MapLabel {
    let name: String
    let point: CGPoint
    let size: CGFloat
    let priority: Int
    let bold: Bool
  }
  private struct MapControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.primary.opacity(configuration.isPressed ? 0.3 : 0.12))
        }
        .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
  }
  @ViewBuilder private func controls(size: CGSize) -> some View {
    Button {
      navigate()
      zoom = min(maximumDisplayZoom, zoom + 1)
    } label: {
      Image(systemName: "plus").frame(width: 44, height: 44)
    }.accessibilityLabel("Vergrößern")
      .help("Karte vergrößern")
      .disabled(zoom >= maximumDisplayZoom)
    Button {
      navigate()
      zoom = max(engine.manifest.minZoom, zoom - 1)
    } label: {
      Image(systemName: "minus").frame(width: 44, height: 44)
    }.accessibilityLabel("Verkleinern")
      .help("Karte verkleinern")
      .disabled(zoom <= engine.manifest.minZoom)
    Button {
      cameraIntent.showRegion()
      updateViewport(size: size)
    } label: {
      Image(systemName: "scope").frame(width: 44, height: 44)
    }.accessibilityLabel("Ganze Region anzeigen")
      .help("Ganze Offline-Region anzeigen")
    if let route, !route.path.isEmpty {
      Button {
        cameraIntent.showRoute()
        updateViewport(size: size)
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
      }.accessibilityLabel("Ganze Route anzeigen")
        .help("Ganze Route anzeigen")
    }
  }
  private func labelStyle(for style: PreparedMapTile.Label.Style) -> (
    size: CGFloat, priority: Int, bold: Bool
  )? {
    switch style {
    case .place(let kind):
      switch kind {
      case .city: return (zoom >= 11 ? 17 : 15, 0, true)
      case .town: return (zoom >= 12 ? 15 : 13, 1, true)
      case .village: return (13, 2, true)
      case .other: return (12, 3, false)
      }
    case .road(let major) where zoom >= (major ? 12 : 13):
      return (zoom >= 14 ? 12 : 11, major ? 4 : 5, false)
    default: return nil
    }
  }
  private func drawLabels(_ labels: [MapLabel], context: inout GraphicsContext, size: CGSize) {
    let controlLength: CGFloat = route?.path.isEmpty == false ? 232 : 180
    let controlsSize =
      size.height >= controlLength
      ? CGSize(width: 76, height: controlLength) : CGSize(width: controlLength, height: 76)
    var obstacles = [
      CGRect(
        x: max(0, size.width - controlsSize.width), y: 0, width: controlsSize.width,
        height: controlsSize.height),
      CGRect(x: 0, y: max(0, size.height - 80), width: min(size.width, 260), height: 80),
    ]
    for coordinate in displayedMarkers.map(\.coordinate)
      + [selection, userLocation].compactMap({ $0 })
    where coordinate.lat.isFinite && coordinate.lon.isFinite {
      let point = screen(coordinate, size: size)
      obstacles.append(CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
    }
    var layout = OfflineMapLabelLayout(obstacles: obstacles, viewport: size)
    for label in labels.sorted(by: { $0.priority < $1.priority }) {
      guard layout.canPlace(name: label.name, at: label.point, viewport: size) else { continue }
      let text = context.resolve(
        Text(label.name).font(.system(size: label.size, weight: label.bold ? .semibold : .regular))
          .foregroundStyle(.black))
      let measured = text.measure(in: CGSize(width: 220, height: 30))
      let frame = CGRect(
        x: label.point.x - measured.width / 2, y: label.point.y - measured.height / 2,
        width: measured.width, height: measured.height)
      guard layout.reserve(name: label.name, frame: frame, viewport: size) else { continue }
      context.fill(
        Path(roundedRect: frame.insetBy(dx: -3, dy: -1), cornerRadius: 3),
        with: .color(.white.opacity(label.bold ? 0.92 : 0.86)))
      context.draw(text, in: frame)
    }
  }
  private func coordinate(_ p: CGPoint) -> Coordinate {
    WebMercator.coordinate(p, zoom: zoom)
  }
  private func screen(_ c: Coordinate, size: CGSize) -> CGPoint {
    let p = WebMercator.offset(c, from: center, zoom: zoom)
    return CGPoint(
      x: p.x + size.width / 2 + drag.width,
      y: p.y + size.height / 2 + drag.height)
  }
  private func navigate() {
    cameraIntent.navigate()
    viewportFitter.cancel()
  }
  private func updateViewport(size: CGSize) {
    viewportFitter.cancel()
    let apply: @MainActor (OfflineMapViewport) -> Void = { viewport in
      center = viewport.center
      zoom = viewport.zoom
    }
    switch cameraIntent.framing {
    case .manual: break
    case .region:
      viewportFitter.fit(
        engine.manifest.bounds, size: size, minZoom: engine.manifest.minZoom,
        maxZoom: maximumDisplayZoom, apply: apply)
    case .route:
      if let route {
        viewportFitter.fit(
          route.path, size: size, minZoom: engine.manifest.minZoom,
          maxZoom: maximumDisplayZoom, apply: apply)
      }
    }
  }
}
