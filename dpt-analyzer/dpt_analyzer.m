%DPT_ANALYZER Double Pulse Test waveform analyzer - entry point.
%
%   Edit the bucket configuration below, then run this script. Paths are
%   resolved from this file's location, not from the current folder.
%
%   Workflow (implemented so far: steps 1-6)
%     1. Load settings (dptSettings)
%     2. Validate the bucket configuration
%     3. Discover the bucket's collections
%     4. Import and validate each collection
%     5. Detect the active gate's transitions in each collection
%     6. Align collections on matched edges; build the pulse timeline and
%        measurement windows; normalize current sensors (opt-in)
%     7. Run eligible measurements                (Batches 5-6)
%     8. Report results                           (Batch 6)
%
%   A collection that fails steps 4-6 is excluded and reported; the
%   remaining collections continue.

clear; clc; close all;

%% Bucket configuration ------------------------------------------------
cfg.bucketPath         = "data/example";   % relative to this script, or absolute
cfg.activeDevice       = "LS";             % "HS" | "LS"
cfg.deviceType         = "MOSFET";         % "MOSFET" | "IGBT"
cfg.expectedPulseCount = 10;               % advisory only; [] = no check
cfg.gate.nominal.high  = 18;               % [V] active gate on-state drive
cfg.gate.nominal.low   = -5;               % [V] active gate off-state drive

% Optional: nominal operating point, used only by "nominal" methods.
% cfg.nominal.busVoltage  = 400;            % [V]
% cfg.nominal.testCurrent = 500;            % [A]

% Optional: calibrate the I_D and Iout sensors against each other on the
% on-state of every pulse, taking one of them as the truth.
cfg.currentNormalization.enable    = false;
cfg.currentNormalization.reference = "Iout";   % "Iout" | "Id"

%% Settings overrides (optional) ---------------------------------------
% Example: settingsOverrides.report.verbosity = "verbose";
settingsOverrides = struct();

% Optional measurements (#48-55) run only when enabled here, by id or
% "all". Ids: VdsOn, IdOn, RonEff, Vf, IfDiode, PcondDevice, PcondDiode.
% settingsOverrides.measurements.enableOptional = ["VdsOn", "RonEff"];

%% Paths ---------------------------------------------------------------
% Only code folders go on the path. genpath is deliberately not used: it
% would add every collection folder, each with its own channelMap.m.
scriptDir = fileparts(mfilename('fullpath'));
codeDirs = fullfile(scriptDir, ["", "sync", "measurements", ...
    fullfile("measurements", "primitives"), "analysis"]);
codeDirs = cellstr(codeDirs(isfolder(codeDirs)));
addpath(codeDirs{:});

%% 1-2. Settings and bucket configuration ------------------------------
S = dptSettings(settingsOverrides);
cfg = validateBucketConfig(cfg, S, scriptDir);

%% 3-4. Discover and import collections --------------------------------
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
        excluded(end+1) = struct('name', found(k).name, 'reason', string(ME.message)); %#ok<SAGROW>
        issues = [issues; dptIssue("dpt:import:collectionExcluded", "warning", ...
            "import", found(k).name, ME.message, S)]; %#ok<AGROW>
        continue
    end
    collections{end+1} = col; %#ok<SAGROW>
    issues = [issues; col.issues]; %#ok<AGROW>
end
if isempty(collections)
    error('dpt:import:noValidCollections', ...
        'No valid collections in bucket %s. See the warnings above.', cfg.bucketPath);
end
collections = [collections{:}];

%% 5. Gate-transition detection ----------------------------------------
evs = {};
detected = false(1, numel(collections));
for k = 1:numel(collections)
    try
        ev = detectGateTransitions(collections(k), cfg, S);
    catch ME
        if ~startsWith(ME.identifier, "dpt:")
            rethrow(ME);
        end
        excluded(end+1) = struct('name', collections(k).name, 'reason', string(ME.message)); %#ok<SAGROW>
        issues = [issues; dptIssue("dpt:detection:collectionExcluded", "warning", ...
            "detection", collections(k).name, ME.message, S)]; %#ok<AGROW>
        continue
    end
    evs{end+1} = ev; %#ok<SAGROW>
    detected(k) = true;
    issues = [issues; ev.issues]; %#ok<AGROW>
end
if isempty(evs)
    error('dpt:detection:noValidCollections', ...
        'Gate detection failed in every collection. See the warnings above.');
end
collections = collections(detected);
evs = [evs{:}];

%% 6. Alignment and pulse timeline --------------------------------------
al = alignCollections(evs, S);
issues = [issues; al.issues];
excluded = [excluded, al.excluded];
collections = collections(al.sourceIndex);
evs = evs(al.sourceIndex);

tl = buildPulseTimeline(evs, al, cfg, S);
issues = [issues; tl.issues];

%% 6b. Current-sensor normalization (opt-in: cfg.currentNormalization) ---
for k = 1:numel(collections)
    [collections(k), iss] = normalizeCurrentSensors(collections(k), k, al, tl, cfg, S);
    issues = [issues; iss]; %#ok<AGROW>
end

%% Summary --------------------------------------------------------------
if S.report.verbosity ~= "quiet"
    fprintf('Bucket: %s  (active device: %s)\n', cfg.bucketPath, cfg.activeDevice);
    for k = 1:numel(collections)
        col = collections(k);
        fprintf('  %-16s %d channels, dt = %.4g ns, N = %d, span = %.4g us\n', ...
            col.name, numel(col.channels), col.sampleInterval * 1e9, ...
            col.recordLength, (col.time(end) - col.time(1)) * 1e6);
        fprintf('  %-16s %s\n', '', strjoin([col.channels.signal], ", "));
        fprintf('  %-16s gate %s: levels %.3g / %.3g V, %d edges, offset %.6g us\n', '', ...
            evs(k).signal, evs(k).levels.low, evs(k).levels.high, ...
            height(evs(k).edges), al.offset(k) * 1e6);
        nz = col.normalization;
        if nz.applied
            fprintf('  %-16s currents normalized to %s: %s x %.5g %+.3g A\n', '', ...
                nz.reference, nz.adjusted, nz.gain, nz.offset);
        elseif cfg.currentNormalization.enable
            fprintf('  %-16s currents NOT normalized: %s\n', '', nz.reason);
        end
    end
    for x = excluded
        fprintf('  %-16s EXCLUDED: %s\n', x.name, x.reason);
    end
    fprintf('Timeline: %d pulse(s), %d edge(s), %d of %d window(s) usable.\n  %s\n', ...
        tl.detectedPulseCount, height(tl.edges), nnz(tl.windows.valid), ...
        height(tl.windows), tl.origin);
    fprintf('Issues: %d warning(s), %d info.\n', ...
        sum([issues.severity] == "warning"), sum([issues.severity] == "info"));
end
