# Orca external terminal integration

This fork keeps Orca as the terminal authority while open-maestri acts as the
visual control plane. The first integration slice exposes a bounded bridge
through the existing `omaestri` IPC:

```bash
omaestri orca list
omaestri orca list --environment my-vps
omaestri orca read term_abc --cursor 42 --limit 1000
omaestri orca send term_abc "Reread the connected specification" --mode queue
omaestri orca send term_abc "Stop and reread the specification" --mode interrupt
```

## Delivery semantics

- `queue` is the default. It waits for Orca's `tui-idle` state and sends the
  message only after the current model turn has finished.
- `interrupt` is explicit. It requests Orca's interrupt-style input before
  delivering the message and must not be used for automatic note updates.
- Terminal handles are runtime-scoped. Call `list` again after an Orca restart
  or a `terminal_handle_stale` error.
- `--environment` targets an Orca environment such as a configured VPS.

The bridge invokes the Orca CLI with an argument array, never through a shell,
so note text is not evaluated as a command.

## Next slice

Add a runtime-only external terminal binding and canvas node adapter without
changing the Maestri-compatible `workspace.json` schema. That adapter will map
Agentic OS worker events to Orca handles, stream output using cursors, and use
the queue above to deliver note-change notifications.
