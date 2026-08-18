import SwiftUI
import AppKit
import WebKit

/// SwiftUI wrapper for PortalWebView
struct PortalRepresentable: NSViewRepresentable {
    let portalId: UUID
    let url: String

    func makeNSView(context: Context) -> PortalWebView {
        let view = PortalWebView()
        view.configure(portalId: portalId, url: url)
        return view
    }

    func updateNSView(_ nsView: PortalWebView, context: Context) {}
}
