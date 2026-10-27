#if !os(tvOS)
import SwiftUI
import WebKit

/// Die echte YouTube-Seite (Anmelden, Abos, Kommentare) mit eingebautem Werbeblocker und
/// „Unhook“-Regeln: keine Shorts, keine Startseiten-Vorschläge, keine Vorschläge neben/nach dem Video.
/// Nur iPhone, iPad und Mac – Apple TV hat keine Web-Ansicht.
struct YouTubeWebScreen: View {
    @Environment(AppModel.self) private var model
    @State private var web = YouTubeWebModel()
    @State private var importing = false
    @State private var importResult: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { web.view.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!web.canGoBack)
                Button { web.view.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!web.canGoForward)
                Button { web.view.reload() } label: { Image(systemName: "arrow.clockwise") }
                Spacer()
                Button { Task { await importSubscriptions() } } label: {
                    if importing {
                        ProgressView()
                    } else {
                        Label("Abos übernehmen", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(importing)
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
        .alert("Abos übernehmen", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
            Button("OK") { importResult = nil }
        } message: {
            Text(importResult ?? "")
        }
    }

    /// Abos des angemeldeten Google-Kontos in die App-Ansicht holen (und damit per Sync auf Apple TV).
    private func importSubscriptions() async {
        importing = true
        defer { importing = false }
        do {
            let channels = try await web.accountSubscriptions()
            let added = model.addSubscriptions(channels)
            importResult = "\(channels.count) Abos gefunden, \(added) neu übernommen. Sie erscheinen unter „App“ und – mit Geräte-Sync – auch auf dem Apple TV."
        } catch {
            importResult = error.localizedDescription
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

    /// Liest die Abos des angemeldeten Kontos über die Sitzung der Seite (wie YouTube selbst).
    func accountSubscriptions() async throws -> [YouTubeChannel] {
        guard view.url?.host?.hasSuffix("youtube.com") == true else {
            throw AppFailure.message("Öffne zuerst YouTube (Knopf „Start“) und melde dich an.")
        }
        let result = try await view.callAsyncJavaScript(YouTubeWebRules.subscriptionsScript, contentWorld: .page)
        guard let object = result as? [String: Any] else { throw AppFailure.message("YouTube hat keine Abos geliefert.") }
        if let error = object["error"] as? String {
            throw AppFailure.message(error == "login"
                ? "Du bist nicht angemeldet. Tippe oben rechts auf „Anmelden“ und versuche es danach nochmals."
                : "YouTube hat die Abos nicht herausgegeben (\(error)).")
        }
        let list = object["channels"] as? [[String: Any]] ?? []
        let channels = list.compactMap { entry -> YouTubeChannel? in
            guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
            return YouTubeChannel(id: id, title: title, thumbnail: (entry["thumb"] as? String).flatMap(URL.init(string:)))
        }
        guard !channels.isEmpty else { throw AppFailure.message("In diesem Konto wurden keine Abos gefunden.") }
        return channels
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

    /// Abo-Liste („FEchannels“) mit der Anmeldung der Seite abrufen, alle Seiten nacheinander.
    /// Läuft als Funktionskörper (`callAsyncJavaScript`), darum `return` und `await` erlaubt.
    static let subscriptionsScript = """
    const pick = (name) => (document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]+)')) || [])[1];
    const sapisid = pick('SAPISID') || pick('__Secure-3PAPISID');
    if (!sapisid) return { error: 'login' };
    const origin = location.origin;
    const ts = Math.floor(Date.now() / 1000);
    const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(ts + ' ' + sapisid + ' ' + origin));
    const hex = Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
    const context = (window.ytcfg && ytcfg.get('INNERTUBE_CONTEXT'))
      || { client: { clientName: 'WEB', clientVersion: '2.20250101.00.00', hl: 'de' } };
    const headers = {
      'Content-Type': 'application/json',
      'Authorization': 'SAPISIDHASH ' + ts + '_' + hex,
      'X-Origin': origin,
      'X-Goog-AuthUser': '0'
    };
    const channels = {};
    let body = { context: context, browseId: 'FEchannels' };
    for (let page = 0; page < 40; page++) {
      const response = await fetch('/youtubei/v1/browse?prettyPrint=false', {
        method: 'POST', credentials: 'include', headers: headers, body: JSON.stringify(body)
      });
      if (!response.ok) return { error: 'HTTP ' + response.status };
      const data = await response.json();
      let next = null;
      const walk = (node) => {
        if (!node || typeof node !== 'object') return;
        if (Array.isArray(node)) { node.forEach(walk); return; }
        const c = node.channelRenderer;
        if (c && c.channelId) {
          const thumbs = (c.thumbnail && c.thumbnail.thumbnails) || [];
          let thumb = thumbs.length ? thumbs[thumbs.length - 1].url : null;
          if (thumb && thumb.startsWith('//')) thumb = 'https:' + thumb;
          const title = c.title ? (c.title.simpleText || (c.title.runs || []).map(r => r.text).join('')) : '';
          channels[c.channelId] = { id: c.channelId, title: title, thumb: thumb };
        }
        if (node.continuationCommand && node.continuationCommand.token) next = node.continuationCommand.token;
        for (const key in node) walk(node[key]);
      };
      walk(data);
      if (!next) break;
      body = { context: context, continuation: next };
    }
    return { channels: Object.values(channels) };
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
