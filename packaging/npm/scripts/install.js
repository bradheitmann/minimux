#!/usr/bin/env node
// Downloads the prebuilt minimux binary for this platform from the GitHub
// release matching the package version, verifies its published SHA-256, and
// stages it under vendor/ for the bin shim. No runtime dependencies.
"use strict";

const { createHash } = require("node:crypto");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");

const pkg = require("../package.json");

const TARGETS = {
  "darwin arm64": "aarch64-macos",
  "darwin x64": "x86_64-macos",
  "linux arm64": "aarch64-linux",
  "linux x64": "x86_64-linux",
};

const target = TARGETS[`${process.platform} ${process.arch}`];
if (!target) {
  console.error(
    `minimux: unsupported platform ${process.platform}/${process.arch}. ` +
      "Prebuilt binaries cover darwin/linux on arm64/x64; build from source instead: " +
      pkg.homepage,
  );
  process.exit(1);
}

const tag = `v${pkg.version}`;
const artifact = `minimux-${tag}-${target}.tar.gz`;
const baseUrl = `https://github.com/bradheitmann/minimux/releases/download/${tag}`;
const packageRoot = path.join(__dirname, "..");
const vendorDir = path.join(packageRoot, "vendor");

function fetch(url, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { "user-agent": `minimux-npm/${pkg.version}` } }, (res) => {
        if (
          res.statusCode >= 301 &&
          res.statusCode <= 308 &&
          res.headers.location &&
          redirectsLeft > 0
        ) {
          res.resume();
          resolve(fetch(res.headers.location, redirectsLeft - 1));
          return;
        }
        if (res.statusCode !== 200) {
          res.resume();
          reject(new Error(`GET ${url} returned HTTP ${res.statusCode}`));
          return;
        }
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => resolve(Buffer.concat(chunks)));
        res.on("error", reject);
      })
      .on("error", reject);
  });
}

async function main() {
  const [tarball, checksumFile] = await Promise.all([
    fetch(`${baseUrl}/${artifact}`),
    fetch(`${baseUrl}/${artifact}.sha256`),
  ]);

  const expected = checksumFile.toString("utf8").trim().split(/\s+/u)[0];
  const actual = createHash("sha256").update(tarball).digest("hex");
  if (!expected || expected !== actual) {
    throw new Error(
      `checksum mismatch for ${artifact}: expected ${expected}, got ${actual}`,
    );
  }

  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), "minimux-npm-"));
  try {
    const tarballPath = path.join(stagingDir, artifact);
    fs.writeFileSync(tarballPath, tarball);
    const extract = spawnSync("tar", ["-xzf", tarballPath, "-C", stagingDir], {
      stdio: "inherit",
    });
    if (extract.status !== 0) {
      throw new Error(`tar extraction failed with status ${extract.status}`);
    }

    const binarySource = path.join(stagingDir, `minimux-${tag}-${target}`, "minimux");
    fs.mkdirSync(vendorDir, { recursive: true });
    fs.copyFileSync(binarySource, path.join(vendorDir, "minimux"));
    fs.chmodSync(path.join(vendorDir, "minimux"), 0o755);
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }

  const health = spawnSync(path.join(vendorDir, "minimux"), ["--json", "system.health"], {
    encoding: "utf8",
  });
  if (health.status !== 0 || !health.stdout.includes(`"version":"${pkg.version}"`)) {
    throw new Error(
      `installed binary failed its health check (status ${health.status}): ${health.stdout}${health.stderr}`,
    );
  }
  console.log(`minimux ${pkg.version} (${target}) installed and verified.`);
}

main().catch((error) => {
  console.error(`minimux install failed: ${error.message}`);
  process.exit(1);
});
