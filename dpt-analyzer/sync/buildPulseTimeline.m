function tl = buildPulseTimeline(evs, al, cfg, S)
%BUILDPULSETIMELINE Build the universal pulse timeline and measurement windows.
%
%   tl = buildPulseTimeline(evs, al, cfg, S) returns the timeline of
%   DATA_CONTRACTS.md section 7. EVS are the gate-event structs of the
%   ALIGNED collections, in al.collections order (evs(al.sourceIndex)).
%
%     origin              definition of t_u = 0
%     edges               edgeId, direction, kind, pulseIndex, time [s]
%     pulses              pulseIndex, turnOnEdge, turnOffEdge, onTime [s]
%     windows             one row per (edge, collection), see below
%     expectedPulseCount  from cfg (advisory)
%     detectedPulseCount  number of pulses (turn-on edges)
%     issues
%
%   A pulse is a turn-on edge together with the turn-off that follows it.
%   A turn-off before the first turn-on has pulseIndex NaN.
%
%   Windows (universal time). For collection c the corrected-time range
%   to pass to getSignal is [startTime endTime] + al.offset(c).
%     core      the collection's qualified gate edge [coreStart coreEnd]
%     adaptive  [coreStart - pre*D, coreEnd + post*D], D = core duration
%     fixed     edge time + S.windows.fixed.<kind>
%     territory [midpoint to previous edge, midpoint to next edge],
%               clipped to the collection's record. Used for settled
%               levels, ringing decay, peaks and fixed-duration windows
%               (MEASUREMENT_DESIGN.md section 2.4).
%   Both are limited to the midpoints between neighbouring edges when
%   S.windows.limitToNeighborMidpoint is set (column "limited"). A window
%   outside the record uses the fixed fallback if allowed and it fits,
%   otherwise S.windows.onInsufficientCoverage applies.

arguments
    evs (1,:) struct
    al (1,1) struct
    cfg (1,1) struct
    S (1,1) struct
end

if numel(evs) ~= numel(al.collections) || ~isequal([evs.collection], al.collections)
    error('dptTimeline:inputMismatch', ...
        'EVS must be the aligned collections in al.collections order.');
end

issues = dptIssue();
E = height(al.edges);
C = numel(al.collections);
kind = al.edges.kind;
edgeTime = al.edges.time;

%% Pulses
onEdges = find(kind == "turnOn");
P = numel(onEdges);
turnOffEdge = nan(P, 1);
for p = 1:P
    j = onEdges(p) + 1;
    if j <= E && kind(j) == "turnOff"
        turnOffEdge(p) = j;
    end
end
onTime = nan(P, 1);
hasOff = ~isnan(turnOffEdge);
onTime(hasOff) = edgeTime(turnOffEdge(hasOff)) - edgeTime(onEdges(hasOff));
pulses = table((1:P)', onEdges, turnOffEdge, onTime, ...
    'VariableNames', {'pulseIndex', 'turnOnEdge', 'turnOffEdge', 'onTime'});

pulseIndex = nan(E, 1);
pulseIndex(onEdges) = 1:P;
pulseIndex(turnOffEdge(hasOff)) = find(hasOff);
edges = table((1:E)', al.edges.direction, kind, pulseIndex, edgeTime, ...
    'VariableNames', {'edgeId', 'direction', 'kind', 'pulseIndex', 'time'});

if ~isempty(cfg.expectedPulseCount) && P ~= cfg.expectedPulseCount && S.pulses.warnOnCountMismatch
    issues = [issues; dptIssue("dpt:timeline:pulseCountMismatch", "warning", "timeline", "", ...
        sprintf('Detected %d pulse(s), expected %d. Analysis uses the %d detected.', ...
        P, cfg.expectedPulseCount, P), S)];
end

%% Territory of each edge: midpoints to its neighbours
territory = [-inf(E, 1), inf(E, 1)];
if E > 1
    mids = (edgeTime(1:end-1) + edgeTime(2:end)) / 2;
    territory(2:end, 1) = mids;
    territory(1:end-1, 2) = mids;
end
% Windows are limited to the territory only if requested.
if S.windows.limitToNeighborMidpoint
    limit = territory;
else
    limit = [-inf(E, 1), inf(E, 1)];
end

%% Windows
n = E * C;
wEdge = zeros(n, 1);
wCol = zeros(n, 1);
wStart = nan(n, 1);
wEnd = nan(n, 1);
cStart = nan(n, 1);
cEnd = nan(n, 1);
terrStart = nan(n, 1);
terrEnd = nan(n, 1);
wMethod = strings(n, 1);
wLimited = false(n, 1);
wTruncated = false(n, 1);
wValid = false(n, 1);
wNote = strings(n, 1);

r = 0;
for c = 1:C
    span = evs(c).recordSpan - al.offset(c);
    for j = 1:E
        r = r + 1;
        wEdge(r) = j;
        wCol(r) = c;
        terrStart(r) = max(territory(j, 1), span(1));
        terrEnd(r) = min(territory(j, 2), span(2));
        m = al.match(j, c);
        if isnan(m)
            wNote(r) = "edge not present in this collection";
            continue
        end
        e = evs(c).edges(m, :);
        tEdge = e.time - al.offset(c);
        core = [e.startTime, e.endTime] - al.offset(c);
        cStart(r) = core(1);
        cEnd(r) = core(2);

        if S.windows.method == "adaptive"
            D = core(2) - core(1);
            w = [core(1) - S.windows.adaptive.pre * D, core(2) + S.windows.adaptive.post * D];
            method = "adaptive";
        else
            w = tEdge + S.windows.fixed.(kind(j));
            method = "fixed";
        end
        [w, limited] = limitTo(w, limit(j, :));
        note = "";

        if ~fits(w, span) && method == "adaptive" && S.windows.useFixedAsFallback ...
                && ~isempty(S.windows.fixed.(kind(j)))
            [wf, limitedF] = limitTo(tEdge + S.windows.fixed.(kind(j)), limit(j, :));
            if fits(wf, span)
                w = wf;
                limited = limitedF;
                method = "fallback";
                note = "adaptive window exceeds the record; fixed fallback used";
            end
        end

        valid = true;
        if ~fits(w, span)
            if S.windows.onInsufficientCoverage == "truncate"
                w = [max(w(1), span(1)), min(w(2), span(2))];
                wTruncated(r) = true;
                note = strjoin([note, "truncated at the record boundary"], "; ");
            else
                valid = false;
                note = strjoin([note, "window exceeds the record (coverage policy: skip)"], "; ");
            end
        end

        wStart(r) = w(1);
        wEnd(r) = w(2);
        wMethod(r) = method;
        wLimited(r) = limited;
        wValid(r) = valid;
        wNote(r) = strip(strip(note, "left", ";"));
    end
end

windows = table(wEdge, wCol, wStart, wEnd, cStart, cEnd, terrStart, terrEnd, ...
    wMethod, wLimited, wTruncated, wValid, wNote, 'VariableNames', {'edgeId', ...
    'collection', 'startTime', 'endTime', 'coreStartTime', 'coreEndTime', ...
    'territoryStartTime', 'territoryEndTime', 'method', 'limited', ...
    'truncated', 'valid', 'note'});

for c = 1:C
    rows = windows.collection == c;
    nFallback = nnz(rows & windows.method == "fallback");
    nTrunc = nnz(rows & windows.truncated);
    nInvalid = nnz(rows & ~windows.valid);
    if nFallback > 0
        issues = [issues; dptIssue("dpt:timeline:fallbackWindow", "info", "timeline", ...
            al.collections(c), sprintf('%d window(s) use the fixed fallback.', nFallback), S)]; %#ok<AGROW>
    end
    if nTrunc > 0
        issues = [issues; dptIssue("dpt:timeline:truncatedWindow", "warning", "timeline", ...
            al.collections(c), sprintf('%d window(s) truncated at the record boundary.', ...
            nTrunc), S)]; %#ok<AGROW>
    end
    if nInvalid > 0
        issues = [issues; dptIssue("dpt:timeline:unusableWindow", "warning", "timeline", ...
            al.collections(c), sprintf(['%d window(s) unusable (edge missing or ' ...
            'outside the record); dependent measurements will be skipped.'], nInvalid), S)]; %#ok<AGROW>
    end
end

%% Output
tl.origin = sprintf(['t = 0 at the first turn-on reference crossing of ' ...
    'collection "%s" (%s)'], al.collections(al.reference), evs(al.reference).signal);
tl.edges = edges;
tl.pulses = pulses;
tl.windows = windows;
tl.expectedPulseCount = cfg.expectedPulseCount;
tl.detectedPulseCount = P;
tl.issues = issues;

end

% =====================================================================
function [w, limited] = limitTo(w, territory)
limited = w(1) < territory(1) || w(2) > territory(2);
w = [max(w(1), territory(1)), min(w(2), territory(2))];
end

function tf = fits(w, span)
tf = w(1) >= span(1) && w(2) <= span(2);
end
