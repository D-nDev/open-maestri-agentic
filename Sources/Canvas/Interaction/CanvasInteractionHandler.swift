import AppKit
import WebKit

// MARK: - CanvasViewportView mouse event handling

extension CanvasViewportView {

    // MARK: - Unified mouse event handling

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        // 0. Stroke control point priority hit detection (must be selected and has the highest priority)
        for node in currentNodes.reversed() {
            guard selectedNodeIds.contains(node.id),
                  case .stroke(let sc) = node.content,
                  let frame = nodeCanvasFrames[node.id] else { continue }
            let screenFrame = canvasRectToScreen(frame)
            var candidates: [(role: String, pt: CGPoint)] = [
                ("start", CGPoint(x: screenFrame.minX + sc.startPoint.x * screenFrame.width,
                                   y: screenFrame.minY + sc.startPoint.y * screenFrame.height)),
                ("end",   CGPoint(x: screenFrame.minX + sc.endPoint.x * screenFrame.width,
                                   y: screenFrame.minY + sc.endPoint.y * screenFrame.height)),
            ]
            if let cp = sc.controlPoint {
                candidates.append(("control",
                    CGPoint(x: screenFrame.minX + cp.x * screenFrame.width,
                             y: screenFrame.minY + cp.y * screenFrame.height)))
            }
            for (role, pt) in candidates {
                if hypot(loc.x - pt.x, loc.y - pt.y) < 8 {
                    interaction = .draggingStrokePoint(node.id, pointRole: role, startContent: sc, startFrame: frame)
                    return
                }
            }
        }

        // 1. Space+click → pan mode
        if isSpaceHeld {
            interaction = .panCanvas(startOrigin: canvasOrigin, startMouse: loc)
            NSCursor.closedHand.set()
            return
        }

        // 2. Connection mode: Click on the node to establish a connection, click on the blank space to cancel
        if isInConnectingMode {
            let hit = hitTestCanvas(at: loc)
            if case .nodeHeader(let id) = hit {
                handleConnectionClick(nodeId: id)
            } else if case .nodeFooter(let id) = hit {
                handleConnectionClick(nodeId: id)
            } else if case .nodeContent(let id, _) = hit {
                handleConnectionClick(nodeId: id)
            } else {
                deactivateConnectionMode()
            }
            return
        }

        // Compatible: Program-triggered connection starting point
        if connectingFromNodeId != nil {
            let hit = hitTestCanvas(at: loc)
            if case .nodeHeader(let id) = hit {
                handleConnectionClick(nodeId: id)
                return
            } else if case .nodeFooter(let id) = hit {
                handleConnectionClick(nodeId: id)
                return
            } else if case .nodeContent(let id, _) = hit {
                handleConnectionClick(nodeId: id)
                return
            } else {
                connectingFromNodeId = nil
                connectionDragPoint = nil
                needsDisplay = true
                return
            }
        }

        // 3. Node drawing mode: start drawing in blank area
        if isInDrawingMode {
            let hit = hitTestCanvas(at: loc)
            if case .canvas = hit {
                if isStrokeDrawing {
                    interaction = .drawingStroke(start: loc)
                } else if isFreehandDrawing {
                    interaction = .drawingFreehand(points: [loc])
                } else {
                    interaction = .drawing(start: loc)
                }
                drawingLastSnappedRect = nil
                return
            }
            // Click on a node in drawing mode → fall through normal node interaction
        }

        // 4. Semantic hit testing → distribution
        let hit = hitTestCanvas(at: loc)
        switch hit {
        case .canvas:
            if !event.modifierFlags.contains(.command) {
                selectedNodeIds.removeAll()
            }
            window?.makeFirstResponder(self)
            interaction = .marquee(start: loc)
            marqueeCurrentPoint = nil

        case .nodeHeader(let id), .nodeFooter(let id):
            guard !isNodeLocked(id) else { return }
            updateSelection(id, modifiers: event.modifierFlags)
            let startFrame = nodeCanvasFrames[id] ?? .zero
            interaction = .mayDragNode(id, startMouse: loc, startFrame: startFrame, contentTarget: nil)

        case .nodeContent(let id, _):
            guard !isNodeLocked(id) else { return }
            let wasAlreadySelected = selectedNodeIds.contains(id)
            updateSelection(id, modifiers: event.modifierFlags)
            // Send activation notification (focus terminal, etc.)
            NotificationCenter.default.post(
                name: .canvasNodeActivated,
                object: nil,
                userInfo: ["nodeId": id]
            )
            // shape node
            if let node = currentNodes.first(where: { $0.id == id }),
               case .shape = node.content {
                // Click again when selected → enter editing state
                // NSTextView is always registered in ShapeTextViewRegistry and directly forwards mouseDown after coordinate correction.
                // Position the cursor by NSTextView itself (exactly the same as the Note node processing path)
                if wasAlreadySelected,
                   let tv = ShapeTextViewRegistry.shared.textView(for: id) {
                    // ShapeTextEditor always exists, tv is always registered, no need to wait for SwiftUI updates.
                    // 1. Send notification first to let SwiftUI set isEditing=true (trigger @State changes synchronously)
                    NotificationCenter.default.post(
                        name: .shapeNodeShouldBeginEditing,
                        object: nil,
                        userInfo: ["nodeId": id, "selectAll": false]
                    )
                    // 2. Next runloop tick: SwiftUI updateNSView has isEditable=true,
                    //    Forward mouseDown to position the cursor with correct coordinates
                    let correctedLocation = correctedWindowLocationForShapeTextView(for: event, nodeId: id, textView: tv)
                    let capturedEvent = event
                    DispatchQueue.main.async {
                        tv.window?.makeFirstResponder(tv)
                        if let syntheticEvent = NSEvent.mouseEvent(
                            with: .leftMouseDown,
                            location: correctedLocation,
                            modifierFlags: capturedEvent.modifierFlags,
                            timestamp: capturedEvent.timestamp,
                            windowNumber: capturedEvent.windowNumber,
                            context: nil,
                            eventNumber: capturedEvent.eventNumber,
                            clickCount: capturedEvent.clickCount,
                            pressure: capturedEvent.pressure
                        ) {
                            tv.mouseDown(with: syntheticEvent)
                        }
                    }
                    return
                }
                // Unchecked or None NSTextView: Go Normal mayDragNode
                let startFrame = nodeCanvasFrames[id] ?? .zero
                interaction = .mayDragNode(id, startMouse: loc, startFrame: startFrame, contentTarget: nil)
                return
            }
            // If the node is already selected, route mouse events to the terminal view (supports text selection)
            if wasAlreadySelected,
               let provider = TerminalManager.shared.providers[id],
               let terminalView = provider.terminalView {
                interaction = .contentInteraction(id, contentTarget: terminalView)
                // Coordinate correction: SwiftUI's .scaleEffect(zoom) scales nodes through CALayer transform,
                // But NSView.convert(_:from:) does not consider layer transform, causing SwiftTerm to
                // calculateMouseHit calculates wrong row and column positions.
                // Correction plan: Calculate the correct local coordinates inside the terminal view by yourself, and then synthesize one
                // Make SwiftTerm convert give correct results for locationInWindow.
                let correctedLocation = correctedWindowLocation(for: event, nodeId: id, terminalView: terminalView)
                if let syntheticEvent = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: correctedLocation,
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: event.clickCount,
                    pressure: event.pressure
                ) {
                    terminalView.mouseDown(with: syntheticEvent)
                }
                window?.makeFirstResponder(terminalView)
            }
            // Note Node: Set NSTextView as first responder and send coordinate-corrected mouseDown.
            // Do not use contentInteraction and let the AppKit native response chain handle subsequent drag/up events.
            // Avoid recursive crash with manual forwarding in mouseDragged.
            if let node = currentNodes.first(where: { $0.id == id }),
               case .stickyNote = node.content {
                guard let tv = NoteTextViewRegistry.shared.textView(for: id) else { return }
                window?.makeFirstResponder(tv)
                let correctedLocation = correctedWindowLocationForTextView(for: event, nodeId: id, textView: tv)
                if let syntheticEvent = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: correctedLocation,
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: event.clickCount,
                    pressure: event.pressure
                ) {
                    tv.mouseDown(with: syntheticEvent)
                }
                // interaction remains idle, and subsequent drag/up is directly routed to NSTextView by the AppKit response chain
            }
            // Portal node: Determine whether to focus the URL input box or WebView based on the click position
            if let node = currentNodes.first(where: { $0.id == id }),
               case .portal = node.content {
                let screenFrame = canvasRectToScreen(node.frame)
                let localY = loc.y - screenFrame.minY
                // Navigation bar area (about 40px * zoom after header)
                let navBarBottom = (CanvasNodeConstants.headerHeight + 40) * zoom
                if localY <= navBarBottom,
                   let urlField = PortalWebViewStore.shared.urlTextField(for: id) {
                    window?.makeFirstResponder(urlField)
                } else if let webView = PortalWebViewStore.shared.webView(for: id) {
                    // WebView area: The first click is routed to WKWebView (no need to select first and click again)
                    interaction = .contentInteraction(id, contentTarget: webView)
                    let correctedLocation = correctedWindowLocationForWebView(for: event, nodeId: id, webView: webView)
                    if let syntheticEvent = NSEvent.mouseEvent(
                        with: .leftMouseDown,
                        location: correctedLocation,
                        modifierFlags: event.modifierFlags,
                        timestamp: event.timestamp,
                        windowNumber: event.windowNumber,
                        context: nil,
                        eventNumber: event.eventNumber,
                        clickCount: event.clickCount,
                        pressure: event.pressure
                    ) {
                        webView.mouseDown(with: syntheticEvent)
                    }
                    window?.makeFirstResponder(webView)
                }
            }
            // freehand node: click in the content area → start dragging (no text editing, can be dragged directly)
            if let node = currentNodes.first(where: { $0.id == id }),
               case .freehand = node.content {
                let startFrame = nodeCanvasFrames[id] ?? .zero
                interaction = .mayDragNode(id, startMouse: loc, startFrame: startFrame, contentTarget: nil)
                return
            }
            // Stroke node: Click in the content area → start dragging (control point dragging has been processed at the top of mouseDown)
            if let node = currentNodes.first(where: { $0.id == id }),
               case .stroke = node.content {
                let startFrame = nodeCanvasFrames[id] ?? .zero
                interaction = .mayDragNode(id, startMouse: loc, startFrame: startFrame, contentTarget: nil)
                return
            }

        case .nodeRotateHandle(let id):
            guard !isNodeLocked(id) else { return }
            guard let node = currentNodes.first(where: { $0.id == id }),
                  case .shape(let sc) = node.content else { return }
            let screenFrame = canvasRectToScreen(node.frame)
            let nodeCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
            let dx = loc.x - nodeCenter.x
            let dy = loc.y - nodeCenter.y
            let startAngle = atan2(dy, dx) - sc.rotation
            updateSelection(id, modifiers: event.modifierFlags)
            interaction = .rotatingNode(id, startAngle: startAngle, nodeCenter: nodeCenter)

        case .nodeResize(let id, let edge):
            guard !isNodeLocked(id) else { return }
            updateSelection(id, modifiers: event.modifierFlags)
            let canvasFrame = nodeCanvasFrames[id] ?? .zero
            let startFrame = canvasRectToScreen(canvasFrame)
            interaction = .resizingNode(id, edge: edge, startFrame: startFrame, startMouse: loc)
            edge.cursor.set()
        }
    }

    // MARK: - Drag handling

    private static let dragThreshold: CGFloat = 3.0

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        switch interaction {

        // --- Canvas translation ---
        case .panCanvas(let startOrigin, let startMouse):
            let dx = (loc.x - startMouse.x) / zoom
            let dy = (loc.y - startMouse.y) / zoom
            canvasOrigin = CGPoint(x: startOrigin.x - dx, y: startOrigin.y - dy)
            needsLayout = true
            notifyViewportChanged()

        // --- Waiting for judgment (click or drag) ---
        case .mayDragNode(let id, let startMouse, let startFrame, let contentTarget):
            let dx = loc.x - startMouse.x
            let dy = loc.y - startMouse.y
            let dist = sqrt(dx * dx + dy * dy)
            guard dist >= Self.dragThreshold else { return }
            // Security check: There must be a physical left button pressed to prevent accidental touches when scrolling with two fingers on the trackpad
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }

            // Option+drag → trigger node copying instead of moving
            if event.modifierFlags.contains(.option) {
                interaction = .idle
                onDuplicateNode?(id)
                return
            }

            // If mouseDown has been transparently transmitted to the content area, send synthesized mouseUp to cancel its internal state.
            if let target = contentTarget {
                if let cancelEvent = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: event.locationInWindow,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: event.windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: 1,
                    pressure: 0
                ) {
                    target.mouseUp(with: cancelEvent)
                }
            }
            // Return focus to the canvas when dragging starts to prevent content views such as NSTextView from consuming events during dragging
            window?.makeFirstResponder(self)

            // Switch to real drag
            let canvasMouse = screenToCanvas(startMouse)
            if selectedNodeIds.count > 1 && selectedNodeIds.contains(id) {
                var startFrames: [UUID: CGRect] = [:]
                for sid in selectedNodeIds {
                    startFrames[sid] = nodeCanvasFrames[sid] ?? .zero
                }
                interaction = .batchDragging(startFrames, primaryId: id, startMouse: canvasMouse)
            } else {
                interaction = .draggingNode(id, startMouse: canvasMouse, startFrame: startFrame)
            }
            // Process first frame drag immediately (recursive call)
            mouseDragged(with: event)

        // --- Single node drag ---
        case .draggingNode(let id, let startMouse, let startFrame):
            let currentCanvas = screenToCanvas(loc)
            let rawDX = currentCanvas.x - startMouse.x
            let rawDY = currentCanvas.y - startMouse.y
            var newOrigin = CGPoint(x: startFrame.origin.x + rawDX, y: startFrame.origin.y + rawDY)
            var newFrame = CGRect(origin: newOrigin, size: startFrame.size)

            let otherFrames = nodeCanvasFrames.filter { $0.key != id }.map { $0.value }
            if event.modifierFlags.contains(.command) {
                let (snapped, guidelines) = TileSnapping.snap(draggingFrame: newFrame, against: otherFrames)
                let snapActive = snapped != newOrigin
                newOrigin = snapped
                newFrame = CGRect(origin: newOrigin, size: startFrame.size)
                dragGuidelines = guidelines
                if snapActive && !lastSnapActive {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                lastSnapActive = snapActive
            } else {
                let (nodeSnapped, guidelines) = TileSnapping.snap(draggingFrame: newFrame, against: otherFrames)
                let nodeSnapActive = nodeSnapped != newOrigin
                if nodeSnapActive {
                    newOrigin = nodeSnapped
                    dragGuidelines = guidelines
                    if !lastSnapActive {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    lastSnapActive = true
                } else {
                    dragGuidelines = []
                    let gridSnapped = snapToGrid(newOrigin, size: startFrame.size)
                    let gridChanged = gridSnapped != lastSnappedGridOrigin
                    newOrigin = gridSnapped
                    if gridChanged && lastSnappedGridOrigin != nil {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    }
                    lastSnappedGridOrigin = gridSnapped
                    lastSnapActive = false
                }
                newFrame = CGRect(origin: newOrigin, size: startFrame.size)
            }

            nodeCanvasFrames[id] = newFrame
            updateNodeFrameInPlace(id: id, frame: newFrame)
            needsLayout = true
            // Notify Wire Physics Engine: Endpoint has moved
            onNodeFramesDuringDrag?([id])

        // --- Batch drag ---
        case .batchDragging(let startFrames, let primaryId, let startMouse):
            let currentCanvas = screenToCanvas(loc)
            let rawDX = currentCanvas.x - startMouse.x
            let rawDY = currentCanvas.y - startMouse.y

            guard let primaryStart = startFrames[primaryId] else { return }
            let primaryRaw = CGRect(
                origin: CGPoint(x: primaryStart.origin.x + rawDX, y: primaryStart.origin.y + rawDY),
                size: primaryStart.size
            )
            let otherFrames = nodeCanvasFrames.filter { !startFrames.keys.contains($0.key) }.map { $0.value }
            let (snapped, guidelines) = TileSnapping.snap(draggingFrame: primaryRaw, against: otherFrames)
            let finalDX = snapped.x - primaryStart.origin.x
            let finalDY = snapped.y - primaryStart.origin.y
            dragGuidelines = guidelines
            let snapActive = snapped != primaryRaw.origin
            if snapActive && !lastSnapActive {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            lastSnapActive = snapActive

            var updatedFrames: [UUID: CGRect] = [:]
            for (sid, sFrame) in startFrames {
                let newOrigin = CGPoint(x: sFrame.origin.x + finalDX, y: sFrame.origin.y + finalDY)
                let newFrame = CGRect(origin: newOrigin, size: sFrame.size)
                nodeCanvasFrames[sid] = newFrame
                updatedFrames[sid] = newFrame
            }
            updateNodeFramesInPlace(frames: updatedFrames)
            needsLayout = true
            // Notification to Wired Physics Engine: Multiple endpoints moved
            onNodeFramesDuringDrag?(Set(startFrames.keys))

        // --- Resize ---
        case .resizingNode(let id, let edge, let startFrame, let startMouse):
            guard nodeCanvasFrames[id] != nil else { return }
            let dx = loc.x - startMouse.x
            let dy = loc.y - startMouse.y
            applyResizeOnCanvas(id: id, edge: edge, dx: dx, dy: dy, startFrame: startFrame)

        // --- Rotation ---
        case .rotatingNode(let id, let startAngle, let nodeCenter):
            let dx = loc.x - nodeCenter.x
            let dy = loc.y - nodeCenter.y
            let currentAngle = atan2(dy, dx)
            let newRotation = currentAngle - startAngle
            // Post notification for WorkspaceCanvasView to update ShapeContent.rotation
            NotificationCenter.default.post(
                name: .shapeNodeRotationChanged,
                object: nil,
                userInfo: ["nodeId": id, "rotation": newRotation]
            )

        // --- Frame selection ---
        case .marquee(let start):
            marqueeCurrentPoint = loc
            let rect = CGRect(
                x: min(start.x, loc.x),
                y: min(start.y, loc.y),
                width: abs(loc.x - start.x),
                height: abs(loc.y - start.y)
            )
            snapGuideView?.selectionRect = rect
            needsDisplay = true

        // --- stroke node drawing mode (line/arrow) ---
        case .drawingStroke(let start):
            drawingCurrentPoint = loc
            snapGuideView?.strokePreviewPath = (start: start, end: loc, type: drawingNodeType)
            needsDisplay = true

        // --- freehand node drawing mode (free pen, sampling interval 4pt) ---
        case .drawingFreehand(var pts):
            let last = pts.last ?? loc
            let dx = loc.x - last.x
            let dy = loc.y - last.y
            if dx * dx + dy * dy > 16 {
                pts.append(loc)
                interaction = .drawingFreehand(points: pts)
            }
            drawingCurrentPoint = loc
            // Pass the current accumulated points (if the current points are not appended, append them to ensure that the preview follows the hand in real time)
            let previewPts = pts.last == loc ? pts : pts + [loc]
            snapGuideView?.freehandPreviewPoints = previewPts
            needsDisplay = true

        // --- Node drawing mode (grid adsorption + haptic) ---
        case .drawing(let start):
            drawingCurrentPoint = loc

            // Convert the starting point and current point to canvas coordinates and snap to the grid
            let grid = Constants.canvasGridSpacing
            let canvasStart = screenToCanvas(start)
            let canvasCurrent = screenToCanvas(loc)

            let snappedStartX = (canvasStart.x / grid).rounded() * grid
            let snappedStartY = (canvasStart.y / grid).rounded() * grid
            let snappedCurrentX = (canvasCurrent.x / grid).rounded() * grid
            let snappedCurrentY = (canvasCurrent.y / grid).rounded() * grid

            let snappedCanvasRect = CGRect(
                x: min(snappedStartX, snappedCurrentX),
                y: min(snappedStartY, snappedCurrentY),
                width: abs(snappedCurrentX - snappedStartX),
                height: abs(snappedCurrentY - snappedStartY)
            )

            // Detect grid crossing: trigger haptic feedback when rectangle changes
            if let lastRect = drawingLastSnappedRect, lastRect != snappedCanvasRect {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
            drawingLastSnappedRect = snappedCanvasRect

            // Convert the adsorbed canvas rectangle back to screen coordinates for drawing preview
            let screenOrigin = canvasToScreen(snappedCanvasRect.origin)
            let screenRect = CGRect(
                x: screenOrigin.x,
                y: screenOrigin.y,
                width: snappedCanvasRect.width * zoom,
                height: snappedCanvasRect.height * zoom
            )
            snapGuideView?.drawingRect = screenRect
            needsDisplay = true

        // --- Content area interaction (terminal text selection/WebView click and drag, etc.) ---
        case .contentInteraction(let id, let contentTarget):
            let correctedLocation: CGPoint
            if contentTarget is WKWebView {
                correctedLocation = correctedWindowLocationForWebView(for: event, nodeId: id, webView: contentTarget)
            } else {
                correctedLocation = correctedWindowLocation(for: event, nodeId: id, terminalView: contentTarget)
            }
            if let syntheticEvent = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: correctedLocation,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
            ) {
                contentTarget.mouseDragged(with: syntheticEvent)
            }

        // --- stroke control point drag ---
        case .draggingStrokePoint(let id, let role, let origContent, let startFrame):
            let canvasLoc = screenToCanvas(loc)

            if role == "control" {
                // Drag Bezier control point: frame follows expansion, start/end canvas absolute coordinates remain unchanged
                let absStart = CGPoint(
                    x: startFrame.minX + origContent.startPoint.x * startFrame.width,
                    y: startFrame.minY + origContent.startPoint.y * startFrame.height
                )
                let absEnd = CGPoint(
                    x: startFrame.minX + origContent.endPoint.x * startFrame.width,
                    y: startFrame.minY + origContent.endPoint.y * startFrame.height
                )
                let absControl = canvasLoc
                let padding: CGFloat = 20
                let newMinX = min(absStart.x, absEnd.x, absControl.x) - padding
                let newMinY = min(absStart.y, absEnd.y, absControl.y) - padding
                let newMaxX = max(absStart.x, absEnd.x, absControl.x) + padding
                let newMaxY = max(absStart.y, absEnd.y, absControl.y) + padding
                let newFrame = CGRect(x: newMinX, y: newMinY,
                                     width: newMaxX - newMinX,
                                     height: newMaxY - newMinY)
                let nw = newFrame.width
                let nh = newFrame.height
                var updated = origContent
                updated.startPoint   = CGPoint(x: nw > 0 ? (absStart.x   - newMinX) / nw : 0.5,
                                               y: nh > 0 ? (absStart.y   - newMinY) / nh : 0.5)
                updated.endPoint     = CGPoint(x: nw > 0 ? (absEnd.x     - newMinX) / nw : 0.5,
                                               y: nh > 0 ? (absEnd.y     - newMinY) / nh : 0.5)
                updated.controlPoint = CGPoint(x: nw > 0 ? (absControl.x - newMinX) / nw : 0.5,
                                               y: nh > 0 ? (absControl.y - newMinY) / nh : 0.5)
                nodeCanvasFrames[id] = newFrame
                let newContent = NodeContent.stroke(updated)
                NotificationCenter.default.post(
                    name: .canvasNodeContentChanged,
                    object: nil,
                    userInfo: ["nodeId": id, "content": newContent, "frame": newFrame]
                )
            } else {
                // Drag start/end: only the normalized coordinates are updated, the frame remains unchanged
                let w = startFrame.width
                let h = startFrame.height
                let normalized = CGPoint(
                    x: w > 0 ? (canvasLoc.x - startFrame.minX) / w : 0.5,
                    y: h > 0 ? (canvasLoc.y - startFrame.minY) / h : 0.5
                )
                var updated = origContent
                switch role {
                case "start": updated.startPoint = normalized
                case "end":   updated.endPoint   = normalized
                default: break
                }
                let newContent = NodeContent.stroke(updated)
                NotificationCenter.default.post(
                    name: .canvasNodeContentChanged,
                    object: nil,
                    userInfo: ["nodeId": id, "content": newContent]
                )
            }

        // --- idle (connection tool tracking) ---
        case .idle:
            if connectingFromNodeId != nil {
                connectionDragPoint = loc
                needsDisplay = true
            }
        }
    }

    // MARK: - mouseUp

    override func mouseUp(with event: NSEvent) {
        defer {
            interaction = .idle
            lastSnapActive = false
            lastSnappedGridOrigin = nil
        }

        switch interaction {

        case .mayDragNode(let id, _, _, let contentTarget):
            // No drag occurred = click, node activation notification sent
            NotificationCenter.default.post(
                name: .canvasNodeActivated,
                object: nil,
                userInfo: ["nodeId": id]
            )
            // text node: Click again when selected → enter editing state
            if selectedNodeIds.contains(id),
               let node = currentNodes.first(where: { $0.id == id }),
               case .text = node.content {
                NotificationCenter.default.post(
                    name: .textNodeShouldBeginEditing,
                    object: nil,
                    userInfo: ["nodeId": id]
                )
            }
            // Shape node editing state trigger has been moved to mouseDown (NSTextView is always registered and directly forwards coordinate correction events)
            // Click on a node that is already in the multi-select set → narrow to single selection
            if selectedNodeIds.count > 1 && selectedNodeIds.contains(id) {
                selectedNodeIds = [id]
            }

        case .draggingNode(let id, _, _):
            dragGuidelines = []
            if let finalFrame = nodeCanvasFrames[id] {
                onNodeDragEnded?(id, finalFrame)
            }

        case .batchDragging(let startFrames, _, _):
            dragGuidelines = []
            var finalFrames: [UUID: CGRect] = [:]
            for id in startFrames.keys {
                if let f = nodeCanvasFrames[id] { finalFrames[id] = f }
            }
            onBatchNodeDragEnded?(finalFrames)

        case .resizingNode(let id, _, _, _):
            NSCursor.arrow.set()
            if let finalFrame = nodeCanvasFrames[id] {
                onNodeResizeEnded?(id, finalFrame)
            }

        case .rotatingNode(let id, _, _):
            NotificationCenter.default.post(
                name: .shapeNodeRotationDidEnd,
                object: nil,
                userInfo: ["nodeId": id]
            )

        case .marquee(let start):
            if let current = marqueeCurrentPoint {
                let rect = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
                if rect.width > 4 || rect.height > 4 {
                    let canvasRect = screenRectToCanvas(rect)
                    let hitIds = Set(nodeCanvasFrames.compactMap { (id, frame) in
                        frame.intersects(canvasRect) ? id : nil
                    })
                    selectedNodeIds = hitIds
                }
            }
            marqueeCurrentPoint = nil
            snapGuideView?.selectionRect = nil
            needsDisplay = true

        case .drawingStroke(let start):
            let canvasStart = screenToCanvas(start)
            guard let current = drawingCurrentPoint else {
                snapGuideView?.strokePreviewPath = nil
                needsDisplay = true
                break
            }
            let canvasCurrent = screenToCanvas(current)
            let dx = canvasCurrent.x - canvasStart.x
            let dy = canvasCurrent.y - canvasStart.y
            let dist = sqrt(dx * dx + dy * dy)
            if dist >= 10 {
                let minX = min(canvasStart.x, canvasCurrent.x)
                let minY = min(canvasStart.y, canvasCurrent.y)
                let maxX = max(canvasStart.x, canvasCurrent.x)
                let maxY = max(canvasStart.y, canvasCurrent.y)
                let padding: CGFloat = max(CGFloat(UserDefaults.standard.double(forKey: "drawingDefaultStrokeWidth")), 4)
                let boundingRect = CGRect(
                    x: minX - padding, y: minY - padding,
                    width: (maxX - minX) + padding * 2,
                    height: (maxY - minY) + padding * 2
                )
                NotificationCenter.default.post(
                    name: .strokeNodeDrawn,
                    object: nil,
                    userInfo: [
                        "nodeType": drawingNodeType,
                        "startPoint": canvasStart,
                        "endPoint": canvasCurrent,
                        "frame": boundingRect
                    ]
                )
            }
            drawingCurrentPoint = nil
            snapGuideView?.strokePreviewPath = nil
            needsDisplay = true

        case .drawingFreehand(let pts):
            // Clear freehand preview
            snapGuideView?.freehandPreviewPoints = []
            guard pts.count >= 2 else {
                drawingCurrentPoint = nil
                snapGuideView?.freehandPreviewPoints = nil
                needsDisplay = true
                break
            }
            let canvasPts = pts.map { screenToCanvas($0) }
            guard let minX = canvasPts.map(\.x).min(),
                  let minY = canvasPts.map(\.y).min(),
                  let maxX = canvasPts.map(\.x).max(),
                  let maxY = canvasPts.map(\.y).max() else {
                drawingCurrentPoint = nil
                snapGuideView?.freehandPreviewPoints = nil
                interaction = .idle
                needsDisplay = true
                break
            }
            let padding: CGFloat = 8
            let boundingRect = CGRect(
                x: minX - padding, y: minY - padding,
                width: (maxX - minX) + padding * 2,
                height: (maxY - minY) + padding * 2
            )
            let normalized = canvasPts.map { pt in
                CGPoint(
                    x: boundingRect.width > 0 ? (pt.x - boundingRect.minX) / boundingRect.width : 0.5,
                    y: boundingRect.height > 0 ? (pt.y - boundingRect.minY) / boundingRect.height : 0.5
                )
            }
            onFreehandDrawn?(drawingNodeType, normalized, boundingRect)
            drawingCurrentPoint = nil
            snapGuideView?.freehandPreviewPoints = nil
            needsDisplay = true

        case .drawing(let start):
            // Create nodes using rectangles after grid adsorption
            let grid = Constants.canvasGridSpacing
            let canvasStart = screenToCanvas(start)
            let canvasCurrent = screenToCanvas(drawingCurrentPoint ?? start)

            let snappedStartX = (canvasStart.x / grid).rounded() * grid
            let snappedStartY = (canvasStart.y / grid).rounded() * grid
            let snappedCurrentX = (canvasCurrent.x / grid).rounded() * grid
            let snappedCurrentY = (canvasCurrent.y / grid).rounded() * grid

            let snappedRect = CGRect(
                x: min(snappedStartX, snappedCurrentX),
                y: min(snappedStartY, snappedCurrentY),
                width: abs(snappedCurrentX - snappedStartX),
                height: abs(snappedCurrentY - snappedStartY)
            )

            if drawingNodeType == "text" {
                // text node: Created on click, centered on click point using default dimensions
                let defaultSize = defaultNodeSize(for: drawingNodeType)
                let canvasRect = CGRect(
                    x: snappedStartX - defaultSize.width / 2,
                    y: snappedStartY - defaultSize.height / 2,
                    width: defaultSize.width,
                    height: defaultSize.height
                )
                onNodeDrawn?(drawingNodeType, canvasRect)
            } else if snappedRect.width > 20 && snappedRect.height > 20 {
                // Remaining nodes: must be dragged over 20pt to create
                onNodeDrawn?(drawingNodeType, snappedRect)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            drawingCurrentPoint = nil
            drawingLastSnappedRect = nil
            snapGuideView?.drawingRect = nil
            needsDisplay = true

        case .contentInteraction(let id, let contentTarget):
            let correctedLocation: CGPoint
            if contentTarget is WKWebView {
                correctedLocation = correctedWindowLocationForWebView(for: event, nodeId: id, webView: contentTarget)
            } else {
                correctedLocation = correctedWindowLocation(for: event, nodeId: id, terminalView: contentTarget)
            }
            if let syntheticEvent = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: correctedLocation,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
            ) {
                contentTarget.mouseUp(with: syntheticEvent)
            }

        case .draggingStrokePoint(let id, let role, let origContent, let startFrame):
            let loc2 = convert(event.locationInWindow, from: nil)
            let canvasLoc2 = screenToCanvas(loc2)

            var finalContent = origContent
            var finalFrame: CGRect? = nil

            if role == "control" {
                let absStart = CGPoint(
                    x: startFrame.minX + origContent.startPoint.x * startFrame.width,
                    y: startFrame.minY + origContent.startPoint.y * startFrame.height
                )
                let absEnd = CGPoint(
                    x: startFrame.minX + origContent.endPoint.x * startFrame.width,
                    y: startFrame.minY + origContent.endPoint.y * startFrame.height
                )
                let absControl = canvasLoc2
                let padding: CGFloat = 20
                let newMinX = min(absStart.x, absEnd.x, absControl.x) - padding
                let newMinY = min(absStart.y, absEnd.y, absControl.y) - padding
                let newMaxX = max(absStart.x, absEnd.x, absControl.x) + padding
                let newMaxY = max(absStart.y, absEnd.y, absControl.y) + padding
                let newFrame = CGRect(x: newMinX, y: newMinY,
                                     width: newMaxX - newMinX,
                                     height: newMaxY - newMinY)
                let nw = newFrame.width
                let nh = newFrame.height
                finalContent.startPoint   = CGPoint(x: nw > 0 ? (absStart.x   - newMinX) / nw : 0.5,
                                                    y: nh > 0 ? (absStart.y   - newMinY) / nh : 0.5)
                finalContent.endPoint     = CGPoint(x: nw > 0 ? (absEnd.x     - newMinX) / nw : 0.5,
                                                    y: nh > 0 ? (absEnd.y     - newMinY) / nh : 0.5)
                finalContent.controlPoint = CGPoint(x: nw > 0 ? (absControl.x - newMinX) / nw : 0.5,
                                                    y: nh > 0 ? (absControl.y - newMinY) / nh : 0.5)
                finalFrame = newFrame
            } else {
                let w = startFrame.width
                let h = startFrame.height
                let normalized = CGPoint(
                    x: w > 0 ? (canvasLoc2.x - startFrame.minX) / w : 0.5,
                    y: h > 0 ? (canvasLoc2.y - startFrame.minY) / h : 0.5
                )
                switch role {
                case "start": finalContent.startPoint = normalized
                case "end":   finalContent.endPoint   = normalized
                default: break
                }
            }

            var userInfo: [String: Any] = ["nodeId": id, "content": NodeContent.stroke(finalContent)]
            if let f = finalFrame { userInfo["frame"] = f }
            NotificationCenter.default.post(
                name: .strokePointDragDidEnd,
                object: nil,
                userInfo: userInfo
            )

        case .panCanvas:
            if isSpaceHeld { NSCursor.openHand.set() } else { NSCursor.arrow.set() }

        case .idle:
            break
        }
    }

    // MARK: - mouseMoved

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        // Wiring Tools: Track mouse position
        if connectingFromNodeId != nil {
            connectionDragPoint = loc
            needsDisplay = true
        }

        // Cursor: Set based on hit area
        if isSpaceHeld {
            NSCursor.openHand.set()
            return
        }
        switch hitTestCanvas(at: loc) {
        case .nodeResize(_, let edge):
            edge.cursor.set()
        case .nodeRotateHandle:
            NSCursor.crosshair.set()
        case .nodeHeader, .nodeFooter, .nodeContent, .canvas:
            NSCursor.arrow.set()
        }
    }

}
