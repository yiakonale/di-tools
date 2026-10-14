# DPT Analyzer — Measurement Framework Design (Batch 5)

Status: **approved 2026-10-14** (all questions answered, §10.1). It implements the user's specification in [MEASUREMENT_SPEC.md](MEASUREMENT_SPEC.md); row numbers (#1–#55) refer to that document. No measurement code is written until this design is approved. Findings from the example record are marked **[data]**.

## 1. Plan

The specification is too large to implement in one step. Proposed order, each step reviewed and committed:

| Step | Content |
|---|---|
| **5a** | This design: registry schema, method model, presets, level model, shared primitives, result schema, configuration additions, open questions. |
| **5b** | Shared primitives (§6), with tests on the example record and on synthetic edges. |
| **5c** | Current-sensor normalization (§7.3), operating point (#1–4) and conduction (#49–54). Every other group depends on them. |
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
| `optional` | `true` for #48–55 (off by default; #48 moved to optional, 2026-10-14). |
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
| `slopeBandMax` | Maximum Δx / Δt over any amplitude band of x % of the swing, slid across the transition (user request Q10; default x = 20 %, tagged e.g. `[Custom: max over 20 % band]`). **[data]** On edge 17 (turn-on, about 500 A), the 10–90 % average is 2.7 V/ns. The steepest 20 % band is 27 V/ns: V_DS collapses from 224 V to 118 V in about 4.4 ns, between a slow initial fall and ringing back up. The Savitzky–Golay instantaneous maximum is 33 V/ns. | #24–26 |
| `extremumIn` | max or min within a region, optionally relative to a reference | #29–39 |
| `derivativeExtremum` | max \|dx/dt\| within a region (filter and derivative stated) | #27, 28, 46 peak |
| `levelIn` | Mean or median over a region | #1–4, 49, 50, 52, 53 |
| `composite` | Arithmetic on other results | #7, 10–12, 20, 21, 30, 31, 33, 34, 43, 51, 54, 55 |
| Bespoke | Algorithms that don't fit the families above | t_rr extrapolation (#40), L_loop (#47), extrapolated I_on (#4) |

## 4. Methods, presets and tags

- **Selection.** `S.measurements.preset` sets every measurement's method at once. `S.measurements.<id>.method` and `S.measurements.<id>.params` override it per measurement, and an explicit override beats the preset. The result records both the preset and the effective method.
- **Enable/disable.** All core measurements are attempted by default. Optional ones (#48–55) are enabled explicitly by the user (§10.1).
- **Tag on every result.** The value is always formatted as `"E_off = 1.23 mJ [IEC 60747-9]"`. Result tables carry `methodId` and `methodTag` columns. Values with different tags are never placed in the same comparison or summary column.
- **Device-type check.** A new bucket field `cfg.deviceType` (`"MOSFET"` | `"IGBT"`) is compared against each method's `standard`. An IEC-9 method on a MOSFET is flagged. Device-specific rows such as #19 are skipped with a reason on the wrong device type.
- **Presets:**
  - **IEC 60747-8 and IEC 60747-9:** built directly from the `[IEC-8]`/`[IEC-9]`/`[IEC-2]` tags in the spec. Rows with no IEC definition (#24–28, #22, #23) use their first `[Conv]` option, and the report says so.
  - **IGBT module datasheet style:** my reading is E_on = I_D 10 % → V_DS 2 % of V_DC, and E_off = V_DS 10 % of V_DC → I_D 2 %. Needs confirmation (Q4).
  - **Tektronix WBG-DPT and R&S app note:** I will not guess their method choices. They need your per-row mapping (Q4).
  - **Decision (2026-10-14): IEC presets only** (`"IEC-8"` = 60747-8 + 60747-2, `"IEC-9"` = 60747-9 + 60747-2). Every `[Conv]` and `[Custom]` option of every row stays individually selectable for flexibility. Other presets can be added later as data without code changes.

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

**I_on and I_off come from the inductor current by default** (user decision, 2026-10-14). The method is new, tagged `[Conv] I_L at switching instant`:

- **Why I_L:** the inductor current is continuous. The recovery hump and ringing circulate in the commutation loop and never pass through the inductor, so I_L at the switching instant *is* the commutated current. No extrapolation is needed.
- **Switching instant:** given by already-defined thresholds. Turn-off: V_GS 90 % falling (the #3 option). Turn-on: V_GS 10 % rising, the IEC-9 energy and delay start. Both use the `"swing"` gate basis (Q3).
- **Reading I_L:** the mean of I_L over a centred window of ±D/2 around the instant. This is unbiased on the linear inductor ramp and averages out the Iout quantization (4 A steps on the example).
- **Fallback order:**
  1. I_L from the same collection.
  2. The spec's I_D-based options for #3/#4, labelled with their own tag.

  No cross-collection I_L is used (same-collection rule). For the turn-on fallback the extrapolated option of #4 stays available.
- **Consistency:** when I_L is the 100 % level for I_D thresholds, the two sensors must agree. Without normalization (§7.3), a 6.9 % gain mismatch moves an "I_D 90 %" threshold to about 96 % of I_D's own final value. Results therefore record whether the current sensors were normalized.

### 5.3 Gate voltage

The levels are the gate levels measured at detection (Batch 4). The percentage basis is a setting (#26 asks for it to be stated):

- `"swing"`: V_G(off) → V_G(on);
- `"zero"`: 0 → V_G(on).

The two differ a lot. On the example, 10 % is −3.1 V with `"swing"` and +1.7 V with `"zero"` (Q3).

The synchronization reference (25 % from the initial level) is separate. It only anchors the windows; measurements use their own thresholds.

### 5.4 Percent convention: amplitude scale (fixed in 5b)

Percentages are positions on the **amplitude scale** of the transition, independent of its direction (the IEC convention, and the one the spec uses throughout):

> level(p) = low + p·(high − low), where low and high are the smaller and larger of the pre- and post-levels.

So "V_DS falls to 90 %" is near the **start** of a falling edge. It does not mean "90 % of the transition completed". Every row is consistent with this reading:

- t_vf runs from V_DS 90 % to 10 % at turn-on;
- the IEC-8 E_on ends at V_DS 10 %;
- E_off starts at V_GS 90 % falling.

### 5.5 Crossings

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

From the hysteresis-qualified crossings of x − settled level over the ringing segment. Needed for #47 and #55. Two refinements from 5b:

- **Crossing timing.** Each crossing is timed at the midpoint of its first and last level crossings, and the half-period is the least-squares slope of crossing time against crossing number. Timing each crossing at its last level crossing biased a decaying 47 MHz test signal 0.8 % low; with these changes the error is 0.06 %.
- **Band floor.** The hysteresis band must exceed **both the noise (3σ) and one ADC step**. **[data]** On the example, 3σ = 2.4 V is smaller than the 2.8 V step of V_DS, so a single-code flicker counted as a crossing.

**[data]** The turn-off ringing on edge 18 is a clean 45.9 MHz, with half-periods of 8.5–13.6 ns. The 5h method will bound the segment from the overshoot peak to the settling time, which drops the first and last partial intervals.

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

### 7.3 Current-sensor normalization (user proposal, 2026-10-14)

**Purpose.** During the on-state of the active device, all of the inductor current flows through it, so I_D,active = I_L. Two current sensors in one collection can therefore be calibrated against each other on the on-state segments of every pulse. This applies the same correction everywhere I_L and I_D are combined: operating point, thresholds, derived diode current, E_io.

**Configuration** (bucket config, because it depends on the sensor setup):

```matlab
cfg.currentNormalization.enable    = false;     % opt-in
cfg.currentNormalization.reference = "Iout";    % "Iout" | "Id": the sensor taken as truth
```

**Method:**

1. **Segments:** the on-state of each pulse, from the end of its turn-on window to the start of its turn-off window, so recovery and ringing are excluded.
2. **Fit:** I_ref = k·I_other + b by least squares over all pulses. A multi-pulse train spans the full current range, which makes the fit well-conditioned.
3. **Apply:** k and b go to the non-reference channel as a declared correction (`corrections.gain`, `corrections.offset`). `getSignal` applies them like deskew and invert. Raw data is never modified.
4. **Accept or refuse:** the fit is refused, and nothing is applied, if either check fails:
   - the residual rms is large compared with the sensors' noise and quantization;
   - the per-pulse ratio I_ref/I_other spreads widely, which points to non-linearity such as saturation or probe droop, where one gain cannot fix it.

   The thresholds are defined in 5c and are data-derived like the others.
5. **Reporting:** k, b, residual, per-pulse spread and the reference sensor appear in the collection's issues and in every result's provenance (`currentsNormalized = true/false`).

**[data]** Example, normalized to Iout:

| Quantity | Value |
|---|---|
| Fit | k = 1.0691, b = −0.10 A |
| Residual | 1.98 A rms, at the quantization level (Iout steps 4 A, Id 2 A) |
| Per-pulse ratio | 1.065–1.071 over 32–572 A |

A pure gain error with a clean fit, which this method corrects well. The data shows the sensors disagree by 6.9 %; only the user can say which is right.

**Scope.** Normalization needs both sensors in the same collection. A collection with only one of them is not normalized and is reported as such. Reusing constants across collections (same physical sensor) is left as a possible later addition.

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
4. **#48 Q_oss** is **moved to the optional measurements** (user decision, 2026-10-14). Method: the non-active device at the active device's turn-on. Its measured current is integrated from its zero crossing until its V_DS reaches 90 % of its peak. This is the only physically separable case: the active device's drain probe sees channel and capacitive current together. It requires the non-active I_D; the derived current is excluded by Q5.
5. **#4 extrapolated I_on** is superseded as the default by I_L at the switching instant (§5.2). The extrapolated option remains selectable, with fit window = settling time + 2·D and instant = V_GS 10 % rising.
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

### 10.1 Answers (2026-10-13)

| # | Status |
|---|---|
| Q1 | **Agreed.** I_D positive drain → source; I_L positive into the active device's drain when it conducts. |
| Q2 | **Agreed (2026-10-14).** No per-event exclusion. A percent threshold is used only if min(p, 1 − p)·A ≥ 3σ, where A is the signal's transition amplitude and σ its noise on the settled segment; otherwise the dependent result is skipped with a reason. Reverse recovery additionally needs measurable forward diode current. Results are **not clamped**: raw values are kept and flagged `belowNoiseFloor`. An optional `S.report.clampNonNegative` changes only the displayed value, with a marker. |
| Q3 | **Agreed.** Gate basis `"swing"` (V_G(off) → V_G(on)), stated in results. |
| Q4 | **Decided (2026-10-14).** IEC presets only (§4); all row options stay individually selectable. |
| Q5 | **Agreed.** Derived diode current is opt-in, refused if the conduction mismatch is more than 25 % of I_rrm. |
| Q6 | **Agreed.** User windows and settling are proportional to D, with absolute overrides. |
| Q7 | **Agreed.** New signals `Vdc`, `Vds-HS-clamp`, `Vds-LS-clamp`. |
| Q8 | **Decided (2026-10-14).** I_on/I_off from I_L at the switching instant (§5.2). Optional current-sensor normalization (§7.3). #48 Q_oss moved to optional, using the non-active-device method (§9, issue 4). |
| Q9 | **Agreed.** Composites (E_sw etc.) use results from the same collection only. |
| Q10 | **Decided (2026-10-14).** Amplitude-band sliding maximum (`slopeBandMax`, §3.2) for #24–26. |
| — | **Optional measurements** (#48–55) are enabled explicitly by the user. Until a UI exists, this is a labelled block in `dpt_analyzer.m` that sets `settingsOverrides.measurements.enableOptional`; a future UI would write the same field. |

## 11. Implementation notes (5c, 2026-10-14)

Refinements made while implementing the framework and the first groups. They supersede the corresponding sketches in §3–§5.

### 11.1 Requirements are slots with alternatives

`requires` is a list of **slots**, each naming one signal role with alternatives in preference order. For example:

| Slot | Alternatives, in order |
|---|---|
| `V` | `drainVoltageClamped@active`, `drainVoltage@active` |
| `I` | `outputCurrent`, `drainCurrent@nonActive` |
| `gate` | `gateVoltage@active` |

A method is available when every slot finds a signal **in the collection**. The signal actually used is recorded in `provenance.signals`. This replaces "alternative signal sets", which would have needed every combination listed.

### 11.2 Selection

`evaluateMeasurement` applies four rules in order:

1. Optional measurements are skipped unless listed in `S.measurements.enableOptional`.
2. Device-restricted measurements are skipped on the other device type.
3. Methods are tried in the order of `S.measurements.methods.<key>`; the first available one is used.
4. If none is available, the result is `skipped`, and the reason lists what each preferred method lacked.

`"nominal"` methods are available only when listed **and** the `cfg.nominal` value is set. An unknown method name in the settings is an error.

### 11.3 Tags

IEC methods are tagged with the standard name. All others carry their class and a label, e.g. `[Conv: I_L at V_GS 10 %]`. A bare `[Conv]` cannot tell two conventional options of the same row apart.

### 11.4 Gate instants

`gateInstant` uses the same local zero-phase smoothing as the edge's own reference crossing (`smoothingSamples`) and the last crossing in the edge direction. On the synthetic tanh edges it is accurate to 0.001 ns.

### 11.5 Physics notes recorded in the method descriptions

- **V_DS-based bus voltage reads high by V_F** (#1 settledVds, #2 offStateVds). With the freewheel diode conducting, V_DS,active = V_DC + V_F, so these methods read about V_F high (3–8 V on the example). The bus channel does not, which is why it is preferred.
- **Extrapolated I_on undershoots I_L** (#4). It reads below I_L at the gate instant by the ramp over the delay to the actual current rise: −0.9 A on the synthetic set, about 10 A/µs × 90 ns.
- **Example record:** I_on(k+1) − I_off(k) goes from +1.96 A to −0.79 A over the train. The current keeps ramping during the turn-off delay, and the V_F loss during the break grows with current.

### 11.6 Flags never change values

- `belowNoiseFloor`: |value| < 3σ of its samples.
- `resolutionLimited`: |value| < 10 ADC steps of its channel.

A power inherits its voltage's resolution flag. **[data]** Every on-state voltage on the example's full-range channel is flagged: V_DS(on) is at most 1–2 V against a 2.8 V step.

## 12. Bus-voltage model V_DC(t) (approved 2026-10-14, implemented 2026-10-15)

**Problem.** A separate bus-voltage channel is rarely captured because scopes are channel-limited, and a small DC link droops during the pulse train.

**[data]** On the example record, V_DC falls from about 404 V to 374 V (−7.5 %) over the 10 pulses. The droop is linear in the charge drawn from the link, Q(t) = ∫ I_D,active dt:

> ΔV = Q / C with C = 0.685 mF; residual 0.42 V rms over 9 breaks.

**Why "first V_DS, the rest is diode drop" fails.** Before pulse 1 no current flows, and the inductor DC-shorts the non-active device, so the active V_DS equals V_DC exactly (403.2 V on the example). That part is right. During a break, though, V_DS = V_DC(t) + V_F with V_F > 0, so a break V_DS *below* V_DC0 proves droop. On the example, break 9 is 22 V below V_DC0, which would mean an impossible V_F of −22 V.

### 12.1 Approved chain

V_DC(t) is computed **once per collection**. Every measurement that needs V_DC uses it: #1, #2, the "x % of V_DC" thresholds of #5/#6, #8 E_io, #30 overshoot, and #45. The first available source is used:

1. **Bus channel** (`Vdc`), if mapped.
2. **KVL:** V_DS,HS + V_DS,LS, when both are in the collection. Evaluated on settled segments only; switching transients are excluded because loop L·di/dt adds to them.
3. **Charge droop:** V_DC(t) = V_DC0 − Q(t)/C_dc.
   - V_DC0 is the active V_DS before pulse 1, or `cfg.nominal.busVoltage` when no pre-pulse segment exists.
   - Q(t) = ∫ I_D,active dt.
   - C_dc comes from `cfg.circuit.Cdc`.
4. **Constant V_DC0** (measured before pulse 1, or entered), with the **droop check**: if any break's off-state V_DS is below V_DC0 by more than its noise floor, results are flagged `busDroopDetected` and the observed droop is stated.

The spec's per-event options ("settled off-state V_DS", "off-state V_DS before turn-on") stay selectable for #1/#2, labelled as including V_F. With only one V_DS channel, V_F = V_DS(break) − V_DC(t) becomes a model-based method for #52, flagged as such; −V_DS of the non-active device stays preferred when present.

### 12.2 User decisions

- **Fallback order** as above. Usually not all V_DS channels are captured, so source 3 or 4 will be common.
- **C_dc is always known, with a tolerance**, typically ±20 % for DC-link capacitors. New fields: `cfg.circuit.Cdc` [F] and `cfg.circuit.CdcTolerance` (default 0.2).
  - The droop uncertainty must be propagated and reported. On the example a 30 V droop ±20 % is ±6 V at the last pulse.
  - Proposed: when KVL or a bus channel is available in any collection of the bucket, C is also estimated from data as a **cross-check** (warning if outside the tolerance). That is consistent with the identical-setup model.
- **UI requirement.** Which V_DC source is used must be obvious to the user. At minimum:
  - the run summary states the source per collection, e.g. "V_DC(t): charge droop, C = 0.68 mF ±20 %, V_DC0 = 403.2 V (pre-pulse V_DS)";
  - every V_DC-dependent result carries the source in its tag or provenance.

  The configuration block in `dpt_analyzer.m` should present the choice in plain words.
- **Future option: calibration routine.** Run the same pulse train once with a dedicated V_DC channel, to measure the droop-versus-charge curve of the setup exactly. That replaces C_dc ± 20 % with a measured curve for that bucket. Not now.

### 12.3 Related open point

**The full-range V_DS probes disagree by about 1 %.** On the example, Vds-HS reads −2.8 V before pulse 1 where the true value is 0 V, and the three V_DC readings around pulse 1 (pre-pulse V_DS, on-state KVL, break KVL) differ by 3–4 V. Any V_DS-based V_DC is therefore absolute only to about 1 %, the same size as V_F. A possible later opt-in: zero-offset correction of the non-active V_DS from the pre-pulse segment, where it must read 0.

### 12.4 Implementation notes (2026-10-15)

**Files.**

| File | Role |
|---|---|
| `busVoltageModel.m` | Pipeline step 6c, after normalization: selects the source and runs the diagnostics. |
| `measurements/busVoltageAt.m` | The only way measurements read V_DC. |
| `measurements/chargeAt.m` | Q(t). |

**Settings 0.7.0.**

- `S.busVoltage.sources` sets the order.
- `S.busVoltage.nominalTolerance` (5 %) bounds the pre-pulse V_DS vs `cfg.nominal` check.
- `S.busVoltage.prePulseCurrentFraction` (2 %) is explained in the pre-pulse current check below.
- `cfg.circuit.Cdc` and `cfg.circuit.CdcTolerance` (default 0.2) are new bucket fields.

**Charge intervals depend on the current signal.**

- **I_D:** from the turn-on window start to the turn-off window end. I_D is zero outside conduction, so a wider interval cannot add charge, and it cannot miss a slow fall or tail.
- **Iout (when no I_D is mapped):** stops at the gate-edge cores, because after the turn-off it carries the freewheel current, which does not drain the link.

**Uncertainty is conservative.** Droop = Q/C, so the worst case over C·(1 ± tol) is C·(1 − tol), an error of droop·tol/(1 − tol). That is 25 % of the droop for tol = 20 %. On the synthetic set, with C configured 20 % high, the error is 4.43 V against 5.54 V reported.

**Pre-pulse current check.** It requires more than the noise floor **and** more than 2 % of the record's peak current. The example's Iout reads −4.8 A before pulse 1 (probe zero offset, against a 638 A peak) and is not a pre-charge.

**The C estimate scales with the current sensor.** It comes from the measured droop against Q, where available:

- example with normalized currents: 0.680 mF;
- example with uncorrected Id, which reads 6.9 % low: 0.637 mF.

The issue message says which sensor the charge came from.

**#1/#2.** The separate `busChannel` method is replaced by `model`, whose first source is the bus channel. The model's source is appended to the tag, e.g. `[Conv: V_DC(t) from KVL]`, and its flags and uncertainty are carried over. `settledVds`/`offStateVds` (V_DC + V_F) stay selectable.

**#52.** New fallback `busModel`: V_F = active off-state V_DS − V_DC(t), flagged `modelBased`. On a drooping record with a constant V_DC0 it gives an impossible negative V_F (−1.84 V on the synthetic set), flagged `busDroopDetected`.

**[data] Example results.**

| Configuration | Source | V_DC at the last turn-off |
|---|---|---|
| Both V_DS | KVL (V_DC0 = 403.0 V) | 372.4 V |
| Single-V_DS copy, C = 0.685 mF | charge droop | 374.1 V |
| Single-V_DS copy, no C | constant | droop of at least 21.7 V detected, results flagged |
