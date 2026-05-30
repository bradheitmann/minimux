# Examples

`prototype.sh` is the checked first-contact path used by the documentation
slice.

```bash
bash examples/prototype.sh --check
```

The script:

- builds `zig-out/bin/minimux` when the binary is missing
- creates an isolated `MINIMUX_STATE_DIR`
- starts a managed shell with `run`
- sends input with `send`
- waits with `wait-idle`
- snapshots live state
- kills the daemon process
- snapshots recovered state

Set `MINIMUX_BIN` to test a different binary:

```bash
MINIMUX_BIN=/path/to/minimux bash examples/prototype.sh --check
```

The script exits non-zero when any JSON field does not match the documented
path.
