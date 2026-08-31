# PhoneFold — working rules

A Swift app that folds a protein on the Apple Neural Engine and turns the trajectory into music.
Five surfaces: iPhone, iPad, Mac ("PhoneFold Studio"), Apple Watch, Vision Pro.

`PLAN.md` is the specification and is **read-only**. `STATE.md` is the task ledger.

## Hard rules

1. **Do not stop between phases.** When a phase's machine-verifiable gate is green, commit, push,
   decompose the next phase in `STATE.md` and start it in the same turn. Finishing a phase is not
   a question. Pause only for a decision that is genuinely Marc's: a scientific default or
   threshold, a licence, anything destructive or outward-facing, anything needing `sudo`, and the
   App Store Connect app record.
2. **Never fake a gate.** No placeholder that returns plausible-looking fake data. No commenting
   out a failing test. No marking a human-verifiable criterion as met. If a real implementation is
   blocked, write to `BLOCKERS.md`, `touch HALT`, and stop.
3. **Every number in `METRICS.md` is measured**, never estimated. Simulator figures are labelled
   as Simulator figures — they are meaningless for ANE work.
4. **One task, one commit.** Message form: `phase N task <id>: <summary>`.
5. **No `#if os(...)` in `FoldCore`, `FoldEngine` or `FoldGeometry`.** Enforced by
   `Tools/verify_phase.sh`. If one appears, the design is wrong, not the lint.
6. **Stage files explicitly. Never `git add -A`** — session transcripts and scratch files live
   alongside the repo.
7. **PhoneFold is a concert, not a workbench.** The only analysis concession in the whole project
   is Mac structure comparison in Phase 5a. Anything else analytical belongs in BOFFIN.
8. Approved dependencies: **Apple frameworks only**. SwiftLint as a build-tool plugin and
   XcodeGen as a project generator are acceptable (neither ships in the binary). Any other
   dependency is a halt.

## This machine

- **DerivedData must live outside `~/Documents`.** iCloud puts extended attributes on everything
  under Documents and `codesign` then fails with "resource fork, Finder information, or similar
  detritus not allowed". Always pass
  `-derivedDataPath /Users/dellboy/Library/Developer/PhoneFold-DerivedData`.
- **iCloud evicts large files** from `~/Documents` under Optimize Mac Storage. Before any run that
  reads `Models/` or `Apps/Shared/Resources/Trajectories/`, check for dataless files
  (`find … -flags dataless` or `brctl download`).
- Python work uses the Homebrew **python3.12** venv at `Tools/.venv` (torch has no 3.14 wheels).
- Xcode 26.6, Swift 6.3.3, SDKs for iOS/macOS/watchOS/visionOS 26.5 all present.
- Free disk is tight (~41 GB). Check before downloading checkpoints.

## Apple identity (settled, never ask)

- Team: `${APPLE_TEAM_ID}`, sourced from `~/.claude/skills/marcs-vibe-coding/credentials.env`.
  **The value is never written into this repository** — XcodeGen expands the variable, and the
  generated `.xcodeproj` is gitignored. It was in this file until 2026-08-31 and was taken out
  of the history before the first push.
- Bundle IDs: `com.mdeller.phonefold`, `com.mdeller.phonefold.studio`,
  `com.mdeller.phonefold.watchkitapp`, `com.mdeller.phonefold.vision`.
  `com.marcdeller.*` is wrong.
- App Store name is **PhoneFold**; the Mac app is **PhoneFold Studio**. Never rename for
  consistency — the name is the origin story.
