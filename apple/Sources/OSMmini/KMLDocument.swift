import CryptoKit
import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// The two-dimensional geometry displayed by the offline map. Altitude and
/// presentation instructions in the source KML do not change the basemap.
public enum KMLGeometry: Codable, Sendable, Equatable {
  case point(Coordinate)
  case lineString([Coordinate])
  case polygon(outer: [Coordinate], holes: [[Coordinate]])

  public var coordinates: [Coordinate] {
    switch self {
    case .point(let coordinate): [coordinate]
    case .lineString(let coordinates): coordinates
    case .polygon(let outer, let holes): outer + holes.flatMap { $0 }
    }
  }
}

public struct KMLFeature: Identifiable, Codable, Sendable, Equatable {
  public let id: UUID
  public let name: String?
  /// Literal text only. KML descriptions are never interpreted as HTML.
  public let description: String?
  public let geometry: KMLGeometry

  public init(
    id: UUID = UUID(), name: String? = nil, description: String? = nil, geometry: KMLGeometry
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.geometry = geometry
  }
}

/// A local KML overlay. Parsing never fetches links, icons, schemas or entities.
public struct KMLDocument: Codable, Sendable, Equatable {
  public static let maximumBytes = 10 * 1024 * 1024
  public static let maximumFeatures = 5_000
  public static let maximumPositions = 100_000

  public let name: String
  public let features: [KMLFeature]

  public var coordinates: [Coordinate] { features.flatMap { $0.geometry.coordinates } }

  /// Initial map placement needs one position, without flattening every feature.
  var firstCoordinate: Coordinate? {
    for feature in features {
      let coordinate: Coordinate?
      switch feature.geometry {
      case .point(let point): coordinate = point
      case .lineString(let points): coordinate = points.first
      case .polygon(let outer, let holes):
        coordinate = outer.first ?? holes.lazy.compactMap(\.first).first
      }
      if let coordinate { return coordinate }
    }
    return nil
  }

  public init(data: Data, name: String = "KML") throws {
    try Task.checkCancellation()
    guard !data.isEmpty, data.count <= Self.maximumBytes else {
      throw OSMminiError.native("Eine KML-Datei darf höchstens 10 MB groß sein.")
    }
    try Self.rejectDoctype(in: data)
    let delegate = KMLParserDelegate(identitySeed: Data(SHA256.hash(data: data)))
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate
    let parsed = parser.parse()
    try Task.checkCancellation()
    if delegate.cancelled { throw CancellationError() }
    guard parsed, delegate.failure == nil else {
      throw OSMminiError.native(delegate.failure ?? "Die KML-Datei enthält ungültiges XML.")
    }
    guard delegate.sawRoot, !delegate.features.isEmpty else {
      throw OSMminiError.native("Die KML-Datei enthält keine unterstützten Punkte, Linien oder Flächen.")
    }
    let fallback = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.name = delegate.documentName
      ?? (fallback.isEmpty ? "KML" : String(String.UnicodeScalarView(fallback.unicodeScalars.prefix(160))))
    features = delegate.features
  }

  private static func rejectDoctype(in data: Data) throws {
    enum Context { case content, opening, comment, cdata, instruction }
    let declaration = Array("<!DOCTYPE".utf8)
    let comment = Array("<!--".utf8)
    let cdata = Array("<![CDATA[".utf8)
    let instruction = Array("<?".utf8)
    let commentEnd: [UInt8] = [45, 45, 62] // -->
    let cdataEnd: [UInt8] = [93, 93, 62] // ]]>
    let instructionEnd: [UInt8] = [63, 62] // ?>
    var context = Context.content
    var sequence: [UInt8] = []
    sequence.reserveCapacity(declaration.count)
    for (index, byte) in data.enumerated() {
      if index.isMultiple(of: 4096) { try Task.checkCancellation() }
      // Removing zero bytes recognizes ASCII markup in UTF-16/32, in either
      // byte order. XMLParser still validates the original encoded document.
      guard byte != 0 else { continue }
      switch context {
      case .content:
        if byte == 60 {
          sequence.removeAll(keepingCapacity: true)
          sequence.append(byte)
          context = .opening
        }
      case .opening:
        sequence.append(byte)
        if sequence == declaration {
          throw OSMminiError.native("KML-Dateien mit DTD oder eigenen XML-Entitäten werden nicht unterstützt.")
        }
        if sequence == comment { context = .comment; sequence.removeAll(keepingCapacity: true) }
        else if sequence == cdata { context = .cdata; sequence.removeAll(keepingCapacity: true) }
        else if sequence == instruction { context = .instruction; sequence.removeAll(keepingCapacity: true) }
        else if !declaration.starts(with: sequence), !comment.starts(with: sequence),
          !cdata.starts(with: sequence), !instruction.starts(with: sequence)
        {
          context = byte == 60 ? .opening : .content
          sequence.removeAll(keepingCapacity: true)
          if byte == 60 { sequence.append(byte) }
        }
      case .comment, .cdata, .instruction:
        // DOCTYPE text in literal descriptions, comments or processing
        // instructions is harmless and must not reject an otherwise valid KML.
        sequence.append(byte)
        let ending: [UInt8]
        switch context {
        case .comment: ending = commentEnd
        case .cdata: ending = cdataEnd
        default: ending = instructionEnd
        }
        if sequence.count > ending.count { sequence.removeFirst() }
        if sequence == ending { context = .content; sequence.removeAll(keepingCapacity: true) }
      }
    }
  }
}

private final class KMLParserDelegate: NSObject, XMLParserDelegate {
  private struct Element {
    let name: String
    let accepted: Bool
  }

  private struct Placemark {
    let depth: Int
    var name: String?
    var description: String?
    var geometries: [KMLGeometry] = []
  }

  private enum RingRole { case outer, inner }
  private enum Kind { case point, line, polygon, multi, ring(RingRole) }
  private struct Geometry {
    let depth: Int
    let kind: Kind
    var coordinates: [Coordinate]?
    var outer: [Coordinate]?
    var holes: [[Coordinate]] = []
    var children: [KMLGeometry] = []
  }

  private enum TextKind { case documentName, name, description }
  private struct TextCapture {
    let depth: Int
    let kind: TextKind
    let limit: Int
    var text = ""
  }

  private static let namespaces: Set<String> = [
    "", "http://www.opengis.net/kml/2.2", "http://earth.google.com/kml/2.1",
    "http://earth.google.com/kml/2.2",
  ]
  private var elements: [Element] = []
  private var placemark: Placemark?
  private var geometries: [Geometry] = []
  private var textCapture: TextCapture?
  private var coordinateDepth: Int?
  private var coordinateToken = ""
  private var coordinates: [Coordinate] = []
  private var positionCount = 0
  private var geometryCount = 0
  private var placemarkCount = 0
  private(set) var documentName: String?
  private(set) var sawRoot = false
  private(set) var features: [KMLFeature] = []
  private(set) var failure: String?
  private(set) var cancelled = false
  private let identitySeed: Data

  init(identitySeed: Data) {
    self.identitySeed = identitySeed
    super.init()
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    guard checkCancellation(parser), failure == nil else { return }
    let depth = elements.count + 1
    guard depth <= 64 else { fail(parser, "Die KML-Datei ist zu tief verschachtelt."); return }
    guard coordinateDepth == nil else {
      fail(parser, "Eine KML-Koordinatenliste darf keine XML-Elemente enthalten."); return
    }
    let parent = elements.last
    let accepted = Self.namespaces.contains(namespaceURI ?? "") && (parent?.accepted ?? true)
    if !sawRoot {
      guard accepted, elementName == "kml" else {
        fail(parser, "Die Datei ist kein unterstütztes KML-Dokument."); return
      }
      sawRoot = true
    }
    elements.append(Element(name: elementName, accepted: accepted))
    guard accepted else { return }
    if elementName == "Placemark", ["kml", "Document", "Folder"].contains(parent?.name) {
      guard placemark == nil else { fail(parser, "Ungültig verschachtelte KML-Orte."); return }
      placemarkCount += 1
      guard placemarkCount <= KMLDocument.maximumFeatures else {
        fail(parser, "Eine KML-Datei darf höchstens 5.000 Objekte enthalten."); return
      }
      placemark = Placemark(depth: depth)
    }
    if textCapture == nil {
      if parent?.name == "Placemark", placemark?.depth == depth - 1 {
        if elementName == "name" { textCapture = TextCapture(depth: depth, kind: .name, limit: 200) }
        if elementName == "description" {
          textCapture = TextCapture(depth: depth, kind: .description, limit: 2_000)
        }
      } else if elementName == "name", parent?.name == "Document", documentName == nil {
        textCapture = TextCapture(depth: depth, kind: .documentName, limit: 160)
      }
    }
    guard placemark != nil else { return }
    if ["Point", "LineString", "Polygon", "MultiGeometry"].contains(elementName),
      (parent?.name == "Placemark" && placemark?.depth == depth - 1)
        || (parent?.name == "MultiGeometry" && geometries.last?.depth == depth - 1)
    {
      let kind: Kind
      switch elementName {
      case "Point": kind = .point
      case "LineString": kind = .line
      case "Polygon": kind = .polygon
      default: kind = .multi
      }
      geometries.append(Geometry(depth: depth, kind: kind))
    } else if elementName == "LinearRing", geometries.last?.depth == depth - 2,
      ["outerBoundaryIs", "innerBoundaryIs"].contains(parent?.name),
      elements.dropLast(2).last?.name == "Polygon"
    {
      geometries.append(Geometry(
        depth: depth, kind: .ring(parent?.name == "outerBoundaryIs" ? .outer : .inner)))
    } else if elementName == "coordinates", geometries.last?.depth == depth - 1,
      ["Point", "LineString", "LinearRing"].contains(parent?.name)
    {
      guard geometries.last?.coordinates == nil else {
        fail(parser, "Eine KML-Geometrie enthält mehrere Koordinatenlisten."); return
      }
      coordinateDepth = depth
      coordinateToken = ""
      coordinates = []
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { receive(string, parser: parser) }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    receive(String(decoding: CDATABlock, as: UTF8.self), parser: parser)
  }

  private func receive(_ string: String, parser: XMLParser) {
    guard failure == nil, checkCancellation(parser) else { return }
    if coordinateDepth != nil {
      for (index, scalar) in string.unicodeScalars.enumerated() {
        if index.isMultiple(of: 1024), !checkCancellation(parser) { return }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
          guard flushCoordinate(parser) else { return }
        } else {
          guard coordinateToken.utf8.count < 128 else {
            fail(parser, "Ein KML-Koordinatenwert ist zu lang."); return
          }
          coordinateToken.unicodeScalars.append(scalar)
        }
      }
    } else if var capture = textCapture {
      let remaining = max(0, capture.limit - capture.text.unicodeScalars.count)
      capture.text.unicodeScalars.append(contentsOf: string.unicodeScalars.prefix(remaining))
      textCapture = capture
    }
  }

  private func flushCoordinate(_ parser: XMLParser) -> Bool {
    guard !coordinateToken.isEmpty else { return true }
    defer { coordinateToken = "" }
    let values = coordinateToken.split(separator: ",", omittingEmptySubsequences: false)
    guard (2...3).contains(values.count), let lon = Double(values[0]), let lat = Double(values[1]),
      lon.isFinite, lat.isFinite, (-180...180).contains(lon), (-90...90).contains(lat),
      values.count == 2 || Double(values[2]).map({ $0.isFinite }) == true
    else { fail(parser, "Die KML-Datei enthält ungültige Koordinaten."); return false }
    positionCount += 1
    guard positionCount <= KMLDocument.maximumPositions else {
      fail(parser, "Eine KML-Datei darf höchstens 100.000 Koordinaten enthalten."); return false
    }
    coordinates.append(Coordinate(lat: lat, lon: lon))
    return true
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard failure == nil, checkCancellation(parser), let element = elements.last else { return }
    let depth = elements.count
    defer { elements.removeLast() }
    guard element.accepted else { return }
    if coordinateDepth == depth {
      guard flushCoordinate(parser) else { return }
      guard !geometries.isEmpty else { fail(parser, "Ungültige KML-Geometrie."); return }
      geometries[geometries.count - 1].coordinates = coordinates
      coordinates = []
      coordinateDepth = nil
    }
    if let capture = textCapture, capture.depth == depth {
      let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = text.isEmpty ? nil : text
      switch capture.kind {
      case .documentName: documentName = value
      case .name: placemark?.name = value
      case .description: placemark?.description = value
      }
      textCapture = nil
    }
    if geometries.last?.depth == depth {
      let geometry = geometries.removeLast()
      switch geometry.kind {
      case .point:
        guard let points = geometry.coordinates, points.count == 1 else {
          fail(parser, "Ein KML-Punkt muss genau eine Koordinate enthalten."); return
        }
        append([.point(points[0])], parser: parser)
      case .line:
        guard let points = geometry.coordinates, points.count >= 2 else {
          fail(parser, "Eine KML-Linie muss mindestens zwei Koordinaten enthalten."); return
        }
        append([.lineString(points)], parser: parser)
      case .multi: append(geometry.children, counting: false, parser: parser)
      case .polygon:
        guard let outer = geometry.outer else {
          fail(parser, "Einer KML-Fläche fehlt der äußere Rand."); return
        }
        append([.polygon(outer: outer, holes: geometry.holes)], parser: parser)
      case .ring(let role):
        guard let points = geometry.coordinates, points.count >= 4, points.first == points.last,
          Set(points).count >= 3, !geometries.isEmpty
        else { fail(parser, "Ein KML-Flächenrand muss geschlossen sein und drei Eckpunkte enthalten."); return }
        switch role {
        case .outer:
          guard geometries.last?.outer == nil else {
            fail(parser, "Eine KML-Fläche enthält mehrere äußere Ränder."); return
          }
          geometries[geometries.count - 1].outer = points
        case .inner: geometries[geometries.count - 1].holes.append(points)
        }
      }
    }
    if elementName == "Placemark", let placemark, placemark.depth == depth {
      guard features.count + placemark.geometries.count <= KMLDocument.maximumFeatures else {
        fail(parser, "Eine KML-Datei darf höchstens 5.000 Objekte enthalten."); return
      }
      let firstIndex = features.count
      features.append(contentsOf: placemark.geometries.enumerated().map { index, geometry in
        KMLFeature(
          id: featureID(at: firstIndex + index), name: placemark.name,
          description: placemark.description, geometry: geometry)
      })
      self.placemark = nil
    }
  }

  /// Content and feature order survive restoring the original file. UUIDv8
  /// retains those identities when selected places enter favorites or history.
  private func featureID(at index: Int) -> UUID {
    let digest = SHA256.hash(data: identitySeed + Data(String(index).utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  private func append(_ geometry: [KMLGeometry], counting: Bool = true, parser: XMLParser) {
    if counting {
      geometryCount += geometry.count
      guard geometryCount <= KMLDocument.maximumFeatures else {
        fail(parser, "Eine KML-Datei darf höchstens 5.000 Objekte enthalten."); return
      }
    }
    if let parent = geometries.last {
      guard case .multi = parent.kind else { fail(parser, "Ungültig verschachtelte KML-Geometrie."); return }
      guard parent.children.count + geometry.count <= KMLDocument.maximumFeatures else {
        fail(parser, "Eine KML-Datei darf höchstens 5.000 Objekte enthalten."); return
      }
      geometries[geometries.count - 1].children.append(contentsOf: geometry)
    } else {
      placemark?.geometries.append(contentsOf: geometry)
    }
  }

  private func checkCancellation(_ parser: XMLParser) -> Bool {
    guard !Task.isCancelled else {
      cancelled = true
      parser.abortParsing()
      return false
    }
    return true
  }

  private func fail(_ parser: XMLParser, _ message: String) {
    if failure == nil { failure = message }
    parser.abortParsing()
  }

  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) { fail(parser, "Eigene XML-Entitäten werden in KML-Dateien nicht unterstützt.") }

  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
    publicID: String?, systemID: String?
  ) { fail(parser, "Externe XML-Entitäten werden in KML-Dateien nicht unterstützt.") }

  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
    fail(parser, "Externe XML-Entitäten werden in KML-Dateien nicht unterstützt.")
    return nil
  }
}
