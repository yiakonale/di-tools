function col = importCollection(collectionPath, cfg, S)
%IMPORTCOLLECTION Load one collection's channel map and waveforms.
%
%   col = importCollection(collectionPath, cfg, S) returns the collection
%   struct of DATA_CONTRACTS.md section 4:
%
%     name, path, description
%     time            N-by-1 shared scope time [s] (one copy)
%     sampleInterval  [s]
%     recordLength    N
%     channels        1-by-K struct, one per mapped channel, in map order:
%                     channel, signal, quantity, device, units, data,
%                     corrections, file, layout, sampleInterval,
%                     recordLength, source, zeroIndex, meta
%     unmappedFiles   .mat files present but not in the map
%     normalization   outcome of normalizeCurrentSensors (not run here)
%     busVoltage      bus-voltage model V_DC(t) (busVoltageModel; not run here)
%     issues          issue records (dptIssue)
%
%   The collection is rejected (error) if the map is invalid, a mapped
%   file is missing or invalid, units disagree with the signal catalog,
%   channels do not share one acquisition timebase, or the gate signal of
%   cfg.activeDevice is not mapped. Errors carry "dpt:" identifiers and
%   name the collection.
%
%   Read waveform samples through getSignal, which applies the channel's
%   post-acquisition corrections.

arguments
    collectionPath (1,1) string
    cfg (1,1) struct
    S (1,1) struct
end

collectionPath = regexprep(collectionPath, '[\\/]+$', '');
[~, name] = fileparts(collectionPath);
name = string(name);

try
    col = doImport(collectionPath, name, cfg, S);
catch ME
    if ~startsWith(ME.identifier, "dpt:")
        rethrow(ME);
    end
    wrapped = MException(ME.identifier, 'Collection "%s": %s', name, ME.message);
    throw(addCause(wrapped, ME));
end

end

% =====================================================================
function col = doImport(collectionPath, name, cfg, S)

if ~isfolder(collectionPath)
    error('dpt:import:collectionNotFound', 'folder not found: %s', collectionPath);
end
mapFile = fullfile(collectionPath, 'channelMap.m');
if ~isfile(mapFile)
    error('dpt:import:missingChannelMap', 'no channelMap.m in %s', collectionPath);
end

issues = dptIssue();
catalog = S.signals.catalog;

map = validateChannelMap(loadChannelMap(collectionPath), S, "channelMap.m");
keys = string(fieldnames(map.channels))';
entries = cellfun(@(k) map.channels.(k), cellstr(keys), 'UniformOutput', false);
entries = [entries{:}];
mapped = [entries.signal];

% The active device's gate is the synchronization reference.
gateSignal = catalog.name(catalog.quantity == "gateVoltage" & ...
    catalog.device == cfg.activeDevice);
if ~any(mapped == gateSignal)
    error('dpt:import:missingActiveGate', ...
        ['the active device is %s, but its gate signal "%s" is not mapped. ' ...
         'Every collection must contain it. Mapped: %s.'], ...
        cfg.activeDevice, gateSignal, strjoin(mapped, ", "));
end

% Resolve files case-insensitively against the folder contents.
listing = dir(fullfile(collectionPath, '*.mat'));
present = string({listing.name});
resolved = strings(size(keys));
for k = 1:numel(keys)
    hit = present(strcmpi(present, entries(k).file));
    if isempty(hit)
        error('dpt:import:missingFile', ...
            'channel %s ("%s") maps to "%s", which is not in the folder. Present: %s.', ...
            keys(k), entries(k).signal, entries(k).file, strjoin(present, ", "));
    elseif numel(hit) > 1
        error('dpt:import:ambiguousFile', ...
            'channel %s: several files match "%s" ignoring case: %s.', ...
            keys(k), entries(k).file, strjoin(hit, ", "));
    end
    resolved(k) = hit;
end

unmapped = present(~ismember(lower(present), lower(resolved)));
if ~isempty(unmapped)
    issues = [issues; dptIssue("dpt:import:unmappedFiles", "info", "import", name, ...
        sprintf('Not in channel map, ignored: %s.', strjoin(unmapped, ", ")), S)];
end

% Import channels and verify they share one acquisition.
channels = cell(1, numel(keys));
for k = 1:numel(keys)
    key = keys(k);
    entry = entries(k);
    raw = importChannel(fullfile(collectionPath, resolved(k)), S);
    row = catalog(catalog.name == entry.signal, :);

    if raw.source ~= "" && ~strcmpi(raw.source, key)
        error('dpt:import:sourceMismatch', ...
            ['channel %s maps to %s, but that file was exported from source ' ...
             '"%s". Check the map key or the file.'], key, resolved(k), raw.source);
    end
    if raw.units ~= row.units
        error('dpt:import:unitMismatch', ...
            'channel %s ("%s") has units "%s"; the signal requires "%s".', ...
            key, entry.signal, raw.units, row.units);
    end

    if k == 1
        time = raw.time;
        dt = raw.sampleInterval;
        N = raw.recordLength;
        refKey = key;
    else
        if abs(raw.sampleInterval - dt) > S.sampling.sampleIntervalRelTol * dt
            error('dpt:import:sampleIntervalMismatch', ...
                ['channel %s has sampleInterval %.6g s but %s has %.6g s. ' ...
                 'All channels of a collection must come from one acquisition.'], ...
                key, raw.sampleInterval, refKey, dt);
        end
        if raw.recordLength ~= N
            error('dpt:import:recordLengthMismatch', ...
                'channel %s has %d samples but %s has %d.', ...
                key, raw.recordLength, refKey, N);
        end
        maxDiff = max(abs(raw.time - time));
        if maxDiff > S.sampling.timeVectorRelTol * dt
            error('dpt:import:timeVectorMismatch', ...
                ['channel %s time vector differs from %s by up to %.3g s ' ...
                 '(%.3g samples). All channels of a collection must share ' ...
                 'one timebase.'], key, refKey, maxDiff, maxDiff / dt);
        end
    end

    [corrections, issues] = resolveCorrections(key, entry, dt, name, S, issues);

    channels{k} = struct( ...
        'channel',        key, ...
        'signal',         entry.signal, ...
        'quantity',       row.quantity, ...
        'device',         row.device, ...
        'units',          raw.units, ...
        'data',           raw.data, ...
        'corrections',    corrections, ...
        'file',           raw.file, ...
        'layout',         raw.layout, ...
        'sampleInterval', raw.sampleInterval, ...
        'recordLength',   raw.recordLength, ...
        'source',         raw.source, ...
        'zeroIndex',      {raw.zeroIndex}, ...
        'meta',           raw.meta);
end

col.name = name;
col.path = string(collectionPath);
col.description = map.description;
col.time = time;
col.sampleInterval = dt;
col.recordLength = N;
col.channels = [channels{:}];
col.unmappedFiles = unmapped;
% Outcome of the opt-in current-sensor normalization; filled in by
% normalizeCurrentSensors after the timeline is built.
col.normalization = struct('applied', false, 'reference', "", 'adjusted', "", ...
    'gain', 1, 'offset', 0, 'residualRms', NaN, 'expectedRms', NaN, ...
    'pulseGains', [], 'gainSpread', NaN, 'nPulses', 0, 'reason', "not run");
% Outcome of the opt-in V_DS probe calibration (normalizeVoltageSensors).
col.voltageNormalization = struct('applied', false, 'reference', "", 'adjusted', "", ...
    'gainError', NaN, 'busResistance', NaN, 'residualRms', NaN, 'nPulses', 0, ...
    'currentSignal', "", 'reason', "not run");
% Outcome of the opt-in zero-offset correction (zeroOffsetCorrection).
col.zeroOffset = struct('applied', false, 'signals', strings(1, 0), ...
    'offsets', zeros(1, 0), 'reason', "not run");
% Bus-voltage model V_DC(t); filled in by busVoltageModel after the
% timeline is built.
col.busVoltage = struct('source', "none", 'label', "none", 'description', "not run", ...
    'V0', NaN, 'V0source', "", 'C', [], 'Ctolerance', [], 'currentSignal', "", ...
    'onIntervals', zeros(0, 2), 'signals', strings(1, 0), 'droopDetected', false, ...
    'maxDroop', NaN, 'cEstimate', NaN, 'cEstimateRelSE', NaN, 'cEstimateSignal', "", ...
    'Csource', "", 'breakTimes', [], 'breakVds', []);
col.issues = issues;

end

% =====================================================================
function rawMap = loadChannelMap(folder)
% Every collection defines a function named channelMap, so the folder is
% made current for the call: the current folder takes precedence over
% the MATLAB path. The name is cleared before and after so MATLAB does
% not reuse another collection's cached definition. The previous folder
% is restored even if the map errors.

previous = cd(folder);
restore = onCleanup(@() cd(previous));

clear('channelMap');
expectedFile = fullfile(pwd, 'channelMap.m');
resolvedFile = which('channelMap');
if ~strcmpi(resolvedFile, expectedFile)
    error('dpt:map:shadowed', ...
        'channelMap resolves to "%s" instead of "%s".', resolvedFile, expectedFile);
end

try
    rawMap = feval('channelMap');
catch ME
    error('dpt:map:evaluationFailed', ...
        'channelMap.m could not be evaluated: %s', ME.message);
end
clear('channelMap');

end

% =====================================================================
function [c, issues] = resolveCorrections(key, entry, dt, name, S, issues)
% Apply the non-integer deskew policy and report every non-default
% correction so none is invisible in the results.

shift = entry.deskew / dt;
n = round(shift);
residual = (shift - n) * dt;

if abs(shift - n) > S.corrections.integerShiftTol
    if S.corrections.nonIntegerDeskew == "error"
        error('dpt:import:nonIntegerDeskew', ...
            ['channel %s deskew %.6g ns is %.4f samples, not an integer ' ...
             '(S.corrections.nonIntegerDeskew = "error").'], ...
            key, entry.deskew * 1e9, shift);
    end
    issues = [issues; dptIssue("dpt:import:deskewRounded", "info", "import", name, ...
        sprintf(['%s deskew %.6g ns rounded to %d samples (%.6g ns); ' ...
                 'residual %.3g ps.'], key, entry.deskew * 1e9, n, n * dt * 1e9, ...
                 residual * 1e12), S)];
end

c.deskew = entry.deskew;
c.deskewApplied = n * dt;
c.shift = n;
c.invert = entry.invert;
% Set later by zeroOffsetCorrection and normalizeCurrentSensors.
c.zeroOffset = 0;
c.gain = 1;
c.offset = 0;

if entry.deskew ~= 0 || entry.invert
    issues = [issues; dptIssue("dpt:import:correctionApplied", "info", "import", name, ...
        sprintf('%s (%s): post-acquisition deskew %.6g ns, invert = %s.', ...
        key, entry.signal, c.deskewApplied * 1e9, string(entry.invert)), S)];
end

end
