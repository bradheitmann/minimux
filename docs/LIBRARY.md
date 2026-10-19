# Library capabilities

The default CLI and full `minimux` module retain every capability. Module
selection is a compile-time adoption boundary, not a runtime feature flag.
Zig 0.16 consumers can select a dependency module in their build:

```zig
const mux = b.dependency("minimux", .{ .target = target });
consumer.addImport("control", mux.module("minimux_control"));
consumer.addImport("proto", mux.module("minimux_proto"));
```

`minimux_proto` contains wire metadata and JSON helpers, without daemon startup.
`minimux_control` depends only on the standard library and libc. It does not
create a listener, spawn a process, or access session files. Its `ControlInbox`
and `DeadlineWriter` are also available as `minimux.control.*`; old
`minimux.daemon.*` aliases remain identical types. `session.sameControlUser`
also remains an alias of `control.sameControlUser`.

The caller owns listener creation, socket permissions, canonical endpoint
identity, and cleanup. Authenticate a connected server with `sameControlUser`
before sending requests. `ControlInbox` authenticates accepted clients, retains
at most 16 pending clients, enforces a 4 MiB request limit and a five-second
absolute deadline, and reads at most 256 KiB per client per tick. Completed
`Request.text` belongs to the caller's allocator; close `Request.stream` and free
that text after handling it. Call `inbox.deinit` to close pending streams.

`DeadlineWriter` owns neither the socket nor its buffer. Its one-second absolute
write deadline begins at the first drain, allowing long-running operations
before a response. The caller must handle write failures and close the stream.
These bounds and same-user authentication are preserved in the full daemon.

Product version 0.2.0 preserves the 0.1.0 protocol and snapshot schema. The
library does not promise compatibility with a different Zig compiler version.

Full and scoped modules may be imported together. The build graph shares one
canonical instance of each module, so values retain the same type identity
through full, scoped, and compatibility exports. An external package regression
at `test/consumer` compiles this composition through `b.dependency`; the release
gate runs it before native session tests.
