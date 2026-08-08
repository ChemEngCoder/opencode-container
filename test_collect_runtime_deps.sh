#!/usr/bin/env bash
set -euo pipefail

ROOTFS="$(mktemp -d)"
trap 'rm -rf "$ROOTFS"' EXIT

scripts/collect-runtime-deps.sh "$ROOTFS" true

TRUE_PATH="$(command -v true)"
[ -e "$ROOTFS$TRUE_PATH" ]

if scripts/collect-runtime-deps.sh "$ROOTFS/missing" does-not-exist; then
  echo "expected missing executable to fail" >&2
  exit 1
fi

echo "runtime collector checks passed"
