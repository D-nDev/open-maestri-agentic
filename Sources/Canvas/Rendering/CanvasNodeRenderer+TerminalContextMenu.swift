import AppKit

// MARK: - Terminal Context Menu Handlers

extension CanvasNodeRenderer {

    /// Clear buffer: send clear command to terminal (emulates ⌘K behavior)
    func handleClearBuffer(terminalId: UUID) {
        guard let ws = currentWorkspace,
              let node = ws.nodes.first(where: { $0.id == terminalId }),
              case .terminal(let tc) = node.content else { return }
        // Directly clear the terminal screen through provider
        if let provider = TerminalManager.shared.providers[tc.id],
           let tv = provider.terminalView {
            // Send ANSI to clear screen + reset cursor (equivalent to clear command effect)
            tv.getTerminal().resetToInitialState()
            tv.getTerminal().updateFullScreen()
        }
    }

    /// Reload terminal: restart PTY process
    func handleReloadTerminal(terminalId: UUID) {
        guard let ws = currentWorkspace,
              let node = ws.nodes.first(where: { $0.id == terminalId }),
              case .terminal(let tc) = node.content else { return }
        if tc.agentType == "orca_external" {
            Task { @MainActor in
                await OrcaTerminalRegistry.shared.refresh(nodeId: terminalId)
            }
            return
        }
        if let provider = TerminalManager.shared.providers[tc.id] {
            provider.restartProcess(command: tc.command, workingDirectory: tc.workingDirectory)
        }
    }

    /// Copy the visible content of the terminal to the clipboard
    func handleCopyTerminal(terminalId: UUID) {
        guard let ws = currentWorkspace,
              let node = ws.nodes.first(where: { $0.id == terminalId }),
              case .terminal(let tc) = node.content else { return }
        if tc.agentType == "orca_external" {
            let text = OrcaTerminalRegistry.shared.state(for: terminalId)?.output.joined(separator: "\n") ?? ""
            if !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
        if let session = TerminalManager.shared.terminals[tc.id] {
            let text = session.recentOutput(lines: 200)
            if !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    /// Switch monitoring activity
    func handleToggleMonitor(terminalId: UUID) {
        guard let ws = currentWorkspace,
              let idx = ws.nodes.firstIndex(where: { $0.id == terminalId }),
              case .terminal(var tc) = ws.nodes[idx].content else { return }
        tc.monitorWithOmbro.toggle()
        ws.nodes[idx].content = .terminal(tc)
        NotificationCenter.default.post(
            name: .canvasNodeContentChanged,
            object: nil,
            userInfo: ["nodeId": terminalId, "content": NodeContent.terminal(tc)]
        )
        saveWorkspace()
    }
}
