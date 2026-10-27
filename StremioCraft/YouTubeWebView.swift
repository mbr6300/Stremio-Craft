#if !os(tvOS)
import SwiftUI
import WebKit

/// Die echte YouTube-Seite (Anmelden, Abos, Kommentare) mit eingebautem Werbeblocker und
/// „Unhook“-Regeln: keine Shorts, keine Startseiten-Vorschläge, keine Vorschläge neben/nach dem Video.
/// Nur iPhone, iPad und Mac – Apple TV hat keine Web-Ansicht.
struct YouTubeWebScreen: View {
    @State private var web = YouTubeWebModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { web.view.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!web.canGoBack)
                Button { web.view.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!web.canGoForward)
                Button { web.view.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                Button { web.open("https://www.youtube.com/feed/subscriptions") } label: {
                    Label("Abos", systemImage: "person.crop.rectangle.stack")
                }
                Button { web.open("https://www.youtube.com/") } label: {
                    Label("Start", systemImage: "house")
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 8)
            YouTubeWebContainer(web: web)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

@MainActor
@Observable
final class YouTubeWebModel {
    let view: WKWebView
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: YouTubeWebRules.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        // Als normales Safari auftreten: Google lässt die Anmeldung in eingebetteten Browsern sonst nicht zu.
        // Die Anmeldung bleibt gespeichert (Standard-Datenspeicher von WebKit).
        view.customUserAgent = Platform.isPhone
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
            : "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        view.isOpaque = false
        view.backgroundColor = .black
        observations = [
            view.observe(\.canGoBack) { [weak self] web, _ in Task { @MainActor in self?.canGoBack = web.canGoBack } },
            view.observe(\.canGoForward) { [weak self] web, _ in Task { @MainActor in self?.canGoForward = web.canGoForward } }
        ]
        // Netzwerk-Regeln erst kompilieren, dann laden – sonst rutscht die erste Werbung durch.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "youtube-blocker-1",
            encodedContentRuleList: YouTubeWebRules.blockList
        ) { [weak self] list, _ in
            Task { @MainActor in
                guard let self else { return }
                if let list { self.view.configuration.userContentController.add(list) }
                self.open("https://www.youtube.com/")
            }
        }
    }

    func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        view.load(URLRequest(url: url))
    }
}

private struct YouTubeWebContainer: UIViewRepresentable {
    var web: YouTubeWebModel

    func makeUIView(context: Context) -> WKWebView { web.view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

enum YouTubeWebRules {
    /// Werbe- und Tracking-Adressen blockieren (Content Blocker von WebKit).
    static let blockList = """
    [
      {"trigger": {"url-filter": "^https?://([^/]+\\\\.)?doubleclick\\\\.net"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://([^/]+\\\\.)?googlesyndication\\\\.com"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://([^/]+\\\\.)?googleadservices\\\\.com"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://([^/]+\\\\.)?google\\\\.com/pagead/"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "youtube\\\\.com/pagead/"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "youtube\\\\.com/api/stats/ads"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "youtube\\\\.com/ptracking"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "youtube\\\\.com/get_midroll_"}, "action": {"type": "block"}}
    ]
    """

    /// Ausblenden per CSS (Desktop- und Mobilseite) und Werbung im Player überspringen.
    static let script = """
    (function () {
      const css = `
        ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-banner-promo-renderer, #masthead-ad,
        ytd-promoted-sparkles-web-renderer, ytd-display-ad-renderer, ytd-companion-slot-renderer, #player-ads,
        ytd-merch-shelf-renderer, .ytp-ad-overlay-container, ytd-statement-banner-renderer,
        ad-slot-renderer, ytm-promoted-sparkles-web-renderer, ytm-companion-ad-renderer, ytm-promoted-video-renderer,
        ytd-reel-shelf-renderer, ytd-rich-shelf-renderer[is-shorts], ytd-rich-section-renderer,
        ytd-rich-item-renderer:has(a[href^="/shorts"]), ytd-video-renderer:has(a[href^="/shorts"]),
        ytd-grid-video-renderer:has(a[href^="/shorts"]), ytd-guide-entry-renderer:has(a[title="Shorts"]),
        ytd-mini-guide-entry-renderer[aria-label="Shorts"], yt-tab-shape[tab-title="Shorts"],
        ytd-mini-guide-entry-renderer:has(a[href^="/shorts"]), ytd-guide-entry-renderer:has(a[href^="/shorts"]),
        grid-shelf-view-model:has(a[href^="/shorts"]), ytd-shelf-renderer:has(a[href^="/shorts"]),
        ytd-item-section-renderer:has(> #contents > ytd-reel-shelf-renderer), ytm-shorts-lockup-view-model-v2,
        ytm-reel-shelf-renderer, ytm-shorts-lockup-view-model, ytm-rich-section-renderer,
        ytm-video-with-context-renderer:has(a[href^="/shorts"]), ytm-pivot-bar-item-renderer:has(.pivot-shorts),
        ytd-browse[page-subtype="home"] ytd-rich-grid-renderer, ytd-browse[page-subtype="home"] #chips-wrapper,
        #related, ytd-watch-next-secondary-results-renderer, .ytp-endscreen-content, .ytp-ce-element,
        .ytp-autonav-endscreen-countdown-overlay, ytm-item-section-renderer[section-identifier="related-items"]
        { display: none !important; }
      `;
      const style = document.createElement('style');
      style.textContent = css;
      (document.head || document.documentElement).appendChild(style);

      let mutedByUs = false;
      setInterval(function () {
        // Shorts als normales Video öffnen.
        const short = location.pathname.match(/^\\/shorts\\/([\\w-]+)/);
        if (short) { location.replace('/watch?v=' + short[1]); return; }
        // Startseite: ohne Vorschläge, auf dem Handy direkt zu den Abos.
        if (location.hostname.startsWith('m.') && location.pathname === '/') {
          location.replace('/feed/subscriptions'); return;
        }
        const video = document.querySelector('video');
        const ad = document.querySelector('.ad-showing, .ad-interrupting');
        if (video && ad) {
          if (!video.muted) { video.muted = true; mutedByUs = true; }
          if (isFinite(video.duration)) video.currentTime = video.duration;
        } else if (video && mutedByUs) {
          video.muted = false; mutedByUs = false;
        }
        document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-overlay-close-button')
          .forEach(function (button) { button.click(); });
      }, 300);
    })();
    """
}
#endif
