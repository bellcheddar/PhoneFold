#!/bin/bash
# verify_phase.sh <phase> — machine-verifiable gate checks for a PhoneFold phase.
# Exits 0 only if every machine-verifiable criterion for that phase passes.
# Human-verifiable criteria are NEVER checked here and are never marked met by an agent.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PHASE=""
INVARIANTS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --invariants-only) INVARIANTS_ONLY=1 ;;
    [0-5]) PHASE="$arg" ;;
    *) echo "usage: verify_phase.sh <phase 0-5> [--invariants-only]" >&2; exit 2 ;;
  esac
done
if [[ -z "$PHASE" ]]; then echo "usage: verify_phase.sh <phase 0-5> [--invariants-only]" >&2; exit 2; fi

# Two modes, because a phase gate is red by construction until the phase's last task lands:
#   --invariants-only  what every single task must satisfy: platform-clean core, honest
#                      ledger, package builds, tests green. Run after each loop iteration.
#   (default)          the full phase exit gate, including the phase-specific criteria.
#                      Run only when no `todo` tasks remain for the phase.

FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

if [[ "$INVARIANTS_ONLY" == "1" ]]; then
  echo "PhoneFold phase $PHASE — per-task invariants"
else
  echo "PhoneFold phase $PHASE — machine-verifiable exit gate"
fi
echo

# ---------------------------------------------------------------- always-on checks

# The architectural invariant from PLAN.md §1, enforced from Phase 1 onwards but cheap
# enough to run every time. FoldCore/FoldEngine/FoldGeometry must be platform-clean.
check_platform_clean() {
  local hits=0 d
  for d in FoldCore FoldEngine FoldGeometry; do
    local src="PhoneFoldKit/Sources/$d"
    [[ -d "$src" ]] || continue
    local n
    n=$(grep -rn '#if[[:space:]]*\(os\|canImport\|targetEnvironment\)' "$src" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$n" != "0" ]]; then
      grep -rn '#if[[:space:]]*\(os\|canImport\|targetEnvironment\)' "$src" >&2
      hits=$((hits + n))
    fi
  done
  [[ "$hits" == "0" ]]
}
if check_platform_clean; then
  pass "no #if os / canImport in FoldCore, FoldEngine, FoldGeometry"
else
  fail "platform conditionals found in the platform-clean core"
fi

# The ledger must never claim a human-verifiable criterion is met.
if grep -rn '^\- \[x\]' STATE.md 2>/dev/null | grep -qi 'human'; then
  fail "a human-verifiable criterion is ticked in STATE.md"
else
  pass "no human-verifiable criterion ticked by an agent"
fi

# ---------------------------------------------------------------- build and test

if [[ -f PhoneFoldKit/Package.swift ]]; then
  if swift build --package-path PhoneFoldKit >/tmp/pf_build.log 2>&1; then
    pass "swift build (macOS)"
  else
    fail "swift build (macOS) — see /tmp/pf_build.log"; tail -30 /tmp/pf_build.log >&2
  fi
  if swift test --package-path PhoneFoldKit >/tmp/pf_test.log 2>&1; then
    pass "swift test (macOS)"
  else
    fail "swift test (macOS) — see /tmp/pf_test.log"; tail -30 /tmp/pf_test.log >&2
  fi
else
  fail "PhoneFoldKit/Package.swift missing"
fi

# ---------------------------------------------------------------- per-phase checks

TRAJ_DIR="Apps/Shared/Resources/Trajectories"

if [[ "$INVARIANTS_ONLY" == "1" ]]; then
  echo
  if [[ "$FAIL" == "0" ]]; then
    echo "phase $PHASE per-task invariants: GREEN"
  else
    echo "phase $PHASE per-task invariants: RED"
  fi
  exit "$FAIL"
fi

case "$PHASE" in
  0)
    if [[ -d "$TRAJ_DIR" ]] && [[ $(ls -1 "$TRAJ_DIR"/*.pftraj 2>/dev/null | wc -l | tr -d ' ') -ge 12 ]]; then
      pass "12 or more sample trajectories bundled"
    else
      fail "sample trajectory bundle incomplete (want 12 .pftraj in $TRAJ_DIR)"
    fi
    if [[ -f Models/manifest.json ]] && plutil -lint Models/manifest.json >/dev/null 2>&1; then
      pass "Models/manifest.json present and valid JSON"
    else
      fail "Models/manifest.json missing or invalid"
    fi
    if grep -q 'TM-score' METRICS.md 2>/dev/null; then
      pass "accuracy regression table written to METRICS.md"
    else
      fail "no accuracy regression table in METRICS.md"
    fi
    ;;
  1)
    # The 60 fps criterion is only meaningful in a release build: this engine measures
    # 1.65 ms/frame with -c release and 511 ms/frame in debug, a factor of 310.
    if swift test -c release --package-path PhoneFoldKit >/tmp/pf_test_release.log 2>&1; then
      pass "swift test -c release (includes the 60 fps frame-budget criterion)"
    else
      fail "swift test -c release - see /tmp/pf_test_release.log"
      tail -30 /tmp/pf_test_release.log >&2
    fi
    if grep -q "Learned CA-only vs DSSP" /tmp/pf_test_release.log 2>/dev/null; then
      pass "secondary structure agreement measured against the DSSP reference"
    else
      fail "the DSSP agreement test did not run"
    fi

    # Zero data races under Swift 6 strict concurrency. The frame-budget assertion is
    # suppressed here because under a sanitizer it measures instrumentation, not the engine.
    if PHONEFOLD_SKIP_PERF_BUDGET=1 swift test -c release --sanitize=thread \
         --package-path PhoneFoldKit >/tmp/pf_tsan.log 2>&1; then
      if grep -q "WARNING: ThreadSanitizer" /tmp/pf_tsan.log; then
        fail "ThreadSanitizer reported a data race - see /tmp/pf_tsan.log"
      else
        pass "swift test under ThreadSanitizer, no data races"
      fi
    else
      fail "swift test --sanitize=thread - see /tmp/pf_tsan.log"
      tail -20 /tmp/pf_tsan.log >&2
    fi
    ;;
  2|3|4|5)
    skip "phase $PHASE gate checks not yet implemented"
    ;;
  *)
    echo "unknown phase: $PHASE" >&2; exit 2
    ;;
esac

echo
if [[ "$FAIL" == "0" ]]; then
  echo "phase $PHASE machine gate: GREEN"
else
  echo "phase $PHASE machine gate: RED"
fi
exit "$FAIL"
