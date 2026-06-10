#!/usr/bin/env node
// Orchestrator-seat example: drive minimux from Node the way a scheduler,
// dispatch executor, or harness manager would. Zero dependencies.
//
// Usage:
//   node examples/orchestrator-client.mjs
//   MINIMUX_BIN=/path/to/minimux node examples/orchestrator-client.mjs
//
// The script exits non-zero when any step does not match the documented
// contract, so it doubles as an end-to-end check of the orchestrator path:
// session.create -> pane.create(argv, env, cwd) -> agent.wait_idle ->
// pane.snapshot -> pane.send -> kill-shot -> recovered session snapshot.

import { execFile } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const BIN = process.env.MINIMUX_BIN ?? "zig-out/bin/minimux";
const SESSION = "mx-orch";

async function rpc(args, { allowFailure = false } = {}) {
  try {
    const { stdout } = await run(BIN, args, { env: process.env });
    return JSON.parse(stdout.trim().split("\n").pop());
  } catch (error) {
    if (allowFailure && error.stdout) {
      return JSON.parse(error.stdout.trim().split("\n").pop());
    }
    throw error;
  }
}

function check(condition, label) {
  if (!condition) {
    console.error(`FAIL ${label}`);
    process.exitCode = 1;
    throw new Error(label);
  }
  console.log(`ok ${label}`);
}

const stateDir = mkdtempSync(join(tmpdir(), "minimux-orch-"));
process.env.MINIMUX_STATE_DIR = stateDir;

try {
  const created = await rpc(["run", "--name", SESSION, "--", "sh"]);
  check(created.ok && created.result.daemon_pid > 0, "session.create");

  const pane = await rpc([
    "pane", "create", "--session", SESSION,
    "--cwd", tmpdir(), "--env", "ORCH_PROBE=mx-ok", "--json",
    "--", "sh", "-c", 'echo "probe=$ORCH_PROBE"; sleep 600',
  ]);
  check(pane.ok && pane.result.pane.local_id === "pane-1", "pane.create argv+env+cwd");

  const idle = await rpc([
    "agent", "wait-idle", `${SESSION}:pane-1`, "--timeout-ms", "5000", "--json",
  ]);
  check(idle.ok && idle.result.state === "idle", "agent.wait_idle pane quiescence");

  const snap = await rpc(["pane", "snapshot", `${SESSION}:pane-1`, "--json"]);
  check(
    snap.ok && snap.result.snapshot.visible_text.includes("probe=mx-ok"),
    "pane.snapshot reflects argv env without a send",
  );

  const sent = await rpc(["send", SESSION, "printf 'orchestrated\\n'<CR>"]);
  check(sent.ok && sent.result.stdout.includes("orchestrated"), "pane.send session shell");

  const shellIdle = await rpc(["wait-idle", SESSION, "--timeout-ms", "5000"]);
  check(shellIdle.ok && shellIdle.result.state === "idle", "agent.wait_idle shell queue drained");

  const closed = await rpc(["pane", "close", `${SESSION}:pane-1`, "--json"]);
  check(closed.ok && closed.result.pane.state === "closed", "pane.close stops the child");

  const attach = await rpc(["attach", SESSION, "--json"]);
  const daemonPid = attach.result.session.daemon_pid;
  process.kill(daemonPid, "SIGKILL");
  await new Promise((resolve) => setTimeout(resolve, 300));

  const recovered = await rpc(["snapshot", SESSION, "--json"]);
  check(recovered.ok && recovered.result.recovery.state === "recovered", "recovery state after kill-shot");
  check(
    recovered.result.recovery.notifications.includes("SESSION_RECOVERED"),
    "SESSION_RECOVERED notification",
  );
  check(
    recovered.result.visible_text.includes("orchestrated"),
    "terminal state survived the daemon crash",
  );

  console.log("PASS examples/orchestrator-client.mjs");
} finally {
  await rpc(["terminate", SESSION, "--json"], { allowFailure: true }).catch(() => {});
  rmSync(stateDir, { recursive: true, force: true });
}
