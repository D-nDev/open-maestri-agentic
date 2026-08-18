import SwiftUI
import AppKit

// MARK: - Vibrancy background (NSVisualEffectView bridge)

struct VibrancyBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
    }
}

/// Common shell for all nodes, replacing BaseNodeView (NSView subclass).
/// Provides: background/shadow/rounded corners, Header bar, optional Footer bar, selected blue dotted border, right-click menu.
struct NodeShellView<Content: View, TitleAccessory: View, Accessory: View, Footer: View>: View {
    let nodeId: UUID
    let title: String
    let isSelected: Bool
    let isLocked: Bool
    let isCommunicating: Bool
    let zoom: CGFloat
    let headerIcon: String?
    let headerColor: Color?
    /// Note Node-specific: The theme color applied to the header background and the overall background of the node. Other node types remain nil.
    let themeColor: Color?
    let headerTitleAccessory: TitleAccessory
    let headerAccessory: Accessory
    let footer: Footer
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDuplicate: (() -> Void)?
    var onLockToggle: ((Bool) -> Void)?
    @ViewBuilder let content: () -> Content

    init(
        nodeId: UUID,
        title: String,
        isSelected: Bool,
        isLocked: Bool,
        isCommunicating: Bool = false,
        zoom: CGFloat,
        headerIcon: String?,
        headerColor: Color?,
        themeColor: Color? = nil,
        @ViewBuilder headerTitleAccessory: () -> TitleAccessory = { EmptyView() },
        @ViewBuilder headerAccessory: () -> Accessory = { EmptyView() },
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        onClose: (() -> Void)? = nil,
        onRename: ((String) -> Void)? = nil,
        onDuplicate: (() -> Void)? = nil,
        onLockToggle: ((Bool) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.nodeId = nodeId
        self.title = title
        self.isSelected = isSelected
        self.isLocked = isLocked
        self.isCommunicating = isCommunicating
        self.zoom = zoom
        self.headerIcon = headerIcon
        self.headerColor = headerColor
        self.themeColor = themeColor
        self.headerTitleAccessory = headerTitleAccessory()
        self.headerAccessory = headerAccessory()
        self.footer = footer()
        self.onClose = onClose
        self.onRename = onRename
        self.onDuplicate = onDuplicate
        self.onLockToggle = onLockToggle
        self.content = content
    }

    @Environment(\.dropTargetNodeId) private var dropTargetNodeId

    private var isDropTarget: Bool { dropTargetNodeId == nodeId }

    private var hasFooter: Bool { !(Footer.self == EmptyView.self) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background: vibrancy frosted glass + translucent white overlay + shadow
            RoundedRectangle(cornerRadius: CanvasNodeConstants.cornerRadius)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                .background {
                    VibrancyBackground(material: .popover, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: CanvasNodeConstants.cornerRadius))
                }
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .overlay {
                    if let themeColor {
                        RoundedRectangle(cornerRadius: CanvasNodeConstants.cornerRadius)
                            .fill(themeColor.opacity(0.05))
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: CanvasNodeConstants.cornerRadius)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                }

            VStack(spacing: 0) {
                // Header (fixed 32pt high, aligned with CanvasNodeConstants.headerHeight)
                NodeHeaderSwiftUIView(
                    title: title,
                    icon: headerIcon,
                    color: headerColor,
                    themeColor: themeColor,
                    isLocked: isLocked,
                    titleAccessory: { headerTitleAccessory },
                    accessory: { headerAccessory }
                )
                .frame(height: CanvasNodeConstants.headerHeight)

                Divider().opacity(0.5)

                // Content area (filled with the original canvas size of the node, the content is not affected by zoom)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Footer (optional, only shown when a non-EmptyView is provided)
                if hasFooter {
                    Divider().opacity(0.3)
                    footer
                        .frame(height: CanvasNodeConstants.footerHeight)
                        .frame(maxWidth: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CanvasNodeConstants.cornerRadius))

            // Select blue dotted border
            if isSelected {
                RoundedRectangle(cornerRadius: CanvasNodeConstants.cornerRadius + CanvasNodeConstants.selectionOutset)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .foregroundStyle(.blue)
                    .padding(-CanvasNodeConstants.selectionOutset)
                    .allowsHitTesting(false)
            }

            // Drag and drop target highlight blue solid border
            if isDropTarget {
                RoundedRectangle(cornerRadius: CanvasNodeConstants.cornerRadius)
                    .strokeBorder(Color.blue.opacity(0.8), lineWidth: 2)
                    .allowsHitTesting(false)
            }

        }
        // The right-click menu is handled uniformly by the AppKit layer CanvasViewportView.menu(for:)
        // (SwiftUI .contextMenu never fires because allowsHitTesting(false))
    }
}

/// Header column (title + icon + lock badge + optional accessories)
/// - `titleAccessory`: immediately to the right of title, before Spacer (like character badge)
/// - `accessory`: far right, after Spacer (such as attention dot, Maestro mark)
struct NodeHeaderSwiftUIView<TitleAccessory: View, Accessory: View>: View {
    let title: String
    let icon: String?
    let color: Color?
    /// Note Node-specific: header background overlay color (other nodes pass nil and keep it as is)
    let themeColor: Color?
    let isLocked: Bool
    let titleAccessory: TitleAccessory
    let accessory: Accessory

    init(
        title: String,
        icon: String?,
        color: Color?,
        themeColor: Color? = nil,
        isLocked: Bool,
        @ViewBuilder titleAccessory: () -> TitleAccessory = { EmptyView() },
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self.themeColor = themeColor
        self.isLocked = isLocked
        self.titleAccessory = titleAccessory()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color ?? .primary)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            titleAccessory
            Spacer(minLength: 4)
            accessory
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                VibrancyBackground(material: .sidebar, blendingMode: .behindWindow)
                if let themeColor {
                    themeColor.opacity(0.18)
                }
            }
        }
    }
}

/// Terminal node Footer column (displays the current working directory)
struct TerminalFooterView: View {
    let directory: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(abbreviatedPath)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            VibrancyBackground(material: .sidebar, blendingMode: .behindWindow)
        }
    }

    /// Abbreviate absolute paths to ~/... form
    private var abbreviatedPath: String {
        let home = NSHomeDirectory()
        if directory.hasPrefix(home) {
            return "~" + directory.dropFirst(home.count)
        }
        return directory
    }
}
