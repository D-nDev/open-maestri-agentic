import AppKit

/// Canvas background layer (lattice/solid color/transparent), replaces CanvasViewportView.drawLineGrid.
/// Use CGPattern to implement grid drawing: each tile only draws one grid unit, and Core Graphics automatically tiles it.
/// Only the pattern phase offset (O(1)) is updated when pan is used, and the pattern is rebuilt when zoom changes.
final class CanvasBackground: NSView {
    override var isFlipped: Bool { true }

    var canvasOrigin: CGPoint = .zero { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1.0 {
        didSet {
            if oldValue != zoom {
                cachedPattern = nil  // The tile size changes when zoom changes, and the pattern needs to be rebuilt.
            }
            needsDisplay = true
        }
    }
    var backgroundMode: String = "dotGrid" {
        didSet {
            cachedPattern = nil
            needsDisplay = true
        }
    }

    /// Cache the CGPattern under the current zoom to avoid rebuilding every frame
    private var cachedPattern: CGPattern?
    private var cachedPatternZoom: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch backgroundMode {
        case "dotGrid":
            drawLineGridWithPattern(in: dirtyRect)
        case "solid":
            NSColor(white: 0.98, alpha: 1).setFill()
            dirtyRect.fill()
        case "transparent":
            NSColor.clear.setFill()
            dirtyRect.fill()
        default:
            drawLineGridWithPattern(in: dirtyRect)
        }
    }

    // MARK: - CGPattern grid drawing

    private func drawLineGridWithPattern(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // White background
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)

        let gridSpacing = Constants.canvasGridSpacing * zoom

        // If gridSpacing is too small (zoom is very small), skip grid drawing to avoid performance issues
        guard gridSpacing >= 4.0 else { return }

        // Build or reuse patterns
        let pattern: CGPattern
        if let cached = cachedPattern, cachedPatternZoom == zoom {
            pattern = cached
        } else {
            guard let newPattern = makeGridPattern(tileSize: gridSpacing) else { return }
            cachedPattern = newPattern
            cachedPatternZoom = zoom
            pattern = newPattern
        }

        // Calculate pattern phase: implement pan following through offset
        // phase causes pattern to move with canvasOrigin
        let phaseX = -(canvasOrigin.x * zoom).truncatingRemainder(dividingBy: gridSpacing)
        let phaseY = -(canvasOrigin.y * zoom).truncatingRemainder(dividingBy: gridSpacing)

        // Drawing using pattern color space
        var alpha: CGFloat = 1.0
        let patternSpace = CGColorSpace(patternBaseSpace: nil)!
        ctx.setFillColorSpace(patternSpace)
        ctx.setFillPattern(pattern, colorComponents: &alpha)
        ctx.setPatternPhase(CGSize(width: phaseX, height: phaseY))
        ctx.fill(rect)
    }

    /// Create a tileSize × tileSize grid pattern tile
    /// Tile content: right edge vertical line + bottom edge horizontal line (to form a complete grid after tiles)
    private func makeGridPattern(tileSize: CGFloat) -> CGPattern? {
        var callbacks = CGPatternCallbacks(
            version: 0,
            drawPattern: { info, ctx in
                guard let info else { return }
                let size = info.load(as: CGFloat.self)
                let lineWidth = Constants.canvasGridLineWidth
                let color = Constants.canvasGridLineColor.cgColor

                ctx.setStrokeColor(color)
                ctx.setLineWidth(lineWidth)

                // Draw a vertical line on the right edge of the tile
                ctx.move(to: CGPoint(x: size, y: 0))
                ctx.addLine(to: CGPoint(x: size, y: size))

                // Draw tile bottom edge horizontal line
                ctx.move(to: CGPoint(x: 0, y: size))
                ctx.addLine(to: CGPoint(x: size, y: size))

                ctx.strokePath()
            },
            releaseInfo: { info in
                info?.deallocate()
            }
        )

        // Pass tileSize to callback
        let infoPtr = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<CGFloat>.size, alignment: MemoryLayout<CGFloat>.alignment)
        infoPtr.storeBytes(of: tileSize, as: CGFloat.self)

        let patternBounds = CGRect(x: 0, y: 0, width: tileSize, height: tileSize)

        return CGPattern(
            info: infoPtr,
            bounds: patternBounds,
            matrix: .identity,
            xStep: tileSize,
            yStep: tileSize,
            tiling: .constantSpacing,
            isColored: true,
            callbacks: &callbacks
        )
    }
}
