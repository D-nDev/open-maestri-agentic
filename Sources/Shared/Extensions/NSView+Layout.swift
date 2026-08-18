import AppKit

extension NSView {
    /// Constrain the four sides of the subview to the edges of the superview (translatesAutoresizingMaskIntoConstraints has been set to false before calling)
    func pinEdges(to parent: NSView) {
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    /// Add subview to parent view and fix four sides (automatically set translatesAutoresizingMaskIntoConstraints = false)
    func addSubviewFillingBounds(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
        subview.pinEdges(to: self)
    }
}
