import AppKit
import SwiftUI

/// Registers the native scroll view used by an Orca proxy so the AppKit canvas
/// can route trackpad and mouse-wheel events into its read-only output.
@MainActor
final class OrcaTerminalScrollViewRegistry {
    static let shared = OrcaTerminalScrollViewRegistry()

    private var scrollViews: [UUID: NSScrollView] = [:]

    private init() {}

    func register(nodeId: UUID, scrollView: NSScrollView) {
        scrollViews[nodeId] = scrollView
    }

    func unregister(nodeId: UUID, ifMatching scrollView: NSScrollView) {
        if scrollViews[nodeId] === scrollView {
            scrollViews.removeValue(forKey: nodeId)
        }
    }

    func scrollView(for nodeId: UUID) -> NSScrollView? {
        scrollViews[nodeId]
    }
}

/// AppKit-backed output view for externally managed Orca terminals.
///
/// Canvas nodes deliberately disable SwiftUI hit testing, so a native scroll
/// view is required for deterministic event routing from CanvasViewportView.
struct OrcaTerminalOutputView: NSViewRepresentable {
    let nodeId: UUID
    let text: String
    let isActive: Bool

    @MainActor
    final class Coordinator {
        let nodeId: UUID
        var lastText = ""

        init(nodeId: UUID) {
            self.nodeId = nodeId
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(nodeId: nodeId)
    }

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        updateBackground(of: scrollView)

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        update(textView: textView, in: scrollView, context: context, followOutput: true)
        OrcaTerminalScrollViewRegistry.shared.register(nodeId: nodeId, scrollView: scrollView)
        return scrollView
    }

    @MainActor
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        updateBackground(of: scrollView)
        guard let textView = scrollView.documentView as? NSTextView,
              context.coordinator.lastText != text else { return }

        let followOutput = context.coordinator.lastText.isEmpty || isScrolledToBottom(scrollView)
        update(textView: textView, in: scrollView, context: context, followOutput: followOutput)
    }

    @MainActor
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        OrcaTerminalScrollViewRegistry.shared.unregister(
            nodeId: coordinator.nodeId,
            ifMatching: scrollView
        )
    }

    @MainActor
    private func update(
        textView: NSTextView,
        in scrollView: NSScrollView,
        context: Context,
        followOutput: Bool
    ) {
        textView.textStorage?.setAttributedString(
            OrcaTerminalTextStyler.attributedString(for: text)
        )
        context.coordinator.lastText = text

        guard followOutput else { return }
        DispatchQueue.main.async { [weak textView] in
            textView?.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleBottom = scrollView.contentView.bounds.maxY
        return visibleBottom >= documentView.bounds.maxY - 8
    }

    private func updateBackground(of scrollView: NSScrollView) {
        let base = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        scrollView.backgroundColor = isActive
            ? NSColor.systemGreen.withAlphaComponent(0.045).blended(withFraction: 0.92, of: base) ?? base
            : base
    }
}

enum OrcaTerminalTextStyler {
    @MainActor
    static func attributedString(for text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor,
        ])

        colorMatches(#"(?m)^\s*\$.*$"#, in: attributed, color: .systemGreen)
        colorMatches(#"\"[^\"\n]+\"(?=\s*:)"#, in: attributed, color: .systemCyan)
        colorMatches(#"(?<=:)\s*\"[^\"\n]*\""#, in: attributed, color: .systemGreen)
        colorMatches(#"\b(true|false|null)\b"#, in: attributed, color: .systemPurple)
        colorMatches(#"(?<![A-Za-z_])-?\d+(?:\.\d+)?"#, in: attributed, color: .systemOrange)
        colorMatches(
            #"(?i)\b(error|failed|failure|block|timeout)\b"#,
            in: attributed,
            color: .systemRed
        )
        colorMatches(
            #"(?i)\b(warning|aviso|waiting|queued|idle)\b"#,
            in: attributed,
            color: .systemOrange
        )
        colorMatches(
            #"(?i)\b(pass|passed|success|succeeded|ok|done|completed|running|working)\b"#,
            in: attributed,
            color: .systemGreen
        )
        colorMatches(
            #"(?m)^\s*(Todos|Tasks?|Output|Results?)\b.*$"#,
            in: attributed,
            color: .systemCyan,
            font: .monospacedSystemFont(ofSize: 11, weight: .semibold)
        )
        return attributed
    }

    @MainActor
    private static func colorMatches(
        _ pattern: String,
        in text: NSMutableAttributedString,
        color: NSColor,
        font: NSFont? = nil
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: text.length)
        for match in expression.matches(in: text.string, range: range) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
            if let font { text.addAttribute(.font, value: font, range: match.range) }
        }
    }
}
