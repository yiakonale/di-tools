# DPT Analyzer: Measurement Definitions and Selectable Threshold Methods

> Source: user specification, received 2026-10-13 (Batch 5). Kept verbatim; design decisions live in [MEASUREMENT_DESIGN.md](MEASUREMENT_DESIGN.md).

## Conventions

Signal notation: MOSFET names are used throughout. For IGBTs read V_DS as V_CE, I_D as I_C, V_GS as V_GE, and V_DC as V_CC.
"Active device" = the device being pulsed (DUT). "Non-active device" = the complementary device in the phase-leg.
"High" / "Low" subscripts = high-side / low-side device in the phase-leg.

Method tags:
- [IEC-8]  IEC 60747-8 (MOSFET)
- [IEC-9]  IEC 60747-9 (IGBT)
- [IEC-2]  IEC 60747-2 (diode)
- [JEDEC]  JEDEC diode convention
- [Conv]   Industry or instrument convention (not in a standard)
- [Custom] User-set levels or windows

Percent levels refer to the transition between the pre- and post-switching levels of the named signal unless stated otherwise.

## Core measurements

| # | Category | Quantity | Required signals | Thresholds / calculation criteria |
|---|---|---|---|---|
| 1 | Operating point | Bus voltage at turn-off, V_DC,off | Bus voltage or V_DS | Options: [Conv] bus-voltage channel averaged over a user window ending at the turn-off gate edge; [Conv] settled off-state V_DS after turn-off ringing decays; [Custom] nominal setpoint |
| 2 | Operating point | Bus voltage at turn-on, V_DC,on | Bus voltage or V_DS | Options: [Conv] off-state V_DS averaged over a user window ending at the turn-on gate edge (during the pulse break); [Conv] bus-voltage channel over the same window; [Custom] nominal setpoint |
| 3 | Operating point | Current at turn-off, I_off | I_D | Options: [Conv] filtered I_D averaged over a short user window ending at the turn-off gate edge; [Conv] I_D at the instant V_GS falls to 90%; [Custom] nominal I_test |
| 4 | Operating point | Current at turn-on, I_on | Diode or load current, or I_D | Options: [Conv] diode or load current averaged over a short window ending at the turn-on gate edge; [Conv] settled I_D after turn-on ringing, extrapolated back to the switching instant; [Custom] nominal I_test |
| 5 | Switching energy | Turn-on energy, E_on | V_DS, I_D (V_GS for gate-referenced options) | Integrate V_DS*I_D. Window options: [IEC-8] I_D 10% -> V_DS 10%; [IEC-9] V_GS 10% -> V_DS at 2% of V_DC; [Conv] I_D 10% -> V_DS at 2% of V_DC; [Conv] I_D 10% -> V_DS at 10% of V_DC; [Conv] V_GS 10% -> fixed time (10 to 20 us); [Custom] |
| 6 | Switching energy | Turn-off energy, E_off | V_DS, I_D (V_GS for gate-referenced options) | Integrate V_DS*I_D. Window options: [IEC-8] V_DS 10% -> I_D 10%; [IEC-9] V_GS 90% -> I_D 2%; [Conv] V_DS at 10% of V_DC -> I_D 2%; [Conv] V_DS at 10% of V_DC -> I_D 10%; [Conv] V_GS 90% -> fixed time; [Custom] |
| 7 | Switching energy | Total switching energy, E_sw | E_on, E_off | E_on + E_off, both taken from the same method set and the same operating point |
| 8 | Switching energy | Phase-leg total switching energy, E_io | V_DC, I_L, I_D of active device, V_DS of non-active device | [Conv] energy balance (Zhang et al., IEEE TPEL 2017): E_io = integral of (V_DC*I_D,active - I_L*V_DS,non-active) dt. Window options: per event, from the active device's gate edge (10%) to a user-set settling time after ringing decays; or across both events. Captures both devices' losses including cross-talk; insensitive to V-I deskew |
| 9 | Switching energy | Non-active device switching energy, E_sw,non-active | V_DS and I_D of non-active device, or E_io and E_sw | Options: [Conv] direct: integrate V_DS*I_D of the non-active device over the active device's E_on and E_off windows (needs a second current sensor, which adds loop inductance); [Conv] indirect: E_io - E_sw (active) |
| 10 | Switching energy | Turn-on switching power, P_on | V_DS, I_D | Options: event average = E_on / length of the selected E_on window; peak instantaneous = max(V_DS*I_D) inside the same window. Report which one |
| 11 | Switching energy | Turn-off switching power, P_off | V_DS, I_D | Options: event average = E_off / length of the selected E_off window; peak instantaneous = max(V_DS*I_D) inside the same window. Report which one |
| 12 | Switching energy | Average switching loss, P_sw | E_on, E_off, f_s (E_rr for phase-leg) | f_s*(E_on + E_off) per switch. For phase-leg loss, add f_s*E_rr of the complementary diode. All energies must come from the same operating point (V, I, T_j) |
| 13 | Switching timing | Turn-on delay, t_d(on) | V_GS, V_DS (I_D for IGBT option) | [IEC-8] V_GS 10% rising -> V_DS falls to 90%; [IEC-9] V_GS 10% rising -> I_D rises to 10%; [Custom] |
| 14 | Switching timing | Turn-off delay, t_d(off) | V_GS, V_DS (I_D for IGBT option) | [IEC-8] V_GS 90% falling -> V_DS rises to 10%; [IEC-9] V_GS 90% falling -> I_D falls to 90%; [Custom]. Do not offer a V_DS 90% end point: it overlaps row 16 |
| 15 | Switching timing | Turn-on voltage fall time, t_vf (IEC 60747-8 calls this t_r) | V_DS | [IEC-8] V_DS 90% -> 10% at turn-on; [Conv] 80% -> 20%; [Custom] |
| 16 | Switching timing | Turn-off voltage rise time, t_vr (IEC 60747-8 calls this t_f) | V_DS | [IEC-8] V_DS 10% -> 90% at turn-off; [Conv] 20% -> 80%; [Custom] |
| 17 | Switching timing | Turn-on current rise time, t_ir (IEC 60747-9 calls this t_r) | I_D | [IEC-9] I_D 10% -> 90% at turn-on; [Conv] same levels for MOSFETs; [Custom]. Adjust for current polarity |
| 18 | Switching timing | Turn-off current fall time, t_if (IEC 60747-9 calls this t_f) | I_D | [IEC-9] I_D 90% -> 10% at turn-off; [Conv] same levels for MOSFETs; [Custom]. Adjust for current polarity |
| 19 | Switching timing | Tail time, t_z (IGBT only) | I_D | [IEC-9] I_D 10% -> 2% at turn-off; [Custom] end level |
| 20 | Switching timing | Total turn-on time, t_on | V_GS, V_DS or V_GS, I_D | [IEC-8] t_d(on) + t_vf, spanning V_GS 10% -> V_DS 10%; [IEC-9] t_d(on) + t_ir, spanning V_GS 10% -> I_D 90%; [Custom] start and end events |
| 21 | Switching timing | Total turn-off time, t_off | V_GS, V_DS or V_GS, I_D | [IEC-8] t_d(off) + t_vr, spanning V_GS 90% -> V_DS 90%; [IEC-9] t_d(off) + t_if, spanning V_GS 90% -> I_D 10%; [Custom] |
| 22 | Switching timing | Pulse break, t_break (gap between pulse 1 and pulse 2 on the same gate) | V_GS of active device | [Conv] V_GS 50% falling (end of pulse 1) -> V_GS 50% rising (start of pulse 2); [Custom] levels |
| 23 | Switching timing | Half-bridge dead time, T_dt (between complementary gates) | V_GS of both devices | Only meaningful when the complementary device is actively driven (synchronous mode). [Conv] 50% falling edge of the outgoing gate -> 50% rising edge of the incoming gate; [Custom] user % or absolute volts (e.g. the datasheet V_GS(th)). Report both transitions (high -> low and low -> high) |
| 24 | Slew rate | Average drain-voltage slew rate, dv/dt | V_DS | [Conv] 10 to 90% average; [Conv] 20 to 80% average; [Custom]. No IEC definition exists. Report turn-on and turn-off separately |
| 25 | Slew rate | Average drain-current slew rate, di/dt | I_D | [Conv] 10 to 90% average; [Conv] 20 to 80% average; [Custom]. No IEC definition exists. Account for polarity; report turn-on and turn-off separately |
| 26 | Slew rate | Gate-voltage slew rate, dV_GS/dt | V_GS | [Conv] 10 to 90% of gate swing; [Conv] 20 to 80%; [Custom]. State whether % is of 0 -> V_G(on) or of V_G(off) -> V_G(on), and the derivative or fit method |
| 27 | Slew rate | Maximum instantaneous dv/dt | V_DS | Max absolute dv/dt inside: [Conv] the 10 to 90% window; [Custom] window. State the filter and derivative method |
| 28 | Slew rate | Maximum instantaneous di/dt | I_D | Max absolute di/dt inside: [Conv] the 10 to 90% window; [Custom] window. State the filter and derivative method |
| 29 | Voltage/current stress | Peak drain-source voltage, V_DS,max | V_DS | Max V_DS within: [Conv] the turn-off event window extended until ringing decays; [Conv] a fixed time after V_DS reaches 90%; [Custom] window |
| 30 | Voltage/current stress | Voltage overshoot, dV_DS,over | V_DS | V_DS,max - reference. Reference options: V_DC,off (row 1) / nominal V_DC / settled post-ringing V_DS. Also report as % of the reference |
| 31 | Voltage/current stress | Voltage undershoot, dV_DS,under | V_DS | Min V_DS (turn-on dip or post-turn-off ringing) - same reference options as row 30. Sign convention: negative means below the reference |
| 32 | Voltage/current stress | Peak drain current, I_D,max | I_D | Max I_D within: [Conv] the turn-on event window extended until ringing decays; [Custom] window |
| 33 | Voltage/current stress | Current overshoot, dI_D,over | I_D | I_D,max - reference. Reference options: I_on (row 4) / nominal I_test. At turn-on this roughly equals the diode's I_rrm; cross-check against row 39 |
| 34 | Voltage/current stress | Current undershoot, dI_D,under | I_D | Min I_D after the transition - same reference options as row 33. State the sign convention |
| 35 | Voltage/current stress | Peak gate-source voltage, V_GS,max | V_GS | Max V_GS within: the device's own switching windows / the whole capture. Compare against the V_GS max rating (static and transient if the datasheet gives both) |
| 36 | Voltage/current stress | Minimum gate-source voltage, V_GS,min | V_GS | Min V_GS within: the device's own switching windows / the whole capture. Compare against the negative V_GS rating (static and transient) |
| 37 | Voltage/current stress | Non-active device induced minimum V_GS | V_GS of non-active device | Min V_GS of the non-active device during the active device's turn-off window plus ringing (its V_DS is falling then). Compare against the negative V_GS rating |
| 38 | Voltage/current stress | Non-active device induced maximum V_GS | V_GS of non-active device | Max V_GS of the non-active device during the active device's turn-on window plus ringing (its V_DS is rising then). Compare against V_GS(th),min at the highest T_j, since the threshold drops with temperature |
| 39 | Reverse recovery | Peak reverse-recovery current, I_rrm | Diode current | Peak reverse current relative to zero. Options: raw / smoothed (state the filter) |
| 40 | Reverse recovery | Reverse-recovery time, t_rr | Diode current | Start at the current zero crossing. End options: [IEC-2] where the line through 0.9*I_rrm and 0.25*I_rrm crosses zero; [JEDEC] where the line through I_rrm and 0.25*I_rrm crosses zero; [Conv] direct crossing at 25% of I_rrm; [Conv] second zero crossing after the peak; [Custom] extrapolation points or % |
| 41 | Reverse recovery | Recovery current rise time, t_a | Diode current | Current zero crossing -> I_rrm peak |
| 42 | Reverse recovery | Recovery current fall time, t_b | Diode current | I_rrm peak -> t_rr end point (inherits the method selected in row 40). t_a + t_b = t_rr |
| 43 | Reverse recovery | Softness factor, S | t_a, t_b | Options: [Conv] t_b / t_a; [IEC-2] S_rr (implement once the formula is confirmed from the standard) |
| 44 | Reverse recovery | Reverse-recovery charge, Q_rr | Diode current | Integrate from the zero crossing. End options: [IEC-2] current at 2% of I_rrm; [Conv] the t_rr end point; [Conv] triangle approximation t_rr*I_rrm/2; [Custom] % or fixed t_i |
| 45 | Reverse recovery | Reverse-recovery energy, E_rr | Diode voltage and current | Integrate v*i. Window options: [IEC-2] zero crossing -> 2% of I_rrm; [Conv] diode voltage at 10% of V_DC -> 2% of I_rrm (R&S app note); [Custom] |
| 46 | Reverse recovery | Reverse-recovery current slew rate | Diode current | Options: [Conv] di_F/dt through the zero crossing; [Conv] peak di/dt during t_b; [Conv] average between custom levels. State the filter |
| 47 | Output capacitance/parasitics | Switching-loop inductance estimate, L_loop | V_DS, I_D, circuit assumptions | Options: [Conv] turn-on dip: L = (V_DC - V_DS) / (dI_D/dt) during the current rise, before V_DS collapses; [Conv] ringing: L = 1/((2*pi*f_r)^2 * C) with a known C_oss (pairs with row 55); [Conv] turn-off overshoot (V_DS,max - V_DC) / (di/dt), flagged as less reliable because it includes capacitive charging |
| 48 | Output capacitance/parasitics | Output charge, Q_oss | Diode or device current, V_DS | Integrate current from: [Conv] current zero crossing -> V_DS at 90% of its peak; [Custom] end at user % of peak or of V_DC |

## Optional measurements

| # | Category | Quantity | Required signals | Thresholds / calculation criteria |
|---|---|---|---|---|
| 49 | Conduction | On-state voltage, V_DS(on) | V_DS | Window options: [Conv] final portion of pulse 1 before the turn-off gate edge; [Conv] fixed delay after V_DS reaches 10% until the end of the pulse; [Custom]. Use a clipped or clamped V_DS channel for resolution |
| 50 | Conduction | On-state current, I_D(on) | I_D | Same window as row 49 |
| 51 | Conduction | Effective on-state resistance, R_on,eff | V_DS, I_D | Options: [Conv] V_DS/I_D averaged over the row 49 window; [Conv] time-resolved V_DS/I_D at user-set delays after turn-on (dynamic R_DS(on); see JEDEC JEP173 for GaN). Needs a clipped or clamped V_DS channel |
| 52 | Conduction | Freewheel diode forward voltage, V_F | Diode voltage | Window: during the pulse break, from a user-set delay after turn-off ringing decays until just before the turn-on gate edge |
| 53 | Conduction | Freewheel diode forward current, I_F | Diode current | Same window as row 52 |
| 54 | Conduction | Conduction power, P_cond | Device voltage and current | Average of v*i over the row 49 window (row 52 window for the diode) |
| 55 | Output capacitance/parasitics | Effective parasitic capacitance, C_par | Ringing frequency and L_loop, or Q_oss | Options: [Conv] LC model from turn-off ringing: C = 1/((2*pi*f_r)^2 * L), with L from row 47; [Conv] charge-based: C_eq = Q_oss / dV, with Q_oss from row 48. State the model |

## Built-in checks

- Warn if t_d(off) and t_vr overlap, or if t_d(on) and t_vf overlap.
- Warn if a 2% end point is never reached (common for IGBTs at high current), and suggest using the measured on-state voltage as the 0% reference.
- Warn if E_on + E_off and E_io differ by more than a user-set margin; this is a good deskew and cross-talk check.
- Flag if the chosen method does not match the device type, such as IEC 60747-9 windows on a MOSFET.
- Warn if V_DC,on differs from V_DC,off, or I_on from I_off, by more than a user-set margin (bus droop or current decay during the pulse break).
- Check that dI_D,over at turn-on is consistent with I_rrm.

## Presets

Presets set every method at once:
- IEC 60747-8: MOSFETs, plus IEC 60747-2 for the body diode
- IEC 60747-9: IGBTs, plus IEC 60747-2 for the diode
- IGBT module datasheet style: current-start and voltage-start energy windows
- Tektronix WBG-DPT defaults
- R&S app note, with the legacy t_d(off) flagged

Every result in the report must carry its method tag next to the value, for example "E_off = 1.23 mJ [IEC 60747-9]", so numbers measured with different conventions are never compared by accident.
