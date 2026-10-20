%DPT_ANALYZER Double Pulse Test waveform analyzer - entry point.
%
%   Edit the bucket configuration below, then run this script. Paths are
%   resolved from this file's location, not from the current folder.
%
%   Workflow (implemented so far: steps 1-6; steps 3-6 run in runPipeline)
%     1. Load settings (dptSettings)
%     2. Validate the bucket configuration
%     3. Discover the bucket's collections
%     4. Import and validate each collection
%     5. Detect the active gate's transitions in each collection
%     6. Align collections on matched edges; build the pulse timeline and
%        measurement windows; normalize current sensors (opt-in); build
%        the bus-voltage model V_DC(t)
%     7. Run eligible measurements                (Batches 5-6)
%     8. Report results                           (Batch 6)
%
%   A collection that fails steps 4-6 is excluded and reported; the
%   remaining collections continue. The pipeline result is in "result".

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

% Optional: remove probe zero offsets. Before the first pulse the currents
% and the non-active device's V_DS must read zero (inductor at rest), so
% their mean there is an offset and is subtracted. Needs a record that
% starts at rest.
cfg.zeroOffsetCorrection.enable = true;

% Optional: calibrate the I_D and Iout sensors against each other on the
% on-state of every pulse, taking one of them as the truth.
cfg.currentNormalization.enable    = false;
cfg.currentNormalization.reference = "Iout";   % "Iout" | "Id"

% Optional: calibrate the two V_DS probes against each other, from the
% jump of V_DS,HS + V_DS,LS across every turn-off (needs both V_DS and
% at least 3 pulses). The reference probe is taken as the truth; with
% "active", every active-device result stays unchanged.
cfg.voltageNormalization.enable    = false;
cfg.voltageNormalization.reference = "active";  % "active" | "nonActive"

% Optional: reverse recovery (#39-46) needs the diode current. Without a
% probe on the non-active device, it can be derived as I_L - I_D of the
% active device. That is only as good as the two sensors agree, so it is
% opt-in, best with current normalization on, and refused for any pulse
% whose conduction-phase mismatch exceeds 25 % of its I_rrm.
cfg.diodeCurrent.allowDerived = false;

% Optional: device ratings. A measured peak beyond one is flagged
% "exceedsRating". VgsThMin is the lowest V_GS(th) at the highest T_j,
% the limit for gate cross-talk on the non-active device.
% cfg.ratings.VdsMax   = 1200;      % [V]
% cfg.ratings.VgsMax   = 22;        % [V]
% cfg.ratings.VgsMin   = -8;        % [V]
% cfg.ratings.VgsThMin = 1.8;       % [V]

%% DC bus ------------------------------------------------------------
% The analyzer needs the bus voltage V_DC, which droops during the pulse
% train as the pulses drain the DC link. It takes V_DC from the first of:
%   1. a bus-voltage channel, if one is mapped as "Vdc";
%   2. both V_DS channels, if both are mapped: V_DC = V_DS,HS + V_DS,LS;
%   3. the DC-link capacitance below: V_DC falls by Q/C as the pulses
%      draw charge Q from the link, starting from the V_DS measured
%      before the first pulse;
%   4. a constant V_DC equal to the V_DS before the first pulse (or
%      cfg.nominal.busVoltage). If the record shows droop, the results
%      are flagged and the summary tells you.
% The summary states which one was used for each collection.
cfg.circuit.Cdc          = [];      % [F] DC-link capacitance, e.g. 680e-6; [] = unknown
cfg.circuit.CdcTolerance = 0.20;    % [-] tolerance of Cdc (DC-link capacitors: typ. 20 %)

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

%% 3-6. Pipeline -------------------------------------------------------
result = runPipeline(cfg, S);

%% Summary --------------------------------------------------------------
if S.report.verbosity ~= "quiet"
    fprintf('Bucket: %s  (active device: %s)\n', cfg.bucketPath, cfg.activeDevice);
    for k = 1:numel(result.collections)
        col = result.collections(k);
        ev = result.evs(k);
        fprintf('  %-16s %d channels, dt = %.4g ns, N = %d, span = %.4g us\n', ...
            col.name, numel(col.channels), col.sampleInterval * 1e9, ...
            col.recordLength, (col.time(end) - col.time(1)) * 1e6);
        fprintf('  %-16s %s\n', '', strjoin([col.channels.signal], ", "));
        fprintf('  %-16s gate %s: levels %.3g / %.3g V, %d edges, offset %.6g us\n', '', ...
            ev.signal, ev.levels.low, ev.levels.high, height(ev.edges), result.al.offset(k) * 1e6);
        zo = col.zeroOffset;
        if zo.applied
            parts = compose("%s %+.3g", zo.signals(:), zo.offsets(:));
            fprintf('  %-16s zero offsets removed: %s\n', '', strjoin(parts, ", "));
        end
        if cfg.zeroOffsetCorrection.enable && zo.reason ~= ""
            fprintf('  %-16s zero offsets: %s\n', '', zo.reason);
        end
        nz = col.normalization;
        if nz.applied
            fprintf('  %-16s currents normalized to %s: %s x %.5g %+.3g A\n', '', ...
                nz.reference, nz.adjusted, nz.gain, nz.offset);
        elseif cfg.currentNormalization.enable
            fprintf('  %-16s currents NOT normalized: %s\n', '', nz.reason);
        end
        vz = col.voltageNormalization;
        if vz.applied
            fprintf('  %-16s V_DS probes normalized: %s reads %+.3g %%, bus resistance %.3g mOhm\n', ...
                '', vz.adjusted, 100 * vz.gainError, 1e3 * vz.busResistance);
        elseif cfg.voltageNormalization.enable
            fprintf('  %-16s V_DS probes NOT normalized: %s\n', '', vz.reason);
        end
        fprintf('  %-16s V_DC(t): %s\n', '', col.busVoltage.description);
        if col.busVoltage.droopDetected
            fprintf('  %-16s   BUS DROOP DETECTED (>= %.3g V below V_DC0): set cfg.circuit.Cdc\n', ...
                '', col.busVoltage.maxDroop);
        end
    end
    for x = result.excluded
        fprintf('  %-16s EXCLUDED: %s\n', x.name, x.reason);
    end
    fprintf('Timeline: %d pulse(s), %d edge(s), %d of %d window(s) usable.\n  %s\n', ...
        result.tl.detectedPulseCount, height(result.tl.edges), nnz(result.tl.windows.valid), ...
        height(result.tl.windows), result.tl.origin);
    fprintf('Issues: %d warning(s), %d info.\n', ...
        sum([result.issues.severity] == "warning"), sum([result.issues.severity] == "info"));
end
