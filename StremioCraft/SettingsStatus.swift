import SwiftUI

/// Zustand einer Konfiguration in den Einstellungen (Real-Debrid, TMDB, Torrentio, Mediathek, Sync).
enum ConfigStatus: Equatable {
    case checking
    /// Eingerichtet und geprüft, z. B. „Angemeldet als …“.
    case ok(String)
    /// Noch nicht eingerichtet (bei freiwilligen Funktionen kein Fehler).
    case missing(String)
    case failed(String)

    var symbol: String {
        switch self {
        case .checking: return "clock"
        case .ok: return "checkmark.circle.fill"
        case .missing: return "circle.dashed"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .checking: return .secondary
        case .ok: return .green
        case .missing: return .orange
        case .failed: return .red
        }
    }

    var text: String {
        switch self {
        case .checking: return "Wird geprüft …"
        case .ok(let text), .missing(let text), .failed(let text): return text
        }
    }
}

/// Abschnittstitel mit Statussymbol rechts: ✓ grün = eingerichtet, ◌ orange = fehlt, ⚠︎ rot = Fehler.
struct SettingsHeader: View {
    var title: String
    var status: ConfigStatus?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if let status {
                Label {
                    Text(status.text)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.color)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status.color == .secondary ? .secondary : .primary)
            }
        }
        .textCase(nil)
        .padding(.top, Platform.isTV ? 24 : 10)
        .accessibilityElement(children: .combine)
    }
}

/// Fusszeile in einheitlicher, gut lesbarer Grösse.
struct SettingsFooter: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .padding(.bottom, Platform.isTV ? 12 : 4)
    }
}
