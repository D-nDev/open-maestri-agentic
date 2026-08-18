import AppKit
import WebKit

// MARK: - Portal UIDelegate (handle _blank new window)

final class PortalUIDelegate: NSObject, WKUIDelegate {
    let portalId: UUID

    init(portalId: UUID) {
        self.portalId = portalId
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target="_blank" or window.open(): Create a new Portal node on the canvas
        guard let url = navigationAction.request.url else { return nil }
        let urlString = url.absoluteString
        NotificationCenter.default.post(
            name: .portalOpenedNewWindow,
            object: nil,
            userInfo: ["url": urlString, "openerPortalId": portalId]
        )
        return nil
    }
}

// MARK: - Portal NavigationDelegate (handles self-signed certificates and redirects)

final class PortalNavigationDelegate: NSObject, WKNavigationDelegate {
    let portalId: UUID

    init(portalId: UUID) {
        self.portalId = portalId
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Allow self-signed certificates (common in development environments)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in PortalWebViewStore.shared.navigationDidFinish(for: portalId) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in PortalWebViewStore.shared.navigationDidFail(for: portalId, error: error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in PortalWebViewStore.shared.navigationDidFail(for: portalId, error: error) }
    }
}

/// Portal WKWebView wrapper (direct NSView, for embedding canvas nodes)
final class PortalWebView: NSView {
    private(set) var webView: WKWebView?

    func configure(portalId: UUID, url: String? = nil) {
        let wv = PortalWebViewStore.shared.createWebView(for: portalId, initialURL: url)
        webView = wv
        wv.frame = bounds
        wv.autoresizingMask = [.width, .height]
        addSubview(wv)
    }

    override func layout() {
        super.layout()
        webView?.frame = bounds
    }
}
