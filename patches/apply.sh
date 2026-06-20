#!/usr/bin/env bash
# Asserting codemod: applies CodeVibes production source edits to a checkout.
# Usage: apply.sh [REPO_ROOT]   (default: .)  Idempotent. Fails if a target is absent.
# POSIX-safe (set -eu, no pipefail) so it runs under bash, dash (CI `sh`), and
# busybox ash (Alpine `RUN sh ...` in Dockerfile.web).
set -eu
ROOT="${1:-.}"

# replace_once FILE LITERAL REPLACEMENT
# Succeeds if LITERAL already absent AND REPLACEMENT present (idempotent re-run);
# else requires exactly one LITERAL occurrence.
replace_once() {
  local file="$1" lit="$2" repl="$3"
  [ -f "$file" ] || { echo "apply.sh: missing file $file" >&2; return 1; }
  local n; n="$(grep -F -c -- "$lit" "$file" || true)"
  if [ "$n" -eq 0 ]; then
    if grep -F -q -- "$repl" "$file"; then return 0; fi
    echo "apply.sh: $file: expected 1 occurrence of target literal, found 0 and replacement absent" >&2
    return 1
  fi
  if [ "$n" -ne 1 ]; then
    echo "apply.sh: $file: expected 1 occurrence, found $n" >&2; return 1
  fi
  # literal, non-regex replacement via awk index/substr
  awk -v lit="$lit" -v repl="$repl" '{i=index($0,lit); if(i){$0=substr($0,1,i-1) repl substr($0,i+length(lit))} print}' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

replace_once "$ROOT/src/hooks/useAnalysis.ts" \
  "const API_BASE_URL = 'http://localhost:3001';" \
  "const API_BASE_URL = import.meta.env.VITE_API_URL || '';"

replace_once "$ROOT/codevibes-backend/src/server.ts" \
  "callback(null, true); // Allow for development - tighten in production" \
  "callback(new Error('Not allowed by CORS'), false);"

echo "apply.sh: codemod applied"
