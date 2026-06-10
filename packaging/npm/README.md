# @bradheitmann/minimux

npm distribution of [minimux](https://github.com/bradheitmann/minimux): a
daemon for agent-owned PTY sessions with crash-recoverable terminal state.

Installing this package downloads the prebuilt binary for your platform from
the matching GitHub release, verifies its published SHA-256 checksum, and
exposes it as the `minimux` command.

```bash
npm install -g @bradheitmann/minimux
minimux --json system.health
```

Supported platforms: macOS and Linux on arm64 and x64. The package version is
pinned to the minimux release it installs.

See the [project README](https://github.com/bradheitmann/minimux) for the API
surface, recovery semantics, and orchestrator examples. License: Apache-2.0.
