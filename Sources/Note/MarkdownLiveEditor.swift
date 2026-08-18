import AppKit
import SwiftUI

/// Editable, real-time rendering Markdown style editor
/// Use MarkdownTextStorage to achieve instant highlighting during input, and the content is synchronized in both directions through Binding<String>
struct MarkdownLiveEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = NSFont.systemFontSize
    var nodeId: UUID? = nil
    var onChange: ((String) -> Void)? = nil
    /// Called when view joins window hierarchy (viewDidMoveToWindow), textView can accept focus
    var onWindowAttached: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NoteAwareScrollView {
        let textStorage = MarkdownTextStorage()
        textStorage.fontSize = fontSize

        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        // isRichText cannot be set to false: custom NSTextStorage will set rich text properties,
        // false will cause NSTextView to refuse to process strings with attributes, causing input to fail.
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.delegate = context.coordinator

        if !text.isEmpty {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }

        let scrollView = NoteAwareScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        // textView must configure min/maxSize before documentView is set,
        // Otherwise NSScrollView cannot correctly adjust documentView frame based on content height
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.textStorage = textStorage

        if let nodeId {
            NoteScrollViewRegistry.shared.register(nodeId: nodeId, scrollView: scrollView)
            NoteTextViewRegistry.shared.register(nodeId: nodeId, textView: textView)
        }

        scrollView.onWindowAttached = onWindowAttached
        return scrollView
    }

    func updateNSView(_ scrollView: NoteAwareScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let ts = textView.textStorage as? MarkdownTextStorage else { return }
        ts.fontSize = fontSize
        // Only respond to external (CLI/file synchronization) writes, ignoring callbacks triggered by user input
        guard !context.coordinator.isEditing, textView.string != text else { return }
        let sel = textView.selectedRange()
        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: text)
        let safeRange = NSRange(location: min(sel.location, ts.length), length: 0)
        textView.setSelectedRange(safeRange)
    }

    static func dismantleNSView(_ nsView: NoteAwareScrollView, coordinator: Coordinator) {
        guard let nodeId = coordinator.parent.nodeId,
              let textView = coordinator.textView else { return }
        NoteScrollViewRegistry.shared.unregister(nodeId: nodeId, ifMatching: nsView)
        NoteTextViewRegistry.shared.unregister(nodeId: nodeId, ifMatching: textView)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownLiveEditor
        weak var textView: NSTextView?
        weak var textStorage: MarkdownTextStorage?
        /// True when the user is typing, preventing updateNSView from interfering
        var isEditing = false

        init(parent: MarkdownLiveEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            textStorage?.updateCursorLine(-1)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newText = tv.string
            updateCursorLine(in: tv)
            parent.text = newText
            parent.onChange?(newText)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            updateCursorLine(in: tv)
        }

        private func updateCursorLine(in tv: NSTextView) {
            let pos = tv.selectedRange().location
            let str = tv.string as NSString
            guard str.length > 0 else {
                textStorage?.updateCursorLine(0)
                return
            }
            let safePos = min(pos, str.length - 1)
            let lineRange = str.lineRange(for: NSRange(location: safePos, length: 0))
            let prefix = str.substring(to: lineRange.location)
            let line = prefix.components(separatedBy: "\n").count - 1
            textStorage?.updateCursorLine(line)
        }
    }
}
