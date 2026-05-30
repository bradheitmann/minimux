#!/usr/bin/env sh
set -eu

zig build -Dtest-filter=recovery test
zig build -Dtest-filter=atomic_snapshot test
