import Foundation
import WebKit

/// Portal accessibility tree building (for omaestri portal snapshot)
final class PortalSnapshotService {
    static let shared = PortalSnapshotService()
    private init() {}

    /// Build accessibility tree (returns @e1, @e2 element references)
    func buildAccessibilityTree(for webView: WKWebView) async -> String {
        let js = """
        (function() {
            const elements = document.querySelectorAll('a,button,input,select,textarea,[role]');
            return Array.from(elements).slice(0, 50).map((el, i) => {
                const tag = el.tagName.toLowerCase();
                const text = (el.textContent || el.value || el.placeholder || el.getAttribute('aria-label') || '').trim().slice(0, 40);
                return `@e${i+1} [${tag}] ${text}`;
            }).join('\\n');
        })();
        """
        return (try? await webView.evaluateJavaScript(js) as? String) ?? ""
    }
}
