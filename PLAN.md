# PhoneFold: Build Plan v2

**A Swift app that folds a protein on the Apple Neural Engine and turns the trajectory into music.**
**Now spanning iPhone, iPad, Mac, Apple Watch and Vision Pro, and specified to run unattended under `/loop`.**

Author: Marc C. Deller, D.Phil. (marc@marcdeller.com)
Plan version: v2, 28 August 2026 (supersedes v1, which was iPhone-only and human-driven)
Intended runner: Claude Code, autonomous

### What changed from v1

1. Five platforms instead of one. `PhoneFoldKit` is platform-clean from Phase 1, and a new
   **Phase 5 (Fleet)** delivers the Mac, Watch and Vision Pro surfaces.
2. A full **autonomous execution contract** (Section 0) so the build runs under `/loop` and
   `/goal` without supervision, halting only when Marc is genuinely required.
3. Every acceptance gate is now split into **machine-verifiable** (the loop continues) and
   **human-verifiable** (the loop halts and waits). Nothing that needs real hardware, ears or
   taste is ever marked green by an agent.

---

## 0. Autonomous execution contract (read before anything else)

This plan is designed to be run by `/loop` calling a project command, with `/goal` supplying
the exit condition for each phase. The single most important rule:

> **The loop makes progress or it halts. It never guesses, never fakes a passing gate, and
> never marks a human-verifiable criterion as met.**

### 0.1 Ledger files (create these first, before any code)

All state lives in version-controlled markdown at the repo root. The agent has no memory
between loop iterations; these files are the memory.

| File | Purpose | Written by |
|---|---|---|
| `PLAN.md` | This document. Read-only reference | Marc |
| `STATE.md` | Current phase, current task, ordered task list with status `todo` / `doing` / `blocked` / `done` | Agent |
| `BLOCKERS.md` | Questions and decisions that require Marc. Each entry dated, with context, options considered, and a recommendation | Agent |
| `JOURNAL.md` | Append-only log: one entry per loop iteration with timestamp, task, what changed, test result, commit SHA | Agent |
| `METRICS.md` | Benchmark tables (frames per second, TM-score, memory, launch time) as they are measured | Agent |
| `HALT` | Sentinel file. Its existence means the loop must stop immediately and do nothing further | Agent |

`STATE.md` must be decomposed to tasks small enough that one loop iteration can finish one
task, build, test and commit. If a task cannot be completed in a single iteration, split it
before starting.

### 0.2 The loop command

Create `.claude/commands/phonefold-next.md` containing, in substance:

```
Read PLAN.md, STATE.md and BLOCKERS.md.
If HALT exists, stop immediately and output nothing but "HALTED".
Select the first task in STATE.md with status `todo` whose dependencies are all `done`.
Mark it `doing`. Implement it completely. Then:
  1. Build all active targets.
  2. Run the full test suite.
  3. Run Tools/verify_phase.sh for the current phase.
  4. If green: mark `done`, append to JOURNAL.md, and commit with message
     "phase N task <id>: <summary>".
  5. If red: fix and retry, up to 3 attempts on the same task. On the third failure,
     write the failure to BLOCKERS.md, mark the task `blocked`, create HALT, and stop.
If no `todo` tasks remain for the current phase, run the phase exit gate.
  - If every machine-verifiable criterion passes and no human-verifiable criteria exist,
    advance the phase in STATE.md and continue.
  - If human-verifiable criteria exist, write them to BLOCKERS.md as a checklist for Marc,
    create HALT, and stop.
Never modify PLAN.md. Never delete HALT. Never mark a human-verifiable criterion as met.
```

Then run, from the project root:

```bash
/goal phase 1 exit gate passes: swift test green, Tools/verify_phase.sh 1 exits 0
/loop 15m /phonefold-next
```

Use one `/goal` per phase, restated by Marc when he clears the halt. Do not set a single
project-wide goal: the phase gates are the natural checkpoints and a global goal will
encourage the agent to skip them.

### 0.3 Halt conditions (non-negotiable)

The agent creates `HALT` and stops on any of these:

1. A question in `BLOCKERS.md` that changes scope, cost, architecture or scientific claims
2. Three consecutive failures on the same task
3. Any phase gate containing a **human-verifiable** criterion
4. Anything requiring physical hardware: on-device frame rate, thermal behaviour, ANE
   residency, AirPlay to a real display, headphone spatial audio, haptics, Watch or Vision Pro
   hardware testing
5. Anything requiring Apple Developer account access: signing, provisioning, capabilities,
   App Store Connect, TestFlight
6. A missing external artefact: model weights, SoundFont licence, benchmark structures
7. Accuracy regression outside tolerance in Phase 0 (TM-score loss above 0.05)
8. A git conflict, a force-push requirement, or any history rewrite
9. A dependency that would add a third-party package not already approved in Section 0.5
10. Estimated remaining work for the current phase exceeding twice its budget in Section 7

### 0.4 What the agent may decide alone

To stop it halting on trivia: naming of internal types, file organisation within a target,
test structure, private helper APIs, SwiftUI view decomposition, refactors that keep the
public API and tests intact, and any fix that makes a red gate green without changing scope.

### 0.5 Guardrails and permissions

Prefer a scoped allowlist in `.claude/settings.json` over blanket permission skipping. An
unattended agent with unrestricted shell access on a machine holding Marc's resume, blog and
client work is not a risk worth taking for a hobby app.

- **Allow:** `xcodebuild`, `swift`, `swiftlint`, `git` (except `push --force` and any history
  rewrite), `python3` within `Tools/`, `xcrun simctl`, reads and writes within the project
  directory
- **Deny:** anything outside the project directory, `rm -rf`, `curl` and `wget` to hosts other
  than `rest.uniprot.org` and `huggingface.co`, `security`, `defaults`, package publishing,
  `git push --force`, any App Store Connect API call
- `.claudeignore`: `~/.ssh`, `.env`, credentials, `Models/` weight binaries (too large for
  context), and anything outside the repo
- Enable audit logging. Marc reviews `JOURNAL.md` plus the audit log each morning
- Approved packages only: none beyond Apple frameworks in Phases 0 to 4. SwiftLint as a build
  tool plugin is acceptable. Any other dependency is a halt

### 0.6 Rules that keep the loop honest

- One task, one commit. Never batch unrelated changes
- Never comment out a failing test to make a gate pass. That is a halt, not a fix
- Never write a placeholder that returns plausible-looking fake data. If a real implementation
  is blocked, halt
- Numbers in `METRICS.md` must come from an actual measurement, never an estimate. Mark any
  Simulator-derived figure explicitly as such: Simulator numbers are meaningless for ANE work
- Run `/compact` when context is heavy rather than dropping the ledger files from view
- Every loop iteration must end with the repo in a building, committed state

---

## 1. Platform matrix

`PhoneFoldKit` is written once and is platform-agnostic. Platform differences are confined to
the render, audio, capture and presentation edges, isolated behind protocols with `#if os(...)`
implementations. If a `#if os` appears in `FoldCore`, `FoldEngine` or `FoldGeometry`, the design
is wrong.

| Surface | Role | Runs inference | Key capabilities |
|---|---|---|---|
| **iPhone** | The instrument | Yes, ANE | Live fold, music, haptics, AirPlay, video export, Live Activity |
| **iPad** | The lecture surface | Yes, ANE | Larger stage, Stage Manager, external display, Apple Pencil annotation of frames |
| **Mac ("PhoneFold Studio")** | The studio | Yes, larger models | Batch folding, ProRes and 4K export, CoreMIDI virtual source into a DAW, multi-window, higher residue cap |
| **Apple Watch** | The conductor | No | Transport remote, live pLDDT complication, wrist haptics of the fold, standalone Fold of the Day |
| **Vision Pro** | The theatre | Yes, on-device | Volumetric protein, immersive concert space, true spatial audio, hand interaction, SharePlay teaching |

Keep the name **PhoneFold** everywhere except the Mac app, which is **PhoneFold Studio**. The
name is the origin story; do not let an agent rename it for consistency.

Universal purchase across all five. iCloud sync of saved trajectories, Handoff between phone
and Mac, SharePlay on Vision Pro and Mac.

---

## 2. Visual and sonic identity: "Aurora Stage"

Deliberately differentiated from Marc's other Swift apps. JUMPjet is a dark tactical HUD
("Night Sortie"); PfamIE is an astronomical deep field; BOFFIN is a mobile workbench.
**PhoneFold is a concert.** It is a performance surface, never an analysis tool, or it will
cannibalise BOFFIN.

- **Background:** deep indigo to near-black gradient (`#0B0A1F` to `#181432`)
- **Stage palette (saturated, emissive):** helix magenta `#FF3D9A`, sheet cyan `#22E5FF`,
  coil slate `#6B7C93`, confidence amber `#FCB900`, contact-flash white `#FFFFFF`
- **pLDDT ramp:** the familiar AlphaFold ramp (`#FF7D45` to `#FFDB13` to `#65CBF3` to `#0053D6`)
  so the colour language reads instantly to structural biologists
- **Type:** SF Pro Display for UI, SF Mono for sequence and numerics, Dynamic Type respected
- **Motion:** everything eases, nothing pops. Secondary structure blends in over ~250 ms
- **Chrome:** minimal. Controls fade during playback and return on tap or hover

---

## 3. Module architecture

```
PhoneFold/
├── PhoneFold.xcworkspace
├── PhoneFoldKit/                     # local SPM package, multiplatform, no #if os in the core
│   ├── Sources/
│   │   ├── FoldCore/                 # sequence I/O, tokeniser, FoldFrame, style profiles
│   │   ├── FoldEngine/               # Core ML / ANE inference, frame stream
│   │   ├── FoldGeometry/             # Kabsch, splines, P-SEA, contacts, metrics
│   │   ├── FoldAudio/                # style engines, sonification mapping, MIDI log
│   │   ├── FoldRender/               # RealityKit LowLevelMesh renderer, materials, shaders
│   │   ├── FoldCapture/              # offscreen render, AVAssetWriter, exports
│   │   └── FoldSync/                 # iCloud trajectory store, Handoff, WatchConnectivity
│   └── Tests/                        # one test target per library
├── Apps/
│   ├── PhoneFold-iOS/                # iPhone + iPad
│   ├── PhoneFoldStudio-macOS/        # native AppKit/SwiftUI, not Catalyst
│   ├── PhoneFold-watchOS/
│   └── PhoneFold-visionOS/
├── Models/                           # .mlpackage bundles (git-lfs)
├── Tools/                            # Phase 0 export scripts, verify_phase.sh, bench harness
└── .claude/commands/                 # phonefold-next.md and friends
```

Dependency direction is strictly one way: `FoldCore` ← everything else. `FoldRender` and
`FoldAudio` both consume `FoldFrame` and never talk to each other. The app layer wires them.

---

## Phase 0: Model Forge

**Goal:** produce the Core ML artefacts the app cannot exist without, and prove they run on the
ANE at a usable frame rate. Python work in `Tools/`, not Swift.

### The critical architectural insight

Do not run the whole of ESMFold in a loop. **Split the pipeline:**

1. **Language model, one shot.** ESM-2 650M (`facebook/esm2_t33_650M_UR50D`) runs once per
   sequence to produce residue embeddings and pair features. Expensive, but once only.
2. **Folding trunk plus structure module, iterated.** This is the cheap half and it is what
   generates frames. Export it as a *single step* model called repeatedly, carrying state.

### Tasks

1. `Tools/requirements.txt` with pinned `torch`, `transformers` or `fair-esm`,
   `coremltools>=8.0`, `biotite`. Document versions in `Tools/README.md`
2. **Export ESM-2 650M:** fp16, `computeUnits = .cpuAndNeuralEngine`, Apple `ml-ane-transformers`
   layout (4D `(B, C, 1, S)` tensors, split-einsum attention, chunked matmuls), enumerated
   length buckets 64 / 128 / 192 / 256 / 320 / 384, 6-bit palettisation via
   `coremltools.optimize.coreml` targeting ~0.5 GB on disk
3. **Export the trunk step model:** patch the trunk so the structure module emits a coordinate
   readout every N blocks (start N = 4, giving 12 frames per recycle from 48 blocks). Use a
   **stateful Core ML model** (`MLState`) to carry single and pair representations between calls.
   Outputs per call: backbone N, CA, C, O coordinates, per-residue pLDDT, block index
4. **Benchmark:** `Tools/bench_ane.py` plus an on-device XCTest harness. Per length bucket record
   cold load, one-shot LM time, per-step trunk time, frames per second, peak memory, thermal
   state after 60 s. Write to `METRICS.md`
5. **Accuracy regression:** 20 proteins, 60 to 350 residues, all-alpha / all-beta / mixed.
   TM-score, GDT-TS and mean pLDDT delta against full-precision reference. Above 0.05 TM-score
   loss from palettisation is a **halt**
6. **Manifest:** `Models/manifest.json` with file hashes, source checkpoint, toolchain versions,
   length buckets and measured accuracy deltas. Surfaced in the app's About panel. Provenance
   matters and Marc will be asked about it
7. **Mac variant:** on Apple Silicon Macs with more memory, also export an fp16 (unpalettised)
   variant and larger length buckets up to 640. Studio raises the cap; the phone does not

### Known ceiling

Triangle multiplicative updates are O(L³) in the pair representation. Length, not memory, is the
wall. Live-mode cap ~320 residues on iPhone, ~640 on Mac and Vision Pro. Above the cap the app
offers **Cinema Mode**: fold at whatever rate the device manages, buffer frames to disk, play
back at 60 fps with music.

### Fallback ladder

1. Full stateful trunk step model
2. Trunk as a fixed unrolled graph in 4 chunks, state passed as plain tensors
3. **Coarse mode:** ESM-2 embeddings into a small distilled coordinate head trained locally,
   lower accuracy, fully smooth, clearly labelled in the UI
4. **Sample trajectories:** 12 precomputed folds (ubiquitin, GFP, lysozyme, insulin, myoglobin,
   a GPCR fragment, an IDR, a designed all-alpha bundle, and four of Marc's choosing)

**Implement fallback 4 first, as task one of the entire project.** It is the fixture for every
later phase and it makes the Simulator, the Watch and CI useful.

### Exit gate

Machine-verifiable:
- [ ] `.mlpackage` files load and predict in an XCTest on the Simulator without crashing
- [ ] Accuracy regression table written to `METRICS.md`, all deltas within tolerance
- [ ] Sample trajectory bundle present and loading in `App/Resources/`

Human-verifiable (**halt**):
- [ ] ANE residency confirmed on device in Instruments
- [ ] Real-device frames per second acceptable to Marc across all six length buckets
- [ ] Marc approves the accuracy trade-off before it is baked in

---

## Phase 1: The fold engine and frame stream

**Goal:** a headless, fully tested, platform-agnostic pipeline turning a sequence into a smooth
60 fps stream of enriched `FoldFrame` values. No UI. Get this right and Phases 2 to 5 are just
consumers.

### FoldCore

- `Sequence` type: FASTA parsing (multi-record, wrapped lines, ambiguity codes, `*` and `-`
  stripping) with helpful validation errors
- UniProt fetch from `https://rest.uniprot.org/uniprotkb/{accession}.fasta` plus a metadata call
  for protein and organism name. Disk cache. Handle isoforms and obsolete accessions
- ESM-2 tokeniser in pure Swift, byte-exact against the Python vocabulary (50 fixture sequences)

```swift
public struct FoldFrame: Sendable {
    public let index: Int
    public let recycle: Int
    public let blockIndex: Int
    public let backbone: [BackboneResidue]          // N, CA, C, O
    public let pLDDT: [Float]
    public let secondaryStructure: [SSAssignment]   // with per-residue confidence 0...1
    public let newContacts: [ContactEvent]
    public let radiusOfGyration: Float
    public let meanPLDDT: Float
    public let isInterpolated: Bool
}
```

### FoldEngine

- `actor FoldEngine` exposing `func fold(_ sequence: Sequence) -> AsyncStream<FoldFrame>`
- Length bucketing and padding, model warm-up at launch
- Backpressure: bounded buffer, never drop frames (order is the trajectory), slow the consumer
  clock instead
- Cancellation, `ProcessInfo.thermalState` handling, low-power mode: degrade by reducing
  readouts per recycle, never by stuttering
- Pluggable providers: `LiveANEProvider`, `SampleTrajectoryProvider`, `CoarseProvider`. The rest
  of the app cannot tell them apart

### FoldGeometry

- **Kabsch superposition** of each raw frame onto the previous. Without it the molecule tumbles
  between steps and the animation is unwatchable
- **Interpolation to 60 fps:** quaternion slerp on residue frames, linear on translations,
  Catmull-Rom in time across raw frames. Flag interpolated frames so audio ignores them for
  event triggering
- **Secondary structure:** implement **P-SEA** (CA-only, from CA-CA distances and pseudo-torsions)
  so it works when only CA positions are trustworthy early in the trajectory. Temporal
  hysteresis of ~3 frames stops helices flickering. Emit per-residue confidence for the renderer
- **Contacts:** maintain a CA-CA contact map, emit a `ContactEvent` on inward 8 Å crossing,
  tagged with sequence separation (local / medium / long-range) and hydrophobicity of both
  partners. Long-range hydrophobic contacts are the musically interesting ones
- **Metrics:** radius of gyration, contact order, fraction buried hydrophobic, mean and minimum
  pLDDT per frame

### Exit gate

Machine-verifiable:
- [ ] `swift test` green on macOS and iOS Simulator, including tokeniser byte-equality
- [ ] P-SEA agrees with a DSSP reference on 10 PDB structures at ≥85% per-residue (CA-only)
- [ ] Ubiquitin folds end to end from the sample provider; final pLDDT and RMSD to 1UBQ logged
- [ ] Frame stream sustains 60 fps output with interpolation for a 300-residue input
- [ ] Zero data races under Thread Sanitizer with Swift 6 strict concurrency
- [ ] No `#if os(...)` anywhere in FoldCore, FoldEngine or FoldGeometry (add a lint check)

Human-verifiable: none. **The loop should complete Phase 1 unattended.**

---

## Phase 2: Aurora Stage, the renderer

**Goal:** the thing people film and post. Colourful, fluid, legible as science. Secondary
structure formation is the visual headline. Built multiplatform from the start so Phase 5 is
additive rather than a rewrite.

### Renderer

**RealityKit with `LowLevelMesh`**, so vertex buffers are rewritten each frame by a Metal
compute shader with no CPU round trip. Do not rebuild `MeshResource` per frame. Do not use
SceneKit. RealityKit is also the visionOS path, which is why it wins here.

- **Backbone tube:** Catmull-Rom spline through CA, swept with a variable cross section:
  circular for coil, flattened ribbon for sheet, thicker coil for helix. The cross section
  **morphs** with per-residue SS confidence, so structure grows rather than snapping
- **Helix emergence:** rising helix confidence adds an emissive rim and a subtle axial glow
- **Sheet emergence:** arrowheads extrude progressively toward each strand's C-terminal end
- **Contact flashes:** each `ContactEvent` spawns a short-lived emissive line and a small
  particle burst at the midpoint; long-range contacts flash brighter and linger. This is the
  visual that sells "the fold is happening"
- **Post-processing:** HDR bloom on emissives, mild depth of field, vignette, Aurora grade

### Colour modes (segmented control, animated cross-fade)

1. **Confidence** (default): AlphaFold pLDDT ramp. Orange resolving to blue is the money shot
2. **Secondary structure:** helix magenta, sheet cyan, coil slate
3. **Rainbow:** N to C
4. **Hydrophobicity:** Kyte-Doolittle, so core formation is visible

### Camera and interaction

- Slow cinematic auto-orbit, instantly overridden by drag. Pinch zoom, two-finger pan,
  double-tap reframe. Mac adds scroll-wheel zoom and keyboard shortcuts
- "Follow the action" mode eases the camera toward the centroid of recent contact formation
- Interaction never blocks or delays the fold

### Supporting readouts (compact, collapsible, below the stage)

- Timeline scrubber with recycle boundaries marked, 0.25x to 4x speed, loop a recycle
- Live stacked area chart of helix / sheet / coil fraction over time
- Radius of gyration trace with the current frame marked
- Sequence ribbon strip coloured by current per-residue pLDDT, tappable to focus a residue

### Exit gate

Machine-verifiable:
- [ ] Renderer builds and runs on iOS Simulator and macOS from the sample provider
- [ ] Snapshot tests of all four colour modes against reference images
- [ ] No frame-time regression above 20% versus the recorded baseline in `METRICS.md`
- [ ] Zero geometry NaNs across a full sample trajectory (assert in a test)

Human-verifiable (**halt**):
- [ ] 60 fps sustained on device with 300 residues, confirmed in Instruments
- [ ] No visible popping when secondary structure is assigned or reassigned
- [ ] Thermal state at or below `.fair` after 3 minutes of continuous playback
- [ ] Marc signs off that it looks like a concert, not a workbench

---

## Phase 3: The score

**Goal:** music generated from the *trajectory*, not the sequence. This is the entire
competitive argument against existing protein-to-music tools, so the mapping must be defensible
and audible.

### Audio architecture

- `AVAudioEngine` with `AVAudioUnitSampler` voices fed by a bundled SoundFont (**confirm the
  licence permits redistribution before shipping: unlicensed SoundFont is a halt**)
- `AVAudioEnvironmentNode` with HRTF for **spatial audio**: each residue's note is positioned at
  that residue's live 3D coordinate, so the fold collapses around the listener on headphones
- **Musical clock decoupled from inference.** A fixed-tempo scheduler consumes a jitter buffer of
  frames. If inference starves the buffer, hold a sustained pad and let the harmony breathe.
  Never block, never glitch. Tap `mainMixerNode` for the Phase 4 capture path
- `AVAudioSession` `.playback` with `[.allowAirPlay]` on iOS; on macOS use the default output
  device with a user-selectable route; on visionOS keep the session spatial
- Parallel MIDI event log written as the music plays, for export and for the Mac's CoreMIDI out

### Sonification mapping (the core table)

| Trajectory feature | Musical parameter |
|---|---|
| New contact event | Note onset. Sequence separation sets register: local high, long-range low |
| Long-range hydrophobic contact | Bass note plus a haptic transient |
| Helix content | Sustained pad, stacked fourths voicing |
| Sheet content | Staccato interlocking rhythmic figure |
| Coil content | Arpeggiation between chord tones |
| Mean pLDDT | Low-pass cutoff, detune, reverb wet mix. Low confidence sounds murky and out of tune |
| Per-residue pLDDT | Note velocity for that residue |
| Radius of gyration | Tempo and register. Compaction drives an accelerando |
| Recycle boundary | Harmonic modulation |
| Convergence (pLDDT plateau) | Cadence, resolving to the tonic |

Consequence worth putting in the app copy: **an intrinsically disordered region never resolves,
so it stays a detuned wash for the whole piece.** A trained ear can hear a bad prediction.

### Five style profiles

Declarative JSON in `Apps/Shared/Resources/Styles/*.json` so they are tunable without a
recompile: scale or mode, chord vocabulary, permitted voicings, drum pattern, instrument map,
tempo range, swing, articulation rules.

1. **Fantasy** (default). Implement the Tay et al. Fantasy-Impromptu approach as the *pitch
   layer* beneath the trajectory events: amino acid property mapping with R, K, D and E as
   octave-shift triggers, minor key, rapid arpeggiated figuration. Cite in About:
   Heliyon 2021, 7(9):e07933, doi:10.1016/j.heliyon.2021.e07933
2. **Jazz.** Dorian and Mixolydian, rootless seventh and ninth voicings, brushed kit, walking
   bass driven by hydrophobic core formation
3. **Rock.** Aeolian, power chords on helix formation, driving eighths, distortion depth scaled
   by contact density
4. **Pop.** Major, four-chord loop, sidechained pad, bright plucks, drop on convergence
5. **Surf.** Spring reverb, tremolo picking, Phrygian and Mixolydian mix, twelfth-fret slides on
   long-range contacts. Delightful, and nothing else in this space sounds like it

Style switching is live and beat-quantised, never a restart.

### Determinism and haptics

- Seed all stochastic musical choices from a stable hash of the sequence. **The same protein
  always yields the same piece.** Unit-tested
- `CoreHaptics` on iPhone and Watch: transient on contact formation, sharper for long-range, a
  low rumble tracking core packing, a distinct pattern at convergence. Respect system settings
- Build `Tools/preview_style.swift`, a command-line renderer that turns a sample trajectory plus
  a style profile into a WAV. This lets the loop regression-test audio without a device, and
  lets Marc audition style tweaks in seconds

### Exit gate

Machine-verifiable:
- [ ] Identical audio output hash for the same sequence across three runs (all five styles)
- [ ] Offline render of all five styles completes with no clipping; LUFS within target range
- [ ] MIDI export parses correctly and round-trips
- [ ] No audio-thread allocations detected in the scheduler (assert with a test harness)

Human-verifiable (**halt**):
- [ ] Zero dropouts across a 5-minute fold on device under thermal load
- [ ] Spatial audio verifiably tracks residue positions on headphones
- [ ] Interruption handling correct (call, Siri, route change)
- [ ] **Marc listens to all five styles and approves.** An agent cannot judge whether it is music

---

## Phase 4: Big screen, capture, and the iPhone ship

**Goal:** get it out of the phone and into the world, and ship the iOS app before the fleet
expands.

### AirPlay and external displays

- `AVRoutePickerView` in the transport bar for audio route selection
- **Dedicated external display scene** (`UIScene` role `.windowExternalDisplayNonInteractive`):
  on connection, render a clean full-bleed stage with no controls, larger type, protein name and
  confidence readout. The phone becomes the control surface. This is what makes it work in a
  lecture theatre
- Connect and disconnect mid-fold without interrupting playback
- Verify the mirroring fallback still looks acceptable, since not every route offers a separate
  display scene

### Video export

Do **not** use ReplayKit for the deliverable. Render offscreen for a clean output.

- Offscreen `MTLTexture` pass at export resolution, driven by the same frame stream
- `AVAssetWriter` with `AVAssetWriterInputPixelBufferAdaptor` for video plus an audio input fed
  from a tap on `mainMixerNode`
- H.264 and HEVC. Presets: **Landscape 1920x1080**, **Vertical 1080x1920** (social),
  **4K 3840x2160** where supported. 60 fps
- Optional burned-in overlay: protein name, accession, length, final mean pLDDT, PhoneFold mark
- Progress UI, background-safe, save to Photos with correct permission handling

### Other exports

| Format | Contents |
|---|---|
| `.mp4` | The film, with music |
| `.mid` | MIDI stems, one track per voice |
| `.cif` | Final model, mmCIF, pLDDT in the B-factor column |
| `.cif` (multi-model) | Trajectory of raw frames, for PyMOL |

### Polish and shipping

- **Onboarding:** three cards. What it does, what the music means, and the disclaimer:
  *"PhoneFold visualises how a neural network converges on a structure. It is not a physical
  folding pathway, and no protein folds this way."* Permanent short version in About. Marc will
  be asked about this and the app should answer first
- **Live Activity and Dynamic Island:** progress, current recycle, mean pLDDT
- **Sample gallery:** the 12 bundled proteins as one-tap demos, each with a note on what to
  listen for (GFP's barrel, an IDR that never resolves, lysozyme's disulfide-pinned core)
- **Mutation duet:** fold wild type and mutant in the same key, two channels, pLDDT delta driving
  dissonance. This is the feature that gets it used by protein engineers rather than admired
- **Accessibility:** VoiceOver throughout, Dynamic Type, Reduce Motion (slower orbit, no particle
  bursts), Reduce Transparency, colour-blind-safe alternative SS palette
- **App icon:** generate with Marc's `marcs-vibe-icon` skill, matching the portfolio house style
- Privacy manifest, no analytics SDKs, explicit "sequences never leave your device" on the
  App Store page

### Exit gate

Machine-verifiable:
- [ ] Offscreen export produces a valid MP4 with audio from a sample trajectory in CI
- [ ] All four export formats validate (mmCIF parses in Biotite, MIDI parses, MP4 probes clean)
- [ ] No memory leaks across 20 consecutive folds in an automated instrument run
- [ ] Full accessibility audit passes in the Simulator

Human-verifiable (**halt**):
- [ ] AirPlay to a real Apple TV shows the clean external scene with synchronised audio
- [ ] Exported video and live playback are audibly and visually identical
- [ ] Cold launch to first frame under 3 seconds on device with a warm model cache
- [ ] Signing, capabilities, TestFlight (needs Marc's Developer account)

---

## Phase 5: Fleet (Mac, Watch, Vision Pro)

**Goal:** three new surfaces, each with a genuine reason to exist. Nothing here is a port for
its own sake. Because `PhoneFoldKit` is platform-clean, each app is a presentation layer plus a
small amount of platform-specific capability.

Build order: **Mac, then Watch, then Vision Pro.** The Mac is the most useful and the least
risky; Vision Pro is the most spectacular and needs hardware Marc must be present for.

### 5a. PhoneFold Studio (macOS)

The workstation companion, and the only surface where the analysis instinct is allowed out.

- Native SwiftUI for macOS, **not** Catalyst. Multi-window, full menu bar, keyboard shortcuts
- **Higher residue cap** (~640) using the unpalettised fp16 model variant from Phase 0
- **Batch mode:** drop a multi-record FASTA or a list of accessions, fold them all, produce a
  film per protein overnight. This is the feature that makes it useful rather than a toy
- **ProRes and 4K export**, plus an image-sequence export for anyone who wants to grade it
- **CoreMIDI virtual source:** PhoneFold Studio appears as a MIDI device so Logic, Ableton or
  any DAW can record the fold live. Marc can then actually produce a track from a protein.
  Nothing in this space does this
- Drag and drop of PDB and mmCIF files to compare a prediction against an experimental structure
  (superpose, show RMSD per residue) — the one analytical concession, because on a Mac it is
  expected
- Handoff: start a fold on the phone, continue on the Mac

**Machine gate:** builds and tests on macOS, batch mode processes a 5-record FASTA headlessly,
CoreMIDI source appears and emits valid events to a loopback client.
**Human gate (halt):** Marc records a fold into a DAW and confirms the MIDI is musically usable.

### 5b. PhoneFold on Apple Watch

The conductor. It runs no inference and should never try to.

- **Transport remote** over `WatchConnectivity`: play, pause, scrub, switch style, switch colour
  mode. Digital Crown scrubs the timeline, which is a genuinely lovely fit
- **Wrist haptics of the fold:** the phone plays the audio, the Watch delivers the haptic layer.
  Contact formation on your wrist while the music plays through headphones is the single most
  distinctive thing this app can do
- **Complication:** current or last fold's mean pLDDT as a progress ring, tap to open the remote
- **Live Activity** mirroring on the wrist during a long fold
- **Standalone Fold of the Day:** one precomputed short trajectory per day, playable on the Watch
  alone as a small animation with haptics. No inference, no phone required
- Keep the UI to three screens maximum. Watch apps die of ambition

**Machine gate:** builds, connectivity handshake unit-tested with a mock session, complication
timeline entries generated correctly.
**Human gate (halt):** paired-device testing, haptic timing against audio, battery impact.

### 5c. PhoneFold on Vision Pro

The theatre. This is the version people will remember.

- **Volume mode:** the protein sits on a desk at chosen scale, folding in front of you, viewable
  from any angle. Shared space, so it can sit beside other windows during a meeting
- **Immersive mode ("the concert hall"):** full space, the protein at room scale, folding around
  you. Contact flashes as light events in the environment. Spatial audio finally does what the
  Phase 3 design always intended: notes arrive from where their residues actually are
- **Hand interaction:** pinch and drag to rotate, two-handed pinch to scale, look-and-pinch on a
  residue to pin a label and solo its note
- **"Walk into the core":** scale the protein up until you are standing inside it as the
  hydrophobic core packs around you. Absurd, memorable, and scientifically legible
- **SharePlay:** two or more people in the same fold. This is the teaching mode, and the reason
  a department might buy it
- Ornament-based transport rather than an overlay, so the stage stays clean

**Machine gate:** builds for visionOS, renderer runs in the Simulator from the sample provider,
immersive space lifecycle unit-tested.
**Human gate (halt):** everything else. Comfort, scale, spatial audio, hand tracking and
SharePlay all require the headset and Marc's judgement.

### Cross-platform gate

- [ ] `FoldCore`, `FoldEngine`, `FoldGeometry` still contain zero `#if os(...)` (lint enforced)
- [ ] All five apps build in one `xcodebuild` invocation across the workspace
- [ ] iCloud trajectory sync round-trips between two Simulators
- [ ] Universal purchase configured (**halt**: needs App Store Connect)

---

## 6. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Trunk will not export to Core ML with state | Medium | Fallback ladder in Phase 0; sample trajectories from day one |
| Triangle updates too slow beyond 200 residues | High | Length cap plus Cinema Mode; higher cap on Mac; set expectations in the UI |
| Thermal throttling during long folds | High | Reduce readout frequency, not frame rate; surface thermal state honestly |
| Palettisation degrades accuracy | Medium | Phase 0 regression table; fall back to fp16 above 0.05 TM-score loss |
| Music sounds like noise rather than music | Medium | JSON style profiles plus the CLI preview renderer; Marc's ear is the gate |
| The loop fakes progress on a gate it cannot verify | Medium | Machine / human gate split; HALT sentinel; no-placeholder rule; audit log |
| The loop burns hours on the wrong task | Medium | Small tasks, one commit each, 3-strike rule, JOURNAL.md reviewed each morning |
| Feature creep into BOFFIN's territory | Medium | Hard rule: PhoneFold is a concert. The only analysis concession is Mac structure comparison |
| Vision Pro work outpaces available hardware time | Medium | Build it last, Simulator-first, everything experiential is a human gate |
| SoundFont licensing | Low | Resolve before Phase 3 ships; unlicensed asset is a halt |

---

## 7. Sequencing and budget

| Phase | Scope | Budget | Loop autonomy |
|---|---|---|---|
| 0 | Model Forge, sample trajectories | 2 to 4 days | Partial: export is autonomous, benchmarking halts for device |
| 1 | Engine, geometry, frame stream | 2 days | **Full.** Should run start to finish unattended |
| 2 | Aurora Stage renderer | 3 days | High: halts once at the end for the device and taste check |
| 3 | Score, five styles, haptics | 3 days | High: halts for Marc's ears |
| 4 | AirPlay, capture, exports, iOS ship | 2 to 3 days | Medium: hardware and Developer account halts |
| 5 | Mac, Watch, Vision Pro | 4 to 6 days | Medium: Mac mostly autonomous, Watch and Vision Pro halt for hardware |

Exceeding twice a phase budget is itself a halt condition.

Start Phase 0 with the sample trajectory provider, then attempt the export. That way Phases 1
to 5 are never blocked on the hardest problem in the project, and the loop always has work.
