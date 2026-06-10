#!/usr/bin/env node
// Thin shim: executes the platform binary staged by scripts/install.js,
// forwarding argv, stdio, exit code, and termination signal.
"use strict";

const { spawnSync } = require("node:child_process");
const { existsSync } = require("node:fs");
const path = require("node:path");

const binary = path.join(__dirname, "..", "vendor", "minimux");

if (!existsSync(binary)) {
  console.error(
    "minimux: platform binary is missing. The install step was probably " +
      "skipped (--ignore-scripts). Run: node " +
      path.join(__dirname, "..", "scripts", "install.js"),
  );
  process.exit(1);
}

const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status ?? 1);
