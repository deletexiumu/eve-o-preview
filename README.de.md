<p align="center"><img src="macos/packaging/AppIcon.png" width="128" alt="Symbol von EVE-O Preview for macOS"></p>

# EVE-O Preview for macOS & Windows

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Русский](README.ru.md) | [Français](README.fr.md) | **Deutsch** | [Español](README.es.md)

Diese Übersetzung wurde maschinell erstellt; bei Abweichungen vom [englischen README](README.md) gilt die englische Fassung.

EVE-O Preview zeigt eine Live-Miniatur jedes laufenden EVE Online-Clients. Ein Klick auf eine Miniatur oder ein globaler Hotkey wechselt zu diesem Client.

Dieses Repository enthält zwei native Apps: eine für macOS, geschrieben in Swift, und eine für Windows, geschrieben in Rust. Sie teilen das Konfigurationsformat, die Oberflächentexte und die Testfälle in `shared/` und nutzen jeweils die APIs ihrer Plattform.

Beide implementieren die Funktionen von [EveOPlus/eve-o-preview](https://github.com/EveOPlus/eve-o-preview) (Windows, GPL-3.0) neu. Der C#-Code des Ursprungsprojekts wird nicht portiert, und Oberfläche sowie Konfigurationsformat unterscheiden sich vom Ursprungsprojekt.
Es steht unter der GNU General Public License Version 3 oder einer späteren Version (GPL-3.0-or-later), entsprechend den SPDX-Kennungen in den Quelldateien; das Ursprungsprojekt steht unter GPL-3.0. Den vollständigen Text enthält [LICENSE](LICENSE).

Dieses Repository begann als GitHub-Fork von EveOPlus/eve-o-preview und wurde für v1.0 in ein eigenständiges Repository verschoben. Es ist ein unabhängiges Projekt: Es teilt keinen Code mit EveOPlus/eve-o-preview und wird nicht von den Autoren des Ursprungsprojekts gepflegt.

## Windows

EVE-O Preview for Windows 1.0 ist am 2026-11-24 erschienen. Es bietet dieselben Funktionen wie die macOS-App: DWM-Live-Miniaturen, Wechseln und Tastenkürzel (auch Maustasten), Anordnung, Sichtbarkeitsregeln, Kampfwarnungen, Aufklärungs- und Chat-Übersetzungs-Overlay, Profile, signierte Updates und Problemberichte. Unterschiede zur macOS-App:

- **Bildrate im Spiel** (ab 1.1, standardmäßig aus): Die Gruppe „Bildrate im Spiel“ auf der Seite „Allgemein“ begrenzt alle EVE-Clients über den Grafiktreiber auf dieselbe Bildrate (standardmäßig 60), sodass das Wechseln zwischen Clients beim Multiboxing flüssiger wird. Die Spiel-Clients werden nicht angefasst. Bei NVIDIA wird „Max. Bildrate“ für exefile.exe gesetzt, bei Intel eine Bildratenbegrenzung für exefile.exe; der AMD-Treiber kann nur alle Spiele auf dem PC gemeinsam begrenzen. Beim Ausschalten wird die vorherige Treibereinstellung wiederhergestellt. Die Unterstützung für AMD und Intel wurde noch nicht auf echter Hardware getestet.
- **Beim Anmelden bei Windows starten** auf der Seite „Allgemein“.
- Ein Symbol im Infobereich statt in der Menüleiste: Linksklick öffnet die Einstellungen, Rechtsklick das Menü.
- API-Schlüssel werden in der Windows-Anmeldeinformationsverwaltung statt im macOS-Schlüsselbund gespeichert.

### Installation unter Windows

Erfordert 64‑Bit‑Windows 10 22H2 oder Windows 11.

1. Laden Sie `EVE-O-Preview-<Version>-windows-x64.zip` von der Seite [Releases](https://github.com/deletexiumu/eve-o-preview/releases) herunter. Ab 1.4.0 erscheinen die macOS- und die Windows-Version gemeinsam in einem Release mit dem Tag `v<Version>`; frühere Windows-Versionen tragen das Tag `win-v<Version>`.
2. Entpacken Sie den Ordner an einen Ort mit Schreibrechten, etwa „Dokumente“ oder `D:\Games`. Nicht unter „Program Files“: Updates ersetzen die exe an Ort und Stelle.
3. Starten Sie `EVE-O Preview.exe`. Die exe ist noch nicht codesigniert, daher kann Windows SmartScreen beim ersten Start warnen: Wählen Sie „Weitere Informationen“ und dann „Trotzdem ausführen“.

Die Einstellungen liegen in `%APPDATA%\EVE-O Preview\config.json`, die Protokolle in `%LOCALAPPDATA%\EVE-O Preview\logs\`. Einstellungen des ursprünglichen EVE-O Preview werden nicht übernommen. Zum Deinstallieren beenden Sie die App über das Menü im Infobereich, schalten „Beim Anmelden bei Windows starten“ aus, falls aktiviert, und löschen dann den App-Ordner und die beiden Ordner oben. Das Bauen aus dem Quellcode beschreibt [windows/README.md](windows/README.md).

Der Rest dieses Dokuments beschreibt die macOS-App.

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
- Aufklärungs-Overlay (standardmäßig aus): liest die Chatprotokolle der von Ihnen gewählten Aufklärungskanäle und zeigt für den Charakter im vorderen EVE-Fenster, in welchen Systemen Feinde gemeldet werden, wie viele Sprünge entfernt sie sind, wie viele es sind und welche Schiffe sie fliegen (siehe [Aufklärungs-Overlay](#aufklärungs-overlay)).
- Chat-Übersetzungs-Overlay (standardmäßig aus): übersetzt Nachrichten in anderen Sprachen aus den gewählten Kanälen in Ihre Sprache, mit einem Modelldienst Ihrer Wahl und Ihrem eigenen API-Schlüssel (siehe [Chat-Übersetzung](#chat-übersetzung)).
- Profile: erstellen, duplizieren, umbenennen, löschen und wechseln.
- Updates: sucht auf GitHub nach neuen Releases und installiert sie direkt in der App, nachdem der Download und seine Codesignatur überprüft wurden (siehe [Updates](#updates)).
- Problemberichte: erstellt eine anonymisierte Diagnose-ZIP-Datei und öffnet ein vorausgefülltes GitHub-Issue; nach einem unerwarteten Beenden bietet der nächste Start an, es zu melden (siehe [Problem melden](#problem-melden)).
- Ein Symbol in der Menüleiste anstelle des Windows-Tray-Symbols.
- Ein Einstellungsfenster mit 10 Seiten: „Clients“, „Miniaturen“, „Umschalten“, „Warnungen“, „Aufklärung“, „Übersetzung“, „Profile“, „Allgemein“, „Berechtigungen“ und „Info“.
- Sprachen der Oberfläche: Englisch (Standard), Chinesisch, Russisch, Japanisch, Koreanisch, Französisch, Deutsch und Spanisch. Die Sprache wird auf der Seite „Allgemein“ umgeschaltet, alternativ lässt sich „Systemsprache“ wählen; die Änderung gilt sofort. Die russische, japanische, koreanische, französische, deutsche und spanische Übersetzung sind maschinell erstellt; Korrekturen sind willkommen.

## Voraussetzungen

- macOS 14 oder neuer, auf Apple Silicon oder Intel. Das Release-dmg enthält eine Universal-Binary.
- EVE-Clients funktionieren am besten im Fenstermodus. Clients im nativen Vollbildmodus werden ab 1.1.1 unterstützt (Miniaturen erscheinen über ihnen, solange „Miniaturen im Vordergrund halten“ aktiviert ist), aber jeder liegt in einem eigenen Space, sodass beim Wechseln zu einem solchen Client die Space-Übergangsanimation abläuft.

## Installation

### Release herunterladen

1. Laden Sie `EVE-O-Preview-<version>.dmg` von der Seite [Releases](https://github.com/deletexiumu/eve-o-preview/releases) herunter.
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

Die App hält sich selbst aktuell: Sie sucht auf GitHub nach neuen Versionen und installiert sie aus der App heraus (siehe [Updates](#updates)).

Jedes Release enthält außerdem den Quellcode als `.tar.gz` und `.zip` sowie eine Datei `SHA256SUMS.txt`. Um die Downloads zu überprüfen, führen Sie im Download-Ordner `shasum -a 256 --ignore-missing -c SHA256SUMS.txt` aus.

### Aus dem Quellcode bauen

Wie Sie die App selbst bauen, steht in [docs/macos/development.md](docs/macos/development.md) (auf Englisch). Dort sind auch die Debugging-Werkzeuge, die CI und der Release-Ablauf beschrieben.

## Berechtigungen

Die App nutzt die folgenden Systemberechtigungen, die alle unter Systemeinstellungen > Datenschutz & Sicherheit erteilt werden. Die Seite „Berechtigungen“ im Einstellungsfenster zeigt ihren Status, mit Schaltflächen zum Anfordern und Links zu den Systemeinstellungen.

| Berechtigung | Wofür | Ohne sie |
| --- | --- | --- |
| Bildschirmaufnahme | Client-Fenster aufnehmen und Fenstertitel lesen | Miniaturen zeigen einen Platzhalter; fehlen auch die Bedienungshilfen, können keine Titel gelesen werden und Clients erscheinen als `EVE (PID)` |
| Bedienungshilfen | Client-Fenster wiederherstellen, nach vorne holen und minimieren, Fenstertitel lesen, Maus-Hotkeys abfangen | Nur der Client-Prozess kann aktiviert werden, minimierte Fenster lassen sich also nicht wiederherstellen; „Minimieren“ und „Alle minimieren“ sind deaktiviert; Maus-Hotkeys funktionieren nicht, Tastatur-Hotkeys schon |
| Ordner „Dokumente“ | Kampfwarnungen lesen `~/Documents/EVE/logs/Gamelogs`; Aufklärungs- und Übersetzungs-Overlay lesen `~/Documents/EVE/logs/Chatlogs`, das Aufklärungs-Overlay liest außerdem die Spielprotokolle, um Ihren Standort zu bestimmen | Wird nur angefordert, wenn eine dieser Funktionen eingeschaltet wird oder Sie im Menü „Aus Protokollen hinzufügen“ auf „Aktualisieren“ klicken; bei Ablehnung zeigt die Seite der Funktion den Grund, andere Funktionen sind nicht betroffen |
| Lokales Netzwerk (ab macOS 15) | Verbindung zu einem Übersetzungsdienst auf einem anderen Computer im lokalen Netzwerk, etwa Ollama | Wird nur angefordert, wenn der Übersetzungsdienst auf einem anderen Computer im lokalen Netzwerk läuft, nicht für diesen Mac oder öffentliche Dienste; klicken Sie auf der Seite „Übersetzung“ auf „Testen“, um die Abfrage vorab auszulösen. Bei Ablehnung schlagen Anfragen an diesen Computer mit einem Netzwerkfehler fehl. Erscheint nicht auf der Seite „Berechtigungen“ |

Nach dem Erteilen von „Bildschirmaufnahme“ muss die App meist neu gestartet werden, damit die Berechtigung wirkt; die Seite „Berechtigungen“ hat dafür die Schaltfläche „Neu starten“. „Bedienungshilfen“ wirkt sofort.

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

### Aufklärungs-Overlay

Schalten Sie es mit „Aufklärungs-Overlay anzeigen“ auf der Seite „Aufklärung“ des Einstellungsfensters ein oder mit „Aufklärungs-Overlay anzeigen“ im Menü der Menüleiste. Die App liest dann die Chatprotokolle, die Clients nach `~/Documents/EVE/logs/Chatlogs` schreiben, neben dem auf der Seite „Warnungen“ gewählten Ordner der Spielprotokolle. Jede Zeile des Overlays ist eine Nachricht aus Ihren Aufklärungskanälen: ihr Alter, jedes System mit Sicherheitsstatus und Entfernung in Sprüngen von Ihrem Standort, die Zahl der Feinde, die Schiffe und die Pilotennamen.

- Der EVE-Client muss so eingestellt sein, dass er den Chat in eine Datei protokolliert.
- Ist die Clientsprache nicht Englisch, schreibt der EVE-Client für Mac womöglich keine Protokolle für Local, Corp und Alliance (mit Chinesisch beobachtet); diese Kanäle bleiben dann in beiden Overlays leer. Stellen Sie die Sprache von EVE auf English und loggen Sie den Charakter neu ein; die Statuszeile des Übersetzungs-Overlays weist in diesem Fall darauf hin.
- Kanäle: Wählen Sie „Aus Protokollen hinzufügen“, um aus den Kanälen Ihrer letzten Chatprotokolle zu wählen (jeweils mit der Zahl Ihrer Charaktere darin), oder geben Sie einen Kanalnamen ein und drücken Sie den Zeilenschalter. Der Protokollordner wird nur gelesen, wenn die Funktion eingeschaltet ist oder Sie im Menü „Aus Protokollen hinzufügen“ auf „Aktualisieren“ klicken; solange die Funktion aus ist, zeigt das Menü zunächst nur „Aktualisieren“ (auf der Seite „Übersetzung“ auch die eingebauten Kanäle). Höchstens 16 Kanäle. Private Unterhaltungen werden nie gelesen und nie aufgelistet.
- Beim Einschalten füllt sich das Overlay mit den Nachrichten der letzten 30 Minuten („Behalten für“, 5–120 Minuten); ältere Zeilen verschwinden.
- Standort: Sprünge werden ab dem System gezählt, in dem sich der aktive Charakter befindet. Die App entnimmt es den Sprung- und Abdockzeilen der Spielprotokolle und den Systemwechselmeldungen im Chatprotokoll von Local. Fehlt beides, geben Sie unter „Mein Standort“ einen Systemnamen für diesen Charakter ein und drücken den Zeilenschalter; bei einem unbekannten Namen erscheint „System nicht gefunden“. Der nächste Sprung ersetzt einen manuellen Standort, und ein manueller Standort bleibt über einen Neustart erhalten. Ein Charakter ganz ohne Standort zählt die Sprünge ab dem „Bezugssystem“.
- „Zählen bis“ begrenzt die Sprungzahl (1–30, Standard 15). „Hervorheben bis“ hebt eine Nachricht hervor, wenn ein gemeldetes System höchstens so viele Sprünge entfernt ist (Standard 5; 0 schaltet es aus). „Originaltext anzeigen“ fügt Absender und Nachricht als zweite Zeile hinzu.
- System- und Schiffsnamen erscheinen in der Sprache der Oberfläche.
- Pilotennamen sind das, was von einer Nachricht übrig bleibt, nachdem Systeme, Schiffe und Zahlen erkannt wurden; aufeinanderfolgende Namen mit Leerzeichen sind daher mehrdeutig. Ist „Online-Namensprüfung (ESI)“ eingeschaltet (Standard), fragt die App bei CCPs ESI nach, welche dieser Wörter echte Charakternamen sind, und teilt sie entsprechend auf (siehe [Datenschutz](#datenschutz)). Ein Treffer bedeutet nur, dass ein Charakter mit diesem Namen existiert, nicht, dass er gemeint ist. Ein gefundener Name erhält im Kontextmenü unter „Im Browser öffnen“ einen Link zu zKillboard. „Namenscache leeren“ löscht die gespeicherten Namen.

### Chat-Übersetzung

Schalten Sie sie mit „Übersetzungs-Overlay anzeigen“ auf der Seite „Übersetzung“ ein oder mit „Übersetzungs-Overlay anzeigen“ im Menü der Menüleiste. Sie übersetzt Nachrichten in den gewählten Kanälen, die noch nicht in der Zielsprache sind.

1. Wählen Sie die Kanäle wie beim Aufklärungs-Overlay; „Aus Protokollen hinzufügen“ listet zusätzlich die eingebauten Kanäle „Lokal“, „Corporation“, „Allianz“ und „Flotte“.
2. Wählen Sie unter „Übersetzen in“ eine Sprache oder „Wie die Sprache der Oberfläche“ (Standard).
3. Wählen Sie einen „Dienst“: DeepSeek (Standard), Claude (Anthropic), OpenAI, Qwen (DashScope), Kimi (Moonshot), Ollama oder „Andere (OpenAI-kompatibel)“. „API-Adresse“ und „Modellname“ zeigen die Werte der Voreinstellung; tragen Sie eigene Werte ein, um sie zu ersetzen.
4. Fügen Sie Ihren API-Schlüssel ein und klicken Sie auf „Speichern“. Der Schlüssel wird im macOS-Schlüsselbund gespeichert; „Schlüssel löschen“ entfernt ihn. Ollama braucht keinen Schlüssel.
5. Klicken Sie auf „Testen“, um einen festen Beispielsatz zu übersetzen.

- An das Modell gehen nur Nachrichten, die der Charakter des aktiven Clients empfangen hat. Derselbe Satz wird nur einmal übersetzt und danach aus dem Cache genommen. Nachrichten, die nur Systeme und Schiffe enthalten, werden nicht gesendet. Ist die Zielsprache Chinesisch, Japanisch, Koreanisch oder Russisch, werden auch Nachrichten nicht gesendet, die schon in dieser Sprache sind. Ist sie Englisch, Deutsch, Französisch oder Spanisch, geht jede solche Nachricht an das Modell, das selbst entscheidet, ob sie schon in der Zielsprache ist. System-, Regions- und Schiffsnamen erscheinen mit ihren offiziellen Namen in der Zielsprache.
- Jede Zeile zeigt die EVE-Zeit, den Kanal (nur wenn Sie mehr als einen übersetzen), den Absender und die Übersetzung. „Auch den Originaltext anzeigen“ fügt das Original darunter hinzu; „Nur übersetzte Nachrichten anzeigen“ blendet Nachrichten aus, die übersprungen wurden, weil sie schon in der Zielsprache sind, auch solche, die das Modell als in der Zielsprache verfasst eingestuft hat.
- Lehnt der Dienst den Schlüssel ab oder ist das Kontingent aufgebraucht, pausiert die Übersetzung, und die Statuszeile nennt den Grund; „Jetzt erneut versuchen“ versucht es noch einmal.
- Öffentliche Adressen müssen `https` verwenden; `http` ist nur für diesen Mac oder das lokale Netzwerk erlaubt, etwa für Ollama unter `http://127.0.0.1:11434/v1`.
- Die Anfragen laufen über Ihr Konto beim gewählten Dienst und können Kosten verursachen.
- Nach einem Neubau mit einer anderen Signatur kann macOS beim Klick auf „Testen“ oder „Jetzt erneut versuchen“ um Erlaubnis bitten, den Schlüsselbundeintrag zu lesen. Lesezugriffe im Hintergrund sollen diese Abfrage laut Entwurf nicht zeigen; stattdessen bittet die Statuszeile, den Schlüssel erneut zu speichern. Nach einem echten Neubau ist das noch von Hand zu prüfen.

### Gesten auf Overlays

Aufklärungs- und Übersetzungs-Overlay sind eigene Fenster, die sich wie Miniaturen verhalten: Sie übernehmen nie den Fokus, erscheinen in allen Spaces und zeigen nur den Charakter des vorderen EVE-Fensters; beim Wechsel des Clients wechselt der Inhalt sofort. Klicks gehen nicht an das Spiel durch. Die neueste Nachricht steht unten, und die Liste bleibt dort. Scrollen Sie nach oben, folgt die Liste neuen Nachrichten nicht mehr, und unten erscheint ein Balken „N neu“; ein Klick darauf führt zurück zum Neuesten.

| Aktion | Geste |
| --- | --- |
| Liste scrollen | Scrollrad oder Streichen mit zwei Fingern |
| Bewegen | Ziehen mit der rechten Maustaste oder Wahltaste (⌥)+Ziehen mit der linken Maustaste |
| Skalieren | Dieselbe Geste wie beim Bewegen, beginnend innerhalb von 12 Punkten vom Rand des Overlays |
| Einrasten vorübergehend abschalten | Umschalttaste (⇧) beim Ziehen gedrückt halten |
| Menü öffnen | Rechtsklick (weniger als 4 Punkte Bewegung zwischen Drücken und Loslassen) |
| Zurück zum Neuesten | Auf den Balken „N neu“ klicken |

Das Kontextmenü bietet „Zum Neuesten scrollen“, „Diese Zeile kopieren“, „Im Browser öffnen“ (nur bei Zeilen mit Links), „Liste leeren“, „Layout sperren“, „Position und Größe zurücksetzen“, „Dieses Overlay ausblenden“ und „Einstellungen öffnen …“. „Deckkraft des Hintergrunds“ (20–100 %, nur der Hintergrund; der Text bleibt deckend) und „Schriftgröße“ (10–24 Punkte) stehen auf der Seite der jeweiligen Funktion. „Layout sperren“ und „Miniaturen ausblenden, wenn EVE nicht aktiv ist“ gelten auch für die Overlays; „Alle Miniaturen ausblenden“ gilt nur für Miniaturen.

### Menüleiste

Das Symbol in der Menüleiste zeigt ein Molekül in einem Achteck. Das Menü bietet: „Alle Miniaturen einblenden“ bzw. „Alle Miniaturen ausblenden“, Profil wechseln, „Alle Clients minimieren“, „Hotkeys nur in EVE“, „Aufklärungs-Overlay anzeigen“, „Übersetzungs-Overlay anzeigen“, „Nach Updates suchen …“, „Problem melden …“, „Einstellungen …“ und „EVE-O Preview beenden“. Wenn ein Update verfügbar ist oder der letzte Lauf unerwartet beendet wurde, erscheint ein Punkt auf dem Symbol, und oben im Menü erscheint ein Eintrag dazu. Fehlt eine Berechtigung, hat das Menü einen zusätzlichen Eintrag dazu. Wird die Aufnahme eines Clients über die Aufnahmeanzeige des Systems gestoppt, erhält das Menü einen Eintrag „Aufnahme fortsetzen“.

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

Die App verbindet sich für Updates mit GitHub und stellt keine weiteren Verbindungen her, solange Sie keine der nach dieser Liste beschriebenen optionalen Funktionen einschalten:

- Die Suche nach Updates fragt `api.github.com/repos/deletexiumu/eve-o-preview/releases/latest` beim Start und einmal täglich ab, solange „Automatisch nach Updates suchen“ aktiviert ist, sowie jedes Mal, wenn Sie „Nach Updates suchen …“ wählen.
- Wird eine neue Version angeboten, fragt die App außerdem einmal die Release-Liste `api.github.com/repos/deletexiumu/eve-o-preview/releases` mit denselben Headern ab, um die Änderungen übersprungener Versionen anzuzeigen.
- Die Installation eines Updates lädt `SHA256SUMS.txt` und das dmg aus dem Release herunter.

Die Anfragen enthalten nur die App-Version im Header `User-Agent`, ein festes `Accept-Language: en` und ein Cache-Tag; es werden keine Charakternamen, Einstellungen, Protokolle, Hardwaredetails, Systemversion oder Kennungen gesendet, und es werden keine Cookies verwendet. GitHub sieht Ihre IP-Adresse und den Zeitpunkt der Anfrage. Es gibt keine Telemetrie und keinen automatischen Upload von Abstürzen: „Problem melden …“ erstellt nur eine ZIP-Datei auf Ihrem Mac und öffnet eine Webseite, auf der Sie selbst entscheiden, ob Sie absenden.

Aufklärungs- und Übersetzungs-Overlay lesen nur die Chat- und Spielprotokolle; sie schreiben nie hinein, und private Unterhaltungen werden nie gelesen. Zwei optionale Funktionen verbinden sich mit anderen Diensten:

- Prüfung von Pilotennamen: „Online-Namensprüfung (ESI)“ ist standardmäßig eingeschaltet, sobald Sie das Aufklärungs-Overlay einschalten. Enthält eine Aufklärungsnachricht, die der aktive Charakter empfangen hat, aufeinanderfolgende Pilotennamen aus zwei oder mehr Wörtern, sendet die App diese Wörter einzeln und in Kombinationen von bis zu drei an CCPs ESI unter `esi.evetech.net/universe/ids`. Absender, Kanal und der Rest der Nachricht werden nicht gesendet; Ihre eigenen Charakternamen sind nur dabei, wenn jemand sie in eine Aufklärungsnachricht geschrieben hat. Ein Name, der für sich allein steht und nur aus einem Wort besteht, wird nie abgefragt. CCP sieht Ihre IP-Adresse und den Header `User-Agent` mit der App-Version und der Projekt-URL. Schalten Sie die Einstellung auf der Seite „Aufklärung“ aus, um diese Anfragen zu beenden. Die App selbst verbindet sich nie mit zKillboard: „Im Browser öffnen“ öffnet die zKillboard-Seite eines Charakters in Ihrem Browser, mit nur der Charakter-ID in der Adresse.
- Chat-Übersetzung (standardmäßig aus): Der Text der Nachrichten, die der Charakter des aktiven Clients in Ihren Übersetzungskanälen empfängt, geht zusammen mit den offiziellen Namen der darin genannten Systeme und Schiffe an den auf der Seite „Übersetzung“ gewählten Modelldienst. Absender- und Kanalnamen werden nicht gesendet; „Testen“ sendet einen festen Beispielsatz. Der API-Schlüssel liegt nur im macOS-Schlüsselbund, unter dem Dienst `io.github.deletexiumu.eveopreview-macos.translation` mit einem Eintrag pro Modelldienst, und wird nur an diesen Modelldienst gesendet. Er erscheint nie in der Konfigurationsdatei, in Protokollen oder Problemberichten. Öffentliche Adressen müssen `https` verwenden; `http` ist nur für diesen Mac oder das lokale Netzwerk erlaubt, etwa für Ollama. Was der Dienst mit dem Text macht, regeln seine eigenen Bedingungen.

Problemberichte enthalten die Einstellungen dieser Funktionen als Zahlen und Schalter (etwa die Zahl der Kanäle und den gewählten Dienst), aber keine Kanal- und Systemnamen, API-Adressen, Modellnamen, Pilotennamen, Chattexte oder Schlüssel.

Die App speichert Daten an diesen Orten. Für eine vollständige Deinstallation löschen Sie sie zusammen mit der App und `~/Library/Application Support/EVE-O Preview/config.json`:

| Ort | Inhalt |
| --- | --- |
| `~/Library/Logs/EVE-O Preview/` | App-Protokolle, höchstens etwa 5 MiB |
| `~/Library/Application Support/EVE-O Preview/session.json`, `state.json` | Sitzungsmarkierung; Einträge zu Updates und Diagnose; manuelle Standorte für die Aufklärung |
| `~/Library/Application Support/EVE-O Preview/Reports/` | Von Ihnen erstellte, anonymisierte Problembericht-ZIP-Dateien (die 3 neuesten) |
| `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` | Geladene Update-Dateien, werden nach der Installation gelöscht |
| `~/Library/Application Support/EVE-O Preview/pilot-names.json` | Über ESI gefundene Pilotennamen und Charakter-IDs (öffentliche Spieldaten), 30 Tage lang aufbewahrt. Nur für Sie lesbar (0600) und nie in Problemberichten; „Namenscache leeren“ auf der Seite „Aufklärung“ leert die Datei. Namen ohne Treffer bleiben nur 6 Stunden im Speicher |
| `~/Library/Application Support/EVE-O Preview/translation-cache.json` | Original- und übersetzter Nachrichtentext, ohne Absender- und Kanalnamen. Nur für Sie lesbar (0600) und nie in Problemberichten; „Cache leeren“ auf der Seite „Übersetzung“ leert die Datei |
| Schlüsselbundeinträge mit dem Dienst `io.github.deletexiumu.eveopreview-macos.translation` | Ihre API-Schlüssel für die Übersetzung, einer pro Modelldienst; „Schlüssel löschen“ auf der Seite „Übersetzung“ entfernt den des aktuellen Modelldienstes |

## Konfigurationsdatei

Die Konfiguration wird in `~/Library/Application Support/EVE-O Preview/config.json` gesichert. Eine Datei enthält alle Profile.

- Änderungen werden 0,5 Sekunden nach dem Vornehmen automatisch gesichert und beim Beenden noch einmal.
- Ist die Datei beschädigt, wird sie in `config.corrupt-<date-time>.json` umbenannt, und die App verwendet die Standardkonfiguration.
- Stammt die Datei von einer neueren Version, läuft die App mit der Standardkonfiguration, schreibt während dieser Sitzung nichts auf die Festplatte und überschreibt die Datei nicht.

Die Seite „Profile“ hat eine Schaltfläche „Im Finder zeigen“.

## Nicht übernommene Funktionen des Ursprungsprojekts

| Funktion des Ursprungsprojekts | Grund |
| --- | --- |
| Bildratenbegrenzung und selektive Stummschaltung (Robin-Injektion) | Das Ursprungsprojekt injiziert eine DLL in Windows-Prozesse; macOS hat keinen vergleichbaren öffentlichen Mechanismus. Die Windows-App begrenzt die Bildrate stattdessen über den Grafiktreiber (siehe [Windows](#windows)) |
| CPU-Affinität | Beruht auf Windows CPU Sets; Apple Silicon hat keine öffentliche API, um einen Prozess an Kerne zu binden |
| Kampfprotokoll-Erweiterungen (Augments): Schadenszahlen, DPS, Reparaturmengen, System-Overlay, statische FC-Daten | Ein großes eigenständiges Subsystem außerhalb von „Vorschau und Wechseln“; übernommen wurde nur „Blinken bei Angriff“ |
| Themes, alte Oberfläche, eigene Stile für das Kontextmenü | Die macOS-Version folgt dem Erscheinungsbild des Systems |
| Kompatibler Aufnahmemodus (`PrintWindow`) | ScreenCaptureKit ist die einzige Aufnahmemethode |
| Low-Level-Tastatur-Hook | Tastatur-Hotkeys nutzen globale Carbon-Hotkeys; ein Maus-Event-Tap wird nur erstellt, wenn eine Maustaste belegt ist |

Bereiche mit Andocken per Drag & Drop, Mehrfachauswahl und Gruppenverschiebung, Widerrufen, Ausrichtungshilfslinien, Import von Windows-Konfigurationen und Start bei der Anmeldung sind für die Zeit nach v1 geplant.

## Haftungsausschluss

Dieses Tool wechselt nur den Fensterfokus. Es sendet keine Eingaben an mehrere Clients gleichzeitig und liest oder verändert nicht den Spielspeicher – dieselbe Grenze wie beim Ursprungsprojekt. Aufklärungs- und Übersetzungs-Overlay lesen nur die Protokolldateien, die der Client schreibt. Lesen Sie vor der Verwendung die Endbenutzer-Lizenzvereinbarung von EVE Online.

Die App verbindet sich mit GitHub, um nach Updates zu suchen und sie zu laden. Mit CCPs ESI und einem Übersetzungsdienst verbindet sie sich nur, wenn Sie diese optionalen Funktionen einschalten, und sendet nur, was unter [Datenschutz](#datenschutz) beschrieben ist.

EVE Online und zugehörige Logos sind Marken von CCP ehf. Dieses Projekt steht in keiner Verbindung zu CCP und wird nicht von CCP unterstützt.

Das App-Symbol ist ein Sensenmann im Cartoon-Stil, den der Projektbetreuer bereitgestellt hat. `shared/branding/make-icons.py` erzeugt daraus die Symbole für macOS und Windows (Quelle: `shared/branding/logo-source.jpg`). Das Symbol enthält keine Marken oder Spielgrafiken von CCP.
