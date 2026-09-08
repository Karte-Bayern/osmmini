package main

import (
	"encoding/json"
	"regexp"
	"strings"
)

// The same bounded protocol works with local models without native function calling.
const aiUIInstructions = `
WERKZEUGE UND VISUELLE AUSGABEN:
Wenn du Ortskoordinaten benötigst, gib ausschließlich einen Block aus:
` + "```agent-ui\n{\"search\":[\"Ortsname\"]}\n```" + `
Das System liefert echte lokale Suchergebnisse. Maximal 4 Suchanfragen je Runde, 3 Runden. Verwende ausschließlich gefundene oder vom Nutzer gelieferte Koordinaten; bei mehreren Treffern frage mit Buttons nach.
Für die finale Antwort darfst du zusätzlich zum Text einen agent-ui JSON-Block mit {"elements":[...]} ausgeben. Maximal 20 Elemente. Kein HTML, JavaScript oder URLs.
Elemente:
{"type":"marker","label":"Ort","coordinates":[[12.5,48.6]],"color":"#2563eb"}
{"type":"line","label":"Verbindung","coordinates":[[12.5,48.6],[12.6,48.7]],"color":"#2563eb"}
{"type":"arrow","label":"Richtung","coordinates":[[12.5,48.6],[12.6,48.7]]}
{"type":"circle","label":"Umkreis","coordinates":[[12.5,48.6]],"radius_m":1000}
{"type":"polygon","label":"Gebiet","coordinates":[[12.5,48.6],[12.6,48.6],[12.6,48.7]]}
{"type":"place","label":"Ortsname","text":"Belegte Informationen zum Ort","coordinates":[[12.5,48.6]]}
{"type":"card","label":"Titel","text":"Sachliche Information"}
{"type":"chart","label":"Vergleich","unit":"km","values":[{"label":"A","value":12},{"label":"B","value":20}]}
{"type":"button","label":"Mehr Details","prompt":"Zeige Details zu ..."}
Für gefundene Orte bevorzuge place: Die Oberfläche bietet Karte und Route hierher an. Eine Ortskarte benötigt genau einen gefundenen oder vom Nutzer gelieferten Punkt. Ortskarten berechnen keine Route automatisch. Öffnungszeiten, Bewertungen und Ausstattung nur nennen, wenn diese in den Werkzeugdaten belegt sind; sonst als unbekannt kennzeichnen.
Koordinaten IMMER [Längengrad,Breitengrad]. Kreisradius 1–100000 Meter. Linien sind geometrische Verbindungen, keine berechneten Routen. Diagramme nur mit belegten Zahlen; nenne die Datenquelle im Text. Buttons lösen erst nach Klick eine neue Anfrage aus. Zeichne nur wenn gewünscht. Bei Zeichen-/Informationsaufträgen KEIN route-action-Block. Bestätige keine Ausführung vorab, die Oberfläche zeigt Ausführungsfehler.
`

var aiUIBlock = regexp.MustCompile("(?s)```agent-ui\\s*\\n?(.*?)```")

type aiUIEnvelope struct {
	Search   []string          `json:"search,omitempty"`
	Elements []json.RawMessage `json:"elements,omitempty"`
}

func extractAIUI(text string) (string, aiUIEnvelope, error) {
	var out aiUIEnvelope
	matches := aiUIBlock.FindAllStringSubmatch(text, -1)
	for _, match := range matches {
		var part aiUIEnvelope
		if err := json.Unmarshal([]byte(match[1]), &part); err != nil {
			return aiUIBlock.ReplaceAllString(text, ""), out, err
		}
		out.Search = append(out.Search, part.Search...)
		out.Elements = append(out.Elements, part.Elements...)
	}
	if len(out.Search) > 4 {
		out.Search = out.Search[:4]
	}
	if len(out.Elements) > 20 {
		out.Elements = out.Elements[:20]
	}
	return strings.TrimSpace(aiUIBlock.ReplaceAllString(text, "")), out, nil
}
func wantsAIVisuals(prompt string) bool {
	p := strings.ToLower(prompt)
	for _, word := range []string{"zeichne", "zeichnen", "markiere", "markierung", "pfeil", "kreis", "diagramm", "infokarte", "ortskarte", "buttons", "polygon", "visualisiere"} {
		if strings.Contains(p, word) {
			return true
		}
	}
	return false
}
