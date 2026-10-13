# DPT Analyzer — Measurement Framework Design (Batch 5)

Status: **proposal, under review.** It implements the user's specification in [MEASUREMENT_SPEC.md](MEASUREMENT_SPEC.md); row numbers (#1–#55) refer to that document. No measurement code is written until this design is approved. Findings from the example record are marked **[data]**.

## 1. Plan

The specification is too large to implement in one step. Proposed order, each step reviewed and committed:

| Step | Content |
|---|---|
| **5a** | This design: registry schema, method model, presets, level model, shared primitives, result schema, configuration additions, open questions. |
| **5b** | Shared primitives (§6), with tests on the example record and on synthetic edges. |
| **5c** | Operating point (#1–4) and conduction (#49–54). Every other group depends on them. |
| **5d** | Timing (#13–23) and slew rates (#24–28). |
| **5e** | Switching energy and power (#5–12). |
| **5f** | Voltage, current and gate stress (#29–38). |
| **5g** | Reverse recovery (#39–46). |
| **5h** | Parasitics (#47, #48, #55). |
| **6** | `runMeasurements`: eligibility, dependency order, built-in checks, presets, results and report with method tags. |

## 2. How the specification maps onto the existing architecture

### 2.1 Events

Every measurement is evaluated **per event**. The event kinds come from the Batch 4 timeline:

| Event kind | Defined by | Rows |
|---|---|---|
| `turnOn` | A turn-on edge | #2, 4, 5, 10, 13, 15, 17, 20, 24–28, 32–34, 38–48 |
| `turnOff` | A turn-off edge | #1, 3, 6, 11, 14, 16, 18, 19, 21, 24–31, 37, 55 |
| `pulse` | A turn-on edge and its turn-off edge (the on-time) | #49–51 |
| `break` | Turn-off of pulse k → turn-on of pulse k+1 | #22, 52, 53 |
| `pair` | Turn-off k + turn-on k+1, which is the same operating point in a DPT | #7, 9, 12 |
| `capture` | The whole record | #35/36 "whole capture" option |

For multi-pulse trains, every eligible event is measured. A train therefore produces each quantity as a curve against current, e.g. E_on(I) over pulses 2–10.

**Hard-switching eligibility [data].** On the example, the first turn-on happens at I_L = −6 A, which is just the probe offset. There is no freewheeling current, so there is no reverse recovery and no meaningful E_on. Turn-on events need an eligibility rule (Q2).

### 2.2 Signals by role

Requirements name a **role and a quantity**, never a fixed signal. Examples:

- `drainVoltage@active`
- `gateVoltage@nonActive`
- `outputCurrent`
- `busVoltage`

Roles are resolved through `cfg.activeDevice` and `S.signals.catalog`, so one registry entry serves both HS-active and LS-active buckets.

The **diode** in #39–46 and #52–53 is the non-active device's body or antiparallel diode:

- **Diode voltage:** taken from the non-active device's V_DS.
- **Diode current, from one of two sources:**
  - **measured:** the non-active device's I_D, with its sign reversed;
  - **derived:** I_L − I_D,active. This combines two channels of the *same* collection, which share one time grid (§4.1 of the contracts), so the same-collection rule holds.

**Derived diode current is unreliable on the example [data].** While LS conducts, I_L − I_D should be 0. It reads +4 A at 62 A and +38 A at 574 A: a gain mismatch of about 6.6 % between the Iout probe and the CH5 + CH8 sum. At high current this error exceeds the recovery current (about −20 A) and hides it completely. The derived source is therefore **opt-in only**. It must also pass a conduction-phase consistency check: |I_L − I_D,active| during the on-state must be small relative to the measured I_rrm. Otherwise the result is refused, not reported (Q5).

### 2.3 Same-collection rule

Each method lists its requirements as **alternative signal sets**. For example, bus voltage comes from either `{busVoltage}` or `{drainVoltage@active}`. For a measurement on collection c, at least one complete set must be present in c. Different sets are never mixed across collections.

Composite results such as E_sw = E_on + E_off combine two *events*, not two simultaneous signals. They are still restricted to one collection by default (Q9).

### 2.4 Search regions

Each event has two time regions:

- **Event window (Batch 4):** the gate-edge core plus `pre·D` before and `post·D` after. All **transition thresholds** are searched here: 10 %, 90 %, 2 %, and so on.
- **Territory:** from the midpoint to the previous edge to the midpoint to the next edge. Used for **settled levels, ringing decay, peaks, and fixed-duration windows**. It will be added to the timeline's window table as `territoryStart` and `territoryEnd`.

**Spec conflict [data].** #5's "[Conv] V_GS 10% → fixed time (10 to 20 µs)" cannot fit in a multi-pulse train: the example has a 6.47 µs on-time, so only 3.2 µs of territory follows each turn-on. A fixed-duration window that leaves the territory makes that method **skipped**, with the reason stated. It is never extended into the neighbouring event.

## 3. Registry schema

`R = measurementRegistry(S)` returns a struct array with one element per measurement:

| Field | Meaning |
|---|---|
| `id` | Stable identifier, e.g. `"Eon"`, `"tdOn"`, `"Irrm"`. |
| `row` | Row number in the specification. |
| `symbol`, `name`, `category`, `unit` | Display information. |
| `event` | Event kind (§2.1). |
| `optional` | `true` for #49–55 (off by default). |
| `deviceTypes` | Device types the measurement applies to, e.g. `["IGBT"]` for #19. |
| `methods` | Struct array (below). |
| `defaultMethod` | Method id used when neither the preset nor the user selects one. |
| `dependsOn` | Measurements whose results this one needs, e.g. Esw → {Eon, Eoff}; tb → {Irrm, trr}. The registry rejects dependency cycles at load time (§9, issue 2). |
| `fn` | Implementation function handle. One function serves a whole family of methods (§3.2). |

Each element of `methods`:

| Field | Meaning |
|---|---|
| `id` | e.g. `"IEC8"`, `"IEC9"`, `"conv_I10_V2"`, `"custom"`. |
| `tag` | The report tag, e.g. `"IEC 60747-8"`, `"Conv"`, `"Custom"`. |
| `standard` | `"IEC-8"`, `"IEC-9"`, `"IEC-2"`, `"JEDEC"`, `"Conv"` or `"Custom"`. Used for the device-type mismatch check. |
| `requires` | Alternative signal sets (§2.3). |
| `params` | **Declarative definition**: start and end events, levels, windows, reference choices (§3.1). |

### 3.1 Methods are data, not code

Most rows differ only in **which thresholds** bound an interval or an integral. So a method is described as data. For example, the IEC-9 method of E_on:

```matlab
m.id       = "IEC9";
m.tag      = "IEC 60747-9";
m.standard = "IEC-9";
m.requires = {["drainVoltage@active", "drainCurrent@active", "gateVoltage@active"]};
m.params.start = threshold("gateVoltage@active", 0.10, "gate",  "rising");
m.params.stop  = threshold("drainVoltage@active", 0.02, "Vdc",  "falling");
```

A threshold has four parts:

- **signal** (by role);
- **level**;
- **basis**, which decides what the level is a percentage of:
  - `"transition"` (the default in the spec);
  - `"Vdc"` (x % of V_DC, e.g. #5 "2 % of V_DC");
  - `"Irrm"` (x % of I_rrm);
  - `"gate"` (§5.3);
  - `"absolute"` (in V or A);
- **direction**: `"rising"`, `"falling"`, or `"auto"`, which is taken from the pre- and post-levels and so handles polarity.

`[Custom]` then needs no new code: the user supplies `start` and `stop` thresholds in the settings.

### 3.2 Implementation families

Rows map onto a small number of reusable implementations:

| Family | What it computes | Rows |
|---|---|---|
| `intervalBetween` | t(stop) − t(start) | #13–23, #41, #42 |
| `integralBetween` | ∫ f(signals) dt between two thresholds, or a threshold plus a fixed duration | #5, 6, 8, 9, 44, 45, 48 |
| `slopeBetween` | Δx / Δt between two levels | #24–26, #46 avg |
| `extremumIn` | max or min within a region, optionally relative to a reference | #29–39 |
| `derivativeExtremum` | max \|dx/dt\| within a region (filter and derivative stated) | #27, 28, 46 peak |
| `levelIn` | Mean or median over a region | #1–4, 49, 50, 52, 53 |
| `composite` | Arithmetic on other results | #7, 10–12, 20, 21, 30, 31, 33, 34, 43, 51, 54, 55 |
| Bespoke | Algorithms that don't fit the families above | t_rr extrapolation (#40), L_loop (#47), extrapolated I_on (#4) |

## 4. Methods, presets and tags

- **Selection.** `S.measurements.preset` sets every measurement's method at once. `S.measurements.<id>.method` and `S.measurements.<id>.params` override it per measurement, and an explicit override beats the preset. The result records both the preset and the effective method.
- **Enable/disable.** All core measurements are attempted by default. Optional ones (#49–55) are enabled per measurement or by group.
- **Tag on every result.** The value is always formatted as `"E_off = 1.23 mJ [IEC 60747-9]"`. Result tables carry `methodId` and `methodTag` columns. Values with different tags are never placed in the same comparison or summary column.
- **Device-type check.** A new bucket field `cfg.deviceType` (`"MOSFET"` | `"IGBT"`) is compared against each method's `standard`. An IEC-9 method on a MOSFET is flagged. Device-specific rows such as #19 are skipped with a reason on the wrong device type.
- **Presets:**
  - **IEC 60747-8 and IEC 60747-9:** built directly from the `[IEC-8]`/`[IEC-9]`/`[IEC-2]` tags in the spec. Rows with no IEC definition (#24–28, #22, #23) use their first `[Conv]` option, and the report says so.
  - **IGBT module datasheet style:** my reading is E_on = I_D 10 % → V_DS 2 % of V_DC, and E_off = V_DS 10 % of V_DC → I_D 2 %. Needs confirmation (Q4).
  - **Tektronix WBG-DPT and R&S app note:** I will not guess their method choices. They need your per-row mapping (Q4).

## 5. Level model

Percent thresholds need a 0 % and a 100 % level for each (event, signal). These come from **measured operating-point results**, not from naive medians. The method used is recorded in the result.

### 5.1 Drain voltage

| Event | Pre-level | Post-level |
|---|---|---|
| turn-on | V_DC,on (#2) | On-state level: settled V_DS in the territory, or V_DS(on) (#49) when available |
| turn-off | On-state level | V_DC,off (#1) |

"x % of V_DC" is an absolute level x·V_DC, as the spec states. It is not a transition percentage.

**Never-reached 2 % levels.** If a 2 % end point is never reached (IGBT V_CE(sat) at high current), the result **fails with a reason** and the built-in check suggests using the measured on-state level as 0 %.

### 5.2 Drain current

The zero level is **measured** as the off-state current median. **[data]** On the example it is −2 to −4 A of probe offset; assuming 0 A would shift every low-percentage threshold.

| Event | Pre-level | Post-level |
|---|---|---|
| turn-on | Measured zero | I_on (#4) |
| turn-off | I_off (#3) | Measured zero |

The current keeps ramping through the on-time (di/dt = V/L). A plain median of the post-switching current would therefore be biased, which is why #4 offers the extrapolated method.

### 5.3 Gate voltage

The levels are the gate levels measured at detection (Batch 4). The percentage basis is a setting (#26 asks for it to be stated):

- `"swing"`: V_G(off) → V_G(on);
- `"zero"`: 0 → V_G(on).

The two differ a lot. On the example, 10 % is −3.1 V with `"swing"` and +1.7 V with `"zero"` (Q3).

The synchronization reference (25 % from the initial level) is separate. It only anchors the windows; measurements use their own thresholds.

### 5.4 Crossings

- **Search:** the first crossing in the threshold's direction, within the event window, after the start event (or, for end points, the first crossing after the start threshold).
- **Interpolation:** linear between samples, done on the measurement filter's output when one is set (§6.1).
- **Polarity:** never assumed from sign. Direction comes from the pre- and post-levels.

## 6. Shared primitives (5b)

All of these are base MATLAB; the Signal Processing Toolbox is not installed.

### 6.1 Measurement filter

`S.measurements.filter.method`:

- `"none"` (default for thresholds);
- `"movmean"`;
- `"savgol"`: Savitzky–Golay, with coefficients computed by least squares, so no toolbox is needed.

The window is set in seconds. The filter and window are recorded in every result that uses them; the spec asks for this explicitly for #27, 28, 39 and 46.

### 6.2 Derivative

Central difference on the filtered signal, or the Savitzky–Golay derivative.

### 6.3 Settling

"Ringing has decayed" means: the signal stays within ±band of its settled level for the rest of the territory. The settled level is the median of the territory's final portion. Band and portion are settings (Q6).

### 6.4 Ringing frequency

From the zero crossings of x − settled level over the ringing segment: f_r = (number of half-periods) / (2 · span). Needed for #47 and #55. An FFT is the alternative if the zero-crossing estimate proves noisy.

### 6.5 Integration

`trapz` on the shared corrected grid. `getSignal` guarantees that V and I share it.

### 6.6 Resolution check

Compares a level-type result with the channel's quantization step (estimated from the data). **[data]** V_F from Vds-HS steps in 2.8 V: −2.8 / −5.6 / −8.4 V. So #49–53 from an unclamped channel are flagged "resolution-limited", in line with the spec's clamped-channel advice.

## 7. Configuration and signal additions

### 7.1 Signal catalog (`S.signals.catalog`)

| Name | Quantity | Purpose |
|---|---|---|
| `Vdc` | `busVoltage` | Bus-voltage channel, used by #1, 2, 8. |
| `Vds-HS-clamp`, `Vds-LS-clamp` | `drainVoltageClamped` | Clamped or clipped V_DS channels for #49–52. They can co-exist with the full-range `Vds-*` in one collection. |
| `Id-HS`, `Id-LS` | — | Already present. The non-active one is the measured diode current. |

### 7.2 Bucket configuration (`dpt_analyzer.m`), all new fields optional except `deviceType`

| Field | Used by |
|---|---|
| `cfg.deviceType` = `"MOSFET"` \| `"IGBT"` | Method/device check, #19. |
| `cfg.switchingFrequency` [Hz] | #12. `[]` skips #12 with a reason. |
| `cfg.junctionTemperature` [°C] | Operating-point metadata (#12 requires the same T_j). |
| `cfg.nominal.busVoltage` [V], `cfg.nominal.testCurrent` [A] | `[Custom]` references in #1–4, 30, 33. |
| `cfg.ratings.VgsMax`, `.VgsMin` | #35, 36, 37. |
| `cfg.ratings.VgsMaxTransient`, `.VgsMinTransient` | #35, 36 transient ratings. |
| `cfg.ratings.VgsThMin` | #38: V_GS(th),min at the highest T_j. |
| `cfg.circuit.Coss` [F] | #47 ringing option. |

**Rows 23 and 37/38 [data]:**

- **#23 dead time** is skipped with the reason "complementary gate not actively driven" when the non-active gate has no qualified edges. On the example, the HS gate sits at −5.6 V: non-synchronous, so #23 doesn't apply.
- **#37/38** are measurable on the example: the HS gate shows +1.8 V and −8.0 V of induced voltage.

## 8. Results (detailed in Batch 6)

One row per (measurement, method, event, collection), with these fields:

| Group | Fields |
|---|---|
| Identity | `id`, `symbol` |
| Value | `value`, `unit` |
| Method | `methodId`, `methodTag`, `preset` |
| Event | `eventKind`, `edgeId`, `pulseIndex` |
| Source | `collection` |
| Operating point | V_DC, I (copied from #1–4 so every row is self-describing) |
| Outcome | `status`: `ok` \| `skipped` (unsupported: missing data, device type, disabled) \| `failed` (attempted: threshold never reached, check refused) |
| Explanation | `reason` |
| Provenance | Threshold times and levels used, filter, signal sources |
| Checks | `warnings` |

## 9. Issues found in the specification

1. **#5/#6 fixed 10–20 µs windows** do not fit multi-pulse trains (§2.4). They are skipped when outside the territory.
2. **#47 ringing ↔ #55 LC is circular.** #47's ringing option needs C, and #55's LC option needs L from #47. The registry rejects the cycle: #55 LC requires #47 by the dip or overshoot method.
3. **#43 IEC-2 S_rr** is deferred, as the spec says.
4. **#48 Q_oss doesn't say which device and current.** I assume the non-active device at the active device's turn-on, while its V_DS rises, integrating the diode current from its zero crossing. Confirm (Q8).
5. **#4 extrapolated I_on** needs two definitions: the fit window (from the settling time to the end of the event window?) and the extrapolation instant (V_GS 10 %? the I_D 10 % crossing?) (Q8).
6. **#9 direct** requires the non-active I_D, which the spec notes adds loop inductance. It is skipped automatically when that signal is absent.
7. **#12 phase-leg** adds f_s·E_rr from the same pair event. That requires #45 to be available on the turn-on of the same pair.

## 10. Questions

Each has a recommendation, so a short "agree" is enough.

| # | Question | Recommendation |
|---|---|---|
| Q1 | **Sign conventions:** each device's I_D is positive drain → source, and I_L (`Iout`) is positive in the direction that flows into the active device's drain when it conducts. Both hold on the example. Wrong probe orientations are fixed with `invert` in the channel map. | Adopt these conventions. |
| Q2 | **Event eligibility.** Turn-on (and pair) events count only if hard-switched, i.e. \|I_on\| ≥ `S.events.minCurrent`. Should all eligible events be measured, or a user-selected subset of pulses? | Measure all eligible events. Optional `cfg.events.pulses` subset. Default `minCurrent` = 5 % of the bucket's largest measured I_on, which rejects offset-only events like the example's −6 A. |
| Q3 | **Gate percentage basis.** | `"swing"` (V_G(off) → V_G(on)) as default, reported with every gate-referenced result. |
| Q4 | **Presets.** | Confirm my IGBT-datasheet reading (§4). Give the per-row method mapping for Tektronix WBG-DPT and R&S (including which t_d(off) is the "legacy" one), or I leave those presets out until you do. |
| Q5 | **Derived diode current** (I_L − I_D). | Opt-in only, refused if the conduction-phase mismatch is more than 25 % of I_rrm. On the example it would be refused at high current. |
| Q6 | **Defaults for the "user windows" and settling** (#1–4, 49, 52). | Make them proportional to the edge duration D, like the Batch 4 windows: averaging window 1·D ending at the gate edge; settling band ±2 % of the transition; settled level from the final 25 % of the territory. Absolute-time overrides available. |
| Q7 | **New signal names:** `Vdc`, `Vds-HS-clamp`, `Vds-LS-clamp`. | Adopt. |
| Q8 | **#48 and #4 clarifications** (§9, issues 4–5). | Your answer needed. |
| Q9 | **Cross-collection composites.** May E_sw take E_on and E_off from different collections, with a check that the operating points match? | Same collection only (strict) for now; can be relaxed later. |
