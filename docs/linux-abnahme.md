# Linux: erste Paket- und Geräteprüfung

Stand: 2026-11-04, Kandidat 0.9.47. Diese Prüfung belegt eine erste installierbare
Fassung, keine vollständige Gleichwertigkeit zur macOS-Oberfläche.
Die spätere Erweiterung und ihre Nachweise stehen getrennt im
[Mac-/Linux-Abgleich](linux-paritaet.md); die folgenden Grenzen beschreiben 0.9.47.

## Bestanden

- CachyOS/KDE/Wayland und Mint 22.2/Cinnamon/X11 starten dasselbe auf Ubuntu 24.04
  gebaute Paket mit mitgelieferter Swift-/Qt-Laufzeit. Benutzerlokale Installation,
  App-Menü, Versionsausgabe und geprüfte Modelleinrichtung funktionieren.
- Vorhandene Mac-Client-Konfiguration abgeglichen: LAN-Bereinigung zuerst,
  gleicher freigegebener Modellstand und gleiche Kontextgröße, lokaler Gemma-
  Fallback. Nur geeignete Einstellungen übernommen; kein Cloud-Fallback und
  keine privaten Endpunkte im Quellstand.
- Künstliche deutsche Sprache über einen virtuellen Mikrofoneingang wurde auf
  beiden Desktops durch den tatsächlichen Qt-Aufnahmeweg verarbeitet. Der
  vollständige Referenztext wurde erkannt und bereinigt; die Tests veränderten
  das persönliche Clipboard nicht. Ein eigener Test schützt zudem das Beenden
  von Linux-Kindprozessen, die TERM ignorieren.
- Lokale Testdienste belegen Segmentreihenfolge, einmalige Gesamtbereinigung,
  geordnete Ausweichdienste und unmittelbaren Rohtext bei Plausibilitätsfehlern.
  Geerbte Proxies und Audio-Redirects leiten keine Samples aus. Erfolg entfernt
  WAV-Dateien; Transkriptionsfehler erhalten sie.
- Signaturen, Plattform-/Produkt-/Versionsgrenzen und Archivpfade werden geprüft.
  Eine isolierte Paketprobe mit künstlichen Vorgänger-Versionsmetadaten und einem
  eigenen kurzlebigen Testschlüssel durchlief Installation, Qt-Selbsttest,
  atomaren Wechsel und lokalen Rollback. Es gab keinen öffentlichen Upload.
- macOS: portable gemeinsame Regressionen, synthetischer Audio-E2E-Lauf,
  Build-/Release-Shellverträge und ein temporäres App-Bundle bestanden. Das
  installierte macOS-Bundle und dessen Signatur blieben unverändert. Der volle
  Testlauf enthielt Schlüsselbund-/TLS-Fehler in der SSH-Sitzung; diese Tests
  bleiben dort eine Prüfgrenze, kein als bestanden gezählter Lauf.

## Begrenzte Leistungsstichprobe

Referenz: 7,8 Sekunden künstliche deutsche Sprache, unverändertes Whisper
large-v3-turbo. Dies ist kein umfangreicher Qualitätsbenchmark.

| Ziel/Pfad | Messung |
|---|---|
| CachyOS, Radeon RX 7600M XT, Vulkan | Whisper-CLI insgesamt rund 1,45 s inklusive Modellstart; rund 0,58 s Ladezeit. |
| Mint, integrierte Radeon, Vulkan | Warme HTTP-Transkription rund 3,23 s. Der GPU-Pfad ist auf beiden Testgeräten aktiviert. |
| Mint, CPU | Gesamter Worker-Dateiimport einschließlich Bereinigung rund 14,7 s; für kontinuierliches Diktat weniger geeignet. |
| Mint, lokaler Gemma-Fallback | Erster geprüfter Bereinigungsaufruf rund 38,9 s einschließlich Ausfallprüfung und Modellstart. Sichtbarer Notbetrieb; regulär bleibt der LAN-Dienst vorrangig. |

Die Referenzgewichte sind geprüft. Modellgröße auf Platte ist kein Nachweis des
Spitzenverbrauchs; die Stichprobe ersetzt keinen längeren Temperatur-/RAM-Test.

## Noch abzunehmen

Physische Mikrofone auf beiden Geräten, tatsächliche Desktop-Hotkeys und
Portalablehnung, Hotplug/Suspend sowie mehrtägiger Pilotbetrieb. Ein echter
Mikrofoneingang war am Mint-Gerät beim ersten Bestandsabgleich nicht vorhanden.
Kopieren mit manuellem Einfügen ist die freigegebene Linux-Ausgabe; automatisches
Einfügen und Gedrückthalten bleiben aus.

Der Updater benötigt vor öffentlicher Freigabe ein unabhängiges Review und einen
realen GitHub-Feed-/Update-Lauf. Sein Vertrauensanker ist im Paket enthalten;
Signierschlüssel liegen außerhalb des Repositories. Dieses Paket wurde nur
privat installiert und gesichert, nicht als GitHub-Release veröffentlicht.
