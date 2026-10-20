function S = dptSettings(overrides)
%DPTSETTINGS Analyzer-wide settings for the DPT waveform analyzer.
%
%   S = dptSettings() returns the default settings struct.
%
%   S = dptSettings(overrides) recursively merges the struct OVERRIDES
%   into the defaults, then validates the result. Every field in
%   OVERRIDES must already exist in the defaults, so a misspelled field
%   is an error rather than a silently ignored setting. Example:
%
%       ov.gate.levels.tolerance = 0.5;
%       S = dptSettings(ov);
%
%   Always construct settings through this function; do not edit fields
%   of a returned struct, because edits made afterwards bypass validation.
%
%   Scope
%     This file holds analyzer-wide behaviour only. Bucket configuration
%     (bucket path, active device, expected pulse count, nominal gate
%     drive levels) lives in dpt_analyzer.m; channel assignments live in
%     each collection's channelMap.m.
%
%   Conventions
%     All values are SI (V, A, s). Fractions are unitless in [0, 1].
%     An empty value [] means "not set / feature disabled" and is
%     documented per field. Settings never describe a particular
%     acquisition: levels, edge times and windows are measured from the
%     waveforms; settings only define how that measurement is done and
%     how its results are validated.
%
%   Fixed rules that are deliberately NOT settings (they are data
%   integrity invariants, not preferences):
%     - All channels within one collection must share sample interval,
%       record length and time vector.
%     - Raw waveforms are never modified; conditioning acts on a copy.
%     - A measurement requiring simultaneous signals uses one collection.
%     - Expected pulse count is advisory; detected pulses drive analysis.
%     - Waveforms are never resampled or interpolated for alignment.
%     - All collections of a bucket share one scope setup (sample
%       interval, record length) and capture the same complete pulse
%       train of the active gate; only the trigger point varies. Each
%       collection is aligned by one constant offset, and a collection
%       whose setup or gate edge sequence differs is excluded.

S = defaultSettings();

if nargin > 0 && ~isempty(overrides)
    if ~isstruct(overrides) || ~isscalar(overrides)
        error('dpt:settings:invalidOverrides', ...
            'Overrides must be a scalar struct.');
    end
    S = mergeOverrides(S, overrides, "");
end

validateSettings(S);

end

% =====================================================================
function S = defaultSettings()

S.schemaVersion = "0.15.0";

%% Canonical signals --------------------------------------------------
% The semantic signal namespace used by channel maps and measurements.
%   name     : canonical name used in channelMap.m
%   quantity : physical role, so measurements can request e.g. "the
%              drainVoltage of the active device" without naming signals
%   device   : "HS" | "LS" | "" (not device-specific)
%   units    : required verticalUnits of the scope export
%
% Sign conventions (Q1): I_D of each device is positive drain -> source;
% Iout (inductor current) is positive in the direction that flows into
% the active device's drain while it conducts. Fix a reversed probe with
% "invert" in the channel map.
%
% Vdc is a dedicated bus-voltage channel. Vds-*-clamp are clamped or
% clipped V_DS channels for on-state voltages (#49-52); they can be
% mapped alongside the full-range Vds-* in the same collection.
S.signals.catalog = table( ...
    ["Vgs-HS"; "Vgs-LS"; "Vds-HS"; "Vds-LS"; "Id-HS"; "Id-LS"; "Iout"; ...
     "Vdc"; "Vds-HS-clamp"; "Vds-LS-clamp"], ...
    ["gateVoltage"; "gateVoltage"; "drainVoltage"; "drainVoltage"; ...
     "drainCurrent"; "drainCurrent"; "outputCurrent"; ...
     "busVoltage"; "drainVoltageClamped"; "drainVoltageClamped"], ...
    ["HS"; "LS"; "HS"; "LS"; "HS"; "LS"; ""; ""; "HS"; "LS"], ...
    ["V"; "V"; "V"; "V"; "A"; "A"; "A"; "V"; "V"; "V"], ...
    'VariableNames', {'name', 'quantity', 'device', 'units'});

%% Gate drive ---------------------------------------------------------
% The nominal drive levels vary between test setups (+15/-15 V to
% +20/-5 V), so they are bucket configuration (dpt_analyzer.m), not
% settings. Detection thresholds are computed from the MEASURED levels;
% the nominal levels only validate the gate channel and seed the level
% estimate.

% Gate polarity. "high" means the device conducts when Vgs is high
% (n-channel MOSFET, IGBT, GaN HEMT), so a rising gate edge is a
% turn-on and a falling gate edge is a turn-off.
S.gate.activeLevel = "high";   % "high" | "low"

% How the actual off/on levels are obtained.
%   "measured": estimated from the gate waveform itself (median of the
%               samples on each side of the nominal midpoint). Requires
%               no time constants; valid when the record spends most of
%               its time at the two drive levels, as a DPT record does.
%   "nominal" : use the bucket's nominal levels directly (diagnostic
%               use only).
S.gate.levels.source = "measured";

% Maximum allowed |measured - nominal| for each level. Exceeding it
% means the channel is probably not the active gate (wrong mapping,
% passive device's gate, wrong probe attenuation), or the bucket's
% nominal levels are wrong for this setup. Must be smaller than half
% the nominal swing; that check is made against the bucket config.
S.gate.levels.tolerance = 1.0;             % [V]
S.gate.levels.onMismatch = "error";        % "error" | "warn"

%% Gate-transition detection ------------------------------------------
% Detection has two stages:
%   1. Edge qualification (hysteresis / Schmitt trigger): an edge exists
%      only when the gate travels from one arm to the other. This
%      rejects noise, ringing and Miller-plateau recrossings without any
%      slope threshold or time constant.
%   2. Timing reference: the edge's time is the crossing of a reference
%      level located between the two arms, interpolated between samples.

% Hysteresis arms, as fractions of the measured swing above the
% measured low level. Must satisfy 0 < lower < upper < 1 and must
% bracket the reference level for both edge directions.
S.detection.hysteresis.lower = 0.15;
S.detection.hysteresis.upper = 0.85;

% Reference-level strategy.
%   "percent" : initial + fraction * (final - initial), i.e. the fraction
%               is measured FROM THE LEVEL THE EDGE STARTS AT. For a
%               rising edge 0.25 means 25 % above the low level; for a
%               falling edge it means 25 % below the high level.
%   "midpoint": (low + high) / 2 for both directions.
%   "absolute": a fixed voltage, S.detection.reference.absolute.
S.detection.reference.strategy = "percent";

% Default 0.25: on the test record (MSO58B, 160 ps, -5.4/+17.4 V) the
% gate edges are clean at 20-30 % from the initial level in BOTH
% directions (<= 3 crossings, <= 2 ns spread), because this region lies
% before the Miller plateau on both turn-on and turn-off. That makes it
% depend mainly on the gate loop (driver, Rg, Ciss), not on load
% current or Vds, so it is repeatable across collections. The midpoint
% and the 90 % level both sit on the Miller plateau or the slow tail
% and show up to 19-25 recrossings spanning 65-230 ns.
S.detection.reference.fraction = 0.25;     % [-] used by "percent"
S.detection.reference.absolute = [];       % [V] used by "absolute"

% Which reference crossing to report when the conditioned gate crosses
% the reference level more than once inside one qualified edge.
%   "last" : the final crossing before the far arm is reached (the one
%            after which the gate never returned). Standard choice.
%   "first": the first crossing after leaving the near arm.
% The number of crossings is always recorded as a diagnostic.
S.detection.reference.crossingSelection = "last";

% Linear interpolation between the two samples bracketing the crossing.
S.detection.interpolateCrossing = true;

% Timing smoothing: each qualified edge is timed on a local, centred
% (zero-phase) moving mean of length timingSmoothing * D, where D is that
% edge's duration between the hysteresis arms. Scaling with D keeps the
% filter appropriate for any gate speed (us IGBT edges to ns GaN edges).
% 0 disables it. Default 0.04 from the test record (a copy with extra
% gate noise vs the clean copy, same filter): timing error 2.88 ns
% unsmoothed, 0.64 / 0.16 / 0.053 / 0.14 ns at 0.005 / 0.02 / 0.04 /
% 0.08; bias on a noise-free edge 0.02 ns at 0.04, rising to 0.19 ns at
% 0.16. Any bias common to all collections cancels in alignment.
S.detection.timingSmoothing = 0.04;        % [-] fraction of D

% Warn when a qualified edge has more than this many reference
% crossings (1 = any recrossing warns). Indicates a poorly chosen
% reference level or excessive noise.
S.detection.maxReferenceCrossings = 3;

% Optional minimum time between consecutive qualified edges. Edges
% closer than this are an error in detection, not a physical event.
% [] disables the check; hysteresis already rejects recrossings.
S.detection.minEdgeSpacing = [];           % [s]

%% Detection-only signal conditioning ---------------------------------
% Applied to a COPY of the gate waveform used for edge detection only.
% Any method must be zero-phase (symmetric) so it does not shift edge
% timing. Only base-MATLAB methods are offered: the Signal Processing
% Toolbox is not assumed to be installed.
%   "none"     : no conditioning (default; the hysteresis band is about
%                100x the measured gate noise on the test record, so edge
%                qualification needs none). Edge TIMING is smoothed
%                separately, per edge: S.detection.timingSmoothing.
%   "movmean"  : centred moving average.
%   "movmedian": centred moving median (removes isolated spikes while
%                preserving edges better than a mean).
S.conditioning.method = "none";
S.conditioning.windowDuration = [];        % [s] required by movmean/movmedian

%% Pulses -------------------------------------------------------------
% Warn when the number of detected pulses differs from the expected
% count configured in dpt_analyzer.m. Analysis always proceeds with the
% detected pulses.
S.pulses.warnOnCountMismatch = true;

% Edges cut by the start or end of the record (the gate is not at a
% settled level when the record begins or ends) cannot be qualified.
%   "discard": drop incomplete edges and report them.
%   "error"  : treat an incomplete edge as a collection error.
S.pulses.incompleteEdgePolicy = "discard";

%% Cross-collection alignment -----------------------------------------
% Collections are aligned on the matched gate edges of the active
% device; zeroIndex is retained as metadata only.

% Origin of the universal timeline.
%   "firstTurnOn": t = 0 at the first detected turn-on reference
%                  crossing (the DPT's natural origin).
S.alignment.timeOrigin = "firstTurnOn";

% How a collection's time offset is estimated from its matched edges.
%   "median"   : median of per-edge offsets (robust to one bad edge).
%   "mean"     : mean of per-edge offsets.
%   "firstEdge": offset of the first matched edge only.
S.alignment.offsetEstimator = "median";

% Maximum allowed per-edge residual after alignment. Residuals are
% always reported. [] = report only, no pass/fail; the right limit
% depends on the timing precision the measurements need, which is not
% yet specified.
S.alignment.maxResidual = [];              % [s]

%% Sampling validation ------------------------------------------------
% Numerical tolerances only; they absorb floating-point representation
% error, not physical timing differences.

% Relative tolerance when comparing sample intervals between channels
% and between collections.
S.sampling.sampleIntervalRelTol = 1e-9;

% Relative tolerance on diff(time) versus sampleInterval when checking
% that a time vector is uniform (test record: 1e-10).
S.sampling.timeVectorRelTol = 1e-6;

%% Post-acquisition corrections ---------------------------------------
% Optional per-channel deskew and inversion declared in channelMap.m,
% applied on read by getSignal.m. Raw samples are never rewritten.

% A deskew that is not an integer multiple of the sample interval.
%   "round": apply round(deskew/dt)*dt everywhere and report the residual
%            (<= dt/2). Signals then share one time grid, so sample-wise
%            products such as V*I need no interpolation.
%   "error": reject the collection.
S.corrections.nonIntegerDeskew = "round";

% Floating-point tolerance [samples] for deciding that deskew/dt is
% already an integer (e.g. 1.28 ns / 160 ps = 8 +/- 1e-15).
S.corrections.integerShiftTol = 1e-6;

%% Zero-offset correction (cfg.zeroOffsetCorrection) ---------------------
% Before the first pulse of a DPT the inductor is at rest and both devices
% are off; the inductor DC-shorts the non-active device. Channels playing
% these roles must then read zero, so their pre-pulse mean is a probe
% zero offset, removed as a declared correction (getSignal). The active
% V_DS reads V_DC there and is never zero-corrected.
S.zeroOffset.roles = ["drainCurrent@active", "drainCurrent@nonActive", ...
    "outputCurrent", "drainVoltage@nonActive", "drainVoltageClamped@nonActive"];
% An "offset" larger than this fraction of the channel's scale is a real
% signal (e.g. a record that starts inside a pulse train), not an offset:
% that channel is left uncorrected and reported. Scale: the channel's
% peak for currents, the pre-pulse V_DS of the active device (V_DC) for
% voltages. Probe offsets do not shrink with the test current (the
% example's -4.8 A is 0.8 % of its 638 A peak but would be 2.7 % of a
% 180 A test), so the limit only catches gross cases.
S.zeroOffset.maxFraction = 0.05;

%% DC bus voltage model -------------------------------------------------
% V_DC(t) is estimated once per collection from the first available
% source in this list (MEASUREMENT_DESIGN.md section 12). Every
% V_DC-dependent result states the source used.
%   "busChannel" : a mapped bus-voltage channel (Vdc)
%   "kvl"        : V_DS,HS + V_DS,LS, when both are mapped. Valid on
%                  settled segments; during switching transients the
%                  loop's L*di/dt adds to it.
%   "chargeDroop": V_DC0 - Q(t)/C_dc, with Q the charge drawn from the DC
%                  link while the active device conducts. Needs
%                  cfg.circuit.Cdc; its tolerance becomes the uncertainty.
%   "constant"   : V_DC0 for the whole record. A pulse break whose
%                  off-state V_DS lies below V_DC0 proves droop (V_F > 0),
%                  and results are flagged "busDroopDetected".
% V_DC0 is the active V_DS before the first pulse (no current flows and
% the inductor shorts the other device, so it equals V_DC), else
% cfg.nominal.busVoltage.
S.busVoltage.sources = ["busChannel", "kvl", "chargeDroop", "constant"];

% Warn when the pre-pulse V_DS and cfg.nominal.busVoltage differ by more
% than this fraction (wrong setpoint entered, or a probe error).
S.busVoltage.nominalTolerance = 0.05;

% Inductor current before the first pulse counts as a pre-charge (V_DC0
% would include a diode drop) only above this fraction of the record's
% peak current; smaller readings are probe zero offsets (the example
% record shows -5 A against a 638 A peak).
S.busVoltage.prePulseCurrentFraction = 0.02;

%% Measurement windows ------------------------------------------------
% One window per (edge, collection), anchored to that collection's
% detected gate edge. The window CORE is the qualified gate edge itself:
% from the last sample at the near hysteresis arm to the first sample at
% the far arm. Its duration D adapts to the gate drive, device and
% current. On the test record every Vds/Id 10-90 % transition lies
% inside the core, and Vds has settled to 5 % by the core's end.
%
%   "adaptive": [coreStart - pre*D, coreEnd + post*D]
%   "fixed"   : reference time + S.windows.fixed.<kind> (override)
S.windows.method = "adaptive";

% Margins in multiples of D. PROVISIONAL defaults pending the measurement
% specification (Batch 5): pre gives a settled baseline segment of length
% D before the edge; post covers ringing and tail current after it.
S.windows.adaptive.pre  = 1.0;             % [-] multiples of D
S.windows.adaptive.post = 2.0;             % [-] multiples of D

% Hard limit: a window never extends past the midpoint between its edge
% and the neighbouring edges, so windows of adjacent transitions never
% overlap. Derived from the data; needs no constant.
S.windows.limitToNeighborMidpoint = true;

% Fixed windows relative to the edge reference time, [before, after] in
% seconds (e.g. [-200e-9, 800e-9]). Required when method is "fixed".
% [] = not defined. Values depend on the measurement specification.
S.windows.fixed.turnOn  = [];              % [s] 1x2, before <= 0 <= after
S.windows.fixed.turnOff = [];              % [s] 1x2

% Use the fixed window as a fallback when the adaptive window does not
% fit inside the record and the fixed one does. The window is then
% marked method = "fallback" and reported.
S.windows.useFixedAsFallback = true;

% A window that would extend past the record boundary.
%   "skip"    : do not use the window; dependent measurements are skipped.
%   "truncate": clip to the record and flag the window as truncated.
S.windows.onInsufficientCoverage = "skip";

%% Measurements -------------------------------------------------------
% Method selection and shared parameters of the measurement framework
% (MEASUREMENT_DESIGN.md). The methods themselves are defined in
% measurements/measurementRegistry.m; this section only selects them and
% sets their parameters. Lengths are in multiples of the event's gate-edge
% duration D, so they scale with the device (Q6).

% Noise-floor rule (Q2): a threshold, or a result, closer than k*sigma
% to a level of the same signal is not resolvable.
S.measurements.common.noiseFloorMultiple = 3;
% Ringing has decayed when the signal stays within +/- settlingBand of
% its settled level, as a fraction of the transition amplitude (Q6), but
% never within the noise (settledAfter, design 16.3).
S.measurements.common.settlingBand = 0.02;
% Noise floor of the settling band: the noise of the territory's tail,
% unless it is more than this many times the quiet pre-switching noise
% (max of sigma and the ADC step); then the tail still rings, and the
% pre-switching noise is used instead.
S.measurements.common.tailNoiseRatio = 3;
% Settled level = median of this final fraction of the territory (Q6).
S.measurements.common.settledPortion = 0.25;
% "User windows" ending at a gate instant (#1-4, #49), in D (Q6).
S.measurements.common.averagingWindow = 1;
% A value "at an instant" is the mean over +/- this, in D. On a linear
% ramp (inductor current) the centred mean equals the instantaneous
% value, without its sample noise and quantization.
S.measurements.common.instantHalfWidth = 0.5;
% Fit length for the extrapolated I_on of #4, in D.
S.measurements.common.extrapolationFit = 2;
% A level result smaller than this many ADC steps of its channel is
% flagged resolution-limited (relative resolution worse than 10 %).
S.measurements.common.resolutionSteps = 10;
% Percentage basis of gate-voltage thresholds (Q3).
%   "swing": V_G(off) -> V_G(on)    "zero": 0 -> V_G(on)
S.measurements.common.gateBasis = "swing";

% Acceptance of the current-sensor normalization (cfg.currentNormalization).
% Refused if the fit residual exceeds maxResidualRatio times the expected
% residual from the two sensors' own noise, or if any pulse's gain
% differs from the fitted gain by more than maxGainSpread (a sign of
% saturation or droop, which one gain cannot correct).
S.measurements.normalization.maxResidualRatio = 2;
S.measurements.normalization.maxGainSpread = 0.02;

% V_DS probe calibration (cfg.voltageNormalization): a relative gain error
% beyond this is a wrong probe attenuation setting, not a calibration.
S.measurements.voltageNormalization.maxGainError = 0.05;

% Preset: sets every measurement whose preference below is "preset" to
% the method of the chosen standard (MEASUREMENT_DESIGN.md section 4).
%   "auto" : IEC-8 for cfg.deviceType "MOSFET", IEC-9 for "IGBT"
%   "IEC-8": IEC 60747-8 (MOSFET) + IEC 60747-2 (diode)
%   "IEC-9": IEC 60747-9 (IGBT) + IEC 60747-2 (diode)
%   "none" : each measurement's first registry method
% Rows without an IEC definition use their default conventional method.
% A method from the other device type's standard is flagged
% "methodDeviceMismatch" on the result.
S.measurements.preset = "auto";

% Optional measurements (#48-55) run only when listed here ("all" = all).
S.measurements.enableOptional = strings(1, 0);

% Method preference per measurement: the first method whose required
% signals exist in the collection is used and reported. "nominal" uses
% cfg.nominal and is only used when listed.
S.measurements.methods.VdcOff        = ["model", "settledVds"];
S.measurements.methods.VdcOn         = ["model", "offStateVds"];
S.measurements.methods.Ioff          = ["inductorAtInstant", "idAtGate90"];
S.measurements.methods.Ion           = ["inductorAtInstant", "extrapolatedId"];
S.measurements.methods.onStateWindow = "finalPortion";   % #49-51, #54 device
S.measurements.methods.RonEff        = "averaged";
S.measurements.methods.IfDiode       = ["inductorDuringBreak", "measuredDiode"];
S.measurements.methods.Vf            = ["breakWindow", "busModel"];
% Timing and slew rates (#13-28): "preset", or explicit method ids.
S.measurements.methods.tdOn          = "preset";
S.measurements.methods.tdOff         = "preset";
S.measurements.methods.tvf           = "preset";
S.measurements.methods.tvr           = "preset";
S.measurements.methods.tir           = "preset";
S.measurements.methods.tif           = "preset";
S.measurements.methods.tz            = "preset";
S.measurements.methods.tOn           = "preset";
S.measurements.methods.tOff          = "preset";
S.measurements.methods.tBreak        = "preset";
S.measurements.methods.deadTime      = "preset";
S.measurements.methods.dvdt          = "preset";
S.measurements.methods.didt          = "preset";
S.measurements.methods.dvgsdt        = "preset";
S.measurements.methods.dvdtMax       = "preset";
S.measurements.methods.didtMax       = "preset";
% Switching energy and power (#5-12): "preset", or explicit method ids.
% E_sw, P_on and P_off follow the E_on / E_off methods chosen here.
S.measurements.methods.Eon           = "preset";
S.measurements.methods.Eoff          = "preset";
S.measurements.methods.Esw           = "preset";
S.measurements.methods.Eio           = "preset";
S.measurements.methods.EioPair       = "preset";
S.measurements.methods.EswNonActive  = "preset";
S.measurements.methods.Pon           = "preset";
S.measurements.methods.Poff          = "preset";
S.measurements.methods.Psw           = "preset";
% Voltage, current and gate stress (#29-38): "preset", or explicit ids.
% #30, #31 use the window of #29; #33, #34 that of #32. Their methods
% choose the reference: "ownLevel" (default: the signal's own level at
% that moment), "busModel" / "Ion" (operating point) or "nominal".
S.measurements.methods.VdsMax        = "preset";
S.measurements.methods.dVdsOver      = "preset";
S.measurements.methods.dVdsUnder     = "preset";
S.measurements.methods.IdMax         = "preset";
S.measurements.methods.dIdOver       = "preset";
S.measurements.methods.dIdUnder      = "preset";
S.measurements.methods.VgsMax        = "preset";
S.measurements.methods.VgsMin        = "preset";
S.measurements.methods.VgsNMin       = "preset";
S.measurements.methods.VgsNMax       = "preset";
% Reverse recovery of the non-active device's diode (#39-46), at the
% active device's turn-on: "preset" (IEC 60747-2 where it defines the
% row), or explicit ids. t_a (#41) has one method; t_b (#42) inherits the
% t_rr end point chosen here for #40.
S.measurements.methods.Irrm          = "preset";
S.measurements.methods.trr           = "preset";
S.measurements.methods.Srr           = "preset";
S.measurements.methods.Qrr           = "preset";
S.measurements.methods.Err           = "preset";
S.measurements.methods.didtRR        = "preset";
% Parasitics (#47, #48, #55): "preset" (each row's first [Conv] method
% that applies to the event), or explicit ids. #47 "dip" / "dipVdc" apply
% at turn-on, "ringing" / "overshoot" at turn-off. #48 (optional) "zeroTo90"
% at turn-on, "turnOffDischarge" at turn-off. #55 "LC" at turn-off,
% "charge" at both.
S.measurements.methods.Lloop         = "preset";
S.measurements.methods.Qoss          = "preset";
S.measurements.methods.Cpar          = "preset";

% Method parameters.
% onStateWindow "delayToEnd": delay after V_DS reaches 10 % at turn-on
% [s]; [] = the V_DS settling time.
S.measurements.params.onStateWindow.delay = [];
% onStateWindow "custom": [t0 t1] [s] relative to the turn-off V_GS 90 %
% instant (both <= 0).
S.measurements.params.onStateWindow.custom = [];
% RonEff "timeResolved": delays [s] after V_DS reaches 10 % at turn-on.
S.measurements.params.RonEff.delays = [];
% Extra delay [s] after the turn-off ringing settles before the diode
% forward window of #52-54 starts.
S.measurements.params.breakWindow.delay = 0;

% Slew rates (#24-26): band maximum (Q10). The steepest average slope over
% any band of this fraction of the swing, slid across [10 %, 90 %] in
% steps of bandStep.
S.measurements.params.slew.band = 0.2;
S.measurements.params.slew.bandStep = 0.01;

% Maximum instantaneous slew rate (#27, #28): Savitzky-Golay derivative
% (order 2). Window = windowBandFactor x the time the signal takes to
% cross the steepest band above, at least minSamples (odd; 3 with order 2
% is a plain central difference). If the floor sets the window, the edge
% is under-sampled for a derivative and the result is flagged
% "derivativeUndersampled". On synthetic
% tanh edges quantized like the example (2.8 V steps), one band time
% gives n = 5 / 13 / 51 for tau = 2 / 5 / 20 ns, each within about 2 % of
% the true maximum; no fixed window works for all three (n = 11: -3 %,
% +1 %, +18 %). windowDuration [s] overrides with a fixed window.
S.measurements.params.derivative.order = 2;
S.measurements.params.derivative.windowBandFactor = 1;
S.measurements.params.derivative.minSamples = 3;
S.measurements.params.derivative.windowDuration = [];

% [Custom] definitions, used when a measurement's method is "custom".
%   Intervals (#13-22): struct('start', thr, 'stop', thr), where a
%     threshold is struct('signal', role, 'level', p, 'basis', b) with
%     basis "transition" (amplitude scale of the signal's own levels),
%     "Vdc" (p * V_DC), "gate" (gate basis) or "absolute" [V or A];
%     optional 'edge' (1 or 2, for break events).
%   Slew rates (#24-28): [lo hi] fractions of the swing.
%   Dead time (#23): struct('level', p or volts, 'basis', "swing"|"absolute").
S.measurements.params.custom.tdOn      = [];
S.measurements.params.custom.tdOff     = [];
S.measurements.params.custom.tvf       = [];
S.measurements.params.custom.tvr       = [];
S.measurements.params.custom.tir       = [];
S.measurements.params.custom.tif       = [];
S.measurements.params.custom.tz        = [];
S.measurements.params.custom.tOn       = [];
S.measurements.params.custom.tOff      = [];
S.measurements.params.custom.tBreak    = [];
S.measurements.params.custom.deadTime  = [];
S.measurements.params.custom.dvdt      = [];
S.measurements.params.custom.didt      = [];
S.measurements.params.custom.dvgsdt    = [];
S.measurements.params.custom.dvdtMax   = [];
S.measurements.params.custom.didtMax   = [];
% Energies (#5, #6): struct('start', thr, 'stop', thr), as for intervals.
S.measurements.params.custom.Eon       = [];
S.measurements.params.custom.Eoff      = [];

% Energy windows "[Conv] V_GS 10 % / 90 % -> fixed time" (#5, #6): length
% [s]. The spec gives 10 to 20 us; the window must fit in the territory,
% otherwise the result fails (it would integrate into the next event).
S.measurements.params.energy.fixedDuration = 10e-6;

% E_io (#8): the window ends this long [s] after the active V_DS has
% settled (settlingBand of its transition).
S.measurements.params.Eio.settleDelay = 0;

% V_DS,max (#29) "after90": window length after V_DS reaches 90 %, in D.
S.measurements.params.stress.after90Window = 2;
% Custom peak windows (#29, #32): [t0 t1] [s] relative to the gate
% instant (V_GS 90 % falling / 10 % rising).
S.measurements.params.custom.VdsMax    = [];
S.measurements.params.custom.IdMax     = [];

% Reverse recovery (#39-46).
% Derived diode current I_L - I_D (cfg.diodeCurrent.allowDerived) is
% refused for an event whose mean conduction-phase mismatch exceeds this
% fraction of its I_rrm (design Q5).
S.measurements.params.recovery.derivedMismatch = 0.25;
% "smoothed" I_rrm (#39): Savitzky-Golay order 2 over this fraction of
% t_a (at least params.derivative.minSamples); the filter is stated.
S.measurements.params.recovery.smoothFraction = 0.25;
% Peak di/dt during t_b (#46): Savitzky-Golay derivative over this
% fraction of t_b (at least params.derivative.minSamples).
S.measurements.params.recovery.derivativeFraction = 0.25;
% di_F/dt through the zero crossing (#46): line fit between I_F falling
% through didtLevels(1)*I_F (forward) and -didtLevels(2)*I_rrm (reverse).
S.measurements.params.recovery.didtLevels = [0.5 0.5];
% Custom: t_rr end (#40) where the line through the recovering current at
% -a*I_rrm and -b*I_rrm crosses zero, [a b] (e.g. [0.9 0.25] is IEC-2);
% Q_rr / E_rr end (#44, #45) at a fraction of I_rrm on the recovering
% slope, or a fixed duration [s] after the zero crossing; #46 average
% slope between two diode-current levels [i1 i2] [A].
S.measurements.params.custom.trrLevels        = [];
S.measurements.params.custom.recoveryEnd      = [];
S.measurements.params.custom.recoveryDuration = [];
S.measurements.params.custom.didtRR           = [];

% Q_oss (#48) custom end: V_DS of the non-active device reaching QossEnd
% (fraction) of its peak ("peak") or of V_DC ("Vdc").
S.measurements.params.custom.QossEnd   = [];
S.measurements.params.custom.QossBasis = "peak";

%% Reporting ----------------------------------------------------------
% Warnings are always collected in the results. This controls whether
% they are also issued through MATLAB's warning() as they occur.
S.report.echoWarnings = true;
S.report.showSkippedMeasurements = true;

% "quiet": warnings and final summary only.
% "normal": plus per-stage progress.
% "verbose": plus per-edge and per-measurement diagnostics.
S.report.verbosity = "normal";

end

% =====================================================================
function S = mergeOverrides(S, ov, path)
% Recursively copy fields of OV into S. Unknown fields are errors.

names = fieldnames(ov);
for k = 1:numel(names)
    name = names{k};
    fieldPath = strjoin([path, string(name)], ".");
    fieldPath = strip(fieldPath, "left", ".");
    if ~isfield(S, name)
        error('dpt:settings:unknownField', ...
            'Unknown settings field "%s".', fieldPath);
    end
    % Recurse into nested setting groups; anything else is replaced.
    if isstruct(S.(name)) && ~isempty(fieldnames(S.(name)))
        if ~isstruct(ov.(name)) || ~isscalar(ov.(name))
            error('dpt:settings:invalidOverrides', ...
                'Settings field "%s" is a group; override it with a struct.', ...
                fieldPath);
        end
        S.(name) = mergeOverrides(S.(name), ov.(name), fieldPath);
    else
        S.(name) = ov.(name);
    end
end

end

% =====================================================================
function validateSettings(S)
% Check types, ranges and cross-field consistency. Errors identify the
% offending field so a bad override is easy to locate.

% Signals
C = S.signals.catalog;
if ~istable(C) || ~all(ismember({'name', 'quantity', 'device', 'units'}, ...
        C.Properties.VariableNames))
    fail('signals.catalog', 'must be a table with variables name, quantity, device, units.');
end
if ~isstring(C.name) || any(C.name == "") || numel(unique(C.name)) ~= height(C)
    fail('signals.catalog', 'names must be unique, non-empty strings.');
end
if ~isstring(C.device) || ~all(ismember(C.device, ["HS", "LS", ""]))
    fail('signals.catalog', 'device must be "HS", "LS" or "".');
end
if ~isstring(C.units) || ~all(ismember(C.units, ["V", "A"]))
    fail('signals.catalog', 'units must be "V" or "A".');
end
for dev = ["HS", "LS"]
    if sum(C.quantity == "gateVoltage" & C.device == dev) ~= 1
        fail('signals.catalog', sprintf( ...
            'must define exactly one gateVoltage signal for device %s.', dev));
    end
end

% Gate
mustBeOption(S.gate.activeLevel, ["high", "low"], 'gate.activeLevel');
mustBeOption(S.gate.levels.source, ["measured", "nominal"], 'gate.levels.source');
mustBePositiveScalar(S.gate.levels.tolerance, 'gate.levels.tolerance');
mustBeOption(S.gate.levels.onMismatch, ["error", "warn"], 'gate.levels.onMismatch');

% Detection
lo = S.detection.hysteresis.lower;
hi = S.detection.hysteresis.upper;
mustBeFraction(lo, 'detection.hysteresis.lower');
mustBeFraction(hi, 'detection.hysteresis.upper');
if ~(lo > 0 && lo < hi && hi < 1)
    fail('detection.hysteresis', 'requires 0 < lower < upper < 1.');
end

R = S.detection.reference;
mustBeOption(R.strategy, ["percent", "midpoint", "absolute"], ...
    'detection.reference.strategy');
switch R.strategy
    case "percent"
        mustBeFraction(R.fraction, 'detection.reference.fraction');
        % Rising reference sits at FRACTION above low; falling reference
        % at FRACTION below high, i.e. at (1 - FRACTION) of the swing.
        % Both must lie strictly between the arms.
        if ~(R.fraction > lo && R.fraction < hi && ...
                (1 - R.fraction) > lo && (1 - R.fraction) < hi)
            fail('detection.reference.fraction', sprintf( ...
                ['must lie strictly inside the hysteresis band for both edge ' ...
                 'directions: %.3g < fraction < %.3g and %.3g < 1 - fraction < %.3g.'], ...
                lo, hi, lo, hi));
        end
    case "midpoint"
        if ~(lo < 0.5 && hi > 0.5)
            fail('detection.hysteresis', 'must bracket 0.5 for the midpoint strategy.');
        end
    case "absolute"
        % Whether the level lies inside the hysteresis band depends on
        % the measured gate levels, so that check happens at detection.
        mustBeRealScalar(R.absolute, 'detection.reference.absolute');
end
mustBeOption(R.crossingSelection, ["last", "first"], ...
    'detection.reference.crossingSelection');
mustBeLogicalScalar(S.detection.interpolateCrossing, 'detection.interpolateCrossing');
mustBeFraction(S.detection.timingSmoothing, 'detection.timingSmoothing');
if S.detection.timingSmoothing >= 0.5
    fail('detection.timingSmoothing', 'must be well below 0.5 of the edge duration.');
end
mustBePositiveInteger(S.detection.maxReferenceCrossings, 'detection.maxReferenceCrossings');
mustBeEmptyOrPositiveScalar(S.detection.minEdgeSpacing, 'detection.minEdgeSpacing');

% Conditioning
mustBeOption(S.conditioning.method, ["none", "movmean", "movmedian"], ...
    'conditioning.method');
if S.conditioning.method ~= "none"
    if isempty(S.conditioning.windowDuration)
        fail('conditioning.windowDuration', ...
            sprintf('is required when conditioning.method is "%s".', S.conditioning.method));
    end
end
mustBeEmptyOrPositiveScalar(S.conditioning.windowDuration, 'conditioning.windowDuration');

% Pulses
mustBeLogicalScalar(S.pulses.warnOnCountMismatch, 'pulses.warnOnCountMismatch');
mustBeOption(S.pulses.incompleteEdgePolicy, ["discard", "error"], ...
    'pulses.incompleteEdgePolicy');

% Alignment
mustBeOption(S.alignment.timeOrigin, "firstTurnOn", 'alignment.timeOrigin');
mustBeOption(S.alignment.offsetEstimator, ["median", "mean", "firstEdge"], ...
    'alignment.offsetEstimator');
mustBeEmptyOrPositiveScalar(S.alignment.maxResidual, 'alignment.maxResidual');

% Sampling
mustBePositiveScalar(S.sampling.sampleIntervalRelTol, 'sampling.sampleIntervalRelTol');
mustBePositiveScalar(S.sampling.timeVectorRelTol, 'sampling.timeVectorRelTol');

% Zero-offset correction
if ~isstring(S.zeroOffset.roles) || isempty(S.zeroOffset.roles)
    fail('zeroOffset.roles', 'must be a non-empty string array of signal roles.');
end
mustBeFraction(S.zeroOffset.maxFraction, 'zeroOffset.maxFraction');

% Bus voltage model
src = S.busVoltage.sources;
if ~isstring(src) || isempty(src) || numel(unique(src)) ~= numel(src) || ...
        ~all(ismember(src, ["busChannel", "kvl", "chargeDroop", "constant"]))
    fail('busVoltage.sources', ['must be a non-empty list without repeats of ' ...
        '"busChannel", "kvl", "chargeDroop", "constant".']);
end
mustBeFraction(S.busVoltage.nominalTolerance, 'busVoltage.nominalTolerance');
mustBeFraction(S.busVoltage.prePulseCurrentFraction, 'busVoltage.prePulseCurrentFraction');

% Corrections
mustBeOption(S.corrections.nonIntegerDeskew, ["round", "error"], ...
    'corrections.nonIntegerDeskew');
mustBePositiveScalar(S.corrections.integerShiftTol, 'corrections.integerShiftTol');
if S.corrections.integerShiftTol >= 0.5
    fail('corrections.integerShiftTol', 'must be well below 0.5 samples.');
end

% Windows
mustBeOption(S.windows.method, ["adaptive", "fixed"], 'windows.method');
mustBeNonnegativeScalar(S.windows.adaptive.pre,  'windows.adaptive.pre');
mustBeNonnegativeScalar(S.windows.adaptive.post, 'windows.adaptive.post');
mustBeLogicalScalar(S.windows.limitToNeighborMidpoint, 'windows.limitToNeighborMidpoint');
mustBeEmptyOrWindow(S.windows.fixed.turnOn,  'windows.fixed.turnOn');
mustBeEmptyOrWindow(S.windows.fixed.turnOff, 'windows.fixed.turnOff');
if S.windows.method == "fixed" && (isempty(S.windows.fixed.turnOn) || isempty(S.windows.fixed.turnOff))
    fail('windows.fixed', 'turnOn and turnOff are required when windows.method is "fixed".');
end
mustBeLogicalScalar(S.windows.useFixedAsFallback, 'windows.useFixedAsFallback');
mustBeOption(S.windows.onInsufficientCoverage, ["skip", "truncate"], ...
    'windows.onInsufficientCoverage');

% Measurements
M = S.measurements;
mustBePositiveScalar(M.common.noiseFloorMultiple, 'measurements.common.noiseFloorMultiple');
mustBeFraction(M.common.settlingBand, 'measurements.common.settlingBand');
mustBeFraction(M.common.settledPortion, 'measurements.common.settledPortion');
if M.common.settledPortion == 0
    fail('measurements.common.settledPortion', 'must be greater than 0.');
end
mustBePositiveScalar(M.common.averagingWindow, 'measurements.common.averagingWindow');
mustBePositiveScalar(M.common.instantHalfWidth, 'measurements.common.instantHalfWidth');
mustBePositiveScalar(M.common.extrapolationFit, 'measurements.common.extrapolationFit');
mustBePositiveScalar(M.common.resolutionSteps, 'measurements.common.resolutionSteps');
mustBeOption(M.common.gateBasis, ["swing", "zero"], 'measurements.common.gateBasis');
mustBePositiveScalar(M.normalization.maxResidualRatio, 'measurements.normalization.maxResidualRatio');
mustBePositiveScalar(M.normalization.maxGainSpread, 'measurements.normalization.maxGainSpread');
mustBeFraction(M.voltageNormalization.maxGainError, 'measurements.voltageNormalization.maxGainError');
if ~isstring(M.enableOptional)
    fail('measurements.enableOptional', 'must be a string array of measurement ids, or "all".');
end
% Method names are checked against the registry when measurements run.
for name = string(fieldnames(M.methods))'
    v = M.methods.(name);
    if ~isstring(v) || isempty(v) || any(v == "")
        fail("measurements.methods." + name, 'must be a non-empty string array of method ids.');
    end
end
mustBeEmptyOrNonnegativeScalar(M.params.onStateWindow.delay, 'measurements.params.onStateWindow.delay');
c = M.params.onStateWindow.custom;
if ~isempty(c) && ~(isnumeric(c) && isequal(size(c), [1 2]) && all(isfinite(c)) && c(1) < c(2) && c(2) <= 0)
    fail('measurements.params.onStateWindow.custom', 'must be [] or [t0 t1] with t0 < t1 <= 0 [s].');
end
d = M.params.RonEff.delays;
if ~isempty(d) && ~(isnumeric(d) && isvector(d) && all(isfinite(d)) && all(d >= 0))
    fail('measurements.params.RonEff.delays', 'must be [] or a vector of delays >= 0 [s].');
end
mustBeNonnegativeScalar(M.params.breakWindow.delay, 'measurements.params.breakWindow.delay');
mustBeOption(M.preset, ["auto", "IEC-8", "IEC-9", "none"], 'measurements.preset');
if ~(M.params.slew.band > 0 && M.params.slew.band <= 0.8)
    fail('measurements.params.slew.band', 'must lie in (0, 0.8].');
end
mustBePositiveScalar(M.params.slew.bandStep, 'measurements.params.slew.bandStep');
mustBePositiveInteger(M.params.derivative.order, 'measurements.params.derivative.order');
mustBePositiveScalar(M.params.derivative.windowBandFactor, 'measurements.params.derivative.windowBandFactor');
mustBePositiveInteger(M.params.derivative.minSamples, 'measurements.params.derivative.minSamples');
if M.params.derivative.minSamples <= M.params.derivative.order
    fail('measurements.params.derivative.minSamples', 'must exceed the derivative order.');
end
mustBeEmptyOrPositiveScalar(M.params.derivative.windowDuration, 'measurements.params.derivative.windowDuration');
mustBePositiveScalar(M.params.energy.fixedDuration, 'measurements.params.energy.fixedDuration');
mustBeNonnegativeScalar(M.params.Eio.settleDelay, 'measurements.params.Eio.settleDelay');
mustBePositiveScalar(M.params.stress.after90Window, 'measurements.params.stress.after90Window');
mustBePositiveScalar(M.common.tailNoiseRatio, 'measurements.common.tailNoiseRatio');
mustBeFraction(M.params.recovery.derivedMismatch, 'measurements.params.recovery.derivedMismatch');
mustBeFraction(M.params.recovery.smoothFraction, 'measurements.params.recovery.smoothFraction');
mustBeFraction(M.params.recovery.derivativeFraction, 'measurements.params.recovery.derivativeFraction');
L = M.params.recovery.didtLevels;
if ~(isnumeric(L) && numel(L) == 2 && all(L > 0 & L < 1))
    fail('measurements.params.recovery.didtLevels', 'must be two fractions in (0, 1).');
end
L = M.params.custom.trrLevels;
if ~isempty(L) && ~(isnumeric(L) && numel(L) == 2 && all(L > 0 & L < 1) && L(1) > L(2))
    fail('measurements.params.custom.trrLevels', 'must be [] or [a b] with 1 > a > b > 0.');
end
L = M.params.custom.recoveryEnd;
if ~isempty(L) && ~(isnumeric(L) && isscalar(L) && L > 0 && L < 1)
    fail('measurements.params.custom.recoveryEnd', 'must be [] or a fraction in (0, 1).');
end
mustBeEmptyOrPositiveScalar(M.params.custom.recoveryDuration, 'measurements.params.custom.recoveryDuration');
L = M.params.custom.QossEnd;
if ~isempty(L) && ~(isnumeric(L) && isscalar(L) && L > 0 && L < 1)
    fail('measurements.params.custom.QossEnd', 'must be [] or a fraction in (0, 1).');
end
mustBeOption(M.params.custom.QossBasis, ["peak", "Vdc"], 'measurements.params.custom.QossBasis');
L = M.params.custom.didtRR;
if ~isempty(L) && ~(isnumeric(L) && numel(L) == 2 && all(isfinite(L)) && L(1) ~= L(2))
    fail('measurements.params.custom.didtRR', 'must be [] or two different currents [A].');
end

% Reporting
mustBeLogicalScalar(S.report.echoWarnings, 'report.echoWarnings');
mustBeLogicalScalar(S.report.showSkippedMeasurements, 'report.showSkippedMeasurements');
mustBeOption(S.report.verbosity, ["quiet", "normal", "verbose"], 'report.verbosity');

end

% =====================================================================
% Validation helpers. Each raises dpt:settings:invalidValue naming the
% field, so the error message points at the setting to fix.

function fail(field, msg)
error('dpt:settings:invalidValue', 'Setting "%s" %s', field, msg);
end

function mustBeRealScalar(v, field)
if ~(isnumeric(v) && isscalar(v) && isreal(v) && isfinite(v))
    fail(field, 'must be a finite real scalar.');
end
end

function mustBePositiveScalar(v, field)
mustBeRealScalar(v, field);
if v <= 0
    fail(field, 'must be positive.');
end
end

function mustBeNonnegativeScalar(v, field)
mustBeRealScalar(v, field);
if v < 0
    fail(field, 'must be non-negative.');
end
end

function mustBeEmptyOrNonnegativeScalar(v, field)
if ~isempty(v)
    mustBeNonnegativeScalar(v, field);
end
end

function mustBePositiveInteger(v, field)
mustBePositiveScalar(v, field);
if v ~= round(v)
    fail(field, 'must be an integer.');
end
end

function mustBeEmptyOrPositiveScalar(v, field)
if ~isempty(v)
    mustBePositiveScalar(v, field);
end
end

function mustBeFraction(v, field)
mustBeRealScalar(v, field);
if v < 0 || v > 1
    fail(field, 'must lie in [0, 1].');
end
end

function mustBeLogicalScalar(v, field)
if ~(islogical(v) && isscalar(v))
    fail(field, 'must be a logical scalar (true or false).');
end
end

function mustBeOption(v, options, field)
if ~((isstring(v) && isscalar(v)) || (ischar(v) && isrow(v))) || ...
        ~any(string(v) == options)
    fail(field, sprintf('must be one of: "%s".', strjoin(options, '", "')));
end
end

function mustBeEmptyOrWindow(v, field)
if isempty(v)
    return
end
if ~(isnumeric(v) && isreal(v) && isequal(size(v), [1 2]) && all(isfinite(v)))
    fail(field, 'must be [] or a finite 1x2 vector [before, after] in seconds.');
end
if ~(v(1) <= 0 && v(2) >= 0 && v(2) > v(1))
    fail(field, 'must satisfy before <= 0 <= after with before < after.');
end
end
