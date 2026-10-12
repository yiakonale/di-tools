# DPT Analyzer — Data Contracts

Status: **proposal, under review (Batch 2)**. Once approved, this document is the reference that Batches 3–6 implement against. A change here must be agreed before the code changes.

## 0. Conventions

| Topic | Rule |
|---|---|
| Units | SI everywhere: V, A, s. No unit prefixes are stored. |
| Text | MATLAB `string`, not `char`. |
| Vectors | Waveforms are N×1 `double` columns. |
| Sample indices | 1-based MATLAB indices into the collection's arrays. |
| `zeroIndex` | Kept exactly as recorded. It is **0-based** on Tek exports (`time(zeroIndex+1) == 0`). It is metadata only and is never used for synchronization. |
| Scope time `t_s` | The `time` vector as exported. Each collection has its own (on Tek, 0 is the trigger point). |
| Universal time `t_u` | `t_u = t_s − offset(c)` for collection `c`. `t_u = 0` is the first turn-on reference crossing of the reference collection. Shifted time vectors are **never stored**; they are computed when needed. |
| Raw data | `data` and `time` are never modified after import. The only normalizations are converting a row vector to a column and integer/single types to `double`; both are lossless. |
| Errors vs issues | A condition that makes a unit of work invalid (a channel, a collection, or the bucket) **throws** an `MException` with id `dpt:<stage>:<name>`. Conditions that leave results usable are recorded as **issues** (§0.1) and analysis continues. |

### 0.1 Issue record

Every stage output carries `.issues`, a 0×1 or K×1 struct array:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | e.g. `"dpt:import:unmappedFile"` |
| `severity` | string | `"info"` or `"warning"` |
| `stage` | string | `"import"`, `"detection"`, `"alignment"`, `"timeline"`, `"measurement"` |
| `collection` | string | collection name, or `""` if bucket-wide |
| `message` | string | human-readable explanation |

Whether an issue is also echoed through `warning()` is controlled by `S.report.echoWarnings`.

## 1. Bucket configuration — `cfg` (from `dpt_analyzer.m`)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `cfg.bucketPath` | string | yes | Bucket folder. A relative path is resolved against the script's folder, never against `pwd`. |
| `cfg.activeDevice` | `"HS"` \| `"LS"` | yes | The device being switched. Its gate is the sync reference. |
| `cfg.expectedPulseCount` | positive integer or `[]` | yes | Advisory only. `[]` means no count check. |
| `cfg.gate.nominal.high` | double [V] | yes | Nominal on-state gate drive of the active device. |
| `cfg.gate.nominal.low` | double [V] | yes | Nominal off-state gate drive. |

Validation (Batch 3):
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

% Short form: equivalent to .signal only.
map.channels.CH4 = "Vds-LS";
end
```

| Element | Rule |
|---|---|
| Key (`CH2`, `MATH1`, …) | Scope channel ID. It must match the file's `waveformSource` (case-insensitive) when that variable is present. This catches a file exported from the wrong channel. |
| `signal` | Must be a name in `S.signals.catalog`. Each signal may appear **at most once** per collection. |
| `file` | Optional. The default is `<key>.mat`, matched case-insensitively. Files are resolved deterministically; the folder is never scanned to guess. |
| `description` | Optional string. |
| Anything else | An error. Unknown fields are rejected so a typo cannot be ignored. |

`.mat` files in the folder that the map does not reference are ignored and reported as `info` issues.

`validateChannelMap` normalizes both forms to the long form: `map.channels.<key>.signal` and `.file`.

> **Open (Q1):** per-channel probe corrections (deskew, polarity). See §8.

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

Signal lookup: `col.channels([col.channels.signal] == "Vds-LS")`. A struct array is used because the canonical names contain `-`, which is not valid in a field name.

**Why one time vector:** all channels in a collection share a single acquisition. That is the invariant; it is checked here, and keeping one copy saves about 10 MB per channel at 1.25 M samples.

It is an **error** when:
- channels differ in `sampleInterval` (relative tolerance `S.sampling.sampleIntervalRelTol`), in N, or in time vector (`> S.sampling.timeVectorRelTol · dt`);
- a file's units differ from the catalog units for its signal;
- a mapped file is missing;
- the map is invalid;
- the gate signal of `cfg.activeDevice` is not mapped. This is checked at import so the failure happens before any processing.

## 5. Gate events — `ev = detectGateTransitions(col, cfg, S)`

One `ev` per collection, in that collection's **scope time**.

| Field | Type | Meaning |
|---|---|---|
| `collection` | string | `col.name` |
| `signal` | string | The gate signal used, e.g. `"Vgs-LS"`. |
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
| `time` | double [s] | Scope time of the reference crossing (interpolated if `S.detection.interpolateCrossing`). |
| `index` | double | k such that the crossing lies in `[time(k), time(k+1)]`. |
| `startIndex` | double | Last sample at or beyond the near arm before the edge. |
| `endIndex` | double | First sample at or beyond the far arm. |
| `nCrossings` | double | Reference crossings within `[startIndex, endIndex]`. |

## 6. Alignment — `al = alignCollections(evs, S)`

Input: `evs`, a 1×C array of gate-event structs.

| Field | Type | Meaning |
|---|---|---|
| `collections` | 1×C string | Collection names, in `evs` order. |
| `reference` | double | Index of the reference collection. It defines `t_u = 0`. |
| `offset` | 1×C double [s] | `t_u = t_s − offset(c)`. |
| `match` | E×C double | Row j = universal edge j. Entry = row in `evs(c).edges`, or `NaN` if absent. |
| `residual` | E×C double [s] | Aligned edge time minus the universal edge time. `NaN` where absent. |
| `sampleInterval` | 1×C double [s] | For reporting dt mismatches across collections. |
| `issues` | struct array | §0.1 |

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
| `time` | double [s] | Consensus universal time across collections. Its exact definition is set in Batch 4. |

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
| `startTime`, `endTime` | double [s] | Universal time. |
| `startIndex`, `endIndex` | double | Sample indices in **that collection**. |
| `method` | string | `"adaptive"` \| `"fallback"` |
| `truncated` | logical | Clipped at the record boundary. |
| `valid` | logical | `false` if unusable (e.g. `"skip"` coverage policy). |
| `note` | string | Reason for fallback, truncation or invalidity. |

Windows are per collection because record coverage differs between collections. A measurement on collection c uses only rows where `collection == c`. This keeps the same-collection rule visible in the data itself.

## 8. Open decisions

- **Q1 — probe corrections.** Are deskew and current-probe polarity corrected in the scope before export? A few ns of V/I skew causes large switching-energy errors. If they are *not* corrected in the scope, the channel map needs optional per-channel `deskew` [s] and `invert` fields. Measurements would apply them explicitly and record that they did; raw data stays untouched.
- **Q2 — invalid collection policy.** When one collection fails import or detection, either abort the whole bucket, or exclude that collection, report it, and continue. **Recommendation: exclude and continue.** Measurements are computed within one collection, so the remaining collections stay valid. If no collections remain, abort.
- **Q3 — test-data mapping.** Which signals are on CH1–CH8 and `math1` in `testdata/`, and which device is active? Batch 3 would `git mv` the files into `data/example/collection_A/` with a real `channelMap.m`, so there is no duplicate 160 MB copy.
- **Deferred, not blocking:** ADC clipping detection (it needs per-channel vertical range metadata, which the Tek exports do not include).
