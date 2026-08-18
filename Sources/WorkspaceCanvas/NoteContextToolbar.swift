import SwiftUI
import AppKit

// MARK: - Note exclusive floating toolbar

struct NoteContextToolbar: View {
    let nodeId: UUID
    let isFormatted: Bool
    let fontSize: Int
    let currentColor: String

    let onBgColor: (String) -> Void
    let onFontSize: (Int) -> Void
    let onConnect: () -> Void
    let onToggleFormatted: () -> Void
    let onDelete: () -> Void
    let onSaveAs: () -> Void
    var connections: [ToolbarConnectionItem] = []
    var onDeleteConnection: (UUID) -> Void = { _ in }

    @State private var showColorPicker = false
    @State private var showFontSizeMenu = false
    @State private var showHeadingPicker = false
    @State private var currentFontSize: Int = 14

    var body: some View {
        HStack(spacing: 2) {
            // Group 1: Appearance
            colorButton
            fontSizeButton

            toolbarSeparator

            // Group 2: Inline format
            noteButton("bold",        tooltip: "note.toolbar.bold".localized)         { insertWrapping("**", "**") }
            noteButton("italic",      tooltip: "note.toolbar.italic".localized)       { insertWrapping("*",  "*") }
            noteButton("strikethrough", tooltip: "note.toolbar.strikethrough".localized) { insertWrapping("~~", "~~") }
            noteButton("chevron.left.forwardslash.chevron.right",
                       tooltip: "note.toolbar.inline_code".localized)                 { insertWrapping("`", "`") }

            toolbarSeparator

            // Group 3: Block Level Format
            headingButton
            noteButton("checklist",   tooltip: "note.toolbar.task_item".localized)    { insertLinePrefix("- [ ] ") }
            noteButton("list.bullet", tooltip: "note.toolbar.list_item".localized)    { insertLinePrefix("- ") }
            noteButton("curlybraces", tooltip: "note.toolbar.code_block".localized)   { insertCodeBlock() }

            toolbarSeparator

            // Group 4: Media & Operations
            noteButton("photo",              tooltip: "note.toolbar.insert_image".localized) { insertImage() }
            noteButton("doc.on.doc",         tooltip: "note.toolbar.copy_all".localized)    { copyAll() }
            noteButton("square.and.arrow.down", tooltip: "note.toolbar.save_as".localized)  { onSaveAs() }

            toolbarSeparator

            // Group 5: Node Operations
            noteButton("arrow.trianglehead.branch", tooltip: "button.connect".localized) { onConnect() }
            if !connections.isEmpty {
                ConnectionBadgeButton(connections: connections, onDelete: onDeleteConnection)
            }
            noteButton("m.square",
                       tooltip: isFormatted ? "note.toolbar.toggle_format.plain".localized : "note.toolbar.toggle_format.formatted".localized,
                       isActive: isFormatted)                           { onToggleFormatted() }
            noteButton("trash", tooltip: "button.delete".localized, isDestructive: true) { onDelete() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(white: 0.9), lineWidth: 0.5)
        )
    }

    // MARK: - subview

    private var toolbarSeparator: some View {
        Rectangle()
            .fill(Color(white: 0.88))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private var colorButton: some View {
        Button {
            showColorPicker = true
        } label: {
            Circle()
                .fill(NoteColorPickerPopover.colorFromString(currentColor))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color(white: 0.7), lineWidth: 1))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("note.toolbar.background_color".localized)
        .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
            NoteColorPickerPopover(selectedColor: currentColor) { color in
                onBgColor(color)
                showColorPicker = false
            }
        }
    }

    private var fontSizeButton: some View {
        ContextToolbarButton(icon: "textformat.size", tooltip: "settings.terminal.font_size".localized) {
            currentFontSize = fontSize
            showFontSizeMenu = true
        }
        .popover(isPresented: $showFontSizeMenu, arrowEdge: .bottom) {
            NoteFontSizePopover(fontSize: $currentFontSize) { size in
                onFontSize(size)
            }
        }
    }

    private var headingButton: some View {
        ContextToolbarButton(icon: "textformat", tooltip: "note.toolbar.heading".localized) {
            showHeadingPicker = true
        }
        .popover(isPresented: $showHeadingPicker, arrowEdge: .bottom) {
            NoteHeadingPickerPopover { level in
                switch level {
                case 1: insertLinePrefix("# ")
                case 2: insertLinePrefix("## ")
                default: insertLinePrefix("### ")
                }
                showHeadingPicker = false
            }
        }
    }

    @ViewBuilder
    private func noteButton(
        _ icon: String,
        tooltip: String,
        isActive: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        NoteToolbarButton(
            icon: icon,
            tooltip: tooltip,
            isActive: isActive,
            isDestructive: isDestructive,
            action: action
        )
    }

    // MARK: - Formatting operations (delegated to NoteTextViewRegistry)

    private func insertWrapping(_ prefix: String, _ suffix: String) {
        NoteTextViewRegistry.shared.insertWrapping(nodeId: nodeId, prefix: prefix, suffix: suffix)
    }

    private func insertLinePrefix(_ prefix: String) {
        NoteTextViewRegistry.shared.insertLinePrefix(nodeId: nodeId, prefix: prefix)
    }

    private func insertCodeBlock() {
        // Insert a code block and position the cursor on the empty line in the middle
        let text = "```\n\n```"
        NoteTextViewRegistry.shared.insertText(nodeId: nodeId, text: text, cursorOffset: 4)
    }


    private func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { [nodeId] response in
            guard response == .OK, let url = panel.url else { return }
            // Copy the image to the images/ subdirectory of Note, keeping the relative path (consistent with the paste logic)
            Task { @MainActor in
                guard let tv = NoteTextViewRegistry.shared.textView(for: nodeId) else { return }
                // Locate note file path from registry (via associated view of NoteScrollViewRegistry)
                // Unable to get filePath directly, fall back to using file name + absolute path (can be optimized to copy to relative directory in subsequent versions)
                let filename = url.lastPathComponent
                let snippet = "![\(filename)](\(url.path))"
                let range = tv.selectedRange()
                if tv.shouldChangeText(in: range, replacementString: snippet) {
                    tv.replaceCharacters(in: range, with: snippet)
                    tv.didChangeText()
                }
            }
        }
    }

    @MainActor private func copyAll() {
        guard let tv = NoteTextViewRegistry.shared.textView(for: nodeId) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tv.string, forType: .string)
    }
}

// MARK: - Color selection pop-up box

struct NoteColorPickerPopover: View {
    let selectedColor: String
    let onSelect: (String) -> Void

    private let row1: [(name: String, color: Color)] = [
        ("yellow",  Color(red: 0.99, green: 0.97, blue: 0.72)),
        ("pink",    Color(red: 0.96, green: 0.75, blue: 0.80)),
        ("blue",    Color(red: 0.73, green: 0.84, blue: 0.96)),
        ("green",   Color(red: 0.73, green: 0.93, blue: 0.80)),
        ("orange",  Color(red: 0.99, green: 0.84, blue: 0.67)),
        ("purple",  Color(red: 0.87, green: 0.77, blue: 0.96)),
        ("white",   Color(red: 0.97, green: 0.97, blue: 0.97)),
    ]

    private let row2: [(name: String, color: Color)] = [
        ("black",     Color(red: 0.18, green: 0.18, blue: 0.18)),
        ("darkgray",  Color(red: 0.25, green: 0.32, blue: 0.38)),
        ("darkblue",  Color(red: 0.10, green: 0.18, blue: 0.45)),
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(row1, id: \.name) { preset in
                    colorCircle(preset)
                }
            }
            HStack(spacing: 6) {
                ForEach(row2, id: \.name) { preset in
                    colorCircle(preset)
                }
                Spacer()
            }
            Divider()
            Button {
                let panel = NSColorPanel.shared
                panel.showsAlpha = false
                panel.setTarget(nil)
                panel.setAction(nil)
                panel.orderFront(nil)
                NotificationCenter.default.addObserver(
                    forName: NSColorPanel.colorDidChangeNotification,
                    object: panel,
                    queue: .main
                ) { notif in
                    if let p = notif.object as? NSColorPanel {
                        let hex = p.color.hexString
                        onSelect(hex)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 13))
                    Text("note.toolbar.more_colors".localized)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(minWidth: 220)
    }

    private func colorCircle(_ preset: (name: String, color: Color)) -> some View {
        Circle()
            .fill(preset.color)
            .frame(width: 28, height: 28)
            .overlay(
                Circle().strokeBorder(
                    selectedColor == preset.name ? Color.accentColor : Color(white: 0.8),
                    lineWidth: selectedColor == preset.name ? 2 : 1
                )
            )
            .onTapGesture { onSelect(preset.name) }
    }

    /// Convert color string (default name or hex) to Color
    static func colorFromString(_ str: String) -> Color {
        switch str {
        case "yellow":   return Color(red: 0.99, green: 0.97, blue: 0.72)
        case "pink":     return Color(red: 0.96, green: 0.75, blue: 0.80)
        case "blue":     return Color(red: 0.73, green: 0.84, blue: 0.96)
        case "green":    return Color(red: 0.73, green: 0.93, blue: 0.80)
        case "orange":   return Color(red: 0.99, green: 0.84, blue: 0.67)
        case "purple":   return Color(red: 0.87, green: 0.77, blue: 0.96)
        case "white":    return Color(red: 0.97, green: 0.97, blue: 0.97)
        case "black":    return Color(red: 0.18, green: 0.18, blue: 0.18)
        case "darkgray": return Color(red: 0.25, green: 0.32, blue: 0.38)
        case "darkblue": return Color(red: 0.10, green: 0.18, blue: 0.45)
        default:
            if let nsColor = NSColor(hex: str) {
                return Color(nsColor: nsColor)
            }
            return Color(red: 0.99, green: 0.97, blue: 0.72)
        }
    }
}

// MARK: - Font size adder and subtractor popup

struct NoteFontSizePopover: View {
    @Binding var fontSize: Int
    let onConfirm: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                let newSize = max(10, fontSize - 1)
                fontSize = newSize
                onConfirm(newSize)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("\(fontSize)")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(minWidth: 32, alignment: .center)

            Button {
                let newSize = min(32, fontSize + 1)
                fontSize = newSize
                onConfirm(newSize)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Title level selection pop-up box

struct NoteHeadingPickerPopover: View {
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headingRow("# Heading 1",   level: 1, size: 20, weight: .bold)
            headingRow("## Heading 2",  level: 2, size: 16, weight: .semibold)
            headingRow("### Heading 3", level: 3, size: 13, weight: .medium)
        }
        .padding(6)
        .frame(minWidth: 160)
    }

    private func headingRow(_ label: String, level: Int, size: CGFloat, weight: Font.Weight) -> some View {
        Button { onSelect(level) } label: {
            Text(label)
                .font(.system(size: size, weight: weight))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Note toolbar button (supports active / destructive state)

struct NoteToolbarButton: View {
    let icon: String
    let tooltip: String
    var isActive: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(backgroundFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            HoverTrackingView { hovering in
                isHovered = hovering
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard !Task.isCancelled else { return }
                        showTooltip = true
                    }
                } else {
                    hoverTask?.cancel()
                    showTooltip = false
                }
            }
        )
        .overlay(alignment: .bottom) {
            if showTooltip {
                Text(tooltip)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.15))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(white: 0.88), lineWidth: 0.5)
                    )
                    .fixedSize()
                    .offset(y: 36)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    .zIndex(1000)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showTooltip)
    }

    private var iconColor: Color {
        if isDestructive && isHovered { return .red }
        if isActive { return .accentColor }
        return isHovered ? Color(white: 0.15) : Color(white: 0.35)
    }

    private var backgroundFill: Color {
        if isDestructive && isHovered { return .red.opacity(0.08) }
        if isActive { return .accentColor.opacity(0.12) }
        return isHovered ? Color.black.opacity(0.05) : Color.clear
    }
}
