import Foundation
import WebKit
import OSLog

/// Portal WKWebView Instance Manager
/// Each Portal node holds an independent WKWebViewConfiguration (independent Cookie/Storage)
@MainActor
final class PortalWebViewStore {
    static let shared = PortalWebViewStore()
    private let logger = Logger.make(category: "PortalWebViewStore")
    private var webViews: [UUID: WKWebView] = [:]
    private var navigationDelegates: [UUID: PortalNavigationDelegate] = [:]
    private var uiDelegates: [UUID: PortalUIDelegate] = [:]
    private var loadingContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Portal URL input box reference (for AppKit layer focus)
    private var urlTextFields: [UUID: NSTextField] = [:]
    private init() {}

    // MARK: - URL TextField Management

    func registerURLTextField(_ textField: NSTextField, for portalId: UUID) {
        urlTextFields[portalId] = textField
    }

    func unregisterURLTextField(for portalId: UUID) {
        urlTextFields.removeValue(forKey: portalId)
    }

    /// Logout through NSTextField reference (nodeId is not easy to obtain in dismantleNSView scenario)
    func unregisterURLTextField(matching textField: NSTextField) {
        if let key = urlTextFields.first(where: { $0.value === textField })?.key {
            urlTextFields.removeValue(forKey: key)
        }
    }

    func urlTextField(for portalId: UUID) -> NSTextField? {
        urlTextFields[portalId]
    }

    // MARK: - WebView life cycle

    /// sharedDataStores: portal-portal connection group → shared WKWebsiteDataStore
    private var sharedDataStores: [UUID: WKWebsiteDataStore] = [:]  // groupId → store
    private var portalGroups: [UUID: UUID] = [:]                     // portalId → groupId

    func createWebView(for portalId: UUID, initialURL: String? = nil, sharedGroupId: UUID? = nil) -> WKWebView {
        // Deduplication protection: If a WebView with the same portalId already exists, return directly (to avoid repeated creation causing the old WebView to lose references)
        if let existing = webViews[portalId] {
            // If the caller provides the initialURL and the WebView currently has no content and is not loading, it will only be loaded additionally.
            if let urlStr = initialURL, let url = URL(string: urlStr),
               existing.url == nil && !existing.isLoading {
                existing.load(URLRequest(url: url))
            }
            return existing
        }
        let config = WKWebViewConfiguration()
        // Independent Portal uses non-persistent storage (storageScope: isolated)
        // Portal-Portal connections share the same WKWebsiteDataStore
        if let groupId = sharedGroupId {
            if let existing = sharedDataStores[groupId] {
                config.websiteDataStore = existing
            } else {
                let store = WKWebsiteDataStore.nonPersistent()
                sharedDataStores[groupId] = store
                config.websiteDataStore = store
            }
            portalGroups[portalId] = groupId
        } else {
            // Use persistent storage to retain Cookie/Session to avoid infinite refresh of the website due to session loss.
            config.websiteDataStore = WKWebsiteDataStore.default()
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        // Set navigationDelegate to handle certificate challenges (allow self-signed HTTPS)
        let delegate = PortalNavigationDelegate(portalId: portalId)
        webView.navigationDelegate = delegate
        // Set uiDelegate to handle target="_blank" / window.open() new window request
        let uiDelegate = PortalUIDelegate(portalId: portalId)
        webView.uiDelegate = uiDelegate
        // Keep delegate reference to avoid being released by ARC
        navigationDelegates[portalId] = delegate
        uiDelegates[portalId] = uiDelegate
        webViews[portalId] = webView

        if let urlStr = initialURL, let url = URL(string: urlStr) {
            webView.load(URLRequest(url: url))
        }
        logger.debug("WebView created for portal \(portalId.uuidString.prefix(8))")
        return webView
    }

    @discardableResult
    func createWebView(for portalId: UUID, initialURL: String? = nil) -> WKWebView {
        createWebView(for: portalId, initialURL: initialURL, sharedGroupId: nil)
    }

    func removeWebView(for portalId: UUID) {
        webViews[portalId]?.stopLoading()
        webViews.removeValue(forKey: portalId)
        navigationDelegates.removeValue(forKey: portalId)
        uiDelegates.removeValue(forKey: portalId)
        loadingContinuations.removeValue(forKey: portalId)?.resume()
        lastNotifiedURLs.removeValue(forKey: portalId)
        // Clean up shared group if last member
        if let groupId = portalGroups.removeValue(forKey: portalId) {
            let remaining = portalGroups.values.filter { $0 == groupId }
            if remaining.isEmpty { sharedDataStores.removeValue(forKey: groupId) }
        }
    }

    func webView(for portalId: UUID) -> WKWebView? {
        webViews[portalId]
    }

    // MARK: - Portal↔Portal session sharing (FR31)

    /// Sharing session when establishing Portal-Portal connection
    /// Note: The dataStore cannot be changed after the WKWebView is created, so the WebView needs to be rebuilt
    func shareSession(portalIdA: UUID, portalIdB: UUID) {
        let groupId = portalGroups[portalIdA] ?? UUID()
        let urlA = webViews[portalIdA]?.url?.absoluteString
        let urlB = webViews[portalIdB]?.url?.absoluteString

        // Stop old WebView
        webViews[portalIdA]?.stopLoading()
        webViews[portalIdB]?.stopLoading()
        webViews.removeValue(forKey: portalIdA)
        webViews.removeValue(forKey: portalIdB)

        // Create a new WebView that shares the session
        let newA = createWebView(for: portalIdA, initialURL: urlA, sharedGroupId: groupId)
        let newB = createWebView(for: portalIdB, initialURL: urlB, sharedGroupId: groupId)

        // Notify CanvasNodeRenderer to update WebView embedded in Portal view
        NotificationCenter.default.post(
            name: .portalWebViewReplaced,
            object: nil,
            userInfo: ["portalIdA": portalIdA, "webViewA": newA, "portalIdB": portalIdB, "webViewB": newB]
        )
        logger.info("Session shared: portal \(portalIdA.uuidString.prefix(8)) ↔ \(portalIdB.uuidString.prefix(8)) (group: \(groupId.uuidString.prefix(8)))")
    }

    // MARK: - Navigation callback (called by PortalNavigationDelegate)

    /// The URL of the last notification (to prevent repeated post notifications from triggering @Observable cascading for the same URL)
    private var lastNotifiedURLs: [UUID: String] = [:]

    func navigationDidFinish(for portalId: UUID) {
        loadingContinuations.removeValue(forKey: portalId)?.resume()
        // Write the final landing URL back to the model to ensure recovery after closing and reopening
        // Debounce: Post only when the URL is different from the last notification to avoid repeatedly triggering @Observable cascading updates
        if let url = webViews[portalId]?.url?.absoluteString, !url.isEmpty,
           lastNotifiedURLs[portalId] != url {
            lastNotifiedURLs[portalId] = url
            NotificationCenter.default.post(
                name: .portalURLDidChange,
                object: nil,
                userInfo: ["portalId": portalId, "url": url]
            )
        }
    }

    func navigationDidFail(for portalId: UUID, error: Error) {
        loadingContinuations.removeValue(forKey: portalId)?.resume(throwing: error)
    }

    // MARK: - Portal automation command (omaestri portal)

    func goBack(portalId: UUID) async throws {
        guard let wv = webViews[portalId] else {
            throw MaestriError.portalCommandFailed("Portal not found: \(portalId)")
        }
        await MainActor.run { wv.goBack() }
    }

    func goForward(portalId: UUID) async throws {
        guard let wv = webViews[portalId] else {
            throw MaestriError.portalCommandFailed("Portal not found: \(portalId)")
        }
        await MainActor.run { wv.goForward() }
    }

    func reload(portalId: UUID) async throws {
        guard let wv = webViews[portalId] else {
            throw MaestriError.portalCommandFailed("Portal not found: \(portalId)")
        }
        await MainActor.run { wv.reload() }
    }

    func navigate(portalId: UUID, to urlString: String) async throws {
        guard let wv = webViews[portalId],
              let url = URL(string: urlString) else {
            throw MaestriError.portalCommandFailed("Invalid URL or portal not found: \(urlString)")
        }
        // Cancel previously unfinished navigation (if any)
        loadingContinuations.removeValue(forKey: portalId)?.resume()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadingContinuations[portalId] = continuation
            wv.load(URLRequest(url: url))
            // 15 seconds timeout protection: no error will be reported after timeout and continue directly
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.loadingContinuations.removeValue(forKey: portalId)?.resume()
            }
        }
    }

    func screenshot(portalId: UUID) async throws -> String {
        guard let wv = webViews[portalId] else {
            throw MaestriError.portalCommandFailed("Portal not found: \(portalId)")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let config = WKSnapshotConfiguration()
                wv.takeSnapshot(with: config) { image, error in
                    guard let image, error == nil else {
                        continuation.resume(returning: "error: snapshot failed")
                        return
                    }
                    let data = image.tiffRepresentation ?? Data()
                    continuation.resume(returning: data.base64EncodedString())
                }
            }
        }
    }

    func evaluate(portalId: UUID, javascript: String) async throws -> String {
        guard let wv = webViews[portalId] else {
            throw MaestriError.portalCommandFailed("Portal not found: \(portalId)")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                wv.evaluateJavaScript(javascript) { result, error in
                    if let error {
                        continuation.resume(throwing: MaestriError.portalCommandFailed(error.localizedDescription))
                    } else {
                        continuation.resume(returning: "\(result ?? "")")
                    }
                }
            }
        }
    }

    // MARK: - Global storage management

    /// Clear global portal storage (cookies, cache, local data)
    /// Corresponds to Maestri "Clear global storage..." function
    func clearGlobalStorage() async {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: dataTypes)
        await dataStore.removeData(ofTypes: dataTypes, for: records)
        logger.info("Global portal storage cleared (\(records.count) records removed)")
    }
}
