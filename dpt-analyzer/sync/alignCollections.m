function al = alignCollections(evs, S)
%ALIGNCOLLECTIONS Match gate edges across collections and align timebases.
%
%   al = alignCollections(evs, S) takes the 1-by-C gate-event structs from
%   detectGateTransitions and returns the alignment of DATA_CONTRACTS.md
%   section 6. Collections that cannot be aligned are excluded and listed
%   in al.excluded; all per-collection fields cover only the collections
%   that were aligned, in input order.
%
%     collections     1-by-C' names of the aligned collections
%     sourceIndex     1-by-C' indices into the input EVS
%     reference       index (into collections) of the reference
%     offset          1-by-C' [s]: t_u = t_corrected - offset(c)
%     edges           universal edges (E rows): direction, kind, time,
%                     where time is the median aligned time over the
%                     collections that contain the edge
%     match           E-by-C' row of each edge in evs(c).edges, or NaN
%     residual        E-by-C' aligned edge time minus edges.time [s]
%     sampleInterval  1-by-C' [s]
%     excluded        struct array: name, reason
%     issues          issue records
%
%   Reference: a collection whose edge sequence (order of turn-on and
%   turn-off edges) is the most common one, preferring more edges, then
%   input order. Its edges define the universal edge list, and t_u = 0 is
%   its first turn-on reference crossing.
%
%   Matching: collections with the reference's sequence are matched edge
%   by edge. Others follow S.alignment.onSequenceMismatch. Matching
%   assumes each collection captured the same pulse train; the scope
%   trigger time is used only as a sanity check, never for alignment.

arguments
    evs (1,:) struct
    S (1,1) struct
end

issues = dptIssue();
C = numel(evs);
names = [evs.collection];

%% Reference collection
keys = strings(1, C);
for c = 1:C
    % One character per edge, e.g. "NFNF..." (turn-oN / turn-oFf).
    keys(c) = strjoin(replace(evs(c).edges.kind, ["turnOn", "turnOff"], ["N", "F"]), "");
end
[uKeys, ~, group] = unique(keys, 'stable');
groupSize = accumarray(group(:), 1)';
groupEdges = strlength(uKeys);
order = sortrows([-groupSize(:), -groupEdges(:), (1:numel(uKeys))']);
refGroup = order(1, 3);
ref = find(group == refGroup, 1);
R = evs(ref).edges;
E = height(R);

firstOn = find(R.kind == "turnOn", 1);
if isempty(firstOn)
    error('dpt:alignment:noTurnOn', ...
        'Reference collection "%s" has no turn-on edge to define t = 0.', names(ref));
end

% Matching tolerance: half the smallest spacing between reference edges,
% so an edge can only ever match its own counterpart.
if E > 1
    tolMatch = min(diff(R.time)) / 2;
else
    tolMatch = Inf;
end

%% Match each collection to the reference
match = nan(E, C);
relOffset = nan(1, C);
keep = false(1, C);
excluded = struct('name', {}, 'reason', {});

for c = 1:C
    reason = "";
    dtRatio = abs(evs(c).sampleInterval - evs(ref).sampleInterval) / evs(ref).sampleInterval;
    if c ~= ref && dtRatio > S.sampling.sampleIntervalRelTol
        msg = sprintf('sample interval %.6g ns differs from reference "%s" (%.6g ns).', ...
            evs(c).sampleInterval * 1e9, names(ref), evs(ref).sampleInterval * 1e9);
        if S.alignment.onSampleIntervalMismatch == "exclude"
            reason = string(msg);
        else
            issues = [issues; dptIssue("dpt:alignment:sampleIntervalMismatch", "warning", ...
                "alignment", names(c), msg, S)]; %#ok<AGROW>
        end
    end

    if reason == ""
        if group(c) == refGroup
            match(:, c) = (1:E)';
        elseif S.alignment.onSequenceMismatch == "exclude"
            reason = sprintf(['edge sequence (%d edges) differs from reference "%s" ' ...
                '(%d edges); S.alignment.onSequenceMismatch = "exclude".'], ...
                height(evs(c).edges), names(ref), E);
        else
            [m, reason] = matchByTiming(R, evs(c).edges, tolMatch);
            if reason == ""
                match(:, c) = m;
                issues = [issues; dptIssue("dpt:alignment:timingMatch", "warning", ...
                    "alignment", names(c), sprintf(['edge sequence differs from reference ' ...
                    '"%s"; %d of %d reference edges matched by timing.'], ...
                    names(ref), nnz(~isnan(m)), E), S)]; %#ok<AGROW>
            end
        end
    end

    if reason ~= ""
        excluded(end+1) = struct('name', names(c), 'reason', string(reason)); %#ok<AGROW>
        issues = [issues; dptIssue("dpt:alignment:collectionExcluded", "warning", ...
            "alignment", names(c), "Excluded: " + reason, S)]; %#ok<AGROW>
        continue
    end

    has = ~isnan(match(:, c));
    d = evs(c).edges.time(match(has, c)) - R.time(has);
    switch S.alignment.offsetEstimator
        case "median",    relOffset(c) = median(d);
        case "mean",      relOffset(c) = mean(d);
        case "firstEdge", relOffset(c) = d(1);
    end
    keep(c) = true;

    % Sanity check against the scope trigger: collections of one bucket
    % are triggered on the same gate command, so their scope times should
    % agree to far better than an edge spacing.
    if c ~= ref && abs(relOffset(c)) > tolMatch
        issues = [issues; dptIssue("dpt:alignment:largeOffset", "warning", ...
            "alignment", names(c), sprintf(['edge-based offset to "%s" is %.4g us, more ' ...
            'than half the smallest edge spacing (%.4g us). The scope trigger times ' ...
            'disagree with the edge match: check that both collections captured ' ...
            'the same pulses.'], names(ref), relOffset(c) * 1e6, tolMatch * 1e6), S)]; %#ok<AGROW>
    end
end

%% Universal time
offset = relOffset + R.time(firstOn);
aligned = nan(E, C);
for c = find(keep)
    has = ~isnan(match(:, c));
    aligned(has, c) = evs(c).edges.time(match(has, c)) - offset(c);
end
edgeTime = median(aligned(:, keep), 2, 'omitnan');
residual = aligned - edgeTime;

for c = find(keep)
    worst = max(abs(residual(:, c)), [], 'omitnan');
    issues = [issues; dptIssue("dpt:alignment:summary", "info", "alignment", names(c), ...
        sprintf('offset %.6g us, max |residual| %.4g ns over %d edges.', ...
        offset(c) * 1e6, worst * 1e9, nnz(~isnan(match(:, c)))), S)]; %#ok<AGROW>
    if ~isempty(S.alignment.maxResidual) && worst > S.alignment.maxResidual
        issues = [issues; dptIssue("dpt:alignment:residualExceeded", "warning", ...
            "alignment", names(c), sprintf(['max |residual| %.4g ns exceeds ' ...
            'S.alignment.maxResidual (%.4g ns).'], worst * 1e9, ...
            S.alignment.maxResidual * 1e9), S)]; %#ok<AGROW>
    end
end

%% Output (aligned collections only)
idx = find(keep);
al.collections = names(idx);
al.sourceIndex = idx;
al.reference = find(idx == ref);
al.offset = offset(idx);
al.edges = table(R.direction, R.kind, edgeTime, ...
    'VariableNames', {'direction', 'kind', 'time'});
al.match = match(:, idx);
al.residual = residual(:, idx);
al.sampleInterval = [evs(idx).sampleInterval];
al.excluded = excluded;
al.issues = issues;

end

% =====================================================================
function [m, reason] = matchByTiming(R, Ec, tol)
% Match the edges of one collection to the reference by relative timing.
% Every same-kind pair proposes an offset; each offset is scored by how
% many reference edges then have a same-kind counterpart within TOL.
% The best score must be reached by exactly one distinct offset,
% otherwise the match is ambiguous and is refused.

m = nan(height(R), 1);
reason = "";
if height(R) < 2 || height(Ec) < 1
    reason = "too few edges to match by timing.";
    return
end

[iR, iC] = find(R.kind == Ec.kind');               % same-kind pairs
cand = Ec.time(iC) - R.time(iR);
score = zeros(size(cand));
for k = 1:numel(cand)
    score(k) = numel(pairEdges(R, Ec, cand(k), tol));
end

best = max(score);
top = sort(cand(score == best));
nDistinct = 1 + nnz(diff(top) > tol);
if best < 2
    reason = "fewer than two edges match by timing.";
elseif nDistinct > 1
    reason = sprintf(['ambiguous timing match: %d distinct offsets each match %d ' ...
        'edges (e.g. a periodic pulse train truncated differently).'], nDistinct, best);
else
    [jR, jC] = pairEdges(R, Ec, median(top), tol);
    m(jR) = jC;
end

end

function [jR, jC] = pairEdges(R, Ec, d, tol)
% Reference edges with a same-kind collection edge within TOL of offset D.
jR = [];
jC = [];
for j = 1:height(R)
    k = find(Ec.kind == R.kind(j) & abs(Ec.time - d - R.time(j)) <= tol, 1);
    if ~isempty(k)
        jR(end+1) = j; %#ok<AGROW>
        jC(end+1) = k; %#ok<AGROW>
    end
end
end
