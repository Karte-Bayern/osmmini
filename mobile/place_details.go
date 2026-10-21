package mobile

import (
	"strings"
	"unicode"
	"unicode/utf8"

	osm "simonwaldherr.de/go/osmmini"
)

// PlaceDetails contains source tags, not inferred addresses or interpreted
// opening hours. Missing fields remain absent in previously imported regions.
type PlaceDetails struct {
	Address      string `json:"address,omitempty"`
	OpeningHours string `json:"opening_hours,omitempty"`
	Phone        string `json:"phone,omitempty"`
	Website      string `json:"website,omitempty"`
}

func detailTag(key string) bool {
	switch key {
	case "opening_hours", "phone", "contact:phone", "website", "contact:website":
		return true
	}
	return false
}

func boundedSourceText(value string, limit int) string {
	value = strings.TrimSpace(value)
	if len(value) > limit || !utf8.ValidString(value) || strings.ContainsFunc(value, unicode.IsControl) {
		return ""
	}
	return value
}

func detailValue(value string, limit int) string {
	value = boundedSourceText(value, limit)
	if strings.ContainsFunc(value, func(r rune) bool { return unicode.Is(unicode.Cf, r) }) {
		return ""
	}
	return value
}

func cleanDetails(details *PlaceDetails) *PlaceDetails {
	if details == nil {
		return nil
	}
	value := PlaceDetails{
		Address: detailValue(details.Address, 1024), OpeningHours: detailValue(details.OpeningHours, 1024),
		Phone: detailValue(details.Phone, 128), Website: detailValue(details.Website, 2048),
	}
	if value == (PlaceDetails{}) {
		return nil
	}
	return &value
}

func detailsFromTags(tags osm.Tags) *PlaceDetails {
	street := strings.TrimSpace(tags["addr:street"])
	if street == "" {
		street = strings.TrimSpace(tags["addr:place"])
	}
	street = strings.TrimSpace(street + " " + tags["addr:housenumber"])
	locality := strings.TrimSpace(tags["addr:postcode"] + " " + tags["addr:city"])
	address := street
	if locality != "" {
		if address != "" {
			address += ", "
		}
		address += locality
	}
	first := func(key, fallback string, limit int) string {
		if value := detailValue(tags[key], limit); value != "" {
			return value
		}
		return detailValue(tags[fallback], limit)
	}
	return cleanDetails(&PlaceDetails{
		Address: address, OpeningHours: tags["opening_hours"],
		Phone: first("phone", "contact:phone", 128), Website: first("website", "contact:website", 2048),
	})
}
