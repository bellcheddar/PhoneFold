# 🧬 PhoneFold

> **Fold a protein on your phone's Neural Engine, and listen to it happen.**

![swift](https://img.shields.io/badge/swift-6.3.3-F05138?logo=swift&logoColor=white) ![xcode](https://img.shields.io/badge/xcode-26.6-1575F9?logo=xcode&logoColor=white) ![iOS](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white) ![Core ML](https://img.shields.io/badge/Core%20ML-Neural%20Engine-0A84FF?logo=apple&logoColor=white) ![RealityKit](https://img.shields.io/badge/RealityKit-LowLevelMesh-467FF7) ![AVFoundation](https://img.shields.io/badge/AVFoundation-spatial%20audio-467FF7) ![ActivityKit](https://img.shields.io/badge/ActivityKit-Live%20Activity-467FF7) ![dependencies](https://img.shields.io/badge/dependencies-Apple%20frameworks%20only-00897B) ![swift-testing](https://img.shields.io/badge/swift--testing-530%20passing%20%C2%B7%205%20gated-30B0C7) ![models](https://img.shields.io/badge/models-Genie%202%20%C2%B7%20ESMFold%20%C2%B7%20FoldingDiff-9b51e0) ![data](https://img.shields.io/badge/data-RCSB%20PDB%20%C2%B7%20AlphaFold%20DB%20%C2%B7%20UniProt-9b51e0) ![phase](https://img.shields.io/badge/phase-5%20of%205%20(Fleet)-fcb900) ![licence](https://img.shields.io/badge/licence-MIT-1C244B) ![author](https://img.shields.io/badge/author-Marc%20C.%20Deller%2C%20D.Phil.-1C244B)

<table>
<tr>
<td>🌐 <b>Website</b></td><td><a href="https://marcdeller.com" target="_blank" rel="noopener noreferrer">marcdeller.com</a></td>
<td>✉️ <b>Contact</b></td><td><a href="mailto:marc@marcdeller.com">marc@marcdeller.com</a></td>
<td>🐙 <b>GitHub</b></td><td><a href="https://github.com/bellcheddar/PhoneFold" target="_blank" rel="noopener noreferrer">bellcheddar/PhoneFold</a></td>
</tr>
</table>

---

![Trp-cage TC5b folded on an iPhone: the pink and cyan ribbon sits on a dark indigo stage above live readouts (Rg 7.0 Å, compactness 1.02, 33 contacts, 100% native, 45/5/50 helix-sheet-coil), with structure and radius-of-gyration traces beneath and the protein gallery along the bottom](docs/screenshots/phonefold-iphone.png)

PhoneFold folds a protein on the device in front of you and turns the trajectory into music. Every note comes from the fold itself rather than from the sequence: a contact forming is an onset, how far apart in the chain its two halves are sets how high it sounds, helices are a sustained pad, sheets a staccato figure, coils an arpeggio. As the chain compacts the tempo rises, and when the structure settles the harmony resolves. Confidence is audible, so an uncertain region is dull and out of tune and a disordered protein never resolves at all.

**Why it matters:** structure prediction is something almost everyone experiences as a still picture at the end of a progress bar, which throws away the part that is actually interesting, namely how the answer was arrived at. Rendering the trajectory as sound puts a second, temporal channel on the same data, and a trained ear can hear a bad prediction before reading a single pLDDT value. It is useful for teaching how a model converges, for talks where a folding protein beats another slide, for protein engineers who want to hear where a mutation pushes a fold off course, and for anyone who wants a piece of music that no one has heard before because nobody has folded that sequence yet.

> **What PhoneFold is not.** PhoneFold visualises how a neural network converges on a structure. It is not a physical folding pathway, and no protein folds this way. The app says this on its third onboarding card and keeps a short form of it permanently in About, because it is the first question a structural biologist will ask.

## ✨ Features

**Three engines, and each one states its own claim in the interface** so a viewer is never left to assume:

| Engine | What it does | What it is not |
|---|---|---|
| **Simulate** | A CA-level structure-based (Gō) model relaxing a named protein into its known structure | Not a prediction: the answer is supplied |
| **Morph** | Geometric interpolation toward a known structure | Not physics at all |
| **Generate** | Genie 2 denoising a backbone out of Gaussian noise, on the Neural Engine | Not a named protein: it has never existed |

- **The score.** Five style profiles (Fantasy, Jazz, Pop, Rock, Surf), switchable while the piece is playing, with swing as a piecewise-linear beat warp and a tempo map driven by compaction
- **Spatial audio.** `AVAudioEnvironmentNode` with HRTF, so notes arrive from where their residues are
- **Haptics** layered on the score, and a Watch surface planned to carry them to the wrist
- **The mutation duet.** Fold wild type and mutant in the same key on two channels, with the per-residue confidence difference driving the interval between them: agreement is unison, disagreement is displaced along a consonance ladder until it reaches a tritone. The readout names the residues where the two folds diverge most
- **Exports** that all validate against something other than this repository's own reader
- **The lecture theatre.** A dedicated external display scene renders a clean full-bleed stage with no controls while the phone becomes the control surface
- **Live Activity and Dynamic Island** carrying progress, the current recycle and mean confidence
- **Accessibility.** VoiceOver labels, hints and selection traits throughout, Reduce Motion, Reduce Transparency, Differentiate Without Color, a colour-blind-safe secondary-structure palette, and Dynamic Type

## 📦 Exports

| Format | Contents | Validated by |
|---|---|---|
| `.mp4` / `.mov` | The fold rendered offscreen at export resolution with its music. H.264, HEVC, ProRes 422 HQ and 4444, up to 4K | `ffprobe`, in the phase gate |
| `.mid` | Standard MIDI file, one track per voice, with the tempo map | Round-trip through `AVAudioSequencer` |
| `.cif` | Final model, confidence in the B-factor column | Biotite, in the phase gate |
| `.cif` | Multi-model trajectory of the raw frames, for PyMOL | Biotite, in the phase gate |
| `.wav` | The score alone, loudness-normalised to ITU-R BS.1770-4 | Both gates of the standard |
| PNG sequence | Numbered frames for grading, with a README carrying the frame rate | The frame rate is the one thing a folder of PNGs cannot hold |

## 🧱 Stack

**Apple frameworks only.** No third-party code ships in the binary. SwiftLint and XcodeGen are build-time tools and are not linked into it.

| Package | Responsibility | Platform code |
|---|---|---|
| `FoldCore` | Frames, trajectories, amino acids, provenance | None, enforced by lint |
| `FoldGeometry` | Contacts, secondary structure, superposition, interpolation | None, enforced by lint |
| `FoldEngine` | The three engines, the Genie 2 sampler, mutations | None, enforced by lint |
| `FoldRender` | Tube geometry, colouring, the stage's lighting rig | RealityKit |
| `FoldAudio` | Sonifier, synthesiser, clock, MIDI, offline render | AVFoundation |
| `FoldCapture` | Offscreen stage, film writer, burned-in caption | RealityKit, AVFoundation |
| `FoldSync` | Cross-device state | WatchConnectivity |

`FoldCore`, `FoldEngine` and `FoldGeometry` contain **zero** `#if os(...)`. That is checked on every phase gate rather than trusted: if one appears, the design is wrong, not the lint.

## 🚀 Building

```bash
# The Xcode project is generated, not committed.
export APPLE_TEAM_ID=<your team>
cd Apps/PhoneFold && xcodegen generate

# DerivedData must live outside ~/Documents: iCloud puts extended attributes on
# everything there and codesign then fails with "resource fork, Finder information,
# or similar detritus not allowed".
xcodebuild -project Apps/PhoneFold/PhoneFold.xcodeproj -scheme PhoneFold \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -derivedDataPath ~/Library/Developer/PhoneFold-DerivedData build

swift test --package-path PhoneFoldKit          # 535 tests, 86 suites

# The five CoreMIDI tests are skipped in that run and say so: they fail when 86 suites
# share one process, which is the harness rather than the code (serially the whole suite
# passes). The phase gate runs them in their own invocation, for real:
PHONEFOLD_COREMIDI_TESTS=1 swift test --package-path PhoneFoldKit --filter MIDISourceTests
bash Tools/verify_phase.sh 4                    # the phase's machine gate
```

The Genie 2 weights are **not** in this repository. Obtain them from [aqlaboratory/genie2](https://github.com/aqlaboratory/genie2) under its own licence and run `Tools/export_genie2_coreml.py`.

## 🔧 Command-line tools

`PhoneFoldKit` ships four executables, each of which exists because a question could not be answered by reasoning about the code:

| Tool | Question it answers |
|---|---|
| `preview-style` | What does this trajectory sound like in this style? Writes WAV, MIDI, mmCIF, a still or a whole film |
| `foldaudio-probe` | Does the audio path allocate on the render thread? |
| `genie2-probe` | Does the reverse diffusion stay on the zero-centre-of-mass subspace? |
| `leak-probe` | Does the footprint grow across consecutive folds? |

## 📊 Measured, not estimated

Every number in `METRICS.md` was measured on this machine, and the entries that mattered most were the ones that contradicted an assumption:

- **Genie 2 diverged on half its seeds** because the sampler centred the coordinates it recorded and never the ones it fed back in. The centre of mass random-walked to 114 Å on a chain whose radius of gyration is 11 Å, far outside anything the network saw in training, and the posterior mean's `1/sqrt(alpha_t)` factor amplified the resulting nonsense at every later step. Projecting it out each step takes 3 of 6 seeds failing to 6 of 6 passing, and tightens CA-CA spacing from 3.86 to 3.94 Å down to 3.85 to 3.86 Å
- **Twenty consecutive folds cannot tell a cache from a leak.** The footprint sawtooths, climbing to about 400 MB by fold 17 and being reclaimed to 260 MB by fold 26, so a twenty-fold window sees only the climb. Over forty folds the second half sits 47 to 60 MB *below* the first
- **A destabilising mutation does not necessarily fold less completely.** Weakening villin's most buried residue produced a *higher* final native fraction than the wild type. The duet is therefore presented as a comparison of two folds rather than as a stability prediction, which would be a claim about free energy that nothing here computes

## 🧭 Project state

Phases 0 to 4 hold a green machine gate. Phase 5 is in progress.

| Phase | Surface | State |
|---|---|---|
| 0 to 3 | Engines, stage, score | Gate green |
| 4 | Exports, accessibility, the lecture theatre, iPhone ship | Gate green |
| 5a | PhoneFold Studio (macOS) | Code complete; gate held by one test-suite failure |
| 5b | Apple Watch | Planned |
| 5c | Vision Pro | Planned |

`PLAN.md` is the specification and is read-only. `STATE.md` is the task ledger, `METRICS.md` holds only measured numbers, and `BLOCKERS.md` holds what needs a human and a piece of hardware.

## ✅ To Do

Roadmap for PhoneFold, in dependency order. Completed items keep their detail: the reasoning behind a finished decision is usually the most useful thing to still have.

- [x] **The three engines.** A structure-based Gō model, a geometric morph, and Genie 2 denoising on the Neural Engine, each declaring in the interface what it is and is not
- [x] **The stage.** `LowLevelMesh` tube geometry rewritten in place each frame rather than rebuilding a `MeshResource`, with an explicit key-and-fill lighting rig shared by the live view and the offscreen renderer
- [x] **The score.** Contact onsets, hydropathy-ranked pitch, secondary structure as texture, a compaction-driven tempo map, five styles switchable mid-piece, and spatial audio with HRTF
- [x] **Exports that validate elsewhere.** mmCIF read back by Biotite, MIDI round-tripped, MP4 probed by ffprobe. A file only this repository can open has validated nothing
- [x] **The mutation duet.** Two folds in one key with the confidence delta driving dissonance, after measurement refused the first version of the claim behind it
- [x] **The lecture theatre.** An external display scene and an audio route picker, with the fold lifted above every scene so connecting a display mid-fold does not restart it
- [x] **Live Activity and Dynamic Island.** Rate-limited to 99 publishes over a 45-second fold, because pushing all 2,700 frames freezes the banner rather than failing loudly
- [x] **Accessibility.** VoiceOver, Reduce Motion, Reduce Transparency, a colour-blind-safe palette, and Dynamic Type capped at accessibility 3 (above that the controls leave no room for the protein, and PhoneFold is a stage)
- [x] **Genie 2's divergence traced to its cause** rather than worked around with a seed retry
- [x] **PhoneFold Studio.** A native macOS target compiling the same stage with its own entry point, a menu bar, and multi-window where each window owns its own fold
- [x] **Studio batch mode.** A multi-record FASTA or a list of accessions in, a film per protein out, headless. A FASTA gives sequences and PhoneFold cannot fold a sequence, so what a batch really consumes is identifiers, and a file with no accession in its headers is rejected on line 1 rather than at record 30 of an overnight run. The sequence is still read and checked against the database's, naming the first residue that differs
- [x] **CoreMIDI virtual source**, so a DAW can record the fold live. Nothing else in this space does this. Verified from a separate process enumerating CoreMIDI, which is what Logic does: no sources before the switch, PhoneFold after it, none again on quit
- [x] **ProRes, 4K and image-sequence export** for anyone who wants to grade the result. ProRes needs a QuickTime container, takes no bitrate, and carries uncompressed audio: each of those fails quietly if missed, and an MP4 holding ProRes writes without complaint and then will not open
- [x] **Drag and drop PDB and mmCIF** to superpose a prediction against an experimental structure with per-residue RMSD. The one analytical concession, because on a Mac it is expected. Matching residues by number is necessary and not sufficient: AlphaFold P00698 against 1LYZ matches all 129 by number and returns 18.11 Å, because a UniProt entry includes the signal peptide and a crystal structure of the mature protein does not. Comparing the residue *names* catches it and derives the 18-residue shift, after which the answer is 0.54 Å
- [x] **Handoff**, so a fold started on the phone continues on the Mac. It carries what to fold rather than the fold, and a missing field yields nothing rather than a default: a continuation that quietly substitutes the default engine starts something else and looks like it worked. Crossing between two real devices is still unconfirmed
- [ ] **Apple Watch.** A transport remote with the Digital Crown scrubbing the timeline, wrist haptics of the fold while the phone plays the audio, and a standalone Fold of the Day
- [ ] **Vision Pro.** Volume mode on a desk, an immersive concert hall at room scale, and SharePlay so a department can stand inside the same protein
- [ ] **The app icon**, which is blocked on a house-style skill this machine does not have
- [ ] **The human gates.** AirPlay to a real Apple TV, the Lock Screen banner, a VoiceOver audit driven by ear, cold launch on device, and a fold recorded into a DAW to confirm the MIDI is musically usable

## 📄 Licence

MIT, in `LICENSE`. PhoneFold builds on work under other licences, all compatible with it and none overridden by it: Genie 2 (Apache-2.0), ESMFold and FoldingDiff (MIT), DSSP (BSD-2-Clause), and structures from the RCSB PDB (CC0), AlphaFold DB and UniProt (CC BY 4.0). Every one is named in [THIRD-PARTY.md](THIRD-PARTY.md) with what it is used for and, for Genie 2, what was changed.

---

## 👤 Author

**Marc C. Deller, D.Phil.**  
Structural biologist & drug discovery scientist  

<table>
<tr>
<td>🌐</td><td><a href="https://marcdeller.com" target="_blank" rel="noopener noreferrer">marcdeller.com</a></td>
<td>✉️</td><td><a href="mailto:marc@marcdeller.com">marc@marcdeller.com</a></td>
<td>🐙</td><td><a href="https://github.com/bellcheddar/PhoneFold" target="_blank" rel="noopener noreferrer">github.com/bellcheddar/PhoneFold</a></td>
</tr>
</table>
</content>
</invoke>
