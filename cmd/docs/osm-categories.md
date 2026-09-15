# OSM-Kategorie-Mapping

`cmd/poi_categories.go` ist der gemeinsame Katalog für die lokale KI-Erkennung,
Ortssuche, ortsbezogene KI-Suche und `/api/v1/geo/pois?category=…`.
Er enthält 41 Kategorien mit deutschen und englischen Aliasen, darunter
Ladestationen, Toiletten, Fahrradparkplätze, Campingplätze und Physiotherapie.

- Groß-/Kleinschreibung, Umlaute, Schreibweisen wie `ae`, Akzente, Bindestriche
  und ausdrücklich aufgeführte Pluralformen werden normalisiert.
- In Sätzen gewinnt die längste bekannte Wortfolge, bei Gleichstand die zuerst
  genannte. Teilwörter zählen nicht: `Parkstraße` ist kein Park, `Seestraße`
  kein See und `Zahnarzt` kein allgemeiner Arzt. Eigennamen wie `Isar` sind
  keine generischen Kategorien.
- Eine Kategorie kann mehrere alternative Filter besitzen. Innerhalb eines
  Filters müssen alle Bedingungen zutreffen. Semikolongetrennte Tag-Werte
  werden als einzelne Werte ausgewertet.
- Die Suchrangfolge behält Namen und Adressen bei und berücksichtigt zusätzlich
  exakt erkannte Kategorie-Aliase. Kategorieauflösung erfolgt einmal pro Suche.

## Wichtige Zuordnungen

| Kategorie | Berücksichtigte Tags |
| --- | --- |
| Krankenhaus | `amenity=hospital` oder `healthcare=hospital` |
| Arzt | `amenity=doctors` oder `healthcare=doctor` |
| Zahnarzt | `amenity=dentist` oder `healthcare=dentist` |
| Wald | `landuse=forest` oder `natural=wood` |
| See | `natural=water` **und** `water=lake` |
| Schwimmbad | `leisure=swimming_pool` oder `leisure=sports_centre` **und** `sport=swimming` |
| Bahnhof | `railway=station` |

`Hallenbad` und `Freibad` werden als Schwimmbad-Synonyme ausgewertet; eine
zusätzliche Innen-/Außenfilterung erfolgt nicht. Die Kategorien machen keine
Aussage über öffentliche Zugänglichkeit oder Öffnungszeiten. Unspezifizierte
Wasserflächen werden nicht als See angenommen.

Die Geo-API akzeptiert weiterhin unbekannte rohe Kategorie-Werte wie
`company`, jetzt auch aus `healthcare`, `railway`, `craft`, `historic` und
weiteren POI-Schlüsseln. Ein expliziter Filter wie `amenity=hospital` prüft
exakt diesen Schlüssel/Wert und wird nicht um `healthcare=hospital` erweitert.
Beispiele: `category=Krankenhäuser`, `category=charging_station`,
`category=emergency%3Dfire_hydrant`.

## Quellen

Die medizinischen Alternativen folgen dem
[OSM-Healthcare-Schema](https://wiki.openstreetmap.org/wiki/Healthcare).
Die Unterscheidung von Seen und anderen Gewässern folgt
[natural=water](https://wiki.openstreetmap.org/wiki/Tag:natural%3Dwater) und
[water](https://wiki.openstreetmap.org/wiki/Key:water).
Die Kombination für Schwimmbäder ist unter
[leisure=swimming_pool](https://wiki.openstreetmap.org/wiki/DE:Tag:leisure%3Dswimming_pool)
beschrieben.
