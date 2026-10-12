%DPT_ANALYZER Double Pulse Test waveform analyzer - entry point.
%
%   Edit the bucket configuration below, then run this script. Paths are
%   resolved from this file's location, not from the current folder.
%
%   Workflow (implemented so far: steps 1-4)
%     1. Load settings (dptSettings)
%     2. Validate the bucket configuration
%     3. Discover the bucket's collections
%     4. Import and validate each collection; invalid collections are
%        excluded and reported, the rest continue
%     5. Detect gate transitions                  (Batch 4)
%     6. Align collections, build pulse timeline  (Batch 4)
%     7. Run eligible measurements                (Batches 5-6)
%     8. Report results                           (Batch 6)

clear; clc; close all;

%% Bucket configuration ------------------------------------------------
cfg.bucketPath         = "data/example";   % relative to this script, or absolute
cfg.activeDevice       = "LS";             % "HS" | "LS"
cfg.expectedPulseCount = 10;               % advisory only; [] = no check
cfg.gate.nominal.high  = 18;               % [V] active gate on-state drive
cfg.gate.nominal.low   = -5;               % [V] active gate off-state drive

%% Settings overrides (optional) ---------------------------------------
% Example: settingsOverrides.report.verbosity = "verbose";
settingsOverrides = struct();

%% Paths ---------------------------------------------------------------
% Only code folders go on the path. genpath is deliberately not used: it
% would add every collection folder, each with its own channelMap.m.
scriptDir = fileparts(mfilename('fullpath'));
codeDirs = fullfile(scriptDir, ["", "sync", "measurements", "analysis"]);
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

%% Import summary -------------------------------------------------------
if S.report.verbosity ~= "quiet"
    fprintf('Bucket: %s  (active device: %s)\n', cfg.bucketPath, cfg.activeDevice);
    for col = collections
        fprintf('  %-16s %d channels, dt = %.4g ns, N = %d, span = %.4g us\n', ...
            col.name, numel(col.channels), col.sampleInterval * 1e9, ...
            col.recordLength, (col.time(end) - col.time(1)) * 1e6);
        fprintf('  %-16s %s\n', '', strjoin([col.channels.signal], ", "));
    end
    for x = excluded
        fprintf('  %-16s EXCLUDED\n', x.name);
    end
    fprintf('Issues: %d warning(s), %d info.\n', ...
        sum([issues.severity] == "warning"), sum([issues.severity] == "info"));
end
