import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Note ScrollView Registry

/// Global registry: nodeId → NSScrollView (for canvas routing scroll events)
final class NoteScrollViewRegistry {
    static let shared = NoteScrollViewRegistry()
    private var scrollViews: [UUID: NSScrollView] = [:]
    private let lock = NSLock()
    private init() {}

    func register(nodeId: UUID, scrollView: NSScrollView) {
        lock.lock(); defer { lock.unlock() }
        scrollViews[nodeId] = scrollView
    }

    func unregister(nodeId: UUID, ifMatching scrollView: NSScrollView) {
        lock.lock(); defer { lock.unlock() }
        if scrollViews[nodeId] === scrollView {
            scrollViews.removeValue(forKey: nodeId)
        }
    }

    func scrollView(for nodeId: UUID) -> NSScrollView? {
        lock.lock(); defer { lock.unlock() }
        return scrollViews[nodeId]
    }
}

// MARK: - Note NSTextView registry (used for toolbar formatting operations)

/// Global registry: nodeId → NSTextView, the toolbar button obtains NSTextView through this registry and performs formatted insertion
final class NoteTextViewRegistry {
    static let shared = NoteTextViewRegistry()
    private var textViews: [UUID: NSTextView] = [:]
    private let lock = NSLock()
    private init() {}

    func register(nodeId: UUID, textView: NSTextView) {
        lock.lock(); defer { lock.unlock() }
        textViews[nodeId] = textView
    }

    /// Only log out when the `textView` itself is stored in the registry to prevent the new view from being accidentally deleted by the dismantleNSView of the old view after registration.
    func unregister(nodeId: UUID, ifMatching textView: NSTextView) {
        lock.lock(); defer { lock.unlock() }
        if textViews[nodeId] === textView {
            textViews.removeValue(forKey: nodeId)
        }
    }

    func textView(for nodeId: UUID) -> NSTextView? {
        lock.lock(); defer { lock.unlock() }
        return textViews[nodeId]
    }

    /// Insert markdown wrapping syntax (such as **text**) in the selected range; if it is not selected, place the cursor in the middle after inserting
    @MainActor func insertWrapping(nodeId: UUID, prefix: String, suffix: String) {
        guard let tv = textView(for: nodeId) else { return }
        let range = tv.selectedRange()
        let selectedText = (tv.string as NSString).substring(with: range)
        let replacement = selectedText.isEmpty
            ? "\(prefix)\(suffix)"
            : "\(prefix)\(selectedText)\(suffix)"
        if tv.shouldChangeText(in: range, replacementString: replacement) {
            tv.replaceCharacters(in: range, with: replacement)
            tv.didChangeText()
            if selectedText.isEmpty {
                let cursorPos = range.location + prefix.utf16.count
                tv.setSelectedRange(NSRange(location: cursorPos, length: 0))
            }
        }
    }

    /// Insert a prefix at the beginning of the selected line (title # / list - / to-do - [ ], etc.)
    @MainActor func insertLinePrefix(nodeId: UUID, prefix: String) {
        guard let tv = textView(for: nodeId) else { return }
        let str = tv.string as NSString
        let range = tv.selectedRange()
        let lineStart = str.lineRange(for: NSRange(location: range.location, length: 0)).location
        let insertRange = NSRange(location: lineStart, length: 0)
        if tv.shouldChangeText(in: insertRange, replacementString: prefix) {
            tv.replaceCharacters(in: insertRange, with: prefix)
            tv.didChangeText()
        }
    }

    /// Update font size of NSTextView (monospaced font)
    @MainActor func setFontSize(nodeId: UUID, size: Int) {
        guard let tv = textView(for: nodeId) else { return }
        tv.font = .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    /// Insert original text at cursor and move cursor to end
    @MainActor func insertText(nodeId: UUID, text: String, cursorOffset: Int? = nil) {
        guard let tv = textView(for: nodeId) else { return }
        let range = tv.selectedRange()
        if tv.shouldChangeText(in: range, replacementString: text) {
            tv.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            let newPos = range.location + (cursorOffset ?? text.utf16.count)
            tv.setSelectedRange(NSRange(location: newPos, length: 0))
        }
    }
}

// MARK: - Tree-aware ScrollView (viewDidMoveToWindow callback)

/// onWindowAttached called on viewDidMoveToWindow (first time window is non-nil)
final class NoteAwareScrollView: NSScrollView {
    var onWindowAttached: (() -> Void)?
    private var hasAttached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasAttached else { return }
        hasAttached = true
        onWindowAttached?()
    }
}

// MARK: - Note text editor that supports pasting images

/// Text editor wrapped in AppKit, supports pasting images from the clipboard
/// Image saved to `imagesDir` in PNG format and inserted with `![filename](relative_path)` syntax
struct NoteImagePasteTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// The directory where Note is located (the image storage subdirectory `images/` is located in this directory)
    let noteFilePath: String
    /// Node ID (used to register the ScrollView to the global registry)
    var nodeId: UUID? = nil
    /// Content change callback
    var onChange: ((String) -> Void)? = nil
    /// First line change callback
    var onFirstLineChanged: ((String) -> Void)? = nil
    /// Focus change callback
    var onFocusChanged: ((Bool) -> Void)? = nil
    /// Called when view joins window hierarchy (viewDidMoveToWindow), textView can accept focus
    var onWindowAttached: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NoteAwareScrollView {
        let scrollView = NoteAwareScrollView()
        let textView = NSTextView()

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.string = text
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(
            width: scrollView.frame.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 4, height: 8)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        context.coordinator.textView = textView

        if let nodeId {
            NoteScrollViewRegistry.shared.register(nodeId: nodeId, scrollView: scrollView)
            NoteTextViewRegistry.shared.register(nodeId: nodeId, textView: textView)
        }

        // Add the view to the window hierarchy before grabbing the focus (only then will makeFirstResponder succeed)
        scrollView.onWindowAttached = onWindowAttached
        return scrollView
    }

    static func dismantleNSView(_ nsView: NoteAwareScrollView, coordinator: Coordinator) {
        guard let nodeId = coordinator.parent.nodeId,
              let textView = coordinator.textView else { return }
        NoteScrollViewRegistry.shared.unregister(nodeId: nodeId, ifMatching: nsView)
        NoteTextViewRegistry.shared.unregister(nodeId: nodeId, ifMatching: textView)
    }

    func updateNSView(_ scrollView: NoteAwareScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only update when external changes occur to prevent the cursor from jumping.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let safeRange = NSRange(location: min(selected.location, textView.string.utf16.count), length: 0)
            textView.setSelectedRange(safeRange)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteImagePasteTextEditor
        weak var textView: NSTextView?

        init(parent: NoteImagePasteTextEditor) {
            self.parent = parent
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newText = textView.string
            parent.text = newText
            parent.onChange?(newText)
            // First line title
            emitFirstLine(newText)
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged?(false)
        }

        // MARK: - Paste interception

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSText.paste(_:)) {
                return handlePaste(in: textView)
            }
            return false
        }

        // MARK: - Image pasting processing

        private func handlePaste(in textView: NSTextView) -> Bool {
            let pasteboard = NSPasteboard.general
            // Check pictures first
            if pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier]) {
                if let image = NSImage(pasteboard: pasteboard) {
                    insertImage(image, into: textView)
                    return true
                }
            }
            // Other types are pasted by default.
            return false
        }

        private func insertImage(_ image: NSImage, into textView: NSTextView) {
            // Generate unique file name
            let filename = "image-\(UUID().uuidString.prefix(8)).png"
            let noteDir = URL(fileURLWithPath: parent.noteFilePath).deletingLastPathComponent()
            let imagesDir = noteDir.appendingPathComponent("images")

            do {
                try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                let imageURL = imagesDir.appendingPathComponent(filename)

                // Export to PNG
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let pngData = bitmap.representation(using: .png, properties: [:]) else {
                    return
                }
                try pngData.write(to: imageURL)

                // Insert Markdown syntax (relative path)
                let relPath = "images/\(filename)"
                let markdownSnippet = "![\(filename)](\(relPath))"

                let range = textView.selectedRange()
                if textView.shouldChangeText(in: range, replacementString: markdownSnippet) {
                    textView.replaceCharacters(in: range, with: markdownSnippet)
                    textView.didChangeText()
                }
            } catch {
                // Downgrade to default paste when insert fails
                textView.paste(nil)
            }
        }

        // MARK: - First line title extraction

        private func emitFirstLine(_ text: String) {
            let firstLine = text
                .components(separatedBy: "\n")
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                ?? ""
            let title = firstLine
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                parent.onFirstLineChanged?(title)
            }
        }
    }
}
