# KI-Werkzeuge und visuelle Ausgaben

Der Chat unterstützt lokale Ortssuche als mehrstufiges Werkzeug für Ollama und
OpenAI-kompatible Chatmodelle. Das Modell erhält echte Suchergebnisse und kann
anschließend strukturierte Ausgaben erzeugen. Dies verwendet ein JSON-Protokoll
in `agent-ui`-Codeblöcken, keine nativen Function-Calling-Endpunkte.

Beispiele im Chat:

- „Markiere Dingolfing und zeichne einen Kreis mit 1000 Metern Radius darum.“
- „Zeichne einen Pfeil von Dingolfing nach Landau an der Isar.“
- „Zeige ein Balkendiagramm mit A: 12 km und B: 20 km.“
- „Gib mir Infokarten und Buttons für weitere Details zu diesen Orten.“

Die strukturierten Ausgaben benötigen ein Chatmodell, das die JSON-Anweisungen
befolgt. Normale lokale Navigation bleibt ohne Modell verfügbar. Gezeichnete
Linien sind direkte geometrische Verbindungen, keine Straßenrouten.

## Antwortprotokoll

`POST /api/v1/ai/query` liefert zusätzlich `elements`. Erlaubte Typen sind
`marker`, `line`, `arrow`, `circle`, `polygon`, `card`, `chart`, `button`.
Geometrien verwenden `coordinates: [[lon, lat], ...]`. Kreise benötigen
`radius_m` (1–100000), Farben optional `#RRGGBB`. Ein Button enthält `prompt`;
er sendet diesen erst nach Klick. Diagramme enthalten `values` mit `label`
und nichtnegativem numerischem `value`, optional `unit`.

Maximal 3 Suchrunden mit je 4 Suchbegriffen und 5 Treffern, 20 Ausgabeelemente
pro Antwort, 500 Punkte pro Geometrie und 200 Zeichenfeatures insgesamt.
Fehlerhafte Elemente werden einzeln zurückgewiesen. Texte werden als Text
behandelt, nicht als HTML. Die Oberfläche führt keinen Modellcode aus.

Zeichnungen sind temporär, überleben Kartenstilwechsel und bieten Buttons zum
Zentrieren und Entfernen. „Chat löschen“ entfernt auch die KI-Zeichnungen.
Nach einem Neuladen sind sie weg. Diagramme zeigen zusätzlich alle Werte als
Text. Fehler im Modellprotokoll erscheinen im Chat.
