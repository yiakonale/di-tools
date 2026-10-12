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
%       ov.gate.nominal.high = 15;
%       S = dptSettings(ov);
%
%   Always construct settings through this function; do not edit fields
%   of a returned struct, because edits made afterwards bypass validation.
%
%   Scope
%     This file holds analyzer-wide behaviour only. Bucket configuration
%     (bucket path, active device, expected pulse count) lives in
%     dpt_analyzer.m; channel assignments live in each collection's
%     channelMap.m.
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

S.schemaVersion = "0.1.0";

%% Gate drive ---------------------------------------------------------
% Nominal drive levels of the ACTIVE device's gate. Used to validate the
% gate channel and to sanity-check the levels measured from the
% waveform. Detection thresholds are computed from MEASURED levels, not
% from these values, so probe offset or driver droop does not bias
% timing.
S.gate.nominal.high = 18;      % [V]  on-state gate drive
S.gate.nominal.low  = -5;      % [V]  off-state gate drive

% Gate polarity. "high" means the device conducts when Vgs is high
% (n-channel MOSFET, IGBT, GaN HEMT), so a rising gate edge is a
% turn-on and a falling gate edge is a turn-off.
S.gate.activeLevel = "high";   % "high" | "low"

% How the actual off/on levels are obtained.
%   "measured": estimated from the gate waveform itself (median of the
%               samples on each side of the nominal midpoint). Requires
%               no time constants; valid when the record spends most of
%               its time at the two drive levels, as a DPT record does.
%   "nominal" : use S.gate.nominal directly (diagnostic use only).
S.gate.levels.source = "measured";

% Maximum allowed |measured - nominal| for each level. Exceeding it
% means the channel is probably not the active gate (wrong mapping,
% passive device's gate, wrong probe attenuation), or the nominal
% levels above are wrong for this setup.
S.gate.levels.tolerance = 1.5;             % [V]
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
%                100x the measured gate noise on the test record).
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

% Behaviour when collections do not contain the same edge sequence
% (different edge counts or direction order). Matching then cannot be
% established unambiguously.
S.alignment.onSequenceMismatch = "error";  % "error" | "warn"

% Maximum allowed per-edge residual after alignment. Residuals are
% always reported. [] = report only, no pass/fail; the right limit
% depends on the timing precision the measurements need, which is not
% yet specified.
S.alignment.maxResidual = [];              % [s]

% Collections with different sample intervals can still be aligned
% (alignment is a time offset, not a resampling), and measurements are
% computed within one collection, so a mismatch is a warning by default.
S.alignment.onSampleIntervalMismatch = "warn";   % "error" | "warn"

%% Sampling validation ------------------------------------------------
% Numerical tolerances only; they absorb floating-point representation
% error, not physical timing differences.

% Relative tolerance when comparing sample intervals between channels.
S.sampling.sampleIntervalRelTol = 1e-9;

% Relative tolerance on diff(time) versus sampleInterval when checking
% that a time vector is uniform (test record: 1e-10).
S.sampling.timeVectorRelTol = 1e-6;

%% Measurement windows ------------------------------------------------
% Windows are anchored to detected gate edges. The construction
% algorithm is decided in Batch 4; these fields fix the interface.

% Primary construction method. Only the option name is reserved here;
% its parameters are added when the algorithm is specified.
S.windows.method = "adaptive";

% Hard limit: a window never extends past the midpoint between its edge
% and the neighbouring edges, so windows of adjacent transitions never
% overlap. Derived from the data; needs no constant.
S.windows.limitToNeighborMidpoint = true;

% Fixed fallback windows relative to the edge reference time,
% [before, after] in seconds (e.g. [-200e-9, 800e-9]). [] = no fallback:
% if the primary method fails, the dependent measurements are skipped
% with a reason. Values depend on the measurement specification.
S.windows.fallback.turnOn  = [];           % [s] 1x2, before <= 0 <= after
S.windows.fallback.turnOff = [];           % [s] 1x2

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

% Gate
mustBeRealScalar(S.gate.nominal.high, 'gate.nominal.high');
mustBeRealScalar(S.gate.nominal.low,  'gate.nominal.low');
if S.gate.nominal.high <= S.gate.nominal.low
    fail('gate.nominal', 'high must be greater than low.');
end
mustBeOption(S.gate.activeLevel, ["high", "low"], 'gate.activeLevel');
mustBeOption(S.gate.levels.source, ["measured", "nominal"], 'gate.levels.source');
mustBePositiveScalar(S.gate.levels.tolerance, 'gate.levels.tolerance');
if S.gate.levels.tolerance >= (S.gate.nominal.high - S.gate.nominal.low) / 2
    fail('gate.levels.tolerance', ...
        'must be smaller than half the nominal swing, or the two levels cannot be distinguished.');
end
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
        mustBeRealScalar(R.absolute, 'detection.reference.absolute');
        % Checked against MEASURED levels at detection time; here only
        % against the nominal arms as an early sanity check.
        swing = S.gate.nominal.high - S.gate.nominal.low;
        armLo = S.gate.nominal.low + lo * swing;
        armHi = S.gate.nominal.low + hi * swing;
        if ~(R.absolute > armLo && R.absolute < armHi)
            fail('detection.reference.absolute', sprintf( ...
                'must lie inside the nominal hysteresis band (%.3g V, %.3g V).', ...
                armLo, armHi));
        end
end
mustBeOption(R.crossingSelection, ["last", "first"], ...
    'detection.reference.crossingSelection');
mustBeLogicalScalar(S.detection.interpolateCrossing, 'detection.interpolateCrossing');
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
mustBeOption(S.alignment.onSequenceMismatch, ["error", "warn"], ...
    'alignment.onSequenceMismatch');
mustBeEmptyOrPositiveScalar(S.alignment.maxResidual, 'alignment.maxResidual');
mustBeOption(S.alignment.onSampleIntervalMismatch, ["error", "warn"], ...
    'alignment.onSampleIntervalMismatch');

% Sampling
mustBePositiveScalar(S.sampling.sampleIntervalRelTol, 'sampling.sampleIntervalRelTol');
mustBePositiveScalar(S.sampling.timeVectorRelTol, 'sampling.timeVectorRelTol');

% Windows
mustBeOption(S.windows.method, "adaptive", 'windows.method');
mustBeLogicalScalar(S.windows.limitToNeighborMidpoint, 'windows.limitToNeighborMidpoint');
mustBeEmptyOrWindow(S.windows.fallback.turnOn,  'windows.fallback.turnOn');
mustBeEmptyOrWindow(S.windows.fallback.turnOff, 'windows.fallback.turnOff');
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
