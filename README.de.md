<p align="center"><img src="packaging/AppIcon.png" width="128" alt="Symbol von EVE-O Preview for macOS"></p>

# EVE-O Preview for macOS

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Русский](README.ru.md) | [Français](README.fr.md) | **Deutsch** | [Español](README.es.md)

Diese Übersetzung wurde maschinell erstellt; bei Abweichungen vom [englischen README](README.md) gilt die englische Fassung.

EVE-O Preview for macOS zeigt eine Live-Miniatur jedes laufenden EVE Online-Clients. Ein Klick auf eine Miniatur oder ein globaler Hotkey wechselt zu diesem Client.

Es ist eine native Swift-Neuimplementierung der Funktionen von [EveOPlus/eve-o-preview](https://github.com/EveOPlus/eve-o-preview) (Windows, GPL-3.0) für macOS. Der C#-Code des Ursprungsprojekts wird nicht portiert, und Oberfläche sowie Konfigurationsformat unterscheiden sich vom Ursprungsprojekt.
Es steht unter der GNU General Public License Version 3 oder einer späteren Version (GPL-3.0-or-later), entsprechend den SPDX-Kennungen in den Quelldateien; das Ursprungsprojekt steht unter GPL-3.0. Den vollständigen Text enthält [LICENSE](LICENSE).

Dieses Repository begann als GitHub-Fork von EveOPlus/eve-o-preview und wurde für v1.0 in ein eigenständiges Repository verschoben. Es ist ein unabhängiges Projekt: Es teilt keinen Code mit der Windows-Version und wird nicht von den Autoren des Ursprungsprojekts gepflegt.

## Funktionen

- Client-Erkennung: Die Miniaturen werden automatisch aktualisiert, wenn ein Client startet, beendet wird oder nach dem Einloggen seinen Namen ändert.
- Live-Miniaturen: ein ScreenCaptureKit-Stream pro Client, mit einstellbarer Größe und Bildrate.
- Miniatur-Panels: Sie übernehmen nie den Fokus, erscheinen in allen Spaces und können auf Wunsch im Vordergrund bleiben. Standardmäßig haben sie einen 2 Punkt breiten hellgrauen Rahmen, damit benachbarte Miniaturen leicht zu unterscheiden sind; Farbe und Breite sind einstellbar, und der Rahmen lässt sich abschalten.
- Wechseln: Ein Linksklick auf eine Miniatur wechselt zu ihrem Client; Control+Klick minimiert ihn. Das Kontextmenü bietet „Minimieren“, „Alle minimieren“, „Beim Wechseln überspringen“, „Diese Miniatur ausblenden“ und „Standardgröße wiederherstellen“.
- Einblendungen: Charaktername als Titel, ein Hervorhebungsrahmen am aktiven Client (Farbe pro Charakter einstellbar; ersetzt den hellgrauen Rahmen, solange er sichtbar ist) und eine Markierung für „Beim Wechseln überspringen“.
- „Zoom beim Überfahren“ (9 Ankerpunkte) und Deckkraft.
- Sichtbarkeit: Miniatur des aktiven Clients ausblenden; ausblenden, wenn EVE nicht aktiv ist (mit Verzögerung); pro Charakter ausblenden; alle ausblenden.
- Layout: Ziehen zum Bewegen und Skalieren, Einrasten an anderen Miniaturen und Bildschirmrändern, optional Layout sperren. Position und Größe werden pro Charakter gesichert; Clients am Anmeldebildschirm nutzen eine eigene Startposition.
- Wechselgruppen: Hotkeys vorwärts und rückwärts, Überspringen für die laufende Sitzung; Hotkeys pro Charakter; ein Hotkey zum Durchschalten der Clients am Anmeldebildschirm; Hotkeys für „Alle ausblenden“ und „Alle minimieren“. Hotkeys können die mittlere und die seitlichen Maustasten nutzen, und jeder Hotkey kann überall oder nur in EVE gelten.
- Kampfwarnungen (standardmäßig aus): liest die Spielprotokolle und lässt die Miniatur eines Charakters blinken, wenn dieser angegriffen wird.
- Profile: erstellen, duplizieren, umbenennen, löschen und wechseln.
- Updates: sucht auf GitHub nach neuen Releases und installiert sie direkt in der App, nachdem der Download und seine Codesignatur überprüft wurden (siehe [Updates](#updates)).
- Problemberichte: erstellt eine anonymisierte Diagnose-ZIP-Datei und öffnet ein vorausgefülltes GitHub-Issue; nach einem unerwarteten Beenden bietet der nächste Start an, es zu melden (siehe [Problem melden](#problem-melden)).
- Ein Symbol in der Menüleiste anstelle des Windows-Tray-Symbols.
- Ein Einstellungsfenster mit 8 Seiten: „Clients“, „Miniaturen“, „Umschalten“, „Warnungen“, „Profile“, „Allgemein“, „Berechtigungen“ und „Info“.
- Sprachen der Oberfläche: Englisch (Standard), Chinesisch, Russisch, Japanisch, Koreanisch, Französisch, Deutsch und Spanisch. Die Sprache wird auf der Seite „Allgemein“ umgeschaltet, alternativ lässt sich „Systemsprache“ wählen; die Änderung gilt sofort. Die russische, japanische, koreanische, französische, deutsche und spanische Übersetzung sind maschinell erstellt; Korrekturen sind willkommen.

## Nicht übernommene Funktionen des Ursprungsprojekts

| Funktion des Ursprungsprojekts | Grund |
| --- | --- |
| Bildratenbegrenzung und selektive Stummschaltung (Robin-Injektion) | Das Ursprungsprojekt injiziert eine DLL in Windows-Prozesse; macOS hat keinen vergleichbaren öffentlichen Mechanismus |
| CPU-Affinität | Beruht auf Windows CPU Sets; Apple Silicon hat keine öffentliche API, um einen Prozess an Kerne zu binden |
| Kampfprotokoll-Erweiterungen (Augments): Schadenszahlen, DPS, Reparaturmengen, System-Overlay, statische FC-Daten | Ein großes eigenständiges Subsystem außerhalb von „Vorschau und Wechseln“; übernommen wurde nur „Blinken bei Angriff“ |
| Themes, alte Oberfläche, eigene Stile für das Kontextmenü | Die macOS-Version folgt dem Erscheinungsbild des Systems |
| Kompatibler Aufnahmemodus (`PrintWindow`) | ScreenCaptureKit ist die einzige Aufnahmemethode |
| Low-Level-Tastatur-Hook | Tastatur-Hotkeys nutzen globale Carbon-Hotkeys; ein Maus-Event-Tap wird nur erstellt, wenn eine Maustaste belegt ist |

Bereiche mit Andocken per Drag & Drop, Mehrfachauswahl und Gruppenverschiebung, Widerrufen, Ausrichtungshilfslinien, Import von Windows-Konfigurationen und Start bei der Anmeldung sind für die Zeit nach v1 geplant.

## Voraussetzungen

- macOS 14 oder neuer, auf Apple Silicon oder Intel. Das Release-dmg enthält eine Universal-Binary.
- EVE-Clients funktionieren am besten im Fenstermodus. Clients im nativen Vollbildmodus werden ab 1.1.1 unterstützt (Miniaturen erscheinen über ihnen, solange „Miniaturen im Vordergrund halten“ aktiviert ist), aber jeder liegt in einem eigenen Space, sodass beim Wechseln zu einem solchen Client die Space-Übergangsanimation abläuft.
- Zum Bauen aus dem Quellcode werden Xcode oder die Command Line Tools (Swift 6) benötigt.

## Installation

### Release herunterladen

1. Laden Sie `EVE-O-Preview-<version>.dmg` von der Seite [Releases](https://github.com/deletexiumu/eve-o-preview-macos/releases) herunter.
2. Öffnen Sie das dmg und ziehen Sie `EVE-O Preview.app` in den Ordner „Programme“.
3. Öffnen Sie die App. Ihr Symbol erscheint in der Menüleiste, und beim ersten Start öffnet sich das Einstellungsfenster auf der Seite „Berechtigungen“.

Release-Builds sind mit dem selbstsignierten Zertifikat des Projekts signiert und nicht notarisiert, weil das Projekt keine Apple Developer ID hat. Beim ersten Start blockiert macOS die App mit dem Hinweis, dass der Entwickler nicht überprüft werden kann. So lässt sie sich öffnen:

1. Öffnen Sie Systemeinstellungen > Datenschutz & Sicherheit.
2. Scrollen Sie nach unten zum Hinweis zu EVE-O Preview, klicken Sie auf „Dennoch öffnen“ und bestätigen Sie.

Wenn macOS meldet, die App „ist beschädigt und kann nicht geöffnet werden“, oder als Alternative zu den Schritten oben, entfernen Sie das Quarantäne-Attribut im Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/EVE-O Preview.app"
```

**Hinweis:** Jedes Release ist mit demselben Zertifikat signiert, daher behält macOS die Berechtigungen „Bildschirmaufnahme“ und „Bedienungshilfen“ bei einem Upgrade. Wenn die Berechtigungen nach einem Upgrade nicht mehr funktionieren, setzen Sie sie mit den `tccutil`-Befehlen am Ende von [Berechtigungen](#berechtigungen) zurück und erteilen Sie sie erneut.

Ab 1.1.0 kann sich die App selbst aktualisieren (siehe [Updates](#updates)). Version 1.0.0 hat keine Update-Funktion, installieren Sie 1.1.0 daher einmalig von Hand: Laden Sie das dmg herunter und ersetzen Sie die App im Ordner „Programme“. Die Berechtigungen bleiben erhalten, weil 1.0.0 und spätere Versionen mit demselben Zertifikat signiert sind.

Jedes Release enthält außerdem den Quellcode als `.tar.gz` und `.zip` sowie eine Datei `SHA256SUMS.txt`. Um die Downloads zu überprüfen, führen Sie im Download-Ordner `shasum -a 256 --ignore-missing -c SHA256SUMS.txt` aus.

### Aus dem Quellcode bauen

1. Führen Sie im Stammverzeichnis des Repositorys `scripts/build-app.sh` aus. Das Skript baut die Release-Konfiguration und stellt dann `dist/EVE-O Preview.app` zusammen und signiert sie.
2. Ziehen Sie `dist/EVE-O Preview.app` in den Ordner „Programme“.
3. Öffnen Sie die App.

Das Skript liest diese Umgebungsvariablen:

| Variable | Zweck | Standard |
| --- | --- | --- |
| `VERSION` | Versionsnummer, die in `Info.plist` geschrieben wird | Inhalt der Datei `VERSION` |
| `SIGN_IDENTITY` | Identität für die Codesignatur | `EVEO Preview Dev`, wenn im Schlüsselbund vorhanden, sonst ad hoc (`-`) |
| `UNIVERSAL` | `1` baut arm64 und x86_64 getrennt und führt sie mit `lipo` zu einer Universal-Binary zusammen | Nicht gesetzt: nur die native Architektur |

Wenn `packaging/AppIcon.png` existiert, erzeugt das Skript daraus das App-Symbol.

`scripts/package-release.sh` führt `build-app.sh` aus und schreibt dann das dmg, die Quellarchive und `SHA256SUMS.txt` nach `dist/release/`. Die CI nutzt dieses Skript.

## Berechtigungen

Die App nutzt die folgenden Systemberechtigungen, die alle unter Systemeinstellungen > Datenschutz & Sicherheit erteilt werden. Die Seite „Berechtigungen“ im Einstellungsfenster zeigt ihren Status, mit Schaltflächen zum Anfordern und Links zu den Systemeinstellungen.

| Berechtigung | Wofür | Ohne sie |
| --- | --- | --- |
| Bildschirmaufnahme | Client-Fenster aufnehmen und Fenstertitel lesen | Miniaturen zeigen einen Platzhalter; fehlen auch die Bedienungshilfen, können keine Titel gelesen werden und Clients erscheinen als `EVE (PID)` |
| Bedienungshilfen | Client-Fenster wiederherstellen, nach vorne holen und minimieren, Fenstertitel lesen, Maus-Hotkeys abfangen | Nur der Client-Prozess kann aktiviert werden, minimierte Fenster lassen sich also nicht wiederherstellen; „Minimieren“ und „Alle minimieren“ sind deaktiviert; Maus-Hotkeys funktionieren nicht, Tastatur-Hotkeys schon |
| Ordner „Dokumente“ | Kampfwarnungen lesen `~/Documents/EVE/logs/Gamelogs` | Wird nur angefordert, wenn Kampfwarnungen eingeschaltet werden; bei Ablehnung zeigt die Seite „Warnungen“ den Grund, andere Funktionen sind nicht betroffen |

Nach dem Erteilen von „Bildschirmaufnahme“ muss die App meist neu gestartet werden, damit die Berechtigung wirkt; die Seite „Berechtigungen“ hat dafür die Schaltfläche „Neu starten“. „Bedienungshilfen“ wirkt sofort.

### Mit einem selbstsignierten Zertifikat signieren

macOS erkennt eine App beim Speichern von Berechtigungen an ihrer Codesignatur. Eine Ad-hoc-Signatur hat keine stabile Identität, daher behandelt macOS die App nach jedem Neubau als eine andere, und beide Berechtigungen gehen verloren. Wenn Sie selbst bauen, verwenden Sie ein selbstsigniertes Zertifikat:

1. Öffnen Sie die Schlüsselbundverwaltung und wählen Sie Schlüsselbundverwaltung > Zertifikatsassistent > Zertifikat erstellen.
2. Geben Sie den Namen `EVEO Preview Dev` ein, setzen Sie den Identitätstyp auf „Selbst signiertes Root-Zertifikat“ und den Zertifikatstyp auf „Codesignatur“ und erstellen Sie das Zertifikat.
3. Führen Sie `scripts/build-app.sh` aus. Das Skript verwendet dieses Zertifikat automatisch, wenn es im Schlüsselbund gefunden wird; Sie können auch `SIGN_IDENTITY="EVEO Preview Dev" scripts/build-app.sh` ausführen.
4. Wenn macOS fragt, ob `codesign` den privaten Schlüssel im Schlüsselbund verwenden darf, wählen Sie „Immer erlauben“.

Wenn die Einträge zu den Berechtigungen in einen fehlerhaften Zustand geraten, führen Sie diese beiden Befehle aus und erteilen Sie die Berechtigungen erneut:

```sh
tccutil reset ScreenCapture io.github.deletexiumu.eveopreview-macos
tccutil reset Accessibility io.github.deletexiumu.eveopreview-macos
```

## Verwendung

### Gesten auf Miniaturen

Das Drücken der linken Maustaste wechselt sofort, ohne auf das Loslassen zu warten; Bewegen und Skalieren nutzen daher Ziehen mit der rechten Maustaste oder Wahltaste (⌥)+Ziehen mit der linken Maustaste.

| Aktion | Geste |
| --- | --- |
| Zum Client wechseln | Linke Maustaste drücken |
| Client minimieren | Control+linke Maustaste drücken |
| Menü öffnen | Rechtsklick (weniger als 4 Punkte Bewegung zwischen Drücken und Loslassen) |
| Bewegen | Ziehen mit der rechten Maustaste oder Wahltaste (⌥)+Ziehen mit der linken Maustaste |
| Skalieren | Dieselbe Geste wie beim Bewegen, beginnend innerhalb von 12 Punkten vom Rand der Miniatur |
| Einrasten vorübergehend abschalten | Umschalttaste (⇧) beim Ziehen gedrückt halten; beim Skalieren behält die Umschalttaste außerdem das Seitenverhältnis bei |

Ist „Layout sperren“ aktiviert, bewirken Bewegen und Skalieren nichts; Wechseln, Minimieren und das Menü funktionieren weiterhin.

### Hotkeys

Hotkeys werden auf der Seite „Umschalten“ des Einstellungsfensters aufgenommen: Auf eine Schaltfläche klicken, dann eine Tastenkombination oder Maustaste drücken. Esc bricht ab, ⌫ löscht. Eine Aktion kann mehrere Belegungen haben.

- Wechselgruppen: Jede Gruppe hat Hotkeys vorwärts und rückwärts, die der Reihe nach zwischen den Charakteren der Gruppe wechseln, die online sind und nicht übersprungen werden; am Ende geht es wieder von vorne los.
- Charakter-Hotkeys: wechseln zum Client dieses Charakters.
- Allgemeine Hotkeys: alle Miniaturen ein- oder ausblenden, alle minimieren und die Clients am Anmeldebildschirm durchschalten.

Tastatur-Hotkeys sollten Control (⌃), Wahltaste (⌥) oder Befehlstaste (⌘) enthalten; F1–F20 und die Ziffern des Ziffernblocks können allein verwendet werden. Systemkombinationen wie Cmd+Tab, Cmd+Space und Cmd+Q werden abgelehnt. Hat ein Hotkey ein Problem, zeigt das Einstellungsfenster den Grund daneben an.

Maus-Hotkeys:

- Die mittlere und die seitlichen Maustasten können aufgenommen werden (in der Konfiguration als `Mouse3`–`Mouse32` geschrieben), optional mit Sondertasten, etwa `ctrl+Mouse4`. Die linke und die rechte Maustaste können nicht belegt werden.
- Wenn ein Hotkey auslöst, wird dieser Klick (Drücken, Ziehen und Loslassen) nicht an die App im Vordergrund weitergegeben, eine auf dieselbe Taste gelegte Spielaktion wird also nicht ausgeführt.
- Maus-Hotkeys benötigen die Berechtigung „Bedienungshilfen“.

Bereich:

- Jeder Hotkey kann „Überall“ oder „Nur in EVE“ gelten, in der Konfiguration als Suffix `@global` bzw. `@game` geschrieben. Ein Hotkey ohne Suffix folgt dem Standardbereich des Profils.
- Ein Hotkey mit „Nur in EVE“ funktioniert nur, solange ein EVE-Client im Vordergrund ist. In anderen Apps wird der Tastendruck wie gewohnt an die jeweilige App weitergegeben.
- Neu aufgenommene Maus-Hotkeys gelten standardmäßig „Nur in EVE“, damit Seitentasten nicht in jeder App abgefangen werden.
- „Hotkeys nur in EVE“ im Menü der Menüleiste schaltet den Standardbereich um.

### Kampfwarnungen

Sie werden auf der Seite „Warnungen“ des Einstellungsfensters eingeschaltet. Die App liest dann die Spielprotokolle, die Clients nach `~/Documents/EVE/logs/Gamelogs` schreiben, ordnet jedes Protokoll anhand des Listeners im Protokollkopf einem Charakter zu und lässt Rahmen und Bild der Miniatur eines Charakters 3 Sekunden lang blinken, wenn dieser Charakter angegriffen wird.

- Im EVE-Client muss die Protokollierung von Spielnachrichten aktiviert sein (standardmäßig ist sie das).
- Auch Fehlschüsse lösen standardmäßig eine Warnung aus; das lässt sich abschalten. Mindestschaden, Blinkfarbe und Dauer sind einstellbar.
- Ist „Miniaturen ausblenden, wenn EVE nicht aktiv ist“ aktiviert, wird die Miniatur eines angegriffenen Charakters vorübergehend eingeblendet.
- Ist in den Systemeinstellungen „Bewegung reduzieren“ aktiviert, wird das Blinken durch eine gleichbleibende Hervorhebung ersetzt.
- Die App liest die Protokolle nur. Sie schreibt oder verändert sie nie und sendet keine Eingaben an das Spiel.
- Beim ersten Mal fragt macOS nach dem Zugriff auf den Ordner „Dokumente“. Liegen Ihre Protokolle woanders, wählen Sie den Ordner auf der Seite „Warnungen“.
- Das Protokollformat des chinesischen Clients wurde anhand echter Protokolle geprüft. Japanische und russische Schadenszeilen wurden anhand echter Client-Protokolle (aufgezeichnete Beispiele des Ursprungsprojekts) geprüft; ihre Fehlschusszeilen sind nur aus Vorlagen abgeleitet. Englisch, Deutsch, Französisch, Spanisch und Koreanisch sind aus den Vorlagen des Ursprungsprojekts abgeleitet und wurden nicht anhand echter Protokolle geprüft.

### Menüleiste

Das Symbol in der Menüleiste entspricht dem App-Symbol: ein Molekül in einem Achteck. Das Menü bietet: „Alle Miniaturen einblenden“ bzw. „Alle Miniaturen ausblenden“, Profil wechseln, „Alle Clients minimieren“, „Hotkeys nur in EVE“, „Nach Updates suchen …“, „Problem melden …“, „Einstellungen …“ und „EVE-O Preview beenden“. Wenn ein Update verfügbar ist oder der letzte Lauf unerwartet beendet wurde, erscheint ein Punkt auf dem Symbol, und oben im Menü erscheint ein Eintrag dazu. Fehlt eine Berechtigung, hat das Menü einen zusätzlichen Eintrag dazu. Wird die Aufnahme eines Clients über die Aufnahmeanzeige des Systems gestoppt, erhält das Menü einen Eintrag „Aufnahme fortsetzen“.

EVE-O Preview zeigt sein Symbol auch im Dock; ein Klick darauf öffnet das Einstellungsfenster. Um nur das Symbol in der Menüleiste zu behalten, deaktivieren Sie „Symbol im Dock anzeigen“ unter Einstellungen > Allgemein.

### Updates

EVE-O Preview sucht beim Start und einmal täglich auf GitHub nach einem neuen Release. Zum Abschalten deaktivieren Sie „Automatisch nach Updates suchen“ unter Einstellungen > Allgemein > Updates; „Nach Updates suchen …“ im Menü der Menüleiste sucht weiterhin auf Anfrage.

Ist eine neue Version verfügbar, zeigt ein Fenster die Release-Notes in Ihrer Oberflächensprache (Englisch, wenn es keine Übersetzung gibt) und bietet „Update installieren“, „Diese Version überspringen“ und „Später“ an. Solange ein EVE-Client im Vordergrund ist, wartet das Fenster, bis Sie zu einer anderen App wechseln, und es übernimmt nie von sich aus den Tastaturfokus; ein Punkt auf dem Menüleistensymbol zeigt an, dass ein Update wartet. „Diese Version überspringen“ beendet nur die automatischen Erinnerungen für diese Version; „Nach Updates suchen …“ zeigt sie weiterhin an.

„Update installieren“ lädt das dmg herunter, prüft es anhand von `SHA256SUMS.txt`, überprüft, dass die neue App mit demselben Zertifikat signiert ist wie die laufende, ersetzt die App und startet sie neu. Schlägt ein Schritt fehl, bleibt die installierte App unverändert. „Updates automatisch installieren“ ist standardmäßig aktiviert: Das Update wird im Hintergrund geladen, dann installiert, und die App startet neu, sobald seit etwa einer Minute kein EVE-Client mehr läuft und kein Fenster von EVE-O Preview offen ist. Andernfalls wird es beim Beenden von EVE-O Preview installiert oder wenn Sie im Menü der Menüleiste „Neu starten und auf X.Y.Z aktualisieren“ wählen. Solange ein EVE-Client läuft, startet die App nie von selbst neu. Deaktivieren Sie die Einstellung unter Einstellungen > Allgemein > Updates, wenn das Fenster Sie vorher fragen soll.

Manche Builds können statt der Installation nur den Grund und die Schaltfläche „Release-Seite öffnen“ anzeigen: Ad-hoc- oder lokal signierte Builds, eine App, die aus einem Festplattenimage oder von einem verschobenen Ort (App Translocation) ausgeführt wird, eine App in einem Ordner ohne Schreibrechte und eine App auf einem Volume, das nicht APFS ist, etwa ein externes HFS+-, exFAT- oder FAT-Laufwerk.

### Problem melden

Wählen Sie „Problem melden …“ im Menü der Menüleiste oder auf der Seite „Allgemein“, oder antworten Sie auf die Nachfrage, die erscheint, nachdem EVE-O Preview unerwartet beendet wurde. Das Fenster listet jede Datei auf, die in den Bericht kommt, und zeigt ihren Inhalt nach der Anonymisierung: eine Umgebungsübersicht, eine Einstellungsübersicht ohne Namen, das App-Protokoll (bis zu 2 MiB) und bis zu drei macOS-Absturzberichte. Es wird nichts erstellt, bevor Sie auf „Nur Bericht erstellen“ oder „Bericht erstellen und GitHub öffnen“ klicken. Die ZIP-Datei wird in `~/Library/Application Support/EVE-O Preview/Reports/` gesichert (die 3 neuesten bleiben erhalten), und der Finder zeigt sie an; „Bericht erstellen und GitHub öffnen“ öffnet außerdem ein vorausgefülltes Issue in Ihrem Browser. Die ZIP-Datei hängen Sie selbst an; die App lädt nie etwas hoch.

Ihr macOS-Benutzername, Ihr vollständiger Name, der Pfad Ihres Benutzerordners und die Computernamen werden durch `[user]` und `[host]` ersetzt. EVE-Charakternamen werden zu `[character-1]`, `[character-2]` usw., und Gerätekennungen in Absturzberichten werden zu `[redacted]`. Ersetzt werden nur Namen, die die App kennt: Charaktere, die nie in Ihren Einstellungen oder als laufender Client aufgetaucht sind, werden nicht ersetzt. Ist ein Name ein gängiges Wort, wird dasselbe Wort auch an anderen Stellen im Protokoll ersetzt. Sie können jede Datei vor dem Erstellen des Berichts lesen und jede Datei abwählen, die nicht enthalten sein soll.

Die App behält bis zu 5 Protokolldateien zu je 1 MiB in `~/Library/Logs/EVE-O Preview/`. Charakternamen und Fenstertitel werden als `<private>` geschrieben. Schalten Sie unter „Allgemein“ „Ausführliche Protokollierung“ ein, um zusätzlich Debug-Zeilen aufzuzeichnen; „Protokolle im Finder zeigen“ öffnet den Ordner. Erscheint nach einem Absturz keine Nachfrage, hängen Sie `~/Library/Logs/DiagnosticReports/EVEOPreview-<date>.ips` von Hand an das Issue an.

## Datenschutz

Version 1.0.0 stellte keine Netzwerkanfragen. Ab 1.1.0 verbindet sich die App nur mit GitHub, und nur für Updates:

- Die Suche nach Updates fragt `api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest` beim Start und einmal täglich ab, solange „Automatisch nach Updates suchen“ aktiviert ist, sowie jedes Mal, wenn Sie „Nach Updates suchen …“ wählen.
- Die Installation eines Updates lädt `SHA256SUMS.txt` und das dmg aus dem Release herunter.

Die Anfragen enthalten nur die App-Version im Header `User-Agent`, ein festes `Accept-Language: en` und ein Cache-Tag; es werden keine Charakternamen, Einstellungen, Protokolle, Hardwaredetails, Systemversion oder Kennungen gesendet, und es werden keine Cookies verwendet. GitHub sieht Ihre IP-Adresse und den Zeitpunkt der Anfrage. Es gibt keine Telemetrie und keinen automatischen Upload von Abstürzen: „Problem melden …“ erstellt nur eine ZIP-Datei auf Ihrem Mac und öffnet eine Webseite, auf der Sie selbst entscheiden, ob Sie absenden.

Die App speichert Daten an diesen Orten. Für eine vollständige Deinstallation löschen Sie sie zusammen mit der App und `~/Library/Application Support/EVE-O Preview/config.json`:

| Ort | Inhalt |
| --- | --- |
| `~/Library/Logs/EVE-O Preview/` | App-Protokolle, höchstens etwa 5 MiB |
| `~/Library/Application Support/EVE-O Preview/session.json`, `state.json` | Sitzungsmarkierung; Einträge zu Updates und Diagnose |
| `~/Library/Application Support/EVE-O Preview/Reports/` | Von Ihnen erstellte, anonymisierte Problembericht-ZIP-Dateien (die 3 neuesten) |
| `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` | Geladene Update-Dateien, werden nach der Installation gelöscht |

## Konfigurationsdatei

Die Konfiguration wird in `~/Library/Application Support/EVE-O Preview/config.json` gesichert. Eine Datei enthält alle Profile.

- Änderungen werden 0,5 Sekunden nach dem Vornehmen automatisch gesichert und beim Beenden noch einmal.
- Ist die Datei beschädigt, wird sie in `config.corrupt-<date-time>.json` umbenannt, und die App verwendet die Standardkonfiguration.
- Stammt die Datei von einer neueren Version, läuft die App mit der Standardkonfiguration, schreibt während dieser Sitzung nichts auf die Festplatte und überschreibt die Datei nicht.

Die Seite „Profile“ hat eine Schaltfläche „Im Finder zeigen“.

## Entwicklung

| Befehl | Zweck |
| --- | --- |
| `swift build` | Alle Targets bauen |
| `swift test` | Die Core-Unit-Tests ausführen (swift-testing) |
| `EVEO_FAKE=1 swift run EVEOPreview` | Demomodus: 3 simulierte Clients mit generierten animierten Bildern, ohne EVE und ohne Berechtigungen |
| `python3 scripts/check_quality.py` | Kommentaranteil, Dateilänge und Funktionslänge prüfen |
| `scripts/build-app.sh` | Die `.app` zusammenstellen und signieren |
| `scripts/package-release.sh` | dmg, Quellarchive und Prüfsummen in `dist/release/` bauen |
| `swift run EVEOProbe gamelog [dir] [--follow seconds]` | Jede Art von Kampfzeilen in den Spielprotokollen zählen, zur Diagnose der Kampfwarnungen |
| `swift run EVEOProbe mousetap <seconds> [--swallow <button>]` | Maustastennummern ausgeben, zur Diagnose von Maus-Hotkeys |
| `swift run EVEOProbe update feed [url]` | Den Release-Feed abrufen und auswerten |
| `swift run EVEOProbe update verify <new app> <base app>` | Prüfen, ob eine neue App die Designated Requirement der Basis-App erfüllt |
| `swift run EVEOProbe update prepare <url> [--cache dir]` | Ein Update laden und überprüfen, ohne es zu installieren |
| `scripts/make-update-test-feed.sh [version]` | Eine `feed.json` für einen lokalen Update-Test aus `dist/release/` schreiben |

Der Demomodus schreibt seine Konfiguration in `config-fake.json` im selben Ordner und lässt die echte Konfiguration unberührt. Diese Umgebungsvariablen helfen beim Debuggen:

| Variable | Zweck |
| --- | --- |
| `EVEO_CONFIG_PATH` | Die angegebene Konfigurationsdatei verwenden |
| `EVEO_LANG` | `en`, `zh`, `ru`, `ja`, `ko`, `fr`, `de` oder `es`; überschreibt die Oberflächensprache aus der Konfiguration |
| `EVEO_FAKE_DENY` | Im Demomodus eine fehlende Berechtigung vortäuschen: `screen`, `ax` oder `screen,ax` |
| `EVEO_FAKE_STOP_AFTER` | Im Demomodus vortäuschen, dass die Aufnahme des zweiten Clients nach so vielen Sekunden gestoppt wurde |
| `EVEO_SETTINGS_PAGE` | Beim Start direkt eine Einstellungsseite öffnen, etwa `previews` |
| `EVEO_LOG_DIR` | Die Protokolldateien in einen anderen Ordner schreiben (Standard `~/Library/Logs/EVE-O Preview/`) |
| `EVEO_STATE_DIR` | `state.json` und `session.json` in einem anderen Ordner ablegen |
| `EVEO_LOG_PRIVATE` | `1` zeigt private Werte nur im Systemprotokoll (Konsole); Protokolldateien enthalten immer `<private>` |
| `EVEO_UPDATE_FEED_URL` | Diese Adresse statt GitHub nach Updates abfragen; nur `https` oder `http` auf einem Loopback-Host. Mit einem lokalen Zertifikat signierte Builds dürfen von dort installieren; die Signaturprüfung wird nicht gelockert |
| `EVEO_UPDATE_UI_STATE` | Im Demomodus die Update-Oberfläche in einem Beispielzustand zeigen: `available`, `notifyonly`, `downloading`, `ready`, `failed` oder `uptodate` |
| `EVEO_FAKE_CRASH` | `1` täuscht im Demomodus vor, dass der vorige Lauf abgestürzt ist, um die Nachfrage zum Absturzbericht zu zeigen |

Der Quellcode hat 3 Module: `EVEOPreviewCore` ist die reine Logikschicht, `EVEOPreviewPlatform` kapselt AppKit, ScreenCaptureKit, Bedienungshilfen und Carbon-Hotkeys, und `EVEOPreview` ist die App selbst. Die Architektur ist in [docs/architecture.md](docs/architecture.md) beschrieben (auf Chinesisch).

**Hinweis:** Wenn Sie die ausführbare Datei direkt mit `swift run` starten, speichert macOS die Berechtigungen unter Ihrer Terminal-App, nicht unter `EVE-O Preview.app`.

### CI und Releases

`.github/workflows/build.yml` läuft auf von GitHub gehosteten macOS-Runnern:

- Jeder Pull Request auf `main` und jeder Push auf `main` führt die Qualitätsprüfung und die Unit-Tests aus und baut dann ein Universal-dmg und die Quellarchive. Sie werden als Workflow-Artefakt namens `EVE-O-Preview-<version>-pr.<number>.<commit>` (bzw. `-dev.<commit>` bei Pushes) hochgeladen und 30 Tage aufbewahrt.
- Das Pushen eines `v*`-Tags baut dieselben Dateien und veröffentlicht sie als GitHub-Release. Das Tag muss zur Datei `VERSION` passen. Existiert `docs/release-notes/<tag>.md`, wird diese Datei zu den Release-Notes.

Um eine neue Version zu veröffentlichen, ändern Sie die Datei `VERSION` und fügen in einem Pull Request `docs/release-notes/v<version>.md` hinzu, mergen ihn und taggen dann `main`: `git tag v<version> && git push origin v<version>`.

Die Asset-Namen (`EVE-O-Preview-<version>.dmg`, `SHA256SUMS.txt`), der Aufbau des dmg, das Signaturzertifikat und das Format der Release-Notes sind ein Vertrag mit dem Updater in der App; die CI prüft sie bei jedem Build. Release-Notes enthalten zuerst Englisch zwischen `<!-- lang:en -->` und `<!-- /lang:en -->`, gefolgt von ausklappbaren Blöcken für zh, ja, ko und ru, die auf dieselbe Weise markiert sind; `scripts/check_release_notes.py` prüft die Markierungen. Einzelheiten stehen in den Abschnitten 9.5 bis 9.7 von [docs/architecture.md](docs/architecture.md).

## Haftungsausschluss

Dieses Tool wechselt nur den Fensterfokus. Es sendet keine Eingaben an mehrere Clients gleichzeitig und liest oder verändert nicht den Spielspeicher – dieselbe Grenze wie beim Ursprungsprojekt. Lesen Sie vor der Verwendung die Endbenutzer-Lizenzvereinbarung von EVE Online.

Die App verbindet sich nur mit GitHub, um nach Updates zu suchen und sie zu laden, und sendet keine persönlichen Daten (siehe [Datenschutz](#datenschutz)).

EVE Online und zugehörige Logos sind Marken von CCP ehf. Dieses Projekt steht in keiner Verbindung zu CCP und wird nicht von CCP unterstützt.

Das App-Symbol verwendet das Molekül-Symbol des Ursprungsprojekts EveOPlus/eve-o-preview (GPL-3.0) wieder. Der Hintergrund wird von `scripts/make-app-icon.py` gezeichnet und enthält keine Marken oder Spielgrafiken von CCP.
