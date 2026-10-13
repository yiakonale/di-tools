# DPT Analyzer — Development Log

Running record of batches, decisions, findings, and open questions.
Newest entries go at the top of each section. Every completed step is committed locally.

## Status

| Batch | Scope | Status |
|---|---|---|
| 1 | `dptSettings.m` | Approved (2026-10-12) |
| 2 | Data contracts → [DATA_CONTRACTS.md](DATA_CONTRACTS.md) | Approved (2026-10-13) |
| 3 | Import & validation implementation | Approved (2026-10-13) |
| 4 | Gate detection & synchronization | Implemented; review folded into Batch 5 |
| 5 | Measurement specification & registry | 5a, 5b done; **5c in review** (2026-10-14); 5d–5h to go |
| 6 | Capability-driven analysis | Not started |
| 7 | Validation & tests | Not started |

## Resume here

_Last session ended 2026-10-13. Every step is committed locally._

**State:**
- Batches 1–3 are approved. Batch 4 (detection, alignment, timeline) is implemented and in review.
- Running `dpt_analyzer.m` executes workflow steps 1–6 end to end on `data/example`: 10 pulses, 20 edges, 20/20 windows usable.

**Before continuing:**
- Read this log, then [DATA_CONTRACTS.md](DATA_CONTRACTS.md), then the headers of `dptSettings.m` and `sync/*.m`.
- Re-run the tests to confirm the baseline. With `tests/` on the path, call `test_settings; test_import; test_sync; test_primitives; test_operating_point` (38 + 31 + 33 + 39 cases, plus the settings checks).

**Next step: Batch 5d** (timing #13–23, slew rates #24–28), once 5c is reviewed.
- [MEASUREMENT_DESIGN.md](MEASUREMENT_DESIGN.md) is approved; its §10.1 records every decision.
- The user's specification is stored verbatim in [MEASUREMENT_SPEC.md](MEASUREMENT_SPEC.md); row numbers #1–#55 refer to it.
- Sub-batch order: 5b primitives, then 5c operating point and conduction, 5d timing and slew, 5e energy, 5f stress, 5g reverse recovery, 5h parasitics, then Batch 6.

**Open points:**
- **Window margins are provisional.** `S.windows.adaptive.pre = 1`, `post = 2` (multiples of the gate-edge duration D). Revisit them against the Batch 5 threshold definitions; IGBT tail current may need a larger `post`.
- **`S.alignment.maxResidual` is unset.** Calibrate it once a real bucket with two or more collections exists: the residuals will show the real shot-to-shot gate jitter.
- **Batch 7 note:** the `clear` in `dpt_analyzer.m` wipes the caller's workspace, so tests must not `run` it from inside a function and expect that function's variables to survive.

**Working agreements:**
- Commit locally after every step. Stage only `dpt-analyzer/` paths: the parent `di/` repo has unrelated modified `.mlx` files.
- The user pushes to the remote themselves.
- Batches go out for review and pause for feedback.
- MATLAB R2024b is at `C:\Program Files\MATLAB\R2024b\bin\matlab` (`-batch` works). The Signal Processing Toolbox is **not** installed.

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
| `normalizeCurrentSensors.m` | Opt-in I_D / I_L sensor calibration on the on-state segments (pipeline step 6b). |
| `measurements/measurementRegistry.m` | Measurement and method definitions (slots, tags, implementations). Currently #1–4 and #49–54. |
| `measurements/evaluateMeasurement.m` | Optional/device gating, method selection by preference and available signals, skip reasons. |
| `measurements/eventContext.m`, `gateInstant.m`, `windowStats.m`, `resolveRole.m`, `makeResult.m`, `valueFlags.m`, `formatResult.m` | Framework helpers: event times in corrected time, V_GS p % instants, window statistics, role to signal, result skeleton, quality flags, tagged one-line output. |
| `measurements/measureBusVoltage.m`, `measureSwitchingCurrent.m`, `measureConduction.m` | Implementations of #1–2, #3–4 and #49–54. |
| `tests/makeSyntheticDPT.m` | Synthetic phase-leg generator with known truth, for measurement tests. |
| `measurements/primitives/` | Pure numeric building blocks with explicit arguments (no settings): `findCrossing`, `transitionThreshold`, `integrateBetween`, `noiseLevel`, `settlingTime`, `filterSignal`, `differentiateSignal`, `savgolKernel`, `ringingFrequency`, `slopeBandMax`. |
| `data/example/collection_A/` | Tek MSO58B example record and its `channelMap.m`. |
| `tests/` | Informal test scripts (`test_settings`, `test_import`, `test_sync`, `test_primitives`, `test_operating_point`); formalized in Batch 7. |

## Decision record

### 2026-10-14 — Batch 5c: normalization, operating point, conduction

- **Part 1, foundations (settings 0.6.0):**
  - `S.measurements` populated: shared parameters relative to D (Q6), noise-floor multiple 3, gate basis, normalization acceptance, `enableOptional`, method preference lists, parameters.
  - Catalog: `Vdc`, `Vds-HS-clamp`, `Vds-LS-clamp`, and the documented sign conventions (Q1).
  - Bucket config: `cfg.deviceType` is now **required**; `cfg.nominal.*` and `cfg.currentNormalization.*` are optional.
  - `getSignal` applies the gain/offset corrections.
  - The timeline's window table gains `territoryStartTime`/`territoryEndTime`. The territory is always the midpoint region; only window *limiting* depends on `limitToNeighborMidpoint`.
- **Part 2, current-sensor normalization** (`normalizeCurrentSensors`, pipeline step 6b):
  - An affine fit over the on-state segments, applied as a declared correction.
  - Refused on a negative gain, a residual above 2× the noise-based expectation, or a per-pulse gain spread above 2 %. All failing reasons are listed.
  - Example: k = 1.0691, b = −0.10 A, residual 1.98 vs 2.05 A expected, spread 0.26 %, so it is applied.
  - Synthetic: a ×0.95 + 1.5 A sensor error is recovered exactly. Saturation, inversion, a single pulse and a missing Iout are all refused or reported.
- **Part 3, framework and operating point:**
  - Registry with **requirement slots** (alternatives in preference order).
  - `evaluateMeasurement` handles selection and skip reasons. Tags are `IEC 60747-x` or `Conv: <label>`.
  - Gate instants use the edge's local smoothing.
  - #1–4 implemented: the bus channel is preferred; I_on/I_off come from I_L at V_GS 10 %/90 % (mean ±D/2), with extrapolated-I_D and nominal options.
- **Part 4, conduction #49–54 (optional):**
  - Two shared windows: on-state (final portion / delay-to-end / custom) and diode (from the settled turn-off to the next V_GS 10 %).
  - The clamped V_DS channel is used automatically when mapped.
  - Time-resolved R_on produces one result per delay.
  - A power inherits its voltage's resolution flag.
- **Findings:**
  - V_DS-based V_DC reads high by V_F of the freewheel diode (3–8 V on the example); the bus channel is preferred for this reason.
  - Extrapolated I_on undershoots by the ramp over the delay to the current rise (−0.9 A synthetic).
  - Example: I_on(k+1) − I_off(k) goes from +1.96 A to −0.79 A over the train (turn-off delay ramp vs V_F loss in the break).
  - Every example on-state voltage is flagged resolution-limited (2.8 V ADC step).
- **Verified:** `tests/test_operating_point.m` passes 39 cases (synthetic truth, fallbacks, normalization accept/refuse, example sanity). All earlier suites still pass.

### 2026-10-14 — Batch 5b: shared primitives implemented

- **Design choice:** the primitives are pure numeric functions with explicit arguments and do not read `S`. Defaults such as the noise-floor multiple and filter windows belong to the method layer (5c onward), where each can be justified on data. They live in `measurements/primitives/` (10 files) and are added to the entry script's path.
- **Percent convention fixed: amplitude scale** (IEC): p % = low + p·(high − low), whatever the direction. "V_DS falls to 90 %" is the start of the fall. A test that used "fraction of transition completed" produced a negative t_vf, which exposed the ambiguity. Documented in `transitionThreshold` and design §5.4.
- **Ringing frequency:**
  - each crossing is timed at the midpoint of its first and last level crossings, and the half-period comes from a least-squares fit, so the 0.8 % bias on decaying ringing drops to 0.06 %;
  - the hysteresis band must exceed both 3σ and one ADC step (on the example 3σ = 2.4 V < 2.8 V step, so code flicker had counted as crossings).
- **Other choices:**
  - filters and derivatives are zero-phase; samples without a complete window are returned as NaN, so edges never leak into results;
  - Savitzky–Golay uses least-squares coefficients (no toolbox);
  - `noiseLevel` takes the larger of the MAD estimate (after a linear detrend, so ramps are not counted as noise) and a quantization floor q/√12;
  - `integrateBetween` interpolates the integrand at off-grid limits.
- **Findings on the example record:**
  - **Edge 17 (turn-on, about 500 A):** t_vf (90 → 10 %) = 114 ns, so the 10–90 % average dv/dt is 2.7 V/ns. But V_DS collapses from 224 V to 118 V in about 4.4 ns, so the 20 % band maximum is 27.4 V/ns and the Savitzky–Golay (11-sample) instantaneous maximum is 32.8 V/ns. This justifies Q10.
  - **Edge 18 (turn-off):** t_vr = 60 ns, with average, band and instantaneous dv/dt of 5.1 / 6.0 / 7.5 V/ns. The ringing is a clean 45.9 MHz (half-periods 8.5–13.6 ns).
  - V_DS noise is 0.81 V, which is the quantization floor of the 2.8 V step. The 10/90 % thresholds clear the 3σ noise floor by a factor of about 16.
- **Verified:** `tests/test_primitives.m` passes 33 cases: exact synthetic checks of every primitive, plus real-data sanity checks including |avg| ≤ |band max| ≤ |instantaneous max|. All earlier suites still pass.

### 2026-10-14 — Batch 5a approved

**User decisions:**
- **Q1** sign conventions agreed.
- **Q2** no per-event exclusion, with flag-not-clamp. A percent threshold is used only if min(p, 1 − p)·A ≥ 3σ of that signal, so pulse 1's voltage-based results are kept and its current-based ones are skipped with a reason. An optional display-only clamp, `S.report.clampNonNegative`.
- **Q3** gate basis is the swing.
- **Q4** IEC-8 and IEC-9 presets only; every [Conv]/[Custom] option stays individually selectable.
- **Q5** derived diode current is opt-in, guarded.
- **Q6** windows and settling are proportional to D.
- **Q7** new signals `Vdc` and `Vds-*-clamp`.
- **Q8:**
  - I_on/I_off come from **I_L at the switching instant** (V_GS 10 % rising / 90 % falling), read as the mean over ±D/2. Same collection only, with fallback to the spec's I_D options.
  - #48 Q_oss moves to optional (non-active-device method).
- **Q9** composites use one collection only.
- **Q10** an amplitude-band sliding maximum slew rate (`slopeBandMax`, default 20 % band).
- **Optional measurements** are enabled by the user (a labelled block in `dpt_analyzer.m` for now).

**New feature, user proposal: current-sensor normalization.**
- Opt-in, with the user choosing the reference ("truth") sensor: `cfg.currentNormalization.enable` / `.reference`.
- An affine fit I_ref = k·I_other + b over the on-state segments of all pulses, applied through `getSignal` as a declared correction.
- Refused if the residual or the per-pulse ratio spread is too large.
- **[data]** On the example: k = 1.0691, b = −0.10 A, residual 1.98 A rms (at quantization level), per-pulse ratio 1.065–1.071 over 32–572 A. A pure 6.9 % gain mismatch, which this corrects well.

### 2026-10-13 — Batch 5a: measurement framework design proposed

- **Received** the user's specification: 48 core and 7 optional measurements with selectable methods ([IEC-8]/[IEC-9]/[IEC-2]/[JEDEC]/[Conv]/[Custom]), built-in checks, and presets. Saved verbatim as `MEASUREMENT_SPEC.md`.
- **Proposed design** (`MEASUREMENT_DESIGN.md`):
  - Measurements are evaluated per event (turnOn, turnOff, pulse, break, pair, capture).
  - Requirements are expressed by role (`drainVoltage@active`), as alternative signal sets satisfied within one collection.
  - Methods are **declarative threshold definitions**, so `[Custom]` needs no code. They are served by about 8 implementation families.
  - Percent levels come from measured operating-point results, not naive medians.
  - Every result carries its method tag.
- **Findings on the example record:**
  - The first turn-on is at zero current (I_L = −6 A, probe offset), so turn-on events need an eligibility rule.
  - The Id-LS off-state offset is −2 to −4 A, so the 0 % current level must be measured.
  - A derived diode current I_L − I_D shows a +38 A conduction mismatch at 574 A (about 6.6 % probe gain mismatch). That exceeds the recovery current (about −20 A), so the derived source is opt-in only, guarded by a consistency check.
  - V_F from Vds-HS is quantized in 2.8 V steps, so a resolution check is needed.
  - The HS gate is not driven (non-synchronous, so #23 doesn't apply). HS gate crosstalk is +1.8 / −8.0 V (#37/38 measurable).
- **Spec issues raised:**
  - fixed 10–20 µs windows don't fit multi-pulse trains;
  - a #47 ↔ #55 dependency cycle;
  - #48 device and current unspecified;
  - #4 extrapolation underspecified;
  - Tek and R&S presets need the user's mapping (not guessed).

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
