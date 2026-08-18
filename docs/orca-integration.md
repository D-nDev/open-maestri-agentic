# Orca external terminal integration

This fork keeps Orca as the terminal authority while open-maestri acts as the
visual control plane. Terminals created by the Agentic OS workflow are discovered
through their worker metadata and rendered as live canvas nodes without changing
the Maestri-compatible `workspace.json` schema. Unrelated interactive Orca shells
are intentionally ignored.

## Runtime architecture

1. `OrcaTerminalRegistry` polls the local Orca runtime and every connected saved
   environment.
2. A workspace-scoped sidecar stores stable terminal identity, runtime handle,
   cursor, Agentic OS metadata, and connected-note hashes.
3. The canvas node streams bounded incremental output and displays environment,
   branch, role, model, and current status.
4. A runtime restart is reconciled by stable identity. Stale handles become
   `reconnecting` until Orca publishes the replacement.
5. Agentic OS `worker_started`, `worker_status`, and `worker_done` events restore
   the coordinator/subagent tree and create parent-child canvas connections.

All canvas mutations happen on the main actor. Sidecar writes are debounced and
atomic through `PersistenceManager`.

## Canvas controls

Select an Orca node to expose these controls:

- **Refresh** reads terminal output immediately.
- **Queue message** waits for `tui-idle`, then delivers the message.
- **Interrupt and send** explicitly interrupts the current model turn.
- **Connect** creates normal Maestri canvas connections.

The external node lifecycle is read-only in Open Maestri. It has no local delete
action because Orca is authoritative; the proxy disappears as part of the Orca
reconciliation lifecycle instead of being locally hidden and recreated.
Terminals created directly inside Open Maestri retain their normal close and
delete controls.

When a connected note changes, the app queues a delimited snapshot directly to
the Orca terminal. The snapshot is hash-deduplicated, debounced, and capped at
24,000 characters. This works even though an external Orca process does not
inherit the internal `MAESTRI_SOCKET`.

## Local and VPS environments

The local Orca runtime needs no configuration. Register a remote Orca server
with the Orca CLI, for example:

```bash
orca environment add --help
orca environment list --json
```

The registry discovers saved environments from `orca environment list` and
polls each independently. A failing VPS uses exponential backoff and does not
prevent local terminals from updating. Environment names are shown on every
node so identical worktrees on different hosts remain distinguishable.

## Agentic OS workflow

Set this in both `spec.md` and the compiled `task.yaml`:

```yaml
orchestration:
  subagents:
    required: true
    visualize_in_orca: true
```

The coordinator can then call:

```bash
~/.agentic-os/scripts/agentic-subagent.sh spawn \
  --task-id my-task \
  --worker-id backend \
  --role "Backend engineer" \
  --prompt "Review and implement the HTTP contract."
```

The helper creates an Orca Run, a root coordinator task, a child task, and a
separate supervised Orca terminal. Open Maestri consumes both the Orca runtime
and Agentic OS events to render the resulting tree.

## CLI bridge

Native Maestri terminals can also use the bounded bridge through `omaestri`:

```bash
omaestri orca list
omaestri orca list --environment my-vps
omaestri orca read term_abc --cursor 42 --limit 1000
omaestri orca send term_abc "Reread the connected specification" --mode queue
omaestri orca send term_abc "Stop and reread the specification" --mode interrupt
```

The bridge invokes the Orca CLI with an argument array, never through a shell,
so note or prompt text is not evaluated as a command. Terminal handles are
runtime-scoped; the automatic registry normally performs recovery, while CLI
consumers should list again after `terminal_handle_stale`.

## Verification

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash scripts/build-maestri.sh
```

The final UI check is manual: open a workspace whose working directory matches
an active Orca worktree, confirm that the mirrored node appears, exercise queue
and interrupt deliberately, connect a note, and restart Orca to verify handle
reconciliation.
