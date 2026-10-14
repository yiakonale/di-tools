function result = runPipeline(cfg, S)
%RUNPIPELINE Run the analysis pipeline on one bucket.
%
%   result = runPipeline(cfg, S) runs workflow steps 3-6 on the bucket
%   described by CFG (validated by validateBucketConfig) with settings S:
%
%     3. discover the bucket's collections
%     4. import and validate each collection
%     5. detect the active gate's transitions in each collection
%     6. align the collections and build the pulse timeline, then per
%        collection: zero-offset correction (opt-in), current-sensor
%        normalization (opt-in) and the bus-voltage model V_DC(t)
%
%   A collection that fails steps 4-6 is excluded and reported; the
%   others continue. The run aborts only if no collection remains.
%
%   Output struct
%     cfg, S        the configuration used
%     collections   1-by-C aligned collections (al.collections order)
%     evs           1-by-C gate events, same order
%     al, tl        alignment and timeline
%     excluded      struct array: name, reason
%     issues        all issue records, in pipeline order
%
%   The entry script dpt_analyzer.m only configures, calls this, and
%   prints the summary, so tests can run the whole pipeline as a function.

arguments
    cfg (1,1) struct
    S (1,1) struct
end

%% 3-4. Discover and import collections
[found, issues] = discoverCollections(cfg.bucketPath, S);

collections = {};
excluded = struct('name', {}, 'reason', {});
for k = 1:numel(found)
    try
        col = importCollection(found(k).path, cfg, S);
    catch ME
        if ~startsWith(ME.identifier, "dpt:")
            rethrow(ME);   % a programming error, not a data problem
        end
        excluded(end+1) = struct('name', found(k).name, 'reason', string(ME.message)); %#ok<AGROW>
        issues = [issues; dptIssue("dpt:import:collectionExcluded", "warning", ...
            "import", found(k).name, ME.message, S)]; %#ok<AGROW>
        continue
    end
    collections{end+1} = col; %#ok<AGROW>
    issues = [issues; col.issues]; %#ok<AGROW>
end
if isempty(collections)
    error('dpt:import:noValidCollections', ...
        'No valid collections in bucket %s. See the warnings above.', cfg.bucketPath);
end
collections = [collections{:}];

%% 5. Gate-transition detection
evs = {};
detected = false(1, numel(collections));
for k = 1:numel(collections)
    try
        ev = detectGateTransitions(collections(k), cfg, S);
    catch ME
        if ~startsWith(ME.identifier, "dpt:")
            rethrow(ME);
        end
        excluded(end+1) = struct('name', collections(k).name, 'reason', string(ME.message)); %#ok<AGROW>
        issues = [issues; dptIssue("dpt:detection:collectionExcluded", "warning", ...
            "detection", collections(k).name, ME.message, S)]; %#ok<AGROW>
        continue
    end
    evs{end+1} = ev; %#ok<AGROW>
    detected(k) = true;
    issues = [issues; ev.issues]; %#ok<AGROW>
end
if isempty(evs)
    error('dpt:detection:noValidCollections', ...
        'Gate detection failed in every collection. See the warnings above.');
end
collections = collections(detected);
evs = [evs{:}];

%% 6. Alignment and pulse timeline
al = alignCollections(evs, S);
issues = [issues; al.issues];
excluded = [excluded, al.excluded];
collections = collections(al.sourceIndex);
evs = evs(al.sourceIndex);

tl = buildPulseTimeline(evs, al, cfg, S);
issues = [issues; tl.issues];

%% 6a. Zero-offset correction (opt-in: cfg.zeroOffsetCorrection)
for k = 1:numel(collections)
    [collections(k), iss] = zeroOffsetCorrection(collections(k), k, al, tl, cfg, S);
    issues = [issues; iss]; %#ok<AGROW>
end

%% 6b. Current-sensor normalization (opt-in: cfg.currentNormalization)
for k = 1:numel(collections)
    [collections(k), iss] = normalizeCurrentSensors(collections(k), k, al, tl, cfg, S);
    issues = [issues; iss]; %#ok<AGROW>
end

%% 6c. Bus-voltage model V_DC(t)
for k = 1:numel(collections)
    [collections(k), iss] = busVoltageModel(collections(k), k, al, tl, cfg, S);
    issues = [issues; iss]; %#ok<AGROW>
end

result.cfg = cfg;
result.S = S;
result.collections = collections;
result.evs = evs;
result.al = al;
result.tl = tl;
result.excluded = excluded;
result.issues = issues;

end
