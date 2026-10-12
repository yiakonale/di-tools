# DPT Analyzer — Development Log

Running record of batches, decisions, findings, and open questions.
Newest entries go at the top of each section. Every completed step is committed locally.

## Status

| Batch | Scope | Status |
|---|---|---|
| 1 | `dptSettings.m` | Approved (2026-10-12) |
| 2 | Data contracts → [DATA_CONTRACTS.md](DATA_CONTRACTS.md) | Approved (2026-10-13) |
| 3 | Import & validation implementation | Approved (2026-10-13) |
| 4 | Gate detection & synchronization | **In review** |
| 5 | Measurement specification & registry | Not started (waiting on user's spec) |
| 6 | Capability-driven analysis | Not started |
| 7 | Validation & tests | Not started |

## Open questions (waiting on user)

Batch 2 (details in [DATA_CONTRACTS.md §8](DATA_CONTRACTS.md)):

Batch 4 review points:

- **Provisional window margins:** `S.windows.adaptive.pre = 1`, `post = 2` (multiples of the gate-edge duration D). Revisit in Batch 5 when the measurement thresholds are known. IGBT tail current may need a larger `post`.
- ~~Sequence-mismatch default~~ → resolved: see the acquisition model (2026-10-13).

## File map

| File | Responsibility |
|---|---|
| `dpt_analyzer.m` | Entry script: bucket configuration, path setup, orchestration. Renamed from `main.m`. |
| `dptSettings.m` | Analyzer-wide settings: defaults, overrides, validation. |
| `validateBucketConfig.m` | Validates and normalizes `cfg`; resolves a relative bucket path against the script folder. |
| `discoverCollections.m` | Finds the collection folders in a bucket (folders with a `channelMap.m`). |
| `validateChannelMap.m` | Validates a channel map and normalizes it to long form. |
| `importChannel.m` | Loads one `.mat` file (flat or struct layout) and validates it. |
| `importCollection.m` | Loads a collection: map, files, shared-timebase checks, corrections. |
| `getSignal.m` | The single accessor for reading samples; applies deskew and inversion. |
| `dptIssue.m` | Issue record constructor and echo. |
| `sync/detectGateTransitions.m` | Measures the gate levels, qualifies edges by hysteresis, times them on a local smoothed copy. |
| `sync/alignCollections.m` | Chooses the reference collection, matches edges, estimates offsets and residuals, excludes collections that cannot be aligned. |
| `sync/buildPulseTimeline.m` | Universal edges, pulses, and per-(edge, collection) windows. |
| `data/example/collection_A/` | Tek MSO58B example record and its `channelMap.m`. |
| `tests/` | Informal test scripts (`test_settings`, `test_import`, `test_sync`); formalized in Batch 7. |

## Decision record

### 2026-10-13 — Acquisition model fixed; alignment simplified

- **User decision:** all collections in a bucket share the exact same setup.
  - Horizontal scale and record length are constant.
  - The active-switch Vgs is always captured, and all transitions fit in the capture window.
  - Only the measured channels differ between collections, and the trigger point varies naturally.
  - The two Vgs waveforms are treated as identical; one file is the best case, stitching via Vgs the worst case.
  - Tests are mostly multi-pulse trains.
- **Consequences (settings 0.5.0):**
  - **Removed `"matchByTiming"`** and `S.alignment.onSequenceMismatch`. Truncation can't happen under this model, and for periodic trains the match was always ambiguous anyway. A sequence mismatch now always excludes the collection, as a missing or extra pulse or a different test.
  - **Removed `S.alignment.onSampleIntervalMismatch`.** A dt or record-length mismatch across collections is a setup error and always excludes. Record length was not checked before; it is now (`ev.recordLength`).
  - The model is listed among the settings' fixed rules (header of `dptSettings.m`).
- **New checks of the "identical gate" assumption:**
  - gate levels vs the reference (warning beyond `S.gate.levels.tolerance`);
  - edge-duration agreement (info);
  - per-edge residuals;
  - trigger plausibility (warning if an offset exceeds half an edge spacing).
- **Stitching vs the same-collection rule:** the universal timeline puts every collection's signals on one axis with shared pulse labels. Any measurement that needs simultaneously sampled signals still uses one collection. No change to that rule.
- **Verified:** `test_sync` now has 31 cases, all passing; the timing-match cases were replaced by exclusion, majority-reference, trigger-shift, level-difference, implausible-offset and dt-mismatch cases. The example pipeline is unchanged.

### 2026-10-13 — Batch 4: detection, alignment, timeline implemented

- **Detection on the example record:** 20 edges (10 pulses), 0 discarded, 0 issues. Levels −5.40 / +17.40 V. **Every edge has exactly one reference crossing.**
- **Timing smoothing (new setting `S.detection.timingSmoothing = 0.04`).**
  - *Finding:* with gate noise, `"last"` crossing selection is biased late (up to +2.9 ns) and `"first"` early (up to −3.2 ns). Gate noise therefore shifts the alignment.
  - *Fix:* each qualified edge is timed on a **local, centred moving mean of 4 % of that edge's own duration D**. Scaling with D, rather than using a fixed time, keeps it suitable from µs IGBT edges down to ns GaN edges. Qualification still uses the raw signal and the hysteresis.
  - *Sweep (noisy vs clean copy, same filter):* error 2.88 ns unsmoothed; 0.64 / 0.40 / 0.16 / **0.053** / 0.14 / 0.21 ns at 0.005 / 0.01 / 0.02 / **0.04** / 0.08 / 0.16. Bias on a noise-free tanh edge is ≤ 0.02 ns up to 0.04, then 0.19 ns at 0.16.
  - *Result:* a known 37.3 ns (233.125-sample) offset is recovered to **7 ps** with doubled gate noise, against 1.11 ns without smoothing. The noise-free case is exact.
- **Midpoint stays a poor reference** even with smoothing: 0.36 ns noise error against 0.053 ns for 25 %-from-initial. That confirms the default.
- **Window design (data-derived).** On the example, every Vds-LS/Id-LS 10–90 % transition lies inside the qualified gate edge (0.11–0.71 of D), and Vds has settled to 5 % before the edge ends. The edge itself is therefore the window **core**. The window adds `pre·D` before and `post·D` after, limited to the neighbour midpoints. A plot of a high-current turn-on and turn-off (edges 17/18) confirms this visually.
- **Settings 0.4.0:**
  - `windows.method` is `"adaptive"` | `"fixed"`; added `windows.adaptive.pre/post`; `windows.fallback.*` renamed to `windows.fixed.*`, with `windows.useFixedAsFallback`.
  - `alignment.onSequenceMismatch` is now `"exclude"` | `"matchByTiming"`, and `alignment.onSampleIntervalMismatch` is `"exclude"` | `"warn"`. This replaces `"error"`, consistent with the Q2 exclusion policy.
- **Alignment design:**
  - The reference is the most common edge sequence.
  - Matching in `"matchByTiming"` refuses ambiguous offsets: a periodic train truncated differently is excluded rather than guessed.
  - The scope trigger time is used only as a sanity check (warning if the offset exceeds half an edge spacing), never for alignment.
  - Known limitation: identically truncated strictly periodic trains cannot be told apart by any edge-based method.
- **Contract additions:**
  - §5: `ev.sampleInterval`, `ev.recordSpan`, and edge columns `startTime`, `endTime`, `smoothingSamples`.
  - §6: `al.sourceIndex`, `al.edges`, `al.excluded`.
  - §7: window columns `coreStartTime`, `coreEndTime`, `limited`; method `"fixed"`.
- **Entry script:** steps 5–6 run with the same exclude-and-continue policy.
  - Note: the script's `clear` wipes the caller's workspace, so it cannot be `run` from inside a function and keep that function's variables. This matters for the Batch 7 tests.
- **Verified:**
  - `tests/test_sync.m`: 26 cases pass. They cover real-data crops, a non-integer offset, noise, truncation, ambiguity, the midpoint flag, level mismatch, conditioning, synthetic DPT timing match, window margins, limiting, fallback, truncation, boundary edges, pulse-count warning, and minimum spacing.
  - `test_settings` and `test_import` (38) still pass.

### 2026-10-13 — Batch 3: import & validation implemented

- **Test data moved:** `testdata/` → `data/example/collection_A/` with `git mv` (a rename only). `main.m` was renamed to `dpt_analyzer.m` with `git mv`.
- **Settings 0.3.0:** added `S.corrections.nonIntegerDeskew = "round"` (Q1a) and `S.corrections.integerShiftTol = 1e-6` samples (floating-point tolerance only).
- **Two root files were added beyond the original plan:**
  - `validateBucketConfig.m`, so the entry script contains no validation logic and the check can be tested on its own;
  - `dptIssue.m`, so every stage uses one issue schema.
- **Error ids:** a `dpt:` prefix means a problem in the data. The entry script excludes a collection only for `dpt:` errors; any other error is a code bug and is rethrown, so bugs are never mistaken for bad data. `importCollection` prefixes every error with `Collection "<name>":`.
- **Loading channel maps:** each collection's `channelMap.m` is called with that folder temporarily made current (restored even on error). The cached function is cleared, and `which` confirms the right file. Tested with two collections loaded back to back: no stale definitions. The script never uses `genpath`.
- **Contract change:** `getSignal` now takes a fourth argument, `S`. It supplies the boundary tolerance and keeps configuration flow explicit.
- **Verified:**
  - The example bucket imports correctly, also when the script is run from a different working folder: 6 channels, 160 ps, 1.25 M samples. CH5 and CH8 are reported as unmapped info.
  - `tests/test_import.m`: 38 synthetic cases pass. They cover every error path, both file layouts, deskew rounding and the error policy, the shared grid in `getSignal`, inversion, untouched raw data, and discovery/config validation.
  - `tests/test_settings.m`: the settings validation cases pass.
  - Both are informal function scripts for now; they become `matlab.unittest` tests in Batch 7.
- **Runtime:** a full `-batch` run on the example takes about 21 s including MATLAB start-up. Import alone has not been timed.

### 2026-10-13 — Batch 2 review round 1

- **Q1 → post-acquisition corrections.** The scope applies deskew and inversion by default. `channelMap.m` can add per-channel `deskew` [s] and `invert` corrections on top (defaults 0 / false).
  - Deskew follows the Tek sign convention: positive delays the channel, `t_ch = t_s + deskew`.
  - Corrections are applied only when a signal is read, through a new `getSignal.m` accessor. That accessor is the single place samples are read; raw data is never rewritten.
  - All downstream times are corrected times.
  - Windows now hold only times, no sample indices, because with deskew the indices differ per channel.
- **Q1a open: non-integer deskew.** Proposed: round it to a whole number of samples (residual ≤ 80 ps at 160 ps sampling, reported). V and I then share a time grid, so products like V·I need no interpolation.
- **Q2 → exclude and continue.** An invalid collection is excluded and reported. The run aborts only if no valid collection remains.
- **Q3 → test-data mapping.** LS is the active device.
  - CH1 = Vgs-HS, CH2 = Vgs-LS, CH3 = Vds-LS, CH4 = Vds-HS.
  - MATH1 = Id-LS: the sum of the parallel-device currents CH5 and CH8, which stay unmapped.
  - CH7 = inductor current, assumed to be Iout.

### 2026-10-12 — Batch 2: data contracts proposed

- **Separate time references:**
  - scope time `t_s` (as exported);
  - universal time `t_u = t_s − offset(c)`, with `t_u = 0` at the reference collection's first turn-on.

  Shifted time vectors are never stored.
- **One time vector per collection.** This enforces the shared-acquisition invariant and avoids storing an extra 10 MB copy per channel.
- **Channels are a struct array keyed by `.signal`,** because canonical names contain `-`, which is invalid in a field name.
- **The channel map accepts a short and a long form.** Files resolve to an explicit `file` or else `<key>.mat`. `waveformSource` must match the key. Unknown fields are rejected.
- **The active gate's presence is checked at import,** so a missing gate fails before any processing.
- **Pipeline order:** detect → align → build timeline. Alignment comes before the timeline because the universal timeline needs the offsets.
- **Windows are stored per (edge, collection)** because record coverage differs between collections. Measurements on collection c read only c's windows.
- **Errors vs issues:** an invalid unit of work throws a `dpt:<stage>:<name>` error. Usable-but-noteworthy conditions become issue records with id, severity, stage, collection and message.

### 2026-10-12 — Batch 1 review outcome

- **Nominal gate levels moved to bucket config.** The user's setups range from +15/−15 V to +20/−5 V. `S.gate.nominal` was removed; `dpt_analyzer.m` will supply `cfg.gate.nominal.high/low`. The check that tolerance is less than half the swing moves to bucket-config validation (Batch 3). The sanity check on the absolute reference level moves to detection time, where the measured levels are known.
- **Level tolerance set to 1.0 V** (user decision).
- **Example data stays committed** (user decision).
- **Added `S.signals.catalog`**: a table of canonical name, quantity, device and units. It is the single definition of the signal namespace, used for channel-map validation, unit checks at import, and role-based measurement requirements. Schema version is now 0.2.0.

### 2026-10-12 — Batch 1: settings

- **Construction:** `dptSettings(overrides)` merges a struct of overrides into the defaults recursively and then validates the result. An unknown field raises an error, so a typo can't be silently ignored. Settings should not be edited after construction, because that skips validation.
- **Invariants are not settings.** Same-collection sampling equality, keeping raw waveforms unmodified, the same-collection rule for measurements, advisory pulse count, and no resampling are hard rules. The old `pulseExpectation.warnOnly`, `requireCommonDt` and `report.units` were removed for this reason.
- **Two-stage gate detection:**
  1. A hysteresis (Schmitt) trigger qualifies each edge: arms at 15 % and 85 % of the measured swing.
  2. A separate reference level gives the edge's time.
  This replaces `minSlope`, which was an unexplained constant.
- **Reference = 25 % of the swing from the initial level.** For a rising edge that is low + 25 %; for a falling edge it is high − 25 %. Both points fall before the Miller plateau, so they depend on the gate loop rather than on load current, which makes them repeatable across collections. Midpoint and absolute-voltage references are still available as options.
- **Levels are measured, nominal values validate.** Thresholds are computed from the measured levels. A nominal-vs-measured mismatch larger than 1.5 V raises an error by default, which catches a wrong channel or a wrong probe attenuation.
- **Conditioning defaults to `"none"`.** Only zero-phase, base-MATLAB methods are offered (`movmean`, `movmedian`), because the Signal Processing Toolbox is **not installed**.
- **Deferred values are `[]`, not guesses:** alignment residual limit, fallback windows, conditioning window, minimum edge spacing. One structural window rule needs no constant: windows never extend past the midpoint to a neighbouring edge.
- **Removed as premature:** the energy settings (`includeReverseRecovery`, `currentSignConvention`). They return in Batch 5. Current sign/probe polarity may belong in the channel map (Batch 2).

## Findings from test data

`testdata/Tek000_*.mat` (probed 2026-10-12):

- **Format:** Tektronix MSO58B. Each file holds **separate top-level variables** (`data`, `time`, `sampleInterval`, `recordLength`, `zeroIndex`, `verticalUnits`, `horizontalUnits`, `waveformSource`, `waveformType`, `model`). There is no wrapping struct. Import must accept both layouts.
- **Timebase:** dt = 160 ps (6.25 GS/s), N = 1,250,000, about 200 µs record. `zeroIndex` is **0-based**: `time(zeroIndex+1) == 0`. `diff(time)` is uniform to 1e-10 relative. Data are N×1 doubles.
- **Channels:**

  | Channel | Units | Range |
  |---|---|---|
  | CH2 (active gate) | V | −5.6 to 17.8 |
  | CH1 | V | median −5.6, swings to +1.8; likely the complementary gate, held off |
  | CH3, CH4 | V | 0 to 400 (Vds) |
  | CH5, CH7, CH8, math1 | A | currents |

- **Pulses:** 10 pulses (multi-pulse train, 10 µs period, about 6.5 µs on-time). Expected pulse count must not assume 2.
- **Gate edges:** slow, about 585 ns from 10 % to 90 %. Plateau noise σ ≈ 0.07 V; vertical quantization is 0.2 V.
- **Midpoint reference fails:** the 50 % crossing sits on the Miller plateau, with up to 19 recrossings spanning 136 ns. The 90 % level has up to 25 recrossings spanning 65 ns.
- **Good reference band:** 20–30 % from the initial level is clean in both directions (at most 3 crossings, at most 2 ns spread).
- **Hysteresis works:** arms at 15 % and 85 % qualified exactly 20 edges (10 rising, 10 falling) on the raw signal, with no filtering.
