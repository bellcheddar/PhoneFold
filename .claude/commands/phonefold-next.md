---
description: Advance PhoneFold by exactly one task from STATE.md, then build, test, verify and commit.
---

Read `PLAN.md`, `STATE.md` and `BLOCKERS.md`.

**If `HALT` exists at the repo root, stop immediately and output nothing but `HALTED`.**

Select the first task in `STATE.md` with status `todo` whose dependencies are all `done`.
Mark it `doing`. Implement it completely. Then:

1. Build all active targets (`swift build` for the package; `Tools/build_apps.sh` once app
   targets exist).
2. Run the full test suite (`swift test`).
3. Run `Tools/verify_phase.sh <current phase> --invariants-only`. (The full gate is red by
   construction until the phase's last task lands, so it is run at the exit gate, not per task.)
4. If green: mark the task `done`, append an entry to `JOURNAL.md`, and commit with the message
   `phase N task <id>: <summary>`.
5. If red: fix and retry, up to **3 attempts on the same task**. On the third failure, write the
   failure to `BLOCKERS.md`, mark the task `blocked`, create `HALT`, and stop.

If no `todo` tasks remain for the current phase, run the full exit gate
(`Tools/verify_phase.sh <current phase>`, no flag):

- If every machine-verifiable criterion passes and no human-verifiable criteria exist, decompose
  the next phase into tasks in `STATE.md`, advance the phase, and continue.
- If human-verifiable criteria exist, write them to `BLOCKERS.md` as a checklist for Marc, create
  `HALT`, and stop.

## Non-negotiable

- Never modify `PLAN.md`.
- Never delete `HALT`.
- Never mark a human-verifiable criterion as met.
- Never comment out a failing test to make a gate pass. That is a halt, not a fix.
- Never write a placeholder that returns plausible-looking fake data. If a real implementation is
  blocked, halt.
- Numbers in `METRICS.md` must come from an actual measurement. Mark Simulator figures as such.
- One task, one commit. Never batch unrelated changes.
- Every iteration ends with the repo building and committed.
