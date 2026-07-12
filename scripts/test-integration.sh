#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$REPO_ROOT/tests/integration/loop-install.sh"
"$REPO_ROOT/tests/integration/qemu-boot.sh"
