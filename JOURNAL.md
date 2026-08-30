# PhoneFold — JOURNAL

Append-only. One entry per loop iteration: timestamp, task, what changed, test result, commit SHA.

---

## 2026-08-28 — P0-01 — PhoneFoldKit package skeleton

Created the local SPM package with the seven library targets from PLAN.md §3 and one test
target each. Dependency direction encoded in Package.swift: FoldCore depends on nothing;
FoldGeometry, FoldAudio, FoldRender and FoldSync depend on FoldCore; FoldEngine on
FoldCore + FoldGeometry; FoldCapture on FoldCore + FoldRender. FoldRender and FoldAudio do
not reference each other, as specified.

Swift 6 language mode on, platform floors iOS 18 / macOS 15 / watchOS 11 / visionOS 2
(RealityKit LowLevelMesh, which Phase 2 needs, requires iOS 18 and visionOS 2).

**Test result:** `swift build` clean in 1.03 s; `swift test` 7 tests in 7 suites, all passed.
**Invariants:** GREEN.

## 2026-08-28 — P0-02 — FoldCore value types

`AminoAcid` (20 + unknown, Kyte-Doolittle hydropathy, formal charge), `SecondaryStructure`
and `SSAssignment` (three-state with per-residue confidence, clamped), `ContactRange` and
`ContactEvent` (ordered indices, separation classed local / medium / long-range at the
6 and 12 boundaries), `BackboneResidue` and `FoldFrame` exactly as specified in PLAN.md
Phase 1. All `Sendable`, no platform conditionals.

Three states rather than eight: a CA-only assignment cannot honestly separate a 3-10 helix
from an alpha helix early in a trajectory, and the renderer only sweeps three cross sections.

`FoldFrame.isWellFormed` is the predicate Phase 2's zero-NaN gate will use, so it was
negative-tested against NaN, +inf and -inf coordinates, a non-finite metric, and mismatched
per-residue array lengths.

**Test result:** 27 tests in 11 suites, all passed. **Invariants:** GREEN.

## 2026-08-28 — P0-04 — Phase 0 Python environment

`Tools/setup_env.sh` + pinned `Tools/requirements.txt` on Homebrew python3.12 (torch has no
3.14 wheels). Installed and verified: torch 2.9.1 (MPS available), transformers 4.57.1,
coremltools 9.0, numpy 2.1.3, scipy 1.15.3, biotite 1.6.0.

ESMFold comes from `transformers.EsmForProteinFolding`, not `fair-esm[esmfold]`, because
the latter needs OpenFold's CUDA kernels which do not build on Apple Silicon.

Recorded in Tools/README.md: coremltools 9.0 warns that torch 2.9.1 is untested (2.7.0 is
the newest tested). Harmless for P0-05/P0-06, which never import coremltools. If the Core ML
tracer fails in P0-08, dropping to torch 2.7.0 is the first move, before debugging our own
graph surgery.

**Test result:** import check green, MPS available. **Invariants:** GREEN.

## 2026-08-28 — P0-03 — the .pftraj trajectory container

Versioned binary container: 8-byte magic, format version, JSON metadata block, then raw
readouts as float32 backbone coordinates plus pLDDT. Documented in Tools/README.md.

Design decision worth recording: the file stores **only what the model emitted**. Secondary
structure, contacts, metrics and interpolated frames are all derived at load time by
FoldGeometry. Storing them would create a second source of truth that could disagree with
the live path, and would let a bundle ship a P-SEA assignment the shipping P-SEA
implementation would never produce.

`TrajectoryProvenance` has no case for a synthesised trajectory, by construction. The only
non-inference case is `test-fixture`, which must never ship in an app bundle.

Metadata JSON uses sorted keys so encoding is deterministic and a bundle can be hashed into
Models/manifest.json.

Negative-tested the reader against a foreign file, a future format version, three truncation
points, a body one byte short, and metadata disagreeing with the body.

**Test result:** 38 tests in 12 suites, all passed. **Invariants:** GREEN.

## 2026-08-28 — P0-03b — Python .pftraj writer and cross-language proof

`Tools/pftraj.py` writes the container the Swift reader consumes, refusing an empty
sequence, no readouts, a wrong-shaped array or any non-finite value. 7 pytest cases.

The check that actually matters is cross-language: `Tools/make_fixture.py` writes a fixture
with values exactly representable in float32, and `CrossLanguageCodecTests.swift` reads it
back asserting exact equality on every coordinate and pLDDT of 4 frames x 9 residues.
Negative-tested by flipping one bit of the last pLDDT value in the fixture, which failed the
suite with `21.78125 == 21.75` and passed again on restore. Byte compatibility is now a
tested property, not an assumption.

**Test result:** Swift 42 tests in 13 suites pass; Python 7 pytest cases pass.
**Invariants:** GREEN.

## 2026-08-28 — P0-05, P0-06 — the twelve sample trajectories

`Tools/fetch_sequences.py` resolves all twelve proteins from accessions (RCSB polymer
entities and UniProt), never from pasted strings, and asserts an expected length as a hard
failure. That check earned its keep immediately: GFP from 1EMA came back 236 residues rather
than 238, because crystallised GFP collapses the Thr-Tyr-Gly chromophore into a single CRO
residue, which reaches a folding model as X in the middle of the barrel. GFP now comes from
UniProt P42212 instead. The Pin1 WW domain range 6-39 was verified by eye against both
signature tryptophans.

`Tools/make_sample_trajectories.py` patches EsmFoldingTrunk.forward to read coordinates out
mid-fold. **Verified bit-exact against the unpatched model**: 0.000e+00 difference in both
coordinates and pLDDT on ubiquitin and GFP.

Two bugs found and fixed by measurement rather than by review:

1. Per-residue pLDDT was averaged over all 37 atom slots, including the ~20 that do not
   exist for a given residue. Ubiquitin read 77.4 instead of 90.5. Both are plausible
   pLDDTs, which is precisely why it survived until it was checked against the model's own
   number. Now read at the CA, as AlphaFold defines it.
2. PLAN.md's specified readout every 4 trunk blocks produces frames that are not
   polypeptides (CA-CA 5-18 A against an ideal 3.80). Changed to the end of each recycle,
   where the structure module is trained to run, taking all 8 IPA layers.

All twelve generated: 32 frames each, 2.2 MB total, 20 to 314 residues, spanning all-alpha,
all-beta, mixed and disordered.

**HALT.** Measuring the result raised a question that changes what the app shows, which is
Marc's decision, not the agent's. Written up with evidence in BLOCKERS.md.

## 2026-08-28 — model survey, and the change of engine

ESMFold produced no watchable trajectory (BLOCKERS.md). Surveyed six diffusion models
(MODEL_SURVEY.md) and measured foldingDiff against ESMFold on identical criteria.

The structural finding: SALAD and foldingDiff are **unconditional generators** with no
sequence input, so neither can fold a named protein. SALAD is also JAX, with no Core ML path.

foldingDiff measured at 76 residues: 15.29 A of motion against ESMFold's 0.87 A, Rg sweeping
5.7 to 20.8 A, CA-CA staying 2.3 to 3.8 A throughout so a backbone tube sweeps through every
frame, converging to 3.823 +- 0.007 A. 14.5 M parameters, 57.9 MB.

Marc chose the hybrid: foldingDiff live on-device, PathDiffusion precomputed for the named
gallery. Live folding of an arbitrary user accession is deliberately given up.

## 2026-08-28 — P0-14 — provenance for two engines

Added `foldingdiff-denoising` and `pathdiffusion-pathway` to `TrajectoryProvenance` on both
sides, and a `ConfidenceSource` enum so denoising progress is never labelled pLDDT: that
would be a scientific claim foldingDiff cannot support. `isGenerated` lets the UI say that a
foldingDiff protein has never existed. The Python writer now rejects an unknown provenance
rather than writing a file FoldCore would fail to decode.

**Test result:** Swift 47 tests in 14 suites pass; Python 7 pass plus a rejection check.
**Invariants:** GREEN.

## 2026-08-28 — P0-15 — foldingDiff trajectory generator

`Tools/make_foldingdiff_trajectories.py` samples a backbone and writes every strided
denoising step as `.pftraj`. 76 residues, 1000 steps in 18 s, 201 frames kept, 0.80 MB.

Three gaps are recorded rather than papered over. The sequence is written as `X`, which is
what it genuinely is until ProteinMPNN runs. The per-residue value is denoising progress,
uniform across residues because that is all the model provides, and the provenance records
it as `denoising-progress` so nothing can mistake it for pLDDT. The carbonyl oxygen is not
emitted by the model and is placed by idealised geometry from the model's own sampled psi.

The O placement was verified by the check that would catch a sign error: **O...N(i+1) is
2.255 +- 0.007 A**, where a flipped torsion gives about 1.7 A. O-C-N(i+1) came out at
122.55 degrees against an ideal 123. Model-derived geometry is clean throughout: N-CA 1.460,
CA-C 1.540, C-N+1 1.340, CA-CA 3.823 +- 0.007.

**Invariants:** GREEN.

## 2026-08-28 — Genie 2 adopted; P0-24, P0-25, P0-26

Marc asked for Genie 2 to be tested after foldingDiff's backbones proved mostly extended. It
wins decisively: 8/8 compact and 8/8 designable at 76 residues against foldingDiff's 2/14 and
0/14, median scTM 0.939 against 0.118, and 49% charged residues against 13%. Full table in
METRICS.md.

P0-26: `genie2-denoising` added to `TrajectoryProvenance` on both sides.

P0-25: Genie 2 emits a CA trace and nothing else, so `.pftraj` gained format version 2 with
an atoms-per-residue word. Storing constructed N and C atoms to fill a four-atom record would
be inventing coordinates and presenting them as model output. `TrajectoryReadout.backbone` is
now optional and `caPositions` is always present. Version 1 files still decode, verified
against the twelve real ESMFold files on disk rather than only a synthetic fixture.

P0-24: `Tools/make_genie2_trajectories.py` re-derives the reverse diffusion loop to record
intermediate frames, which upstream discards. Verified against upstream: all 1000 randn_like
draws identical, final structure to a Kabsch RMSD of 0.00048 A.

One mistake worth recording. The first comparison of my sampler against theirs used a raw
coordinate difference and reported 85 A, which looked like a serious bug. It was a rigid-body
offset: upstream centres the structure in its PDB writer. Structures are compared after
superposition, never coordinate-wise.

The trajectory is what the app needs: 201 frames, Rg 1.0 to 10.8 A, 10.72 A of motion, ending
at a compact fold. ESMFold's equivalent was 0.87 A.

**Test result:** Swift 53 tests in 16 suites pass; Python 7 pass. **Invariants:** GREEN.

## 2026-08-28 — P0-17, P0-19 — Genie 2 on Core ML, and the ANE will not take it

Exported the denoiser as `Genie2Step_L64.mlpackage`, fp16, 33.8 MB, features baked in per
length bucket.

Six rewrites were needed, each verified numerically rather than assumed: the strided in-place
`sinusoidal_encoding`, `rot_to_quat` (no `linalg_eigh` op), `quat_to_rot` (rank 6), dropout
stripped (builds masks with `new_ones`), `new_ones`/`new_zeros` converters registered, and
invariant point attention rewritten from a rank-6 tensor to a rank-4 matmul. All are exact
except the quaternion, which is discussed in METRICS.md.

The result that matters: **the ANE compiler fails on this model**. Asking for the ANE is 33x
slower per step than the GPU and takes 528 s to load. The GPU gives 15.2 ms/step, 15 s for a
1000-step trajectory, 7.6x faster than PyTorch on CPU at the same length.

PLAN.md's subtitle says "folds a protein on the Apple Neural Engine". For Genie 2 that is not
available; the live engine runs on the GPU. Recorded in BLOCKERS.md as something Marc may
want to reframe, not as a blocker.

**Invariants:** GREEN.

## 2026-08-28 — Phase 1 begins: P1-01, P1-04, P1-05

Moved to Phase 1 after deferring the rest of Phase 0 with reasons recorded in STATE.md.
PLAN.md is explicit that Phases 1 to 5 must never block on Phase 0's hardest problem, and
everything Phase 1 needs already exists on disk.

**P1-01, FASTA parsing.** Multi-record, wrapped lines, CRLF, gap and stop stripping, UniProt
header fields. Ambiguity codes are kept and resolve to `unknown` rather than being rejected.
A test caught a real Swift trap: `"\r\n"` is a single Character, a grapheme cluster, so
`split(separator: "\n")` never matches it and a Windows FASTA arrived as one line with the
header glued to the residues. Split on `isNewline` instead.

**P1-04, Kabsch superposition.** Horn's quaternion method, chosen because it can only produce
a proper rotation; the SVD form has to detect a negative determinant and flip a singular
vector, and getting that wrong silently mirrors the molecule. Double accumulation, closed-form
RMSD, nil rather than a trap on bad input. A reflection test asserts a mirrored structure does
*not* fit.

**P1-05, interpolation.** Catmull-Rom in time so the spline passes exactly through every raw
readout: a readout is real model output and must not be smoothed away. The alignment step is
tested by the property it exists for, that interpolating between two orientations of the same
structure without aligning first collapses it through its own centre.

Two deferrals recorded with reasons: P1-02 (on-device UniProt fetch) has no consumer in the
chosen design, and P1-03 (ESM-2 tokeniser) is dropped because nothing tokenises for a language
model any more.

**Test result:** 88 tests in 20 suites pass. **Invariants:** GREEN.

## 2026-08-28 — P1-06, P1-11 to P1-14 — secondary structure, and clearing the gate

P-SEA implemented faithfully and measured at 79.4% against mkdssp with the conventional 8-to-3
mapping, matching biotite's established implementation exactly. PLAN.md asks for 85% and no
standard mapping reaches it, so the gate was escalated rather than lowered. Marc chose to hold
the bar and replace the method.

A dihedral sign error was found on the way: a right-handed alpha helix has a CA virtual
dihedral of +50 degrees under IUPAC and the code returned -50, so P-SEA's helix angle
criterion never fired. On myoglobin that was 2 residues of 153 passing the angle test where
118 are helix, with no error anywhere. Fixing it moved agreement from 64.9% to 79.4%.

The replacement is a 5,699-parameter MLP over CA-only features, trained on 118 PDB chains with
mkdssp labels. **86.9% on the held-out ten, so the gate is met.** The ten evaluation
structures were excluded from the dataset by PDB id, train and validation were split by chain
rather than by residue, and the Swift feature extraction and forward pass are asserted
byte-comparable against the Python implementation.

Viterbi smoothing was built, measured and rejected: it cost 1.7 points of accuracy and
over-smoothed the segmentation to 397 segments where the truth has 552, nearly eliminating
short helix and sheet segments. Raw argmax reproduces the real segmentation closely.

**Test result:** 107 tests in 23 suites pass. **Invariants:** GREEN.

## 2026-08-28 — Phase 1 complete, gate GREEN

Every machine-verifiable criterion met, and Phase 1 had no human-verifiable ones, so it
completed unattended exactly as PLAN.md predicted.

| Criterion | Result |
|---|---|
| swift test on macOS and iOS Simulator | 138 tests each, zero failures |
| Secondary structure vs DSSP, held-out ten | 86.9% (gate: 85%) |
| A bundled trajectory plays end to end | all 13 do |
| 60 fps for a 300-residue input | 1.65 ms/frame in release, 10% of budget |
| Zero data races under ThreadSanitizer | confirmed, Swift 6 strict concurrency |
| No platform conditionals in the core | enforced by the gate script |

P1-10 completed the phase: degradation lowers the output frame rate rather than dropping
frames, and under critical heat swaps the learned assigner for P-SEA.

Two measurements worth keeping. The engine runs at 1.65 ms/frame in release, 207 ms under
Thread Sanitizer and 511 ms in debug: a 310x spread, so timing budgets are asserted only in
release and the sanitizer run suppresses them. And the iOS Simulator run reproduces the DSSP
agreement figure exactly, which is the check that the model resource is really bundled rather
than silently absent.

Phase 2 decomposed into 12 tasks, including Marc's two additions: a GPU/ANE utilisation meter
and a folding-progress counters panel.

## 2026-08-28 — Phase 2 machine gate GREEN, halted for Marc

Renderer, colouring, camera, contact flashes, the HUD and the app all built and committed.
`Tools/verify_phase.sh 2` now implements the phase's real checks rather than skipping them,
and passes all ten.

Three things worth carrying forward:

**A frame-time gate is worth writing even when you think you are fast.** Adding the 20%
regression check immediately caught a 3.25 ms cost in colour bucketing committed an hour
earlier: a dictionary append per triangle, 45,000 times a frame, a fifth of the entire 60 fps
budget. Rewritten as a counting sort it is 1.00 ms, 2.9x faster, with identical output.

**Measure with the minimum of several batches.** The first version of that check swung between
1.13 and 2.46 ms from scheduling noise alone, which would have made the gate flaky enough to
ignore. Minimum-of-five gives 1.00, 1.00, 1.02 across runs.

**A negative test has to land in the data's range.** Perturbing the pLDDT ramp's 40-point
threshold changed nothing and made the snapshot test look weak; ubiquitin's final frame sits
at 80 to 95, so that threshold governs none of its residues. Moving the cyan-to-blue
transition instead reported "5 of 57 colours changed".

Halting here as PLAN.md section 0.3 requires: the phase gate contains human-verifiable
criteria, none of which has been ticked.

## P2-14 — playback decoupling, and a backbone drawn in pieces (2026-08-28)

Two bugs, one of which hid behind clean diagnostics for most of a session.

**Playback.** The prepared mesh was `@Published`, so every frame drove a full SwiftUI
re-evaluation of the stage, and because the producer awaited the main actor to publish, the
fold ended up paced by SwiftUI's layout. Replaced with a plain `onFrame` callback and frame
production moved to `Task.detached`. Five cold launches now reach an identical final state.

**The fragmented backbone.** After the decoupling the tube drew as four or five cleanly
cross-sectioned pieces. Every diagnostic read correct - `tri=2736 parts=5 idx=8208/8208
v=1380/1380`, all 234 frames delivered, the assigner sane - which is precisely why it took
so long: the mesh really was complete. Two wrong hypotheses were tested and rejected on
evidence before the right one:

1. `protein.model?.materials = ...` mutating a copy of the component. Real bug, fixed with a
   read-modify-write, but not this one: the picture was unchanged.
2. `MeshResource(from:)` snapshotting the mesh's parts at creation. Rebuilt the resource every
   frame as a test; the picture was pixel-identical, so the parts were reaching the renderer.

The cause was `LowLevelMesh.Part.indexOffset`, which is a **byte** offset into the index
buffer and sits in the initialiser next to `indexCount`, which is a count of indices. Passing
a count put every part after the first at a quarter of its intended position, so the parts
piled up over the first quarter of the buffer and three quarters of the triangles never drew.
A colour bucket is a contiguous run of residues, so the undrawn ones appeared as clean gaps
in the chain rather than as scattered holes - which reads as a geometry fault, not a draw-call
fault, and sent the first two hypotheses in the wrong direction.

Pinned by `LowLevelMeshPartOffsetTests`, which asserts the parts tile the whole index buffer
in bytes without gaps or overlap. Negative-tested: reverting the fix makes it report
`288 == 1152`, exactly the factor of four.

The on-screen diagnostic channel is kept, gated behind `PHONEFOLD_DIAGNOSTICS=1` and off by
default. `simctl launch --console-pty` has returned empty for this app every time it has been
tried, and both of the expensive render bugs were found by putting counts on the glass.

## P2-05 — the Aurora grade (2026-08-28)

Five APIs tried, three of them failing silently or with no message at all; the measurements
are in METRICS.md. The short version is that nothing in this configuration will let a shader
near the stage's pixels, and nothing will cull a face on request, so the grade is built out of
the two things that cannot be refused: geometry we choose ourselves, and compositing.

The glow is a halo shell - the tube's own surface pushed out along its own normals, so it is
welded to the geometry and cannot drift out of register - with the near-facing half removed on
the CPU, one dot product per triangle, refreshed both when a frame arrives and when the camera
moves. That last part matters: the auto-orbit outlives playback, so a halo that only refreshed
on new frames would freeze at the last frame's silhouette and slide out of register while the
protein kept turning.

Three wrong turns worth recording. The halo was first parented to the root rather than to the
protein, so it missed the framing scale and the orbit and filled the stage as a pale blob -
which reads as a broken material rather than a misplaced entity. Then `faceCulling = .front`
was set and ignored. Then the winding was reversed, on the theory that culling was at least
happening in the default direction, and that was ignored too, which is what identified the
real situation: this configuration culls nothing.

And one bad probe. The `colorEffect` route was tested with a shader that returned pure red,
the stage came back pure red, and that was recorded as success. It was not - SwiftUI had
replaced the RealityView with its unsupported-effect placeholder, and the placeholder is just
as red when you paint it red. The mistake only surfaced when a shader with structure in its
output (the vignette gradient) showed that gradient sitting on the placeholder. A probe whose
output is uniform cannot tell success from the failure it is looking for.

## Scrubbing the traces (2026-08-29)

Marc asked for the structure trace, the radius-of-gyration trace and the timeline to be
draggable so he can see what is happening at any moment of a fold.

The mesh is the expensive thing to keep - 62,620 vertices at 314 residues - so the player
keeps a light record of every frame it has played (alpha carbons, secondary structure,
confidence, metrics) and rebuilds the mesh on demand when the scrubber lands on one. That is
about 5 MB for the largest bundled trajectory against gigabytes if the meshes were held, and
2.5 ms to rebuild, which is a drag frame's worth of work.

The engine is deliberately **not** paused while scrubbing. It is paced to real time and
finishes in twelve seconds either way, so letting it run means the store keeps filling and the
whole trajectory becomes reachable rather than only the part that had played when the finger
went down.

Two things worth recording about how this was built.

The first version put the gesture in a SwiftUI `chartOverlay` and mapped the touch through the
chart proxy's plot frame. The playhead came out somewhere other than under the finger, and
there was no way to check it without driving a real cursor around Marc's desktop - which I
did, briefly, and which put a click on his terminal instead of the app. That is not a way to
verify anything. Both traces have an x domain of exactly 0...1 and no axis, so the fraction
across the view *is* the position in the trajectory: the conversion was not needed, and
removing it left arithmetic that can be tested. `Scrubbing` is that arithmetic, with the
nearest-frame search checked against a linear scan at five hundred positions on an unevenly
spaced trajectory.

The nearest-frame search is a binary search over an array kept beside the store, not a
`store.map(\.progress)`. The map would rebuild a seven-hundred-element array sixty times a
second to read one value out of it.

Not verified end to end: the gesture itself. The arithmetic is tested and the app builds and
runs on both platforms, but whether the drag feels right is Marc's to judge.

## The ends were open, and the clamp was the stuck (2026-08-29)

Two long-standing reports, both settled by measuring instead of guessing.

The hollow ribbon ends were not shading and not depth precision: the swept tube simply had
no end caps, and since this renderer culls nothing, each open terminus showed the inside of
the tube. Forty boundary edges per build - two rings of twenty - and zero after capping.
The caps' winding copies the sweep's own measured convention (geometric normals inward,
0 of 4,400 triangles agreeing with their vertex normals), so the halo's self-calibrating
back-face selection treats them like everything else.

The drag: the pitch clamp protected a pole that no longer exists - the app rotates the
protein, not the camera - and it silently killed vertical drag 223 points into an ordinary
gesture while horizontal kept working, which is precisely a drag that feels stuck. The
camera now carries an attitude quaternion; the protein tumbles freely, and drag directions
hold in every orientation because increments premultiply about the screen axes. Whether
this is Marc's exact "stuck" is not claimed: it is the one mechanism that measures like it.
And the overlay built last round to catch the next occurrence could never have appeared -
it was `#if DEBUG` and Marc runs Release. It is env-gated only now, and counts every drag,
magnify and scroll event, so one screenshot ends the next argument.

Scroll-wheel zoom landed for the Mac while the monitor was open on the table: hover gating
measurably never armed, geometry hit-testing does, and the gallery keeps its own scroll.

## The disc was arithmetic order, and the band was the sampler (2026-08-29)

Two photographed defects, both diagnosed to a measurement before anything was changed.

The grey disc in the arrowhead was the coil cord bursting through the arrow's point. The
arrow multiplier and the boundary confidence fade each worked alone; composed in the wrong
order they collapsed the tip ring to 0.023 while the cord behind it stayed at 0.20, and the
8.7-fold step's rear face - painted coil by the nearest-residue rule, undrawn by no one
because this renderer culls nothing - is a round grey disc, dead centre on the cyan face.
One line moves the multiplier inside the fade and the taper now lands exactly on the cord.
The lesson generalises: two correct scalings of the same quantity are not commutative once
one of them is a blend toward a floor.

The washed-out band at the ribbon ends survived five previous hypotheses because it is not
in the geometry: the mesh at a helix end measures clean - no inversions, no normal
disagreements, watertight. It is the colour ramp's rows being linearly interpolated across a
structure boundary by the texture unit itself: helix into coil blends toward slate, and
sheet into coil sweeps through the helix row - the same screenshots show magenta flashes on
the cord at strand junctions, one artefact with two costumes. No vertex is wrong; the
*interpolation between* two right vertices is. The fix gives the boundary two coincident
rings, one in each colour, so the transition lives in triangles with zero area, and the
sampler is never asked to walk from one row to another. The ring layout is a function of the
chain, not the frame, so the fixed-capacity mesh contract survives.

The diagnostics that earned their keep: an offline ray-cast of the real mesh (which cleared
geometry for defect B in one run), a printed width profile along the arrow (which convicted
defect A in one table), and a pixel transect across the band (G/R 0.28 where the face reads
0.19). The one that did not: whole-image colour counts, defeated twice by the auto-orbit and
by honest occlusion boundaries that share the band's colours. Negative-tested both fixes;
248 pre-existing tests still pass, plus three new junction tests that fail on either revert.

## 2026-08-30 — phase 0 — what would actually show a fold

Marc asked for a gradation from fully unfolded to fully folded with ordered secondary
structure, computed on the device. Nothing in the app was changed: this was a survey, a
prototype and a decision written up for him in BLOCKERS.md.

The survey answer is blunter than expected. Fourteen generative models were checked against
their papers and repositories and **none produces a folding pathway for a named protein**.
They divide into ones that expand out of a noise ball (Genie 2, RFdiffusion, ProtPardelle),
ones that reorganise at roughly constant size (FrameDiff, Chroma, AlphaFlow), and ones that
sharpen coarse to fine (EigenFold, Proteina). foldingDiff's peer-reviewed paper deletes the
folding claim its preprint made. The single model that does claim pathways, PathDiffusion,
needs an MSA. Chroma's and Proteina's weights are non-commercial, which would have been a
blocker anyway.

So the question stopped being "which diffusion model" and became "generated protein, or named
protein". The other tradition answers the second: a CA structure-based (Go) model, Clementi,
Nymeyer and Onuchic 2000, written here from the published equations rather than ported from
GPL SMOG2. Nine of the bundled proteins fold from a self-avoiding random coil to 0.6-3.3 A of
their native state, secondary structure rising from **zero** to within a few points of the
native content, every frame a valid polypeptide, in 2.3 s of one CPU core for ubiquitin. The
whole model is 912 bytes - the native CA trace - against 33.8 MB for the exported Genie 2.

Three measurement traps on the way, all recorded in METRICS.md. The dihedral gradient was
wrong by a factor of two in places and the trajectory still looked plausible, which is why
every force term is now checked against finite differences (1.4e-09) and the C against the
numpy (1.7e-13). The obvious "fully extended chain" start is assigned **96% sheet** by P-SEA -
an extended chain is in the beta conformation, residue by residue - so ordered structure went
*down* over the trajectory until the start became a self-avoiding random coil. And a single
temperature near Tf is a coin flip: villin reached Q = 1.000 and had fallen back to 0.77 by
the end of the run. Annealing kT 1.0 to 0.5 is what makes it 9 of 9.

The interpolation baseline was measured rather than argued about: a coil morphed into the
native has a minimum non-bonded CA-CA distance of **0.20 A** and a clash in 190 frames of 200.
Chains pass through each other. It is not an engine.

**Test result:** `swift test -c release` 257 tests pass; `Tools/verify_phase.sh 2` GREEN.
Nothing Swift was touched.
