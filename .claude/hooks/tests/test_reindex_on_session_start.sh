#!/bin/bash
# Tests for reindex-on-session-start.sh SessionStart hook.
# Run: bash .claude/hooks/tests/test_reindex_on_session_start.sh

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/reindex-on-session-start.sh"
PASS=0
FAIL=0
FAILED=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert_silent() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    echo "PASS [$label] — silent (no banner)"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected silent, got: $output" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

assert_contains() {
  local label="$1" output="$2" needle="$3"
  if echo "$output" | grep -qF "$needle"; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected '$needle' in output, got: $output" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

assert_exit_zero() {
  local label="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    echo "PASS [$label] — exit 0"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label] — expected exit 0, got exit $rc" >&2
    FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "
  fi
}

# Run the hook from a given directory, with given env overrides.
# Returns output on stdout; exit code is captured separately.
run_hook() {
  local dir="$1"; shift
  ( cd "$dir" || exit 1; env "$@" bash "$HOOK_SRC" 2>&1 )
}
run_hook_rc() {
  local dir="$1"; shift
  ( cd "$dir" || exit 1; env "$@" bash "$HOOK_SRC" >/dev/null 2>&1; echo $? )
}

# ---------------------------------------------------------------------------
# Test fixture setup: a minimal git repo that looks like an apexyard ops root
# ---------------------------------------------------------------------------
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

make_ops_repo() {
  # $1 = base dir for the repo; creates a minimal git repo with onboarding.yaml
  # and optionally a .mcp.json if MCP_CONFIGURED=1 (caller sets before call)
  local base="$1"
  local with_mcp="${2:-1}"  # default: with .mcp.json
  mkdir -p "$base"
  (
    cd "$base" || exit 1
    git init -q -b main
    git config user.email t@t && git config user.name t
    echo "company: test" > onboarding.yaml
    git add onboarding.yaml && git commit -q -m "init"
    if [ "$with_mcp" = "1" ]; then
      echo '{"mcpServers":{}}' > .mcp.json
    fi
  )
  echo "$base"
}

make_stale_index() {
  # Create a lancedb dir under APEXYARD_SEARCH_CACHE_DIR with a mtime in the past.
  # $1 = cache dir root; $2 = age in seconds
  local cache_dir="$1"
  local age="${2:-7200}"  # default 2 h stale
  local lancedb="${cache_dir}/lancedb"
  mkdir -p "$lancedb"
  # Set mtime to NOW - age using touch -t (portable: macOS + Linux).
  local target_ts
  target_ts=$(date -r "$(($(date +%s) - age))" "+%Y%m%d%H%M.%S" 2>/dev/null \
    || date -d "@$(($(date +%s) - age))" "+%Y%m%d%H%M.%S" 2>/dev/null \
    || echo "")
  if [ -n "$target_ts" ]; then
    touch -t "$target_ts" "$lancedb"
  else
    # Fallback: just ensure the dir is older than 1 h by touching a sentinel
    # and not touching lancedb, then set mtime via perl if available.
    perl -e "utime(time()-$age, time()-$age, '$lancedb')" 2>/dev/null || true
  fi
}

make_fresh_index() {
  # Create a lancedb dir that was just updated (mtime = now).
  local cache_dir="$1"
  local lancedb="${cache_dir}/lancedb"
  mkdir -p "$lancedb"
  touch "$lancedb"
}

mock_path_dir() {
  # Create a mock `apexyard-search` binary in $1/bin that exits 0 silently.
  local bin="${1}/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\n# mock apexyard-search\nexit 0\n' > "${bin}/apexyard-search"
  chmod +x "${bin}/apexyard-search"
  echo "$bin"
}

# ---------------------------------------------------------------------------
# Test: CLI absent → silent no-op, exit 0
# ---------------------------------------------------------------------------
OPS_REPO="${TMPDIR_ROOT}/ops-no-cli"
make_ops_repo "$OPS_REPO" 1 >/dev/null
CACHE="${TMPDIR_ROOT}/cache-no-cli"
make_stale_index "$CACHE"

# Run with PATH that has no apexyard-search
OUT=$(run_hook "$OPS_REPO" "PATH=/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE")
RC=$(run_hook_rc "$OPS_REPO" "PATH=/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE")
assert_silent "CLI absent — no banner" "$OUT"
assert_exit_zero "CLI absent — exit 0" "$RC"

# ---------------------------------------------------------------------------
# Test: CLI present but no .mcp.json → silent no-op, exit 0
# ---------------------------------------------------------------------------
OPS_REPO="${TMPDIR_ROOT}/ops-no-mcp"
make_ops_repo "$OPS_REPO" 0 >/dev/null  # no .mcp.json
CACHE="${TMPDIR_ROOT}/cache-no-mcp"
make_stale_index "$CACHE"
MOCK_BIN=$(mock_path_dir "${TMPDIR_ROOT}/mock-no-mcp")

OUT=$(run_hook "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE")
RC=$(run_hook_rc "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE")
assert_silent "no .mcp.json — no banner" "$OUT"
assert_exit_zero "no .mcp.json — exit 0" "$RC"

# ---------------------------------------------------------------------------
# Test: CLI present, .mcp.json present, index fresh → silent no-op, exit 0
# ---------------------------------------------------------------------------
OPS_REPO="${TMPDIR_ROOT}/ops-fresh"
make_ops_repo "$OPS_REPO" 1 >/dev/null
CACHE="${TMPDIR_ROOT}/cache-fresh"
make_fresh_index "$CACHE"
MOCK_BIN=$(mock_path_dir "${TMPDIR_ROOT}/mock-fresh")

OUT=$(run_hook "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE" "APEXYARD_SEARCH_STALE_THRESHOLD=3600")
RC=$(run_hook_rc "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE" "APEXYARD_SEARCH_STALE_THRESHOLD=3600")
assert_silent "fresh index — no banner" "$OUT"
assert_exit_zero "fresh index — exit 0" "$RC"

# ---------------------------------------------------------------------------
# Test: CLI present, .mcp.json present, index stale → banner with reindex call
# ---------------------------------------------------------------------------
OPS_REPO="${TMPDIR_ROOT}/ops-stale"
make_ops_repo "$OPS_REPO" 1 >/dev/null
CACHE="${TMPDIR_ROOT}/cache-stale"
make_stale_index "$CACHE" 7200  # 2 hours stale; threshold default 3600
MOCK_BIN=$(mock_path_dir "${TMPDIR_ROOT}/mock-stale")

OUT=$(run_hook "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE" "APEXYARD_SEARCH_STALE_THRESHOLD=3600")
RC=$(run_hook_rc "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE" "APEXYARD_SEARCH_STALE_THRESHOLD=3600")
assert_contains "stale index — banner emitted" "$OUT" "apexyard-search: index is stale"
assert_contains "stale index — banner names reindex call" "$OUT" "mcp__apexyard-search__reindex"
assert_contains "stale index — banner names scope param" "$OUT" "scope="
assert_exit_zero "stale index — exit 0 even when stale" "$RC"

# Stale age is human-readable (should show "2h" for 2-hour staleness)
assert_contains "stale index — banner shows human-readable age" "$OUT" "2h"

# ---------------------------------------------------------------------------
# Test: index directory missing entirely → banner with scope=all reindex
# ---------------------------------------------------------------------------
OPS_REPO="${TMPDIR_ROOT}/ops-missing"
make_ops_repo "$OPS_REPO" 1 >/dev/null
CACHE="${TMPDIR_ROOT}/cache-missing"
# Deliberately do NOT create the lancedb dir
mkdir -p "$CACHE"  # cache root exists but no lancedb subdir
MOCK_BIN=$(mock_path_dir "${TMPDIR_ROOT}/mock-missing")

OUT=$(run_hook "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE")
RC=$(run_hook_rc "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE")
assert_contains "missing index — banner emitted" "$OUT" "no index found"
assert_contains "missing index — banner names reindex call" "$OUT" "mcp__apexyard-search__reindex"
assert_contains "missing index — banner uses scope=all" "$OUT" 'scope="all"'
assert_exit_zero "missing index — exit 0" "$RC"

# ---------------------------------------------------------------------------
# Test: threshold=0 → always emit (even if just-created lancedb dir)
# ---------------------------------------------------------------------------
OPS_REPO="${TMPDIR_ROOT}/ops-threshold-zero"
make_ops_repo "$OPS_REPO" 1 >/dev/null
CACHE="${TMPDIR_ROOT}/cache-threshold-zero"
make_fresh_index "$CACHE"
MOCK_BIN=$(mock_path_dir "${TMPDIR_ROOT}/mock-threshold-zero")

OUT=$(run_hook "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE" "APEXYARD_SEARCH_STALE_THRESHOLD=0")
assert_contains "threshold=0 — always fires" "$OUT" "mcp__apexyard-search__reindex"

# ---------------------------------------------------------------------------
# Test: exit 0 always — even when the threshold check would produce a banner
# ---------------------------------------------------------------------------
OPS_REPO="${TMPDIR_ROOT}/ops-exit0"
make_ops_repo "$OPS_REPO" 1 >/dev/null
CACHE="${TMPDIR_ROOT}/cache-exit0"
make_stale_index "$CACHE" 86400  # 24 h stale
MOCK_BIN=$(mock_path_dir "${TMPDIR_ROOT}/mock-exit0")

RC=$(run_hook_rc "$OPS_REPO" "PATH=${MOCK_BIN}:/usr/bin:/bin" "APEXYARD_SEARCH_CACHE_DIR=$CACHE")
assert_exit_zero "always exit 0 — banner case" "$RC"

# ---------------------------------------------------------------------------
# Test: timeout guard is present in the hook (grep the source)
# ---------------------------------------------------------------------------
if grep -q "timeout" "$HOOK_SRC"; then
  echo "PASS [timeout guard present in hook source]"
  PASS=$((PASS+1))
else
  echo "FAIL [timeout guard present in hook source] — 'timeout' not found in hook" >&2
  FAIL=$((FAIL+1)); FAILED="${FAILED}timeout-guard-present "
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0
