import Foundation
import OSMmini
import Testing

@testable import OSMminiDemoCLI

struct DemoPlaceDetailsTests {
  @Test func openingHoursSummaryDoesNotInferALiveOpeningStatus() {
    #expect(DemoPlaceText.hoursSummary("24/7") == "Rund um die Uhr · laut Offline-Karte")
    #expect(DemoPlaceText.hoursSummary("off") == "Als geschlossen eingetragen")
    let complex = "Mo-Fr 08:00-18:00; PH off; \"nach Vereinbarung\""
    #expect(DemoPlaceText.hoursSummary(complex) == complex)
    #expect(!DemoPlaceText.hasContactDetails(PlaceDetails(address: "Markt 1", phone: " ")))
    #expect(DemoPlaceText.hasContactDetails(PlaceDetails(phone: "+49 123 456")))
  }

  @Test func sharingAPlaceIncludesAddressAndCoordinatesWithoutInventingAnOSMObject() {
    let place = DemoPlace(
      coordinate: Coordinate(lat: 48.5, lon: 12.5), name: "Café am Markt",
      category: "cafe", details: PlaceDetails(address: "Markt 1"))
    #expect(
      DemoPlaceText.shareText(place) == "Café am Markt\nMarkt 1\n"
        + DemoPlaceText.coordinates(place.coordinate))
    #expect(!DemoPlaceText.shareText(place).contains("http"))
  }

  @Test func websiteLinksAcceptWebAddressesAndRejectOtherSchemesAndCredentials() {
    #expect(
      DemoPlaceText.websiteURL("https://example.org/cafe?lang=de")?.absoluteString
        == "https://example.org/cafe?lang=de")
    #expect(
      DemoPlaceText.websiteURL("http://example.org/")?.absoluteString
        == "http://example.org/")
    #expect(
      DemoPlaceText.websiteURL("example.org/cafe")?.absoluteString
        == "https://example.org/cafe")
    for invalid in [
      "", "javascript:alert(1)", "file:///tmp/location", "tel:+498731123456",
      "mailto:person@example.org", "https://user:password@example.org/cafe",
      "https://user@example.org/cafe", "https:///", "https://exam\nple.org/",
    ] {
      #expect(DemoPlaceText.websiteURL(invalid) == nil)
    }
  }

  @Test func phoneLinksNormalizeOnlySingleASCIIPhoneNumbers() {
    #expect(DemoPlaceText.phoneURL("+49 (8731) 123-45.6")?.absoluteString == "tel:+498731123456")
    #expect(DemoPlaceText.phoneURL("0049/8731/123456")?.absoluteString == "tel:00498731123456")
    #expect(DemoPlaceText.phoneURL("123")?.absoluteString == "tel:123")
    for invalid in [
      "", "12", "+12", "+", "++498731123456", "123+456", "123;456", "123,456",
      "123 / +456", "tel:123456", "123\n456", "١٢٣٤٥٦", "CALL123456",
    ] {
      #expect(DemoPlaceText.phoneURL(invalid) == nil)
    }
  }

  @Test func sourceLinksRequireRealSupportedOSMObjectIdentities() {
    #expect(
      DemoPlaceText.sourceURL("node/123")?.absoluteString
        == "https://www.openstreetmap.org/node/123")
    #expect(
      DemoPlaceText.sourceURL("way/456")?.absoluteString
        == "https://www.openstreetmap.org/way/456")
    for invalid: String? in [
      nil, "", "street/123", "relation/123", "node/0", "way/-1", "node/9223372036854775808",
      "node/123/extra", "node/123?redirect=other", "https://example.org/node/123",
    ] {
      #expect(DemoPlaceText.sourceURL(invalid) == nil)
    }
  }
}
