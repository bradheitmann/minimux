# minimux Adapter Boundary

minimux adapters translate adjacent systems into the daemon's existing session,
pane, snapshot, tap, and wait primitives. They do not choose where work belongs
in a product, keep durable task records, enforce a container boundary, or draw
an operator-facing terminal.

## CustomPaneBackend

The CustomPaneBackend surface is intentionally small:

- `initialize` maps to `system.health`
- `spawn_agent` maps to `session.create`
- `write` maps to `pane.send`
- `capture` maps to `pane.snapshot`
- `kill` maps to `session.terminate`
- `list` maps to `session.list`
- `context_output` maps to `tap.open`
- `context_exited` maps to `agent.wait_idle`

The adapter can report a protocol manifest and method bindings. It does not own
agent memory, retry policy, task records, sandbox enforcement, or human terminal
rendering.

## Substrate Placement

Substrate placement is a switch beneath minimux. The built-in descriptors are:

- `baremetal`
- `docker`

Each placement descriptor exposes `spawn`, `attach`, `kill`, `wait`, and
`network_proxy`. The descriptor returns a plan for where the minimux daemon and
agent command should run; it does not implement the surrounding platform.

## Validation

Run:

```bash
zig build -Dtest-filter=adapter test --summary all
rg -n "<adapter-boundary-denylist>" src/minimux/adapters docs/adapters.md
```

The second command should return no matches.
