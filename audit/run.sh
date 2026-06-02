#!/usr/bin/env bash
# audit/run.sh — reproducible static-analysis pass for the Directional Toxicity Shield.
#
# Installs are NOT performed here. Required tools (one-time):
#   slither-analyzer + solc-select : python venv at ~/.local/sec-venv
#   aderyn                          : npm i -g @cyfrin/aderyn  (~/.npm-global/bin)
#   forge                           : ~/.foundry/bin
#
# Usage:  bash audit/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export PATH="$HOME/.local/sec-venv/bin:$HOME/.foundry/bin:$HOME/.npm-global/bin:$PATH"

SOLC_VER="0.8.30"
mkdir -p audit

echo "==> solc $SOLC_VER"
solc-select use "$SOLC_VER" >/dev/null 2>&1 || solc-select install "$SOLC_VER"

echo "==> forge build (sanity)"
forge build >/dev/null

echo "==> Aderyn (scoped via aderyn.toml)"
aderyn . -o audit/aderyn-report.md 2> audit/aderyn-stderr.txt || true

echo "==> Slither (scoped via slither.config.json)"
slither . --checklist --markdown-root . > audit/slither-report.md 2> audit/slither-stderr.txt || true
grep -E "analyzed|result\(s\)" audit/slither-stderr.txt | tail -1 || true

echo "==> Done. Reports in audit/: slither-report.md, aderyn-report.md (triage: audit/TRIAGE.md)"
