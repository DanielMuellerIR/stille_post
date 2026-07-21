# Sparkle-Updates veröffentlichen

Stille Post bindet Sparkle 2.9.4 per SwiftPM ein. Die App prüft den Feed unter
`https://danielmuellerir.github.io/stille_post/appcast.xml`, lädt das DMG weiterhin
aus dem zugehörigen GitHub Release und installiert ausschließlich nach Zustimmung.

Version 0.8.9 ist der einmalige Bootstrap: 0.8.4 enthält noch keinen Sparkle-Code und
kann 0.8.9 deshalb nicht selbst finden. Bestehende Installationen müssen 0.8.9 noch
einmal manuell per DMG installieren; erst danach funktionieren automatische Updates.

Zwei voneinander unabhängige Prüfungen bleiben Pflicht:

- Developer-ID-Signatur und Apple-Notarisierung für App und DMG.
- Sparkle-Ed25519-Signatur für das Update-Archiv sowie den Feed.

Der private Sparkle-Schlüssel gehört weder in Git noch in Logs oder Argumente. Der
projektspezifische Schlüssel liegt lokal im Login-Schlüsselbund unter dem Sparkle-
Account `io.github.danielmuellerir.stillepost`. Nur sein öffentlicher Gegenpart ist
im App-Bundle eingecheckt.

## Einmalige GitHub-Einrichtung

1. In den Repository-Einstellungen unter **Pages** als Quelle **GitHub Actions**
   wählen.
2. Den privaten Schlüssel als Actions-Secret `SPARKLE_PRIVATE_KEY` hinterlegen.
   Sparkles `generate_keys -x` exportiert ihn vorübergehend in eine lokale Datei;
   `gh secret set SPARKLE_PRIVATE_KEY < datei` liest diese Datei über stdin. Die
   Exportdatei danach sicher entfernen. Den Schlüssel nie auf stdout ausgeben.
3. Den Schlüssel zusätzlich verschlüsselt sichern. Geht er verloren, ist eine
   kontrollierte Schlüsselrotation über ein Developer-ID-signiertes DMG nötig.

## Ablauf pro Release

1. `VERSION` und `CHANGELOG.md` aktualisieren. `CFBundleVersion` wird aus `VERSION`
   übernommen und muss monoton steigen.
2. `scripts/build-app.sh --notarize` mit einem konfigurierten `NOTARY_PROFILE`
   ausführen. Das Skript signiert Sparkles Helfer von innen nach außen mit derselben
   Developer-ID wie die App.
3. Aus der gestapelten App das übliche DMG erstellen, das DMG selbst mit Developer ID
   signieren, notarisieren und stapeln.
4. Ein GitHub Release als Entwurf anlegen, genau ein DMG anhängen, Release Notes
   eintragen und erst danach veröffentlichen.
5. `.github/workflows/publish-appcast.yml` lädt dieses DMG, erzeugt mit Sparkles
   `generate_appcast` einen signierten Feed, bettet die Release Notes ein und
   veröffentlicht `appcast.xml` über GitHub Pages.
6. Den Workflow und anschließend
   `https://danielmuellerir.github.io/stille_post/appcast.xml` prüfen. Im App-Menü
   **„Nach Updates suchen …“** muss eine ältere, notarisiert installierte und bereits
   Sparkle-fähige Testversion das neue Release finden, installieren und neu starten.
   Für 0.8.9 bedeutet das: einen signierten Test-Build mit kleinerer
   `CFBundleVersion` und demselben Schlüssel verwenden. Die echte 0.8.4 eignet sich
   nicht, weil dort der Updater fehlt.

Für einen automatisierten Menü-Smoke-Test öffnet `STILLEPOST_OPEN_MENU=1` das echte
Statusmenü im nächsten AppKit-Runloop. Zusammen mit `STILLEPOST_NO_AX_PROMPT=1`
bleibt der Test frei vom Bedienungshilfen-Dialog; die gestartete Test-App danach
wieder ausblenden oder beenden.

Der Workflow kann für ein bereits veröffentlichtes Tag manuell gestartet werden.
Er erwartet genau ein `*.dmg` im Release. Momentan enthält der Feed nur das aktuelle
Vollupdate; Delta-Updates sind bewusst deaktiviert, bis der Pages-Workflow mehrere
historische Archive mit ihren jeweiligen Download-URLs verwaltet.
