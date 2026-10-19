# KSPlayer (lokale Kopie)

Stand `da0c29a40087fbc471e1119f2140ea21d4c9791c` von https://github.com/kingslay/KSPlayer (GPL-3.0, siehe LICENSE).

Änderungen gegenüber dem Original:
- `Package.swift`: Test-Target entfernt (Tests sind nicht mitkopiert).
- `Sources/KSPlayer/Video/SeekView.swift`: `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` –
  mit dem macOS-26-SDK ist AppKit auch unter Mac Catalyst importierbar, was sonst nicht kompiliert.
- `Sources/KSPlayer/MEPlayer/TrackDisplayName.swift` (neu) und `SwiftUI/KSVideoPlayerView.swift`: Tonspur-Menü zeigt
  „Sprache · Tonformat · Kanäle“ (z. B. „Deutsch · Dolby TrueHD Atmos · 7.1“) statt der technischen Beschreibung.
- Untertitel-Menü (`SwiftUI/KSVideoPlayerViewBuilder.swift`, `MEPlayer/FFmpegAssetTrack.swift`): „Sprache · Art“
  (z. B. „Englisch · Für Hörgeschädigte“, „Deutsch · Nur fremdsprachige Stellen“), „Aus“ statt „Off“;
  `FFmpegAssetTrack` merkt sich dafür Titel sowie die Kennzeichen „erzwungen“ und „für Hörgeschädigte“.
