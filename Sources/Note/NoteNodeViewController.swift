import AppKit
import OSLog
import SwiftUI

private let noteLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "open-maestri", category: "Note")

// MARK: - Note editor state (@Observable, avoid rebuilding NSHostingView)

@Observable
final class NoteEditorState {
    var isFormatted: Bool = false
    var content: String = ""
    /// The flag that needs to restore focus after mode switching is consumed and cleared by NSViewRepresentable.updateNSView
    var pendingFocusRestore: Bool = false
}

// MARK: - Note node NSViewController

/// Note node NSViewController (wrapped NoteEditingView)
final class NoteNodeViewController: NSViewController {
    let noteId: UUID
    let filePath: String
    let editorState = NoteEditorState()

    /// Title change callback (triggered when the content of the first line changes, used to update node header)
    var onTitleChanged: ((String) -> Void)?

    private var notificationObserver: NSObjectProtocol?
    private var fileChangeObserver: NSObjectProtocol?

    // MARK: - Anti-shake writing status

    /// The current content to be written (nil means there is no content to be refreshed)
    private var pendingSaveContent: String?
    /// Anti-shake task handle, cancel and rebuild to reset 300ms timing
    private var debounceTask: Task<Void, Never>?

    init(noteId: UUID, filePath: String) {
        self.noteId = noteId
        self.filePath = filePath
        super.init(nibName: nil, bundle: nil)
        editorState.content = (try? NoteFileManager.shared.read(filePath: filePath)) ?? ""
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let editingView = NoteEditingView(
            state: editorState,
            filePath: filePath,
            nodeId: noteId
        ) { [weak self] newContent in
            self?.scheduleSave(content: newContent)
        } onFirstLineChanged: { [weak self] title in
            self?.onTitleChanged?(title)
        }

        let host = NSHostingView(rootView: editingView)
        self.view = host

        emitInitialTitle()
        observeFormattedToggle()
        observeFileChange()
    }

    deinit {
        if let obs = notificationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = fileChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        // Immediately write the memory cache to disk when the view is destroyed (executed in the background, without blocking the main thread)
        debounceTask?.cancel()
        if let content = pendingSaveContent {
            let fp = filePath
            DispatchQueue.global(qos: .utility).async {
                try? NoteFileManager.shared.write(filePath: fp, content: content)
            }
        }
    }

    // MARK: - Listen for format switching notifications (from the toolbar)

    private func observeFormattedToggle() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .noteFormattedToggled,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self,
                  let id = notif.userInfo?["nodeId"] as? UUID,
                  id == self.noteId,
                  let isPreviewing = notif.userInfo?["isPreviewing"] as? Bool else { return }
            editorState.isFormatted = isPreviewing
            editorState.pendingFocusRestore = true
        }
    }

    // MARK: - Monitor external file writing (CLI synchronizes editorState when writing)

    private func observeFileChange() {
        fileChangeObserver = NotificationCenter.default.addObserver(
            forName: .noteFileDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self,
                  let changedPath = notif.userInfo?["filePath"] as? String,
                  changedPath == self.filePath,
                  let newContent = notif.userInfo?["content"] as? String,
                  self.editorState.content != newContent else { return }
            self.editorState.content = newContent
        }
    }

    private func emitInitialTitle() {
        let firstLine = editorState.content
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? ""
        let title = firstLine
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
            onTitleChanged?(title)
        }
    }

    // MARK: - Anti-shake disk writing

    /// Anti-shake save: cache the latest content and write to disk in the background thread after no new input for 300ms.
    /// Main thread call (NSTextViewDelegate callback is guaranteed to be on the main thread).
    private func scheduleSave(content: String) {
        pendingSaveContent = content
        // Reset timer
        debounceTask?.cancel()
        let fp = filePath
        debounceTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                // Canceled: Waiting for the next scheduleSave or flushPendingSave
                return
            }
            // ── The main thread has been separated from the main thread and synchronous I/O is performed on the cooperative thread pool ──
            try? NoteFileManager.shared.write(filePath: fp, content: content)
            // Cleanup status (return to main thread)
            await MainActor.run { [weak self] in
                self?.pendingSaveContent = nil
                self?.debounceTask = nil
            }
        }
    }

    /// Immediately flush content to be written to disk (called when the view is hidden).
    /// Cancel the anti-shake task and write asynchronously in the background without blocking the calling thread.
    func flushPendingSave() {
        debounceTask?.cancel()
        debounceTask = nil
        guard let content = pendingSaveContent else { return }
        pendingSaveContent = nil
        let fp = filePath
        Task.detached {
            try? NoteFileManager.shared.write(filePath: fp, content: content)
        }
    }
}
