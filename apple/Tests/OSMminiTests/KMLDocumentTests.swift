import Foundation
import Testing

@testable import OSMmini

private func kml(_ body: String, namespace: String = "http://www.opengis.net/kml/2.2") -> Data {
  Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><kml xmlns=\"\(namespace)\">\(body)</kml>".utf8)
}

@Test func kmlImportPreservesNamesCoordinateOrderAndNestedMultiGeometry() throws {
  let data = Data("""
    <k:kml xmlns:k="http://www.opengis.net/kml/2.2"><k:Document>
      <k:name>Weg &amp; Café</k:name><k:Folder><k:name>Ordner</k:name><k:Placemark>
        <k:MultiGeometry>
          <k:Point><k:coordinates>12.5,48.25,420</k:coordinates></k:Point>
          <k:MultiGeometry><k:LineString><k:coordinates>
            1.25e1,48.25,0 12.6,48.3,100
          </k:coordinates></k:LineString></k:MultiGeometry>
        </k:MultiGeometry>
        <k:name>Grüner Weg &amp; Aussicht</k:name><k:description><![CDATA[<b>Literal</b>]]></k:description>
      </k:Placemark></k:Folder></k:Document></k:kml>
    """.utf8)
  let document = try KMLDocument(data: data, name: "Fallback")
  #expect(document.name == "Weg & Café")
  #expect(document.features.count == 2)
  #expect(Set(document.features.map(\.id)).count == 2)
  #expect(document.features.allSatisfy { $0.name == "Grüner Weg & Aussicht" })
  #expect(document.features.allSatisfy { $0.description == "<b>Literal</b>" })
  #expect(document.features[0].geometry == .point(Coordinate(lat: 48.25, lon: 12.5)))
  #expect(document.features[1].geometry == .lineString([
    Coordinate(lat: 48.25, lon: 12.5), Coordinate(lat: 48.3, lon: 12.6),
  ]))
  #expect(document.coordinates.count == 3)
  #expect(try JSONDecoder().decode(KMLDocument.self, from: JSONEncoder().encode(document)) == document)
}

@Test func kmlPolygonsRetainClosedOuterAndInnerRings() throws {
  let document = try KMLDocument(data: kml("""
    <Placemark><name>Fläche</name><Polygon>
      <outerBoundaryIs><LinearRing><coordinates>
        12,48 13,48 13,49 12,48
      </coordinates></LinearRing></outerBoundaryIs>
      <innerBoundaryIs><LinearRing><coordinates>
        12.1,48.1 12.2,48.1 12.2,48.2 12.1,48.1
      </coordinates></LinearRing></innerBoundaryIs>
    </Polygon></Placemark>
    """))
  guard case .polygon(let outer, let holes) = document.features.first?.geometry else {
    Issue.record("Expected polygon geometry"); return
  }
  #expect(outer.count == 4 && outer.first == outer.last)
  #expect(holes.count == 1 && holes[0].count == 4 && holes[0].first == holes[0].last)
  #expect(document.coordinates.count == 8)
}

@Test func kmlFeatureIdentitiesSurviveRepeatedImportsAndChangeWithTheSourceContent() throws {
  let xml = """
    <kml><Placemark><name>Müller</name><MultiGeometry>
      <Point><coordinates>12,48</coordinates></Point>
      <Point><coordinates>12,48</coordinates></Point>
    </MultiGeometry></Placemark></kml>
    """
  for encoding in [String.Encoding.utf8, .utf16] {
    let data = try #require(xml.data(using: encoding))
    let first = try KMLDocument(data: data, name: "Original")
    let restored = try KMLDocument(data: data, name: "Umbenannt")
    #expect(first.features.map(\.id) == restored.features.map(\.id))
    #expect(Set(first.features.map(\.id)).count == first.features.count)
    let changed = try #require(xml.replacingOccurrences(of: "12,48", with: "13,49").data(using: encoding))
    let replacement = try KMLDocument(data: changed)
    #expect(Set(first.features.map(\.id)).isDisjoint(with: replacement.features.map(\.id)))
  }
}

@Test func kmlSupportsLegacyAndUnprefixedDocumentsAndIgnoresExternalPresentation() throws {
  for namespace in ["", "http://earth.google.com/kml/2.1", "http://earth.google.com/kml/2.2"] {
    let document = try KMLDocument(data: kml("""
      <NetworkLink><Link><href>https://example.invalid/remote.kml</href></Link></NetworkLink>
      <Placemark><Style><IconStyle><Icon><href>file:///private/secret</href></Icon></IconStyle></Style>
        <Point><coordinates>0,0</coordinates></Point>
      </Placemark>
      """, namespace: namespace), name: "  Meine Datei  ")
    #expect(document.name == "Meine Datei")
    #expect(document.features.map(\.geometry) == [.point(Coordinate(lat: 0, lon: 0))])
  }
  let foreign = try KMLDocument(data: kml("""
    <Placemark><x:Point xmlns:x="https://example.invalid/foreign"><x:coordinates>80,70</x:coordinates></x:Point>
      <Point><coordinates>1,2</coordinates></Point>
    </Placemark>
    """))
  #expect(foreign.features.map(\.geometry) == [.point(Coordinate(lat: 2, lon: 1))])
  #expect(throws: (any Error).self) {
    try KMLDocument(data: kml("<Placemark><Point><coordinates>1,2</coordinates></Point></Placemark>", namespace: "https://example.invalid/foreign"))
  }
}

@Test func kmlInvalidGeometryRejectsTheWholeDocumentInsteadOfJoiningBrokenLines() {
  let validPrefix = "<Placemark><Point><coordinates>12,48</coordinates></Point></Placemark>"
  let invalid = [
    "<Point><coordinates>12,48 13,49</coordinates></Point>",
    "<Point><coordinates>NaN,48</coordinates></Point>",
    "<Point><coordinates>12,Inf</coordinates></Point>",
    "<Point><coordinates>181,48</coordinates></Point>",
    "<Point><coordinates>12,-91</coordinates></Point>",
    "<Point><coordinates>12,48,NaN</coordinates></Point>",
    "<LineString><coordinates>12,48</coordinates></LineString>",
    "<LineString><coordinates>12,48 bad 13,49</coordinates></LineString>",
    "<LineString><coordinates>12,48,,</coordinates></LineString>",
    "<Point><coordinates>12,48</coordinates><coordinates>13,49</coordinates></Point>",
    "<Point><coordinates>12,<span>48</span></coordinates></Point>",
    "<Polygon><outerBoundaryIs><LinearRing><coordinates>12,48 13,48 13,49</coordinates></LinearRing></outerBoundaryIs></Polygon>",
    "<Polygon><outerBoundaryIs><LinearRing><coordinates>12,48 12,48 12,48 12,48</coordinates></LinearRing></outerBoundaryIs></Polygon>",
    "<Polygon><innerBoundaryIs><LinearRing><coordinates>12,48 13,48 13,49 12,48</coordinates></LinearRing></innerBoundaryIs></Polygon>",
  ]
  for geometry in invalid {
    #expect(throws: (any Error).self) {
      try KMLDocument(data: kml(validPrefix + "<Placemark>\(geometry)</Placemark>"))
    }
  }
}

@Test func kmlRejectsDTDAndEntitiesInUTF8AndUTF16BeforeParsing() throws {
  let declarations = [
    "<!DOCTYPE kml [<!ENTITY local SYSTEM 'file:///private/secret'>]>",
    "<!DOCTYPE kml [<!ENTITY word 'expanded'>]>",
    "<!DOCTYPE kml SYSTEM 'https://example.invalid/external.dtd'>",
  ]
  for declaration in declarations {
    let xml = declaration + "<kml><Placemark><Point><coordinates>12,48</coordinates></Point></Placemark></kml>"
    for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32] {
      let data = try #require(xml.data(using: encoding))
      #expect(throws: (any Error).self) { try KMLDocument(data: data) }
    }
  }
  #expect(throws: (any Error).self) {
    try KMLDocument(data: kml("<Placemark><name>&missing;</name><Point><coordinates>12,48</coordinates></Point></Placemark>"))
  }
}

@Test(arguments: [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian])
func kmlAllowsDoctypeTextInsideLiteralXMLContentButStillRejectsDeclarations(
  encoding: String.Encoding
) throws {
  let encodingName: String
  switch encoding {
  case .utf16LittleEndian: encodingName = "UTF-16LE"
  case .utf16BigEndian: encodingName = "UTF-16BE"
  default: encodingName = "UTF-8"
  }
  let header = "<?xml version=\"1.0\" encoding=\"\(encodingName)\"?>"
  let body = """
    <!-- Literal <!DOCTYPE text> in an XML comment -->
    <?example <!DOCTYPE text>?>
    <Document><Placemark><description><![CDATA[<!DOCTYPE html><b>Literal</b>]]></description>
      <Point><coordinates>12,48</coordinates></Point></Placemark></Document>
    """
  let data = try #require("\(header)<kml>\(body)</kml>".data(using: encoding))
  let document = try KMLDocument(data: data)
  #expect(document.features[0].description == "<!DOCTYPE html><b>Literal</b>")
  let declared = "\(header)<!-- comment --><?example text?><!DOCTYPE kml><kml>\(body)</kml>"
  #expect(throws: (any Error).self) {
    try KMLDocument(data: #require(declared.data(using: encoding)))
  }
}

@Test func kmlRejectsUnsupportedOrMalformedFilesAndBoundsEveryResource() throws {
  for xml in ["<kml/>", "<notKML/>", "<kml><Placemark>",
    "<kml><NetworkLink><Link><href>https://example.invalid/data.kml</href></Link></NetworkLink></kml>"]
  {
    #expect(throws: (any Error).self) { try KMLDocument(data: Data(xml.utf8)) }
  }
  #expect(throws: (any Error).self) {
    try KMLDocument(data: Data(repeating: 32, count: KMLDocument.maximumBytes + 1))
  }
  let deep = String(repeating: "<Folder>", count: 65) + String(repeating: "</Folder>", count: 65)
  #expect(throws: (any Error).self) { try KMLDocument(data: kml(deep)) }
  let point = "<Placemark><Point><coordinates>1,2</coordinates></Point></Placemark>"
  #expect(throws: (any Error).self) {
    try KMLDocument(data: kml(String(repeating: point, count: KMLDocument.maximumFeatures + 1)))
  }
  let geometry = "<Point><coordinates>1,2</coordinates></Point>"
  #expect(throws: (any Error).self) {
    try KMLDocument(data: kml("<Placemark><MultiGeometry>"
      + String(repeating: geometry, count: KMLDocument.maximumFeatures + 1)
      + "</MultiGeometry></Placemark>"))
  }
  let manyPoints = String(repeating: "1,2 ", count: KMLDocument.maximumPositions + 1)
  #expect(throws: (any Error).self) {
    try KMLDocument(data: kml("<Placemark><LineString><coordinates>\(manyPoints)</coordinates></LineString></Placemark>"))
  }
  let longToken = String(repeating: "1", count: 150)
  #expect(throws: (any Error).self) {
    try KMLDocument(data: kml("<Placemark><Point><coordinates>\(longToken),2</coordinates></Point></Placemark>"))
  }
}

@Test func kmlImportBoundsDisplayTextAndKeepsCoordinatesAcrossCDATAChunks() throws {
  let text = String(repeating: "ü", count: 2_500)
  let document = try KMLDocument(data: kml("""
    <Document><name>\(text)</name><Placemark><name>\(text)</name><description>\(text)</description>
      <LineString><coordinates>12<![CDATA[.5,48.25 13,]]>49</coordinates></LineString>
    </Placemark></Document>
    """))
  #expect(document.name.count == 160)
  #expect(document.features[0].name?.count == 200)
  #expect(document.features[0].description?.count == 2_000)
  #expect(document.features[0].geometry == .lineString([
    Coordinate(lat: 48.25, lon: 12.5), Coordinate(lat: 49, lon: 13),
  ]))
  let combined = "x" + String(repeating: "\u{0301}", count: 5_000)
  let bounded = try KMLDocument(data: kml("""
    <Document><name>\(combined)</name><Placemark><description>\(combined)</description>
      <Point><coordinates>1,2</coordinates></Point></Placemark></Document>
    """))
  #expect(bounded.name.unicodeScalars.count == 160)
  #expect(bounded.features[0].description?.unicodeScalars.count == 2_000)
}

@Test func kmlImportAcceptsUTF16FilesWithUnicodeAndCDATA() throws {
  let xml = """
    <kml><Document><name>Grüner Weg</name><Placemark><name><![CDATA[Müller]]></name>
      <Point><coordinates>12.5,48.25</coordinates></Point></Placemark></Document></kml>
    """
  let data = try #require(xml.data(using: .utf16))
  let document = try KMLDocument(data: data)
  #expect(document.name == "Grüner Weg")
  #expect(document.features[0].name == "Müller")
  #expect(document.features[0].geometry == .point(Coordinate(lat: 48.25, lon: 12.5)))
}

@Test @MainActor func cancelledKMLImportNeverPublishesADocument() async throws {
  let data = kml("<Placemark><Point><coordinates>1,2</coordinates></Point></Placemark>")
  let task = Task { try KMLDocument(data: data) }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}
