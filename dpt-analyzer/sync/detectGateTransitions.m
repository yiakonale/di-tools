function ev = detectGateTransitions(col, cfg, S)
%DETECTGATETRANSITIONS Detect the active device's gate edges in a collection.
%
%   ev = detectGateTransitions(col, cfg, S) returns the gate-event struct
%   of DATA_CONTRACTS.md section 5, in the collection's corrected time.
%
%   Method
%     0. Read the active gate through getSignal (corrections applied) and
%        condition a COPY for detection (S.conditioning, zero-phase).
%     1. Levels: measured as the medians of the samples on either side of
%        the nominal midpoint, then validated against the nominal levels
%        (S.gate.levels). Thresholds derive from the measured levels.
%     2. Qualification: a hysteresis (Schmitt) trigger with arms at
%        S.detection.hysteresis.lower/upper of the measured swing. An edge
%        exists only when the gate travels from one arm to the other, so
%        noise, ringing and Miller-plateau recrossings cannot create edges.
%     3. Timing: the crossing of the reference level inside each qualified
%        edge (S.detection.reference), interpolated between samples, on a
%        local zero-phase moving mean of length S.detection.timingSmoothing
%        times the edge's duration.
%
%   Edges cut by the record boundary (the record starts or ends with the
%   gate between the arms) and edges violating S.detection.minEdgeSpacing
%   are listed in ev.discarded, never silently dropped.

arguments
    col (1,1) struct
    cfg (1,1) struct
    S (1,1) struct
end

catalog = S.signals.catalog;
gateSignal = catalog.name(catalog.quantity == "gateVoltage" & ...
    catalog.device == cfg.activeDevice);
issues = dptIssue();

g = getSignal(col, gateSignal, [], S);
t = g.t;
N = numel(t);
dt = col.sampleInterval;

%% 0. Detection-only conditioning (on a copy)
[xc, conditioning, issues] = conditionCopy(g.x, dt, col.name, S, issues);

%% 1. Levels
nominalHigh = cfg.gate.nominal.high;
nominalLow = cfg.gate.nominal.low;
if S.gate.levels.source == "measured"
    mid = (nominalHigh + nominalLow) / 2;
    lowSide = xc(xc < mid);
    highSide = xc(xc >= mid);
    if isempty(lowSide) || isempty(highSide)
        error('dpt:detection:levelNotFound', ...
            ['Collection "%s": %s never crosses the nominal midpoint (%.3g V), ' ...
             'so it cannot be the switching gate (range %.3g to %.3g V).'], ...
            col.name, gateSignal, mid, min(xc), max(xc));
    end
    low = median(lowSide);
    high = median(highSide);
else
    low = nominalLow;
    high = nominalHigh;
end

deviation = [abs(low - nominalLow), abs(high - nominalHigh)];
if any(deviation > S.gate.levels.tolerance)
    msg = sprintf(['%s levels %.3g / %.3g V differ from nominal %.3g / %.3g V ' ...
        'by more than %.3g V. Check the channel mapping, probe attenuation, ' ...
        'or cfg.gate.nominal.'], gateSignal, low, high, nominalLow, nominalHigh, ...
        S.gate.levels.tolerance);
    if S.gate.levels.onMismatch == "error"
        error('dpt:detection:levelMismatch', 'Collection "%s": %s', col.name, msg);
    end
    issues = [issues; dptIssue("dpt:detection:levelMismatch", "warning", ...
        "detection", col.name, msg, S)];
end

%% Thresholds
A = high - low;
armLow = low + S.detection.hysteresis.lower * A;
armHigh = low + S.detection.hysteresis.upper * A;
R = S.detection.reference;
switch R.strategy
    case "percent"
        refRising = low + R.fraction * A;
        refFalling = high - R.fraction * A;
    case "midpoint"
        refRising = low + 0.5 * A;
        refFalling = refRising;
    case "absolute"
        refRising = R.absolute;
        refFalling = R.absolute;
end
if ~(refRising > armLow && refRising < armHigh && refFalling > armLow && refFalling < armHigh)
    error('dpt:detection:invalidReference', ...
        ['Collection "%s": reference level(s) %.3g / %.3g V are not strictly ' ...
         'inside the hysteresis band (%.3g, %.3g) V of the measured levels.'], ...
        col.name, refRising, refFalling, armLow, armHigh);
end

%% 2. Qualification: hysteresis state machine (vectorized)
isLow = xc <= armLow;
isHigh = xc >= armHigh;
state = nan(N, 1);
state(isLow) = 0;
state(isHigh) = 1;
state = fillmissing(state, 'previous');            % leading NaN: not yet at an arm

change = find(diff(state) ~= 0 & ~isnan(state(1:end-1)) & ~isnan(state(2:end)));
endIndex = change + 1;                              % first sample at the far arm
rising = state(endIndex) == 1;

idx = (1:N)';
lastLow = cummax(isLow .* idx);                     % last sample at/below armLow so far
lastHigh = cummax(isHigh .* idx);
startIndex = zeros(size(endIndex));
startIndex(rising) = lastLow(endIndex(rising));
startIndex(~rising) = lastHigh(endIndex(~rising));

%% 3. Reference crossings
% Each edge is timed on a local, centred (zero-phase) moving mean whose
% length is S.detection.timingSmoothing times the edge's own duration D,
% so the smoothing scales with the edge instead of being a fixed time.
nEdges = numel(endIndex);
time = nan(nEdges, 1);
index = nan(nEdges, 1);
nCrossings = nan(nEdges, 1);
smoothingSamples = ones(nEdges, 1);
for k = 1:nEdges
    s = startIndex(k);
    e = endIndex(k);
    n = round(S.detection.timingSmoothing * (t(e) - t(s)) / dt);
    n = max(1, n + (mod(n, 2) == 0));               % odd: centred window
    smoothingSamples(k) = n;
    if n > 1
        h = (n - 1) / 2;
        a0 = max(1, s - h);
        b0 = min(N, e + h);
        y = movmean(xc(a0:b0), n);
        seg = y(s - a0 + 1 : e - a0 + 1);
    else
        seg = xc(s:e);
    end
    if rising(k)
        ref = refRising;
        forward = find(seg(1:end-1) < ref & seg(2:end) >= ref);
        backward = find(seg(1:end-1) >= ref & seg(2:end) < ref);
    else
        ref = refFalling;
        forward = find(seg(1:end-1) > ref & seg(2:end) <= ref);
        backward = find(seg(1:end-1) <= ref & seg(2:end) > ref);
    end
    nCrossings(k) = numel(forward) + numel(backward);
    if R.crossingSelection == "last"
        j = s + forward(end) - 1;
    else
        j = s + forward(1) - 1;
    end
    index(k) = j;
    if S.detection.interpolateCrossing
        x1 = seg(j - s + 1);
        x2 = seg(j - s + 2);
        time(k) = t(j) + (ref - x1) / (x2 - x1) * (t(j+1) - t(j));
    else
        time(k) = t(j+1);                           % first sample at/beyond ref
    end
end

direction = repmat("falling", nEdges, 1);
direction(rising) = "rising";
kind = edgeKind(direction, S);

edges = table(direction, kind, time, index, startIndex, endIndex, ...
    t(startIndex), t(endIndex), nCrossings, smoothingSamples, ...
    'VariableNames', {'direction', 'kind', 'time', 'index', 'startIndex', ...
    'endIndex', 'startTime', 'endTime', 'nCrossings', 'smoothingSamples'});
discarded = [edges(false(nEdges, 1), :), table(strings(0, 1), 'VariableNames', {'reason'})];

%% Boundary edges: record starts or ends with the gate between the arms
between = @(v) v > armLow && v < armHigh;
if between(xc(1))
    firstArm = find(~isnan(state), 1);
    if isempty(firstArm)
        error('dpt:detection:noEdges', ...
            'Collection "%s": %s never reaches either hysteresis arm.', col.name, gateSignal);
    end
    d = "falling";
    if state(firstArm) == 1, d = "rising"; end
    discarded = [discarded; boundaryRow(d, 1, firstArm, t, S, ...
        "record starts during the transition")];
end
if between(xc(end))
    lastArm = find(isLow | isHigh, 1, 'last');
    d = "rising";
    if state(end) == 1, d = "falling"; end
    discarded = [discarded; boundaryRow(d, lastArm, N, t, S, ...
        "record ends during the transition")];
end

%% Optional minimum edge spacing
if ~isempty(S.detection.minEdgeSpacing) && height(edges) > 1
    tooClose = find(diff(edges.time) < S.detection.minEdgeSpacing);
    if ~isempty(tooClose)
        % Drop both edges of each violating pair, which keeps the
        % rising/falling alternation intact.
        drop = false(height(edges), 1);
        drop([tooClose; tooClose + 1]) = true;
        reason = sprintf('closer than S.detection.minEdgeSpacing (%.4g ns) to a neighbour', ...
            S.detection.minEdgeSpacing * 1e9);
        discarded = [discarded; [edges(drop, :), ...
            table(repmat(string(reason), nnz(drop), 1), 'VariableNames', {'reason'})]];
        edges = edges(~drop, :);
        issues = [issues; dptIssue("dpt:detection:spacingViolation", "warning", ...
            "detection", col.name, sprintf('%d edge(s) discarded: %s.', nnz(drop), reason), S)];
    end
end

if height(discarded) > 0
    if S.pulses.incompleteEdgePolicy == "error" && any(startsWith(discarded.reason, "record"))
        error('dpt:detection:incompleteEdge', ...
            'Collection "%s": %s (S.pulses.incompleteEdgePolicy = "error").', ...
            col.name, strjoin(discarded.reason(startsWith(discarded.reason, "record")), "; "));
    end
    boundary = discarded(startsWith(discarded.reason, "record"), :);
    for k = 1:height(boundary)
        issues = [issues; dptIssue("dpt:detection:incompleteEdge", "info", "detection", ...
            col.name, sprintf('Incomplete %s edge discarded: %s.', ...
            boundary.direction(k), boundary.reason(k)), S)]; %#ok<AGROW>
    end
end

if height(edges) == 0
    error('dpt:detection:noEdges', 'Collection "%s": no complete gate edges detected on %s.', ...
        col.name, gateSignal);
end

noisy = find(edges.nCrossings > S.detection.maxReferenceCrossings);
if ~isempty(noisy)
    issues = [issues; dptIssue("dpt:detection:referenceRecrossing", "warning", ...
        "detection", col.name, sprintf(['%d edge(s) cross the reference level more ' ...
        'than %d times (max %d); edge timing may be ambiguous. Edges: %s.'], ...
        numel(noisy), S.detection.maxReferenceCrossings, max(edges.nCrossings(noisy)), ...
        strjoin(string(noisy'), ", ")), S)];
end

%% Output
ev.collection = col.name;
ev.signal = gateSignal;
ev.sampleInterval = dt;
ev.recordLength = N;
ev.recordSpan = [t(1), t(end)];                     % corrected gate time [s]
ev.levels = struct('low', low, 'high', high, 'nominalLow', nominalLow, ...
    'nominalHigh', nominalHigh, 'source', S.gate.levels.source);
ev.thresholds = struct('armLow', armLow, 'armHigh', armHigh, ...
    'refRising', refRising, 'refFalling', refFalling);
ev.conditioning = conditioning;
ev.edges = edges;
ev.discarded = discarded;
ev.issues = issues;

end

% =====================================================================
function [xc, info, issues] = conditionCopy(x, dt, name, S, issues)
% Zero-phase conditioning of a copy of the gate waveform.

method = S.conditioning.method;
info = struct('method', method, 'windowDuration', S.conditioning.windowDuration, ...
    'windowSamples', 1);
if method == "none"
    xc = x;
    return
end

n = round(S.conditioning.windowDuration / dt);
if mod(n, 2) == 0
    n = n + 1;      % odd length keeps the window centred (zero phase)
end
n = max(n, 1);
info.windowSamples = n;
if n == 1
    issues = [issues; dptIssue("dpt:detection:conditioningIneffective", "warning", ...
        "detection", name, sprintf(['S.conditioning.windowDuration (%.4g ns) is ' ...
        'shorter than one sample; no conditioning applied.'], ...
        S.conditioning.windowDuration * 1e9), S)];
    xc = x;
    return
end

switch method
    case "movmean"
        xc = movmean(x, n);
    case "movmedian"
        xc = movmedian(x, n);
end

end

% =====================================================================
function kind = edgeKind(direction, S)
% Rising gate edges turn the device on when it conducts on a high gate.
isOn = direction == "rising";
if S.gate.activeLevel == "low"
    isOn = ~isOn;
end
kind = repmat("turnOff", size(direction));
kind(isOn) = "turnOn";
end

% =====================================================================
function row = boundaryRow(direction, startIndex, endIndex, t, S, reason)
row = table(direction, edgeKind(direction, S), NaN, NaN, startIndex, endIndex, ...
    t(startIndex), t(endIndex), NaN, NaN, reason, ...
    'VariableNames', {'direction', 'kind', 'time', 'index', 'startIndex', ...
    'endIndex', 'startTime', 'endTime', 'nCrossings', 'smoothingSamples', 'reason'});
end
