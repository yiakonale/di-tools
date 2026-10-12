# DPT Analyzer — Data Contracts

Status: **approved 2026-10-13. Sections 0–4 are implemented (Batch 3); sections 5–7 are implemented (Batch 4, in review).** This document is the reference that Batches 3–6 implement against. A change here must be agreed before the code changes.

## 0. Conventions

| Topic | Rule |
|---|---|
| Units | SI everywhere: V, A, s. No unit prefixes are stored. |
| Text | MATLAB `string`, not `char`. |
| Vectors | Waveforms are N×1 `double` columns. |
| Sample indices | 1-based MATLAB indices into the collection's arrays. |
| `zeroIndex` | Kept exactly as recorded. It is **0-based** on Tek exports (`time(zeroIndex+1) == 0`). It is metadata only and is never used for synchronization. |
| Scope time `t_s` | The `time` vector as exported. Each collection has its own (on Tek, 0 is the trigger point). |
| Corrected time `t_ch` | `t_ch(k) = t_s(k) + deskew_ch`: the time sample k of channel ch actually represents, after post-acquisition deskew (§2.1). It equals `t_s` when deskew is 0, which is the default. **All times downstream of import are corrected times.** |
| Universal time `t_u` | `t_u = t_ch − offset(c)` for collection `c`. `t_u = 0` is the first turn-on reference crossing of the reference collection. Shifted time vectors are **never stored**; they are computed when needed. |
| Raw data | `data` and `time` are never modified after import. The only normalizations are converting a row vector to a column and integer/single types to `double`; both are lossless. Post-acquisition corrections are applied when a signal is read (§4.1), never written back. |
| Errors vs issues | A condition that makes a unit of work invalid (a channel, a collection, or the bucket) **throws** an `MException` with id `dpt:<stage>:<name>`. Conditions that leave results usable are recorded as **issues** (§0.1) and analysis continues. |

### 0.1 Issue record

Every stage output carries `.issues`, a 0×1 or K×1 struct array:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | e.g. `"dpt:import:unmappedFile"` |
| `severity` | string | `"info"` or `"warning"` |
| `stage` | string | `"discovery"`, `"import"`, `"detection"`, `"alignment"`, `"timeline"`, `"measurement"` |
| `collection` | string | collection name, or `""` if bucket-wide |
| `message` | string | human-readable explanation |

Issues are created with `dptIssue(...)`; `dptIssue()` returns an empty 0×1 array for initialization. Warnings are echoed through `warning()` when `S.report.echoWarnings` is true. Info issues are printed when `S.report.verbosity` is `"verbose"`.

## 1. Bucket configuration — `cfg` (from `dpt_analyzer.m`)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `cfg.bucketPath` | string | yes | Bucket folder. A relative path is resolved against the script's folder, never against `pwd`. |
| `cfg.activeDevice` | `"HS"` \| `"LS"` | yes | The device being switched. Its gate is the sync reference. |
| `cfg.expectedPulseCount` | positive integer or `[]` | yes | Advisory only. `[]` means no count check. |
| `cfg.gate.nominal.high` | double [V] | yes | Nominal on-state gate drive of the active device. |
| `cfg.gate.nominal.low` | double [V] | yes | Nominal off-state gate drive. |

Validated by `cfg = validateBucketConfig(cfg, S, scriptDir)`. Unknown or missing fields are errors.
- `high > low`.
- `S.gate.levels.tolerance < (high − low) / 2`.
- The bucket folder exists.

## 2. Channel map — `channelMap.m` (one per collection)

```matlab
function map = channelMap()
% Optional free-text note about this acquisition.
map.description = "LS switching, Vds/Id-LS, 400 V / 50 A";

% Long form: signal plus optional fields.
map.channels.CH2.signal = "Vgs-LS";
map.channels.CH2.file   = "Tek000_ch2.mat";   % optional

% Optional post-acquisition corrections (defaults: 0 and false).
map.channels.MATH1.signal = "Id-LS";
map.channels.MATH1.file   = "Tek000_math1.mat";
map.channels.MATH1.deskew = 1.2e-9;           % [s]
map.channels.MATH1.invert = true;

% Short form: equivalent to .signal only.
map.channels.CH4 = "Vds-LS";
end
```

| Element | Rule |
|---|---|
| Key (`CH2`, `MATH1`, …) | Scope channel ID. It must match the file's `waveformSource` (case-insensitive) when that variable is present. This catches a file exported from the wrong channel. |
| `signal` | Must be a name in `S.signals.catalog`. Each signal may appear **at most once** per collection. |
| `file` | Optional. The default is `<key>.mat`, matched case-insensitively. Files are resolved deterministically; the folder is never scanned to guess. |
| `deskew` | Optional, double [s], default `0`. A correction applied **on top of** any deskew already applied in the scope (§2.1). |
| `invert` | Optional, logical, default `false`. Applied **on top of** any inversion already set in the scope. |
| `description` | Optional string. |
| Anything else | An error. Unknown fields are rejected so a typo cannot be ignored. |

`.mat` files in the folder that the map does not reference are ignored and reported as `info` issues.

`validateChannelMap` normalizes both forms to the full long form, with every optional field filled in: `signal`, `file`, `deskew`, `invert`.

**Loading:** every collection defines a function with the same name, `channelMap`. `importCollection` therefore makes the collection folder current for the call, restores the previous folder afterwards (even on error), clears the cached function before and after, and verifies with `which` that the folder's own file is the one resolved. For the same reason the entry script never puts `data/` on the path (no `genpath`).

### 2.1 Post-acquisition corrections

Deskew and polarity are normally set in the scope, so the exported data already include them. The channel map can add a further correction after acquisition, for example when a skew is discovered later. The defaults (0, `false`) mean no change.

- **Deskew sign convention:** it matches Tektronix. A positive value **delays** the channel: `t_ch = t_s + deskew`.
- **Invert:** the samples are multiplied by −1 when the signal is read.
- **Gate channels:** a deskew on the gate channel shifts the detected edge times, and therefore the alignment. This is consistent: everything uses corrected time.
- **Reporting:** every non-default correction is recorded in the collection's `issues` (`info`) and in the results, so a correction is never invisible.
- **Non-integer deskew — open (Q1a, §8).** A deskew that is not a whole multiple of `dt` cannot be applied by an index shift. Proposed setting: `S.corrections.nonIntegerDeskew = "round"` (default) | `"error"`.
  - `"round"`: the effective deskew is `round(deskew/dt)·dt`, used everywhere. The residual (≤ dt/2 = 80 ps at 160 ps sampling) is reported.
  - Interpolation is deliberately not offered until a measurement needs it, because it is resampling.

## 3. Channel — `ch = importChannel(filePath, S)`

Accepts both `.mat` layouts:
- **flat**: separate top-level variables, as in the Tek MSO58B exports in `testdata/`.
- **struct**: exactly one top-level struct holding the fields.

Anything else is an error.

| Field | Type | Meaning |
|---|---|---|
| `file` | string | Absolute path. |
| `layout` | `"flat"` \| `"struct"` | How the file was stored. |
| `data` | N×1 double | Raw samples, in `units`. |
| `time` | N×1 double [s] | Raw scope time. |
| `sampleInterval` | double [s] | As recorded. |
| `recordLength` | double | N. |
| `units` | string | From `verticalUnits`. |
| `source` | string | From `waveformSource`, or `""` if absent. |
| `zeroIndex` | double or `[]` | As recorded (0-based). |
| `meta` | struct | **Every** recorded variable except `data` and `time`, verbatim. |

The required variables are `data`, `time`, `sampleInterval` and `verticalUnits`. It is an **error** when:
- `data` is non-numeric, complex, empty, or contains non-finite values;
- `numel(time) ≠ numel(data)`;
- `time` is not strictly increasing, or not uniform: `max|diff(time) − dt| > S.sampling.timeVectorRelTol · dt`;
- `recordLength` is present and `≠ N`;
- `horizontalUnits` is present and `≠ "s"`.

## 4. Collection — `col = importCollection(collectionPath, cfg, S)`

| Field | Type | Meaning |
|---|---|---|
| `name` | string | Folder name. |
| `path` | string | Absolute folder path. |
| `description` | string | From the map, or `""`. |
| `time` | N×1 double [s] | **One** shared scope time vector. |
| `sampleInterval` | double [s] | Shared. |
| `recordLength` | double | Shared N. |
| `channels` | 1×K struct | One element per mapped channel, in map order (fields below). |
| `unmappedFiles` | string array | `.mat` files present but not mapped. |
| `issues` | struct array | §0.1 |

`channels(k)` holds the `importChannel` fields **except `time`**, plus:

| Field | Type | Meaning |
|---|---|---|
| `channel` | string | Map key, e.g. `"CH2"`. |
| `signal` | string | Canonical name, e.g. `"Vgs-LS"`. |
| `quantity`, `device` | string | Copied from `S.signals.catalog`, so consumers never re-look them up. |
| `corrections.deskew` | double [s] | As requested in the map. |
| `corrections.deskewApplied` | double [s] | Effective deskew after the non-integer policy (an integer multiple of dt). |
| `corrections.shift` | double | `deskewApplied / dt`, in samples (an integer). |
| `corrections.invert` | logical | As requested in the map. |

Signal lookup: `col.channels([col.channels.signal] == "Vds-LS")`. A struct array is used because the canonical names contain `-`, which is not valid in a field name.

### 4.1 Signal access — `sig = getSignal(col, signal, tRange, S)`

This is the **only** way downstream code reads waveform samples. All corrections are therefore applied in one place, identically for every measurement.

- `tRange`: `[t0 t1]` in **corrected scope time**, or `[]` for the whole record. Samples with `t0 ≤ t ≤ t1` are returned. The boundary tolerance is `S.sampling.timeVectorRelTol · dt`, which absorbs floating-point error.
- Returns:

  | Field | Meaning |
  |---|---|
  | `x` | Corrected samples (`invert` applied). |
  | `t` | Corrected times, `col.time(k) + deskewApplied`. |
  | `index` | Raw sample indices k. |
  | `complete` | `false` if `tRange` extends beyond this channel's corrected record. |
  | `signal`, `channel`, `units` | Identification. |
  | `corrections` | The channel's corrections, for provenance. |

- Because the effective deskew is a whole number of samples, two signals read over the same `tRange` land on the same corrected time grid. Their samples can be combined element by element (e.g. V·I) **without interpolation**.

New root file `getSignal.m` (Batch 3). It is justified because it is the single point that enforces "raw data untouched, corrections always applied".

**Why one time vector:** all channels in a collection share a single acquisition. That is the invariant; it is checked here, and keeping one copy saves about 10 MB per channel at 1.25 M samples.

It is an **error** when:
- channels differ in `sampleInterval` (relative tolerance `S.sampling.sampleIntervalRelTol`), in N, or in time vector (`> S.sampling.timeVectorRelTol · dt`);
- a file's units differ from the catalog units for its signal;
- a mapped file is missing;
- the map is invalid;
- the gate signal of `cfg.activeDevice` is not mapped. This is checked at import so the failure happens before any processing.

## 5. Gate events — `ev = detectGateTransitions(col, cfg, S)`

One `ev` per collection, in that collection's **corrected time** of the gate channel. The gate is read through `getSignal`.

| Field | Type | Meaning |
|---|---|---|
| `collection` | string | `col.name` |
| `signal` | string | The gate signal used, e.g. `"Vgs-LS"`. |
| `sampleInterval` | double [s] | The collection's dt. |
| `recordSpan` | 1×2 double [s] | First and last corrected gate time. Used for window coverage. |
| `levels.low`, `levels.high` | double [V] | Levels actually used (measured, or nominal if `S.gate.levels.source = "nominal"`). |
| `levels.nominalLow`, `levels.nominalHigh` | double [V] | Copied from `cfg`. |
| `thresholds.armLow`, `.armHigh` | double [V] | Hysteresis arms. |
| `thresholds.refRising`, `.refFalling` | double [V] | Reference levels. |
| `conditioning` | struct | `method`, `windowDuration` [s], `windowSamples`. |
| `edges` | table | One row per **qualified** edge, in time order (columns below). |
| `discarded` | table | Same columns plus `reason`: edges rejected as incomplete or because of a spacing violation. |
| `issues` | struct array | §0.1 |

`edges` columns:

| Column | Type | Meaning |
|---|---|---|
| `direction` | `"rising"` \| `"falling"` | Gate direction. |
| `kind` | `"turnOn"` \| `"turnOff"` | From `direction` and `S.gate.activeLevel`. |
| `time` | double [s] | Corrected time of the reference crossing (interpolated if `S.detection.interpolateCrossing`). |
| `index` | double | Raw gate-channel index k such that the crossing lies between samples k and k+1. |
| `startIndex` | double | Last sample at or beyond the near arm before the edge. |
| `endIndex` | double | First sample at or beyond the far arm. |
| `startTime`, `endTime` | double [s] | Corrected times of `startIndex` and `endIndex`. Their difference is the edge duration **D**. |
| `nCrossings` | double | Reference crossings within `[startIndex, endIndex]`, counted on the timing-smoothed signal. |
| `smoothingSamples` | double | Length of the local timing moving mean (odd; 1 = none), `≈ S.detection.timingSmoothing · D / dt`. |

## 6. Alignment — `al = alignCollections(evs, S)`

Input: `evs`, a 1×C array of gate-event structs (`ev.recordLength` is also carried for this check). Collections that cannot be aligned are **excluded** and listed in `excluded`. Every per-collection field covers only the C' aligned collections, in input order.

| Field | Type | Meaning |
|---|---|---|
| `collections` | 1×C' string | Names of the aligned collections. |
| `sourceIndex` | 1×C' double | Their indices into the input `evs`. Use it to filter `collections` and `evs` downstream. |
| `reference` | double | Index (into `collections`) of the reference collection. It defines `t_u = 0`. |
| `offset` | 1×C' double [s] | `t_u = t_ch − offset(c)`. |
| `edges` | table, E rows | Universal edges: `direction`, `kind`, `time`. `time` is the median aligned time over the collections that contain the edge. |
| `match` | E×C' double | Row j = universal edge j. Entry = row in `evs(c).edges`, or `NaN` if absent. |
| `residual` | E×C' double [s] | Aligned edge time minus `edges.time`. `NaN` where absent. |
| `sampleInterval` | 1×C' double [s] | For reporting dt mismatches across collections. |
| `excluded` | struct array | `name`, `reason`. |
| `issues` | struct array | §0.1 |

**Acquisition model** (user decision, 2026-10-13):

- All collections of a bucket use the **same scope setup**: identical sample interval and record length.
- They capture the **same complete pulse train** of the active gate; every transition fits inside the capture window.
- Only the channels other than the active gate differ between collections, and the **trigger point varies** slightly between acquisitions.

The active-gate waveforms are therefore treated as identical. Each collection is aligned by **one constant offset**, which absorbs the trigger variation.

**Algorithm:**

1. **Reference collection.** Each collection's edge sequence is its order of turn-on and turn-off edges. The reference is a collection with the most common sequence; input order breaks ties. So a single deviating collection is always the one excluded.
2. **Exclusion.** A collection is excluded if its sample interval, record length or edge sequence differs from the reference. Under this model, any such difference is a setup or data problem: a missing or extra pulse, or a different test. There is no timing-based re-matching, so a wrong match is impossible.
3. **Offset.** The offset is estimated from the per-edge differences with `S.alignment.offsetEstimator` (default median). Edge j matches edge j.
4. **Checking the "identical gate" assumption:**
   - per-edge residuals (`al.residual`; a pass/fail limit is optional via `S.alignment.maxResidual`);
   - edge-duration agreement with the reference (info);
   - measured gate levels: a warning if they differ from the reference's by more than `S.gate.levels.tolerance`;
   - trigger plausibility: a warning if an offset exceeds half the smallest edge spacing.

`al.match` is kept in the contract (always edge j ↔ row j) so that consumers do not depend on this matching rule.

## 7. Timeline — `tl = buildPulseTimeline(evs, al, cfg, S)`

**Change from the original workflow order:** alignment runs **before** the timeline is built, because a universal timeline needs the offsets. Order: detect (per collection) → align → build timeline.

| Field | Type | Meaning |
|---|---|---|
| `origin` | string | Human-readable definition of `t_u = 0`. |
| `edges` | table, E rows | Universal edges (columns below). |
| `pulses` | table | Pulses (columns below). |
| `windows` | table | One row per (edge, collection) (columns below). |
| `expectedPulseCount` | double or `[]` | From `cfg`. |
| `detectedPulseCount` | double | `height(pulses)` |
| `issues` | struct array | §0.1 |

`edges` columns:

| Column | Type | Meaning |
|---|---|---|
| `edgeId` | double | 1…E, chronological. |
| `direction` | string | `"rising"` \| `"falling"` |
| `kind` | string | `"turnOn"` \| `"turnOff"` |
| `pulseIndex` | double | Pulse this edge belongs to, or `NaN`. |
| `time` | double [s] | Copied from `al.edges.time`: the median aligned time across collections. |

`pulses` columns:

| Column | Type | Meaning |
|---|---|---|
| `pulseIndex` | double | 1…P |
| `turnOnEdge` | double | `edgeId` of the pulse's turn-on. |
| `turnOffEdge` | double | `edgeId` of its turn-off, or `NaN` if the record ends before it. |
| `onTime` | double [s] | turnOff − turnOn, or `NaN`. |

A pulse is the p-th turn-on together with the turn-off that follows it. A turn-off that comes before the first turn-on, because the record started mid-pulse, gets `pulseIndex = NaN`.

`windows` columns:

| Column | Type | Meaning |
|---|---|---|
| `edgeId` | double | Edge the window belongs to. |
| `collection` | double | Index into `al.collections`. |
| `startTime`, `endTime` | double [s] | Universal time. For collection c, the corrected-time range passed to `getSignal` is `[startTime endTime] + offset(c)`. Windows hold no sample indices, because with deskew the indices differ per channel. |
| `coreStartTime`, `coreEndTime` | double [s] | Universal time of the collection's qualified gate edge (`startTime`/`endTime` from §5). This is the core where the switching happens. |
| `method` | string | `"adaptive"` \| `"fixed"` \| `"fallback"` |
| `limited` | logical | Clipped to the midpoint between neighbouring edges. |
| `truncated` | logical | Clipped at the record boundary. |
| `valid` | logical | `false` if unusable (e.g. `"skip"` coverage policy). |
| `note` | string | Reason for fallback, truncation or invalidity. |

Window construction, for each (edge, collection):

1. **Core:** the qualified gate edge, of duration D.
2. **Primary window:**
   - `"adaptive"`: `[coreStart − pre·D, coreEnd + post·D]` (`S.windows.adaptive`; provisional defaults pre = 1, post = 2);
   - `"fixed"`: edge time + `S.windows.fixed.<kind>`.
3. **Limit to the neighbour midpoints** if `S.windows.limitToNeighborMidpoint`.
4. **Coverage.** If the window exceeds the record, the fixed window is used instead as a `"fallback"`, provided it is defined, `S.windows.useFixedAsFallback` is set, and it fits. Otherwise `S.windows.onInsufficientCoverage` applies (`"skip"` makes the window invalid; `"truncate"` clips it).

Windows are per collection because record coverage differs between collections. A measurement on collection c uses only rows where `collection == c`. This keeps the same-collection rule visible in the data itself.

## 8. Open decisions

Resolved:

- **Q1a — non-integer deskew policy** (2026-10-13). `S.corrections.nonIntegerDeskew = "round"` by default, with `"error"` as the alternative. MATLAB's `round` rounds halves away from zero (−1.5 samples → −2).
- **Q1 — probe corrections** (2026-10-13). Deskew and inversion are set in the scope by default. The channel map can apply optional additional corrections after acquisition (`deskew = 0`, `invert = false` by default). See §2.1 and §4.1.
- **Q2 — invalid collection policy** (2026-10-13). A collection that fails import or detection is **excluded and reported**, and analysis continues with the rest. If no valid collection remains, the run aborts.
- **Q3 — test-data mapping** (2026-10-13). The LS device is active.

  | Channel | Signal |
  |---|---|
  | CH1 | Vgs-HS |
  | CH2 | Vgs-LS |
  | CH3 | Vds-LS |
  | CH4 | Vds-HS |
  | CH5, CH8 | Drain currents of the two **parallel** LS devices. Unmapped; no canonical name. |
  | MATH1 | Their sum: the true **Id-LS**. |
  | CH7 | Inductor current → **Iout** (confirmed). |

  The files are now in `data/example/collection_A/` (moved with `git mv`).

Deferred, not blocking:

- **ADC clipping detection.** It needs per-channel vertical range metadata, which the Tek exports do not include.
- **Per-device currents for parallel devices.** These would need new catalog names such as `Id-LS-1`. They should only be added if a current-sharing measurement is specified.
