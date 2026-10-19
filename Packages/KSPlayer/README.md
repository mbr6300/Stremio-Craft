# KSPlayer (lokale Kopie)

Stand `da0c29a40087fbc471e1119f2140ea21d4c9791c` von https://github.com/kingslay/KSPlayer (GPL-3.0, siehe LICENSE).

Änderungen gegenüber dem Original:
- `Package.swift`: Test-Target entfernt (Tests sind nicht mitkopiert).
- `Sources/KSPlayer/Video/SeekView.swift`: `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` –
  mit dem macOS-26-SDK ist AppKit auch unter Mac Catalyst importierbar, was sonst nicht kompiliert.
