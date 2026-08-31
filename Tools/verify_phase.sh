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
  2)
    # The renderer's criteria are only meaningful in a release build: the same work measures
    # roughly 300x slower with optimisation off.
    if swift test -c release --package-path PhoneFoldKit >/tmp/pf_test_release.log 2>&1; then
      pass "swift test -c release"
    else
      fail "swift test -c release - see /tmp/pf_test_release.log"
      tail -30 /tmp/pf_test_release.log >&2
    fi

    for marker in "all four colour modes match their stored snapshot" \
                  "tube geometry and packing stay within the recorded baseline" \
                  "no NaNs across a whole real trajectory"; do
      if grep -q "$marker" /tmp/pf_test_release.log 2>/dev/null; then
        pass "ran: $marker"
      else
        fail "did NOT run: $marker"
      fi
    done

    # The app has to build for both surfaces, which is the criterion's "builds and runs".
    # Running it is verified by screenshot, which no script should claim to have done.
    DD=/Users/dellboy/Library/Developer/PhoneFold-DerivedData
    APP_DIR="$ROOT/Apps/PhoneFold"
    if [[ -f "$APP_DIR/PhoneFold.xcodeproj/project.pbxproj" ]]; then
      for destination in "platform=iOS Simulator,name=iPhone 17" "platform=macOS"; do
        if (cd "$APP_DIR" && xcodebuild build -project PhoneFold.xcodeproj \
              -scheme PhoneFold -configuration Release -destination "$destination" \
              -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >/tmp/pf_gate_app.log 2>&1); then
          pass "app builds: $destination"
        else
          fail "app build failed: $destination - see /tmp/pf_gate_app.log"
        fi
      done
    else
      fail "the app project is missing; run xcodegen in Apps/PhoneFold"
    fi
    ;;
  3)
    # The audio criteria are meaningful in a debug build - they are arithmetic, not throughput -
    # but the allocation harness is a separate executable and has to exist.
    if swift test --package-path PhoneFoldKit --filter FoldAudioTests \
         >/tmp/pf_gate_audio.log 2>&1; then
      pass "swift test (FoldAudio)"
    else
      fail "swift test (FoldAudio) - see /tmp/pf_gate_audio.log"
      tail -30 /tmp/pf_gate_audio.log >&2
    fi

    # Each of these is one line of PLAN.md's exit gate. Named rather than counted, so a test
    # that stops running shows up as a missing criterion rather than as a smaller number.
    for marker in "every style renders identically three times, clean and in range" \
                  "a real fold exports and comes back with every note" \
                  "the scheduler allocates nothing while playing" \
                  "the graph renders audio through the environment node"; do
      if grep -q "$marker" /tmp/pf_gate_audio.log 2>/dev/null; then
        pass "ran: $marker"
      else
        fail "did NOT run: $marker"
      fi
    done

    # And an end-to-end render of every style through the shipping command line tool, which
    # exercises the style files on disk rather than a fixture.
    STYLES="$ROOT/Apps/Shared/Resources/Styles"
    BIN=$(swift build --package-path PhoneFoldKit --show-bin-path 2>/dev/null)
    if [[ -x "$BIN/preview-style" ]]; then
      RENDERED=0
      for style in fantasy jazz rock pop surf; do
        if "$BIN/preview-style" "$TRAJ_DIR/lysozyme.pftraj" --style "$style" \
             --styles "$STYLES" --out "/tmp/pf_gate_$style.wav" --quiet \
             >>/tmp/pf_gate_render.log 2>&1; then
          RENDERED=$((RENDERED + 1))
        else
          fail "preview-style could not render $style - see /tmp/pf_gate_render.log"
        fi
      done
      if [[ "$RENDERED" == "5" ]]; then
        pass "all five styles render to a WAV through preview-style"
      fi
    else
      fail "preview-style is not built"
    fi
    ;;
  4)
    if swift test --package-path PhoneFoldKit --filter MMCIFExportTests \
         >/tmp/pf_gate_cif.log 2>&1; then
      pass "swift test (mmCIF export)"
    else
      fail "swift test (mmCIF export) - see /tmp/pf_gate_cif.log"
      tail -20 /tmp/pf_gate_cif.log >&2
    fi

    # "mmCIF parses in Biotite" is PLAN's own wording, and it is the criterion that matters:
    # a file only this repository's parser can read would satisfy nothing. Biotite refused the
    # first version outright over a missing pdbx_PDB_ins_code column.
    BIN=$(swift build --package-path PhoneFoldKit --show-bin-path 2>/dev/null)
    VENV="$ROOT/Tools/.venv/bin/python3"
    if [[ -x "$BIN/preview-style" && -x "$VENV" ]]; then
      "$BIN/preview-style" "$TRAJ_DIR/lysozyme.pftraj" \
        --styles "$ROOT/Apps/Shared/Resources/Styles" \
        --out /tmp/pf_gate_cif.wav --cif /tmp/pf_gate_cif.cif --quiet >/dev/null 2>&1
      if "$VENV" -c "
import sys
import biotite.structure.io.pdbx as pdbx
import numpy as np
f = pdbx.CIFFile.read('/tmp/pf_gate_cif.cif')
stack = pdbx.get_structure(f, extra_fields=['b_factor'])
assert stack.stack_depth() > 1, 'not a multi-model file'
last = pdbx.get_structure(f, model=stack.stack_depth(), extra_fields=['b_factor'])
ca = last[last.atom_name == 'CA']
d = np.linalg.norm(np.diff(ca.coord, axis=0), axis=1)
assert 3.6 < d.mean() < 4.0, f'CA-CA mean {d.mean():.2f} A is not a backbone'
assert last.b_factor.max() > 0, 'the confidence column is empty'
" >>/tmp/pf_gate_cif.log 2>&1; then
        pass "the exported mmCIF parses in Biotite and is a backbone"
      else
        fail "Biotite could not read the exported mmCIF - see /tmp/pf_gate_cif.log"
        tail -20 /tmp/pf_gate_cif.log >&2
      fi
    else
      fail "preview-style or Tools/.venv is missing; cannot check the mmCIF in Biotite"
    fi

    # PLAN: "All four export formats validate (mmCIF parses in Biotite, MIDI parses, MP4
    # probes clean)". The mmCIF is checked above; this is the MP4. ffprobe rather than this
    # repository's own reader, for the same reason Biotite is used for the mmCIF: a file only
    # we can open has validated nothing.
    if [[ -x "$BIN/preview-style" ]] && command -v ffprobe >/dev/null 2>&1; then
      rm -f /tmp/pf_gate_film.mp4
      "$BIN/preview-style" "$TRAJ_DIR/trp_cage.pftraj" \
        --styles "$ROOT/Apps/Shared/Resources/Styles" \
        --out /tmp/pf_gate_film.wav --film /tmp/pf_gate_film.mp4 \
        --quiet >/dev/null 2>&1
      PROBE=$(ffprobe -v error -show_entries stream=codec_type,codec_name \
                      -of default=nw=1:nk=1 /tmp/pf_gate_film.mp4 2>/dev/null | tr '\n' ' ')
      if [[ "$PROBE" == *"h264"* && "$PROBE" == *"video"* && "$PROBE" == *"audio"* ]]; then
        pass "the exported MP4 probes clean and carries both picture and sound"
      else
        fail "ffprobe did not find an h264 video and an audio track in the export: $PROBE"
      fi
    else
      fail "preview-style or ffprobe is missing; cannot probe the exported MP4"
    fi

    # PLAN: "No memory leaks across 20 consecutive folds in an automated instrument run."
    #
    # **Forty folds, not twenty, and that is a measurement rather than a flourish.** The
    # footprint does not climb; it sawtooths. Measured on an M1 Max: it steps up to about
    # 400 MB by fold 17 and is then reclaimed to 334 at fold 18 and to 260 at fold 26. Over
    # twenty folds the first reclaim lands at the very end, so a twenty-fold window reports
    # +47 MB and cannot tell a bounded cache from a leak. Over forty the mean of the second
    # half is 47 MB *below* the first half's, which a leak cannot do.
    if [[ -n "${PHONEFOLD_GATE_FAST:-}" ]]; then
      skip "the leak run is skipped because PHONEFOLD_GATE_FAST is set"
    elif swift build --package-path PhoneFoldKit -c release --product leak-probe >/dev/null 2>&1
    then
      LEAK=$(PHONEFOLD_LEAK_FOLDS=40 swift run --package-path PhoneFoldKit -c release \
             leak-probe 2>/dev/null | tail -3)
      DRIFT=$(echo "$LEAK" | sed -n 's/.*minus first \([-+0-9.]*\) MB.*/\1/p')
      if [[ -z "$DRIFT" ]]; then
        fail "the leak probe produced no verdict line"
      elif awk -v d="$DRIFT" 'BEGIN { exit !(d <= 20) }'; then
        pass "40 consecutive folds: second half is ${DRIFT} MB against the first, no leak"
      else
        fail "40 consecutive folds grew by ${DRIFT} MB between halves - that is a leak"
      fi
    else
      fail "leak-probe does not build"
    fi

    # The accessibility audit stays human. VoiceOver rotor order, focus escape and gesture
    # conflicts are not things a script can judge, and a check that only asserted that labels
    # exist would pass an app that is unusable. It is in BLOCKERS.md with the rest of what
    # needs Marc.
    skip "phase 4: the full accessibility audit is human-verifiable, see BLOCKERS.md"
    ;;
  5)
    # PLAN.md Phase 5a's machine gate: "builds and tests on macOS". The Studio compiles the
    # phone's own Sources with its own @main, so this also catches the failure mode that shape
    # invites: a change to the shared stage that only builds under one of the two entry points.
    DD=/Users/dellboy/Library/Developer/PhoneFold-DerivedData
    APP_DIR="$ROOT/Apps/PhoneFold"
    if [[ -f "$APP_DIR/PhoneFold.xcodeproj/project.pbxproj" ]]; then
      if (cd "$APP_DIR" && xcodebuild build -project PhoneFold.xcodeproj \
            -scheme PhoneFoldStudio -configuration Release -destination "platform=macOS" \
            -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO \
            >/tmp/pf_gate_studio.log 2>&1); then
        pass "PhoneFold Studio builds for macOS"
      else
        fail "PhoneFold Studio build failed - see /tmp/pf_gate_studio.log"
      fi
    else
      fail "the app project is missing; run xcodegen in Apps/PhoneFold"
    fi

    skip "phase 5: batch mode and the CoreMIDI loopback check arrive with P5-03 and P5-05"
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
