import Foundation
import OSMmini
import Testing
import UniformTypeIdentifiers

@testable import OSMminiDemoCLI

@MainActor struct DemoFileTests {
  private struct ExportFailure: LocalizedError {
    var errorDescription: String? { "Die Datei konnte nicht gespeichert werden." }
  }

  private func route(latitude: String = "48.1") throws -> Route {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return try decoder.decode(
      Route.self,
      from: Data(
        """
        {"path":[{"lat":\(latitude),"lon":12.2},{"lat":48.3,"lon":12.4}],
         "distance_m":100,"duration_s":20,"from_snap_m":0,"to_snap_m":0,"steps":[]}
        """.utf8))
  }

  @Test func cancelledFileDialogsDoNotBecomeErrors() {
    #expect(FileDialogError.message(for: CancellationError()) == nil)
    #expect(FileDialogError.message(for: CocoaError(.userCancelled)) == nil)
    #expect(
      FileDialogError.message(
        for: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) == nil)
  }

  @Test func realFileErrorsRemainVisible() {
    #expect(
      FileDialogError.message(for: ExportFailure()) == "Die Datei konnte nicht gespeichert werden.")
    #expect(FileDialogError.message(for: CocoaError(.fileWriteNoPermission)) != nil)
    // An unrelated domain may use the same numeric code as Cocoa's cancellation.
    #expect(
      FileDialogError.message(for: NSError(domain: "Export", code: NSUserCancelledError)) != nil)
    let failure = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
      userInfo: [NSUnderlyingErrorKey: CocoaError(.userCancelled)])
    #expect(FileDialogError.message(for: failure) != nil)
  }

  @Test func exportFilenamesKeepTheirFormatExtensions() {
    #expect(RouteExportFormat.geoJSON.filename == "route.geojson")
    #expect(RouteExportFormat.gpx.filename == "route.gpx")
    for format in [RouteExportFormat.geoJSON, .gpx] {
      let expected = URL(filePath: format.filename).pathExtension
      // Generic data preserves the full suggested filename if no GPX UTI is installed.
      #expect(
        format.contentType == .data || format.contentType.preferredFilenameExtension == expected)
    }
  }

  @Test func fileDialogAcceptsEachSelectedExportFormatWithoutFallback() {
    for format in [RouteExportFormat.geoJSON, .gpx] {
      // fileExporter tests exact membership, not conformance to .json/.xml.
      // Missing types silently select the first writable type instead.
      #expect(RouteDocument.writableContentTypes.contains(format.contentType))
    }
  }

  @Test func workerExportsPreserveTheEncodedRoute() async throws {
    let route = try route()
    #expect(try await RouteExportFormat.geoJSON.preparedData(for: route) == route.geoJSON())
    #expect(try await RouteExportFormat.gpx.preparedData(for: route) == route.gpx())
    let object = try #require(
      JSONSerialization.jsonObject(with: RouteExportFormat.geoJSON.encode(route)) as? [String: Any])
    let geometry = try #require(object["geometry"] as? [String: Any])
    let coordinates = try #require(geometry["coordinates"] as? [[Double]])
    #expect(coordinates == [[12.2, 48.1], [12.4, 48.3]])
    #expect(
      String(decoding: try RouteExportFormat.gpx.encode(route), as: UTF8.self).contains(
        "<trkpt lat=\"48.1\" lon=\"12.2\"/>"))
  }

  @Test func cancelledPreparationDoesNotReturnAnExport() async throws {
    let route = try route()
    // This main-actor task starts after cancellation, without relying on elapsed time.
    let task = Task { try await RouteExportFormat.geoJSON.preparedData(for: route) }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled export preparation returned a document")
    } catch is CancellationError {
    } catch {
      Issue.record("Unexpected export error: \(error)")
    }
  }

  @Test(arguments: ["\"nan\"", "\"inf\"", "\"-inf\""])
  func encodingFailuresReachTheFileErrorMessage(latitude: String) async throws {
    let route = try route(latitude: latitude)
    for format in [RouteExportFormat.geoJSON, .gpx] {
      do {
        _ = try await format.preparedData(for: route)
        Issue.record("\(format.name) accepted a non-finite coordinate")
      } catch {
        #expect(FileDialogError.message(for: error)?.contains("ungültige Zahlenwerte") == true)
      }
    }
  }
}
