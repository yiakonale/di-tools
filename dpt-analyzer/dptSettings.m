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

S.schemaVersion = "0.4.0";

%% Canonical signals --------------------------------------------------
% The semantic signal namespace used by channel maps and measurements.
%   name     : canonical name used in channelMap.m
%   quantity : physical role, so measurements can request e.g. "the
%              drainVoltage of the active device" without naming signals
%   device   : "HS" | "LS" | "" (not device-specific)
%   units    : required verticalUnits of the scope export
S.signals.catalog = table( ...
    ["Vgs-HS"; "Vgs-LS"; "Vds-HS"; "Vds-LS"; "Id-HS"; "Id-LS"; "Iout"], ...
    ["gateVoltage"; "gateVoltage"; "drainVoltage"; "drainVoltage"; ...
     "drainCurrent"; "drainCurrent"; "outputCurrent"], ...
    ["HS"; "LS"; "HS"; "LS"; "HS"; "LS"; ""], ...
    ["V"; "V"; "V"; "V"; "A"; "A"; "A"], ...
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

% Behaviour when a collection's edge sequence (count and order of
% turn-on/turn-off edges) differs from the reference collection's. The
% reference is a collection with the most common sequence.
%   "exclude"      : exclude the collection and report it.
%   "matchByTiming": match edges by their relative timing (each edge to
%                    the same-kind edge within half the smallest edge
%                    spacing). An ambiguous match, e.g. a strictly
%                    periodic train truncated differently, still
%                    excludes the collection: it is never guessed.
S.alignment.onSequenceMismatch = "exclude";

% Maximum allowed per-edge residual after alignment. Residuals are
% always reported. [] = report only, no pass/fail; the right limit
% depends on the timing precision the measurements need, which is not
% yet specified.
S.alignment.maxResidual = [];              % [s]

% Collections with different sample intervals can still be aligned
% (alignment is a time offset, not a resampling), and measurements are
% computed within one collection, so a mismatch is a warning by default.
%   "exclude": exclude the collection.  "warn": report and keep it.
S.alignment.onSampleIntervalMismatch = "warn";

%% Sampling validation ------------------------------------------------
% Numerical tolerances only; they absorb floating-point representation
% error, not physical timing differences.

% Relative tolerance when comparing sample intervals between channels.
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
% Measurement-specific algorithm settings. Populated in Batch 5 once the
% measurement list and definitions are specified.
S.measurements = struct();

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
    % Recurse only into nested setting groups. S.measurements is an
    % open group (empty until Batch 5), so it is replaced wholesale.
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
mustBeOption(S.alignment.onSequenceMismatch, ["exclude", "matchByTiming"], ...
    'alignment.onSequenceMismatch');
mustBeEmptyOrPositiveScalar(S.alignment.maxResidual, 'alignment.maxResidual');
mustBeOption(S.alignment.onSampleIntervalMismatch, ["exclude", "warn"], ...
    'alignment.onSampleIntervalMismatch');

% Sampling
mustBePositiveScalar(S.sampling.sampleIntervalRelTol, 'sampling.sampleIntervalRelTol');
mustBePositiveScalar(S.sampling.timeVectorRelTol, 'sampling.timeVectorRelTol');

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
if ~isstruct(S.measurements) || ~isscalar(S.measurements)
    fail('measurements', 'must be a scalar struct.');
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
