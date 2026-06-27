#!/bin/bash
# SessionStart hook: emits an advisory when the apexyard-search index is stale,
# instructing the agent to run an incremental reindex before its first search.
#
# Why this exists
# ---------------
# The index is normally updated via the post-pull / post-clone advisory hooks,
# but sessions often start hours or days after the last reindex. When that
# happens, search_code / search_docs silently return stale results and agents
# fall back to grep+Read — exactly the failure mode the MCP is meant to avoid.
# This hook closes the "stale on cold session start" gap by detecting staleness
# before the agent's first query, so results are accurate from the first search.
#
# Behaviour
# ---------
#   - Fires when ALL conditions are true:
#       1. `apexyard-search` CLI is on PATH (MCP server installed)
#       2. A `.mcp.json` is found in or above the ops-root directory (MCP active)
#       3. The vector-store directory is older than APEXYARD_SEARCH_STALE_THRESHOLD
#          seconds (default: 3600 — 1 hour). Set to 0 to always prompt.
#   - Emits a banner to stderr naming the incremental reindex MCP call.
#   - Exits 0 ALWAYS — never blocks session start.
#   - Silent no-op when the CLI is absent, MCP is not configured, or index is fresh.
#   - Timeout-guarded: stat + date calls run inside a 10 s subshell guard so a
#     stalled network mount never hangs session start.
#   - Resolves the cache dir via APEXYARD_SEARCH_CACHE_DIR → XDG_CACHE_HOME →
#     ~/.cache/apexyard-search — mirrors paths.py exactly.
#
# Index location
# --------------
# The vector store lives at <cache_dir>/lancedb/. The mtime of that directory
# is updated whenever the adapter drops and recreates the chunks table on any
# reindex run, making it a reliable staleness signal.
#
# Threshold
# ---------
# Default: 3600 s (1 hour). Override via APEXYARD_SEARCH_STALE_THRESHOLD.
# Set to 0 to always emit the prompt; set to a large number to suppress it.
#
# Design: why a banner and not a direct CLI call?
# -----------------------------------------------
# `apexyard-search` is an MCP server binary — it exposes `reindex` as an MCP
# tool, not as a shell subcommand. The hook therefore cannot invoke reindex
# directly; it instructs the agent (which CAN call MCP tools) to do it. Same
# advisory shape as suggest-mcp-reindex-after-pull.sh and remind-mcp-tools.sh.
#
# Tests at .claude/hooks/tests/test_reindex_on_session_start.sh.

set -u

# --- Prerequisite 1: apexyard-search CLI is on PATH -------------------------
# Most adopters have no apexyard-search installed; this single check makes the
# hook a silent no-op for them with zero overhead.
if ! command -v apexyard-search >/dev/null 2>&1; then
  exit 0
fi

# --- Prerequisite 2: .mcp.json exists (MCP is configured) ------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || exit 0

mcp_configured=false
r="$REPO_ROOT"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  if [ -f "$r/.mcp.json" ]; then
    mcp_configured=true
    break
  fi
  parent=$(dirname "$r"); [ "$parent" = "$r" ] && break; r="$parent"
done
$mcp_configured || exit 0

# --- Resolve cache dir (mirrors apexyard_search/paths.py) -------------------
if [ -n "${APEXYARD_SEARCH_CACHE_DIR:-}" ]; then
  CACHE_DIR="${APEXYARD_SEARCH_CACHE_DIR}"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  CACHE_DIR="${XDG_CACHE_HOME}/apexyard-search"
else
  CACHE_DIR="${HOME}/.cache/apexyard-search"
fi

LANCEDB_DIR="${CACHE_DIR}/lancedb"

# --- Staleness check (timeout-guarded against stalled network mounts) -------
THRESHOLD="${APEXYARD_SEARCH_STALE_THRESHOLD:-3600}"

# Portable timeout: GNU coreutils `timeout` or macOS/brew `gtimeout`.
_TO=""
if command -v timeout >/dev/null 2>&1; then _TO="timeout -k 2 10"
elif command -v gtimeout >/dev/null 2>&1; then _TO="gtimeout -k 2 10"; fi

# Run the mtime check in a subshell; on timeout the guard exits non-zero and
# STALE_INFO stays empty → hook exits 0 silently (safe-fail = no banner).
STALE_INFO=""
if [ -n "$_TO" ]; then
  STALE_INFO=$($_TO bash -c '
    LANCEDB_DIR="$1"; THRESHOLD="$2"
    if [ ! -d "$LANCEDB_DIR" ]; then
      echo "missing"
      exit 0
    fi
    NOW=$(date +%s)
    # Portable mtime: macOS uses -f %m, GNU/Linux uses -c %Y.
    if MTIME=$(stat -f %m "$LANCEDB_DIR" 2>/dev/null) ||
       MTIME=$(stat -c %Y "$LANCEDB_DIR" 2>/dev/null); then
      AGE=$(( NOW - MTIME ))
      if [ "$AGE" -ge "$THRESHOLD" ]; then
        echo "stale:${AGE}"
      fi
    fi
    # stat unavailable or index fresh → print nothing (caller exits 0 silently)
  ' -- "$LANCEDB_DIR" "$THRESHOLD" 2>/dev/null) || STALE_INFO=""
else
  # No timeout binary available — run inline. stat on local fs never hangs.
  if [ ! -d "$LANCEDB_DIR" ]; then
    STALE_INFO="missing"
  else
    NOW=$(date +%s)
    if MTIME=$(stat -f %m "$LANCEDB_DIR" 2>/dev/null) ||
       MTIME=$(stat -c %Y "$LANCEDB_DIR" 2>/dev/null); then
      AGE=$(( NOW - MTIME ))
      if [ "$AGE" -ge "$THRESHOLD" ]; then
        STALE_INFO="stale:${AGE}"
      fi
    fi
    # stat unavailable or index fresh → STALE_INFO stays empty
  fi
fi

# Nothing to do when the index is fresh (or stat was unavailable).
[ -n "$STALE_INFO" ] || exit 0

# --- Emit banner ------------------------------------------------------------
if [ "$STALE_INFO" = "missing" ]; then
  cat >&2 <<'MSG'
> apexyard-search: no index found. Run a full reindex before your first search:
    mcp__apexyard-search__reindex(scope="all")
  If the MCP server is unavailable, print a one-line warning and continue.
MSG
  exit 0
fi

# Build a human-readable age string for the banner.
AGE_SECONDS="${STALE_INFO#stale:}"
if [ "$AGE_SECONDS" -ge 86400 ]; then
  AGE_HUMAN="$((AGE_SECONDS / 86400))d"
elif [ "$AGE_SECONDS" -ge 3600 ]; then
  AGE_HUMAN="$((AGE_SECONDS / 3600))h"
else
  AGE_HUMAN="$((AGE_SECONDS / 60))m"
fi

cat >&2 <<MSG
> apexyard-search: index is stale (${AGE_HUMAN} since last reindex). Reindex
  before your first search so results are accurate:
    mcp__apexyard-search__reindex(scope="framework")
  Use scope="all" to also pick up managed-project code changes. If the MCP
  server is unavailable, print a one-line warning and continue.
MSG

exit 0
