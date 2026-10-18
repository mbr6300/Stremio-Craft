import SwiftUI

/// Plattform-Unterschiede an einer Stelle: tvOS (Fernbedienung, Fokus) und iPadOS (Touch).
enum Platform {
    #if os(tvOS)
    static let isTV = true
    #else
    static let isTV = false
    #endif
}

extension View {
    /// Fokus-Abschnitt für die Fernbedienung; auf dem iPad ohne Wirkung.
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// Karten-Knopf: auf tvOS der System-Stil `.card`, auf dem iPad eine gerundete Fläche zum Antippen.
    @ViewBuilder
    func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        #endif
    }

    /// Menü-/Zurück-Taste der Fernbedienung; auf dem iPad ohne Wirkung.
    @ViewBuilder
    func tvOnExitCommand(perform action: (() -> Void)?) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
