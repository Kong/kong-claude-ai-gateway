#!/usr/bin/env bash
# Usage: scripts/verify-2.0.sh <module>   e.g. scripts/verify-2.0.sh 01-general-proxying
set -euo pipefail

MODULE="${1:?Usage: $0 <module-name, e.g. 01-general-proxying>}"
BASE_URL="${GATEWAY_URL:-http://localhost:8010}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

case "$MODULE" in
  *)
    echo "No verify steps defined yet for module '$MODULE'" >&2
    exit 1
    ;;
esac
