import Foundation
import Observation

/// Im Heimnetz per Bonjour angekündigter WebDAV-Server (z. B. der Mac mini mit
/// `scripts/mac-mini-webdav.sh`, ein NAS mit WebDAV-Ankündigung).
struct DiscoveredLibrary: Identifiable, Hashable {
    var name: String
    var url: String
    var id: String { url }
}

/// Sucht `_webdav._tcp` (http) und `_webdavs._tcp` (https) im lokalen Netz und löst Adresse, Port
/// und den angekündigten Pfad (TXT-Eintrag `path`) auf. Beim ersten Mal fragt das System nach der
/// Erlaubnis für das lokale Netzwerk.
@MainActor
@Observable
final class LocalServiceBrowser: NSObject {
    private(set) var found: [DiscoveredLibrary] = []

    @ObservationIgnored private var browsers: [NetServiceBrowser] = []
    @ObservationIgnored private var resolving: [NetService] = []

    func start() {
        guard browsers.isEmpty else { return }
        for type in ["_webdav._tcp.", "_webdavs._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers = []
        resolving.forEach { $0.stop() }
        resolving = []
    }

    fileprivate func add(_ service: NetService) {
        guard let host = service.hostName, service.port > 0 else { return }
        let secure = service.type.hasPrefix("_webdavs")
        var path = "/"
        if let txt = service.txtRecordData(),
           let value = NetService.dictionary(fromTXTRecord: txt)["path"],
           let text = String(data: value, encoding: .utf8), !text.isEmpty {
            path = text.hasPrefix("/") ? text : "/" + text
        }
        let cleanHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let url = "\(secure ? "https" : "http")://\(cleanHost):\(service.port)\(path)"
        let entry = DiscoveredLibrary(name: service.name, url: url)
        if !found.contains(entry) { found.append(entry) }
    }

    fileprivate func remove(named name: String) {
        found.removeAll { $0.name == name }
    }
}

extension LocalServiceBrowser: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        MainActor.assumeIsolated { remove(named: name) }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            add(sender)
            resolving.removeAll { $0 === sender }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { resolving.removeAll { $0 === sender } }
    }
}
