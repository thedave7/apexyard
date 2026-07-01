#!/usr/bin/env bash
# SessionStart hook: opportunistically refresh the apexyard-search index so an
# agent doesn't search a stale index and fall back to grep (apexyard-premium#371).
#
# It runs `apexyard-search reindex --incremental --if-stale=<threshold>`:
#   - --incremental: cheap manifest-mtime delta sync (only changed files).
#   - --if-stale:    the CLI no-ops when the index is still fresh, so the common
#                    case (just reindexed) costs essentially nothing.
#
# SAFE SHAPE (mirrors check-upstream-drift.sh): this hook NEVER blocks session
# start and ALWAYS exits 0. Every failure mode is a silent no-op:
#   - apexyard-search not on PATH  (MCP not installed)         -> no-op
#   - index already fresh          (--if-stale short-circuits) -> no-op
#   - APEXYARD_OPS_ROOT / _PORTFOLIO_ROOT unset                -> no-op (CLI errs, swallowed)
#   - reindex slower than the timeout                          -> killed, no-op
#   - APEXYARD_SEARCH_REINDEX_DISABLE set                      -> no-op
#
# Tunables (env):
#   APEXYARD_SEARCH_STALE_AFTER       staleness threshold in seconds (default 86400 = 24h)
#   APEXYARD_SEARCH_REINDEX_TIMEOUT   max seconds to spend before giving up (default 25)
#   APEXYARD_SEARCH_REINDEX_DISABLE   non-empty -> skip entirely

set -u

# Operator kill-switch.
if [ -n "${APEXYARD_SEARCH_REINDEX_DISABLE:-}" ]; then
  exit 0
fi

# No CLI -> nothing to do. (The MCP isn't installed, or not on PATH.)
if ! command -v apexyard-search >/dev/null 2>&1; then
  exit 0
fi

STALE_AFTER="${APEXYARD_SEARCH_STALE_AFTER:-86400}"
TIMEOUT_SECS="${APEXYARD_SEARCH_REINDEX_TIMEOUT:-25}"

# Timeout guard: prefer GNU `timeout`, then macOS `gtimeout`; degrade to no
# wrapper if neither exists (the reindex still runs, just unbounded — rare).
TO=""
if command -v timeout >/dev/null 2>&1; then
  TO="timeout -k 2 ${TIMEOUT_SECS}"
elif command -v gtimeout >/dev/null 2>&1; then
  TO="gtimeout -k 2 ${TIMEOUT_SECS}"
fi

# Run the conditional reindex. Discard stdout (the JSON result is for scripts,
# not the session banner); let stderr through so a genuine reindex announces
# itself once. Swallow the exit code unconditionally — this hook must never
# turn a reindex hiccup into a blocked session start.
# shellcheck disable=SC2086
$TO apexyard-search reindex --incremental --if-stale="${STALE_AFTER}" >/dev/null 2>&1 || true

exit 0
