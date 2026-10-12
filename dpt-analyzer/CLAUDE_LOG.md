# DPT Analyzer — Development Log

Running record of batches, decisions, findings, and open questions.
Newest entries go at the top of each section. Every completed step is committed locally.

## Status

| Batch | Scope | Status |
|---|---|---|
| 1 | `dptSettings.m` | Approved (2026-10-12) |
| 2 | Data contracts → [DATA_CONTRACTS.md](DATA_CONTRACTS.md) | Approved (2026-10-13) |
| 3 | Import & validation implementation | **In review** |
| 4 | Gate detection & synchronization | Not started |
| 5 | Measurement specification & registry | Not started (waiting on user's spec) |
| 6 | Capability-driven analysis | Not started |
| 7 | Validation & tests | Not started |

## Open questions (waiting on user)

Batch 2 (details in [DATA_CONTRACTS.md §8](DATA_CONTRACTS.md)):

_None outstanding. Batch 3 awaits review._

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
| `data/example/collection_A/` | Tek MSO58B example record and its `channelMap.m`. |
| `tests/` | Informal test scripts (`test_settings`, `test_import`); formalized in Batch 7. |

## Decision record

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
