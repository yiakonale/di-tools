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
%                     where time is the median aligned time over all
%                     aligned collections
%     match           E-by-C' row of each edge in evs(c).edges
%     residual        E-by-C' aligned edge time minus edges.time [s]
%     sampleInterval  1-by-C' [s]
%     excluded        struct array: name, reason
%     issues          issue records
%
%   Acquisition model
%     All collections of a bucket use the same scope setup (horizontal
%     scale, record length) and capture the same complete pulse train of
%     the active gate; only the channels other than that gate differ, and
%     the trigger point varies slightly between acquisitions. The active
%     gate waveforms are therefore treated as identical, and each
%     collection is aligned by ONE constant time offset that absorbs the
%     trigger variation. The per-edge residuals measure how far the gate
%     waveforms actually are from identical.
%
%   Consequently a collection is excluded if its sample interval, record
%   length or edge sequence (order of turn-on/turn-off edges) differs from
%   the reference: under this model such a difference is a setup or data
%   problem, never something to work around.
%
%   Reference: a collection with the most common edge sequence (input
%   order breaks ties), so a single deviating collection is the one
%   excluded. t_u = 0 is the reference's first turn-on reference crossing.
%   The scope trigger time is used only as a sanity check.

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
[~, ~, group] = unique(keys, 'stable');
groupSize = accumarray(group(:), 1);
[~, refGroup] = max(groupSize);                      % first group wins ties
ref = find(group == refGroup, 1);
R = evs(ref).edges;
E = height(R);

firstOn = find(R.kind == "turnOn", 1);
if isempty(firstOn)
    error('dpt:alignment:noTurnOn', ...
        'Reference collection "%s" has no turn-on edge to define t = 0.', names(ref));
end
Dref = R.endTime - R.startTime;

%% Validate each collection against the reference
keep = false(1, C);
relOffset = nan(1, C);
excluded = struct('name', {}, 'reason', {});

for c = 1:C
    reason = "";
    if c ~= ref
        if abs(evs(c).sampleInterval - evs(ref).sampleInterval) > ...
                S.sampling.sampleIntervalRelTol * evs(ref).sampleInterval
            reason = sprintf(['sample interval %.6g ns differs from reference "%s" ' ...
                '(%.6g ns); all collections of a bucket must share the horizontal setup.'], ...
                evs(c).sampleInterval * 1e9, names(ref), evs(ref).sampleInterval * 1e9);
        elseif evs(c).recordLength ~= evs(ref).recordLength
            reason = sprintf(['record length %d differs from reference "%s" (%d); all ' ...
                'collections of a bucket must share the horizontal setup.'], ...
                evs(c).recordLength, names(ref), evs(ref).recordLength);
        elseif group(c) ~= refGroup
            reason = sprintf(['gate edge sequence (%d edges: %s) differs from reference ' ...
                '"%s" (%d edges: %s): a pulse is missing or extra, or the collection is ' ...
                'from a different test.'], height(evs(c).edges), keys(c), names(ref), ...
                E, keys(ref));
        end
    end
    if reason ~= ""
        excluded(end+1) = struct('name', names(c), 'reason', string(reason)); %#ok<AGROW>
        issues = [issues; dptIssue("dpt:alignment:collectionExcluded", "warning", ...
            "alignment", names(c), "Excluded: " + reason, S)]; %#ok<AGROW>
        continue
    end

    d = evs(c).edges.time - R.time;
    switch S.alignment.offsetEstimator
        case "median",    relOffset(c) = median(d);
        case "mean",      relOffset(c) = mean(d);
        case "firstEdge", relOffset(c) = d(1);
    end
    keep(c) = true;
end

%% Universal time
offset = relOffset + R.time(firstOn);
aligned = nan(E, C);
for c = find(keep)
    aligned(:, c) = evs(c).edges.time - offset(c);
end
edgeTime = median(aligned(:, keep), 2);
residual = aligned - edgeTime;

%% Diagnostics: is the "identical active gate" assumption met?
if E > 1
    halfSpacing = min(diff(R.time)) / 2;
else
    halfSpacing = Inf;
end
for c = find(keep)
    worst = max(abs(residual(:, c)));
    Dc = evs(c).edges.endTime - evs(c).edges.startTime;
    issues = [issues; dptIssue("dpt:alignment:summary", "info", "alignment", names(c), ...
        sprintf(['offset %.6g us, max |residual| %.4g ns over %d edges, edge ' ...
        'duration within %.3g %% of reference.'], offset(c) * 1e6, worst * 1e9, E, ...
        100 * max(abs(Dc ./ Dref - 1))), S)]; %#ok<AGROW>

    if ~isempty(S.alignment.maxResidual) && worst > S.alignment.maxResidual
        issues = [issues; dptIssue("dpt:alignment:residualExceeded", "warning", ...
            "alignment", names(c), sprintf(['max |residual| %.4g ns exceeds ' ...
            'S.alignment.maxResidual (%.4g ns).'], worst * 1e9, ...
            S.alignment.maxResidual * 1e9), S)]; %#ok<AGROW>
    end

    if c == ref
        continue
    end
    levelDiff = max(abs([evs(c).levels.low - evs(ref).levels.low, ...
        evs(c).levels.high - evs(ref).levels.high]));
    if levelDiff > S.gate.levels.tolerance
        issues = [issues; dptIssue("dpt:alignment:gateLevelsDiffer", "warning", ...
            "alignment", names(c), sprintf(['measured gate levels %.3g / %.3g V differ ' ...
            'from reference "%s" (%.3g / %.3g V) by %.3g V, more than ' ...
            'S.gate.levels.tolerance. The active-gate waveforms are expected to be ' ...
            'identical across a bucket.'], evs(c).levels.low, evs(c).levels.high, ...
            names(ref), evs(ref).levels.low, evs(ref).levels.high, levelDiff), S)]; %#ok<AGROW>
    end

    % Trigger variation should be far smaller than an edge spacing.
    if abs(relOffset(c)) > halfSpacing
        issues = [issues; dptIssue("dpt:alignment:largeOffset", "warning", ...
            "alignment", names(c), sprintf(['offset to "%s" is %.4g us, more than half ' ...
            'the smallest edge spacing (%.4g us); this is not plausible trigger ' ...
            'variation. Check the trigger setup.'], names(ref), relOffset(c) * 1e6, ...
            halfSpacing * 1e6), S)]; %#ok<AGROW>
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
al.match = repmat((1:E)', 1, numel(idx));
al.residual = residual(:, idx);
al.sampleInterval = [evs(idx).sampleInterval];
al.excluded = excluded;
al.issues = issues;

end
