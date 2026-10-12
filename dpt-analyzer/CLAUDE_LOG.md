# DPT Analyzer — Development Log

Running record of batches, decisions, findings, and open questions.
Newest entries go at the top of each section. Every completed step is committed locally.

## Status

| Batch | Scope | Status |
|---|---|---|
| 1 | `dptSettings.m` | **In review** |
| 2 | Data contracts (`importChannel`, `importCollection`, timeline) | Not started |
| 3 | Import & validation implementation | Not started |
| 4 | Gate detection & synchronization | Not started |
| 5 | Measurement specification & registry | Not started (waiting on user's spec) |
| 6 | Capability-driven analysis | Not started |
| 7 | Validation & tests | Not started |

## Open questions (waiting on user)

- **Nominal gate levels:** set to −5 / +18 V from the test record (measured −5.43 / +17.40 V). The earlier draft had +20 V, which would be 2.6 V off this record. Confirm the real driver levels, and whether they vary between buckets (if so, they belong in bucket config instead).
- **Test data in git:** `testdata/` (8 × 20 MB `.mat`) is committed. Decide whether `data/` should be committed or gitignored.

## Decision record

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
