import SwiftUI

/// Plattform-Unterschiede an einer Stelle: tvOS (Fernbedienung, Fokus) und iPadOS (Touch).
enum Platform {
    #if os(tvOS)
    static let isTV = true
    #else
    static let isTV = false
    #endif

    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    #if targetEnvironment(macCatalyst)
    /// VLC für macOS kennt kein eigenes URL-Schema; die Stream-Adresse wird darum über
    /// `NSWorkspace` direkt an VLC übergeben. AppKit ist in Catalyst-Apps geladen,
    /// aber nicht importierbar, daher der Aufruf über die Objective-C-Laufzeit.
    @MainActor
    static func openInMacApp(bundleID: String, url: URL, completion: @escaping (Bool) -> Void) {
        guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
              let configClass = NSClassFromString("NSWorkspaceOpenConfiguration") as? NSObject.Type,
              let workspace = workspaceClass.value(forKey: "sharedWorkspace") as? NSObject,
              let appURL = workspace.perform(NSSelectorFromString("URLForApplicationWithBundleIdentifier:"), with: bundleID)?
                .takeUnretainedValue() as? URL
        else {
            completion(false)
            return
        }
        let configuration = configClass.init()
        configuration.setValue(true, forKey: "activates")
        typealias OpenFunction = @convention(c) (
            NSObject, Selector, NSArray, NSURL, NSObject, @escaping @convention(block) (NSObject?, NSError?) -> Void
        ) -> Void
        let selector = NSSelectorFromString("openURLs:withApplicationAtURL:configuration:completionHandler:")
        guard let method = class_getInstanceMethod(type(of: workspace), selector) else {
            completion(false)
            return
        }
        let open = unsafeBitCast(method_getImplementation(method), to: OpenFunction.self)
        open(workspace, selector, [url] as NSArray, appURL as NSURL, configuration) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
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
