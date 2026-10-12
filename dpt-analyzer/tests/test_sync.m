function test_sync(root)
%TEST_SYNC Informal detection, alignment and timeline cases (formalized in Batch 7).
%   test_sync() builds collections from the example record (cropped,
%   time-shifted, noisy, truncated) and from synthetic DPT gates in a
%   temporary folder, then checks detection, alignment and windows.
%   test_sync(root) uses ROOT as the scratch folder (deleted first).

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_sync');
end
codeDir = fileparts(fileparts(mfilename('fullpath')));
addpath(codeDir, fullfile(codeDir, 'sync'));
example = fullfile(codeDir, 'data', 'example', 'collection_A');

S = dptSettings(struct('report', struct('echoWarnings', false)));
cfg = struct('bucketPath', "", 'activeDevice', "LS", 'expectedPulseCount', [], ...
    'gate', struct('nominal', struct('high', 18, 'low', -5)));
if isfolder(root), rmdir(root, 's'); end
mkdir(root);
nPass = 0; nFail = 0;

    function check(cond, label)
        if cond, fprintf('pass  %s\n', label); nPass = nPass + 1;
        else, fprintf('FAIL  %s\n', label); nFail = nFail + 1; end
    end
    function expectError(id, f, label)
        try
            f(); fprintf('FAIL  %-34s no error (expected %s)\n', label, id); nFail = nFail + 1;
        catch ME
            if strcmp(ME.identifier, id)
                fprintf('pass  %-34s %s\n', label, ME.message); nPass = nPass + 1;
            else
                fprintf('FAIL  %-34s got %s: %s\n', label, ME.identifier, ME.message); nFail = nFail + 1;
            end
        end
    end

%% Real-data derived collections --------------------------------------
src = struct();
for f = ["ch2", "ch3", "ch7", "math1"]
    src.(f) = load(fullfile(example, "Tek000_" + f + ".mat"));
end
    function writeCropped(folder, mapBody, tRange, timeShift, noise)
        % Crop the example record to TRANGE (scope time), optionally
        % relabel time by TIMESHIFT and add gate noise + 0.2 V quantization.
        mkdir(folder);
        fid = fopen(fullfile(folder, 'channelMap.m'), 'w');
        fprintf(fid, 'function map = channelMap()\n%s\nend\n', mapBody); fclose(fid);
        for name = ["ch2", "ch3", "ch7", "math1"]
            v = src.(name);
            keep = v.time >= tRange(1) & v.time <= tRange(2);
            v.data = v.data(keep);
            v.time = v.time(keep) + timeShift;
            v.recordLength = nnz(keep);
            v.zeroIndex = find(keep, 1) - 1;
            if name == "ch2" && noise
                rng(1);
                v.data = round((v.data + 0.08 * randn(size(v.data))) / 0.2) * 0.2;
            end
            save(fullfile(folder, upper(name) + ".mat"), '-struct', 'v');
        end
    end

mapA = 'map.channels.CH2 = "Vgs-LS"; map.channels.CH3 = "Vds-LS"; map.channels.MATH1 = "Id-LS";';
mapB = 'map.channels.CH2 = "Vgs-LS"; map.channels.CH7 = "Iout";';
bucket = fullfile(root, 'bucket');
shiftB = 37.3e-9;                                      % 233.125 samples
writeCropped(fullfile(bucket, 'A'), mapA, [-2e-6 28e-6], 0, false);
writeCropped(fullfile(bucket, 'B'), mapB, [-2e-6 28e-6], shiftB, true);
writeCropped(fullfile(bucket, 'C'), mapB, [-2e-6 18e-6], 0, false);   % truncated: 2 pulses

A = importCollection(fullfile(bucket, 'A'), cfg, S);
B = importCollection(fullfile(bucket, 'B'), cfg, S);
Cc = importCollection(fullfile(bucket, 'C'), cfg, S);
evA = detectGateTransitions(A, cfg, S);
evB = detectGateTransitions(B, cfg, S);
evC = detectGateTransitions(Cc, cfg, S);

check(height(evA.edges) == 6 && isequal(evA.edges.kind', repmat(["turnOn", "turnOff"], 1, 3)), ...
    'real crop: 6 alternating edges');
check(all(evA.edges.nCrossings <= S.detection.maxReferenceCrossings) && isempty(evA.issues), ...
    'real crop: clean reference crossings, no issues');
check(abs(evA.levels.low + 5.4) < 0.3 && abs(evA.levels.high - 17.4) < 0.1, ...
    sprintf('measured levels %.2f / %.2f V', evA.levels.low, evA.levels.high));

al = alignCollections([evA, evB], S);
recovered = al.offset(2) - al.offset(1);
fprintf('      offset B-A = %.4f ns (true %.4f ns), max |residual| %.3f ns\n', ...
    recovered * 1e9, shiftB * 1e9, max(abs(al.residual(:))) * 1e9);
check(abs(recovered - shiftB) < 0.2e-9, 'non-integer offset recovered within 0.2 ns despite noise');
check(evA.edges.time(1) - al.offset(al.reference) == 0, 'universal t = 0 at reference first turn-on');
S0 = dptSettings(struct('detection', struct('timingSmoothing', 0), 'report', struct('echoWarnings', false)));
al00 = alignCollections([detectGateTransitions(A, cfg, S0), detectGateTransitions(B, cfg, S0)], S0);
err0 = abs(al00.offset(2) - al00.offset(1) - shiftB);
check(err0 > 5 * abs(recovered - shiftB), sprintf( ...
    'timing smoothing needed: unsmoothed error %.3f ns vs %.3f ns', err0 * 1e9, abs(recovered - shiftB) * 1e9));

% Noise-free copy: recovery must be exact to floating-point precision.
writeCropped(fullfile(root, 'B0'), mapB, [-2e-6 28e-6], shiftB, false);
B0Col = importCollection(fullfile(root, 'B0'), cfg, S);
evB0 = detectGateTransitions(B0Col, cfg, S);
al0 = alignCollections([evA, evB0], S);
check(abs(al0.offset(2) - al0.offset(1) - shiftB) < 1e-15 && max(abs(al0.residual(:))) < 1e-15, ...
    'noise-free offset exact, zero residual');

alC = alignCollections([evA, evB, evC], S);
check(isequal(alC.collections, ["A", "B"]) && alC.excluded(1).name == "C", ...
    'truncated collection excluded (sequence mismatch)');
St = dptSettings(struct('alignment', struct('onSequenceMismatch', "matchByTiming"), ...
    'report', struct('echoWarnings', false)));
alT = alignCollections([evA, evC], St);
check(numel(alT.collections) == 1 && contains(alT.excluded(1).reason, "ambiguous"), ...
    'periodic train truncated: timing match refused as ambiguous');

% Detection settings on real data
Sm = dptSettings(struct('detection', struct('reference', struct('strategy', "midpoint"), ...
    'timingSmoothing', 0), 'report', struct('echoWarnings', false)));
evM = detectGateTransitions(A, cfg, Sm);
check(hasIssue(evM.issues, "dpt:detection:referenceRecrossing") && max(evM.edges.nCrossings) > 3, ...
    sprintf('midpoint on Miller plateau flagged (max %d crossings)', max(evM.edges.nCrossings)));
cfgBad = cfg; cfgBad.gate.nominal.high = 20;
expectError('dpt:detection:levelMismatch', @() detectGateTransitions(A, cfgBad, S), 'nominal 20 V vs measured 17.4 V');
Sw = dptSettings(struct('gate', struct('levels', struct('onMismatch', "warn")), 'report', struct('echoWarnings', false)));
check(hasIssue(detectGateTransitions(A, cfgBad, Sw).issues, "dpt:detection:levelMismatch"), 'level mismatch as warning');
Sc = dptSettings(struct('conditioning', struct('method', "movmean", 'windowDuration', 2e-9), ...
    'report', struct('echoWarnings', false)));
evN = detectGateTransitions(B0Col, cfg, Sc);
check(height(evN.edges) == 6 && evN.conditioning.windowSamples == 13 && ...
    max(abs(evN.edges.time - evB0.edges.time)) < 0.2e-9, 'movmean conditioning: zero-phase, same edges');
cfgHS = cfg; cfgHS.activeDevice = "HS";
expectError('dpt:import:missingActiveGate', @() importCollection(fullfile(bucket, 'A'), cfgHS, S), ...
    'HS active but only Vgs-LS mapped');

%% Synthetic DPT gates ---------------------------------------------------
dt = 1e-9;
    function writeSynthetic(folder, tSpan, ons, offs, tau)
        mkdir(folder);
        fid = fopen(fullfile(folder, 'channelMap.m'), 'w');
        fprintf(fid, 'function map = channelMap()\nmap.channels.CH1 = "Vgs-LS";\nend\n'); fclose(fid);
        v.time = (tSpan(1):dt:tSpan(2))';
        g = zeros(size(v.time));
        for p = 1:numel(ons)
            g = g + 0.5 * (1 + tanh((v.time - ons(p)) / tau)) .* 0.5 .* (1 - tanh((v.time - offs(p)) / tau));
        end
        v.data = -5 + 23 * g;
        v.sampleInterval = dt; v.verticalUnits = 'V'; v.horizontalUnits = 's';
        v.waveformSource = 'CH1'; v.recordLength = numel(v.time);
        save(fullfile(folder, 'CH1.mat'), '-struct', 'v');
    end

% Classic DPT: long first pulse, short second pulse.
ons = [0, 8e-6]; offs = [5e-6, 9.5e-6]; tau = 50e-9;
writeSynthetic(fullfile(root, 'R'), [-2e-6 12e-6], ons, offs, tau);
writeSynthetic(fullfile(root, 'T'), [6e-6 12e-6], ons, offs, tau);     % misses pulse 1
evR = detectGateTransitions(importCollection(fullfile(root, 'R'), cfg, S), cfg, S);
evT = detectGateTransitions(importCollection(fullfile(root, 'T'), cfg, S), cfg, S);
alS = alignCollections([evR, evT], St);
check(isequaln(alS.match(:, 2)', [NaN NaN 1 2]) && abs(alS.offset(2) - alS.offset(1)) < 1e-12, ...
    'DPT with distinct widths: truncated collection matched by timing');

% Windows: default adaptive, limiting, fallback and coverage.
D = 2 * tau * atanh(0.7);                              % 15 %-85 % duration
tlR = buildPulseTimeline(evR, alignCollections(evR, S), cfg, S);
w = tlR.windows;
check(height(tlR.pulses) == 2 && abs(tlR.pulses.onTime(2) - 1.5e-6) < 1e-9, 'pulses and on-time');
check(abs((w.coreEndTime(1) - w.coreStartTime(1)) - D) < 2 * dt, sprintf('core duration = D (%.1f ns)', D * 1e9));
Dc = w.coreEndTime(1) - w.coreStartTime(1);
check(abs((w.coreStartTime(1) - w.startTime(1)) - Dc) < 1e-15 && ...
    abs((w.endTime(1) - w.coreEndTime(1)) - 2 * Dc) < 1e-15, 'adaptive margins pre = 1 D, post = 2 D');

Sl = dptSettings(struct('windows', struct('adaptive', struct('post', 50)), 'report', struct('echoWarnings', false)));
tlL = buildPulseTimeline(evR, alignCollections(evR, Sl), cfg, Sl);
mid23 = mean(tlL.edges.time(3:4));
check(tlL.windows.limited(3) && abs(tlL.windows.endTime(3) - mid23) < 1e-12, 'window limited to neighbour midpoint');

writeSynthetic(fullfile(root, 'E'), [-2e-6 9.5e-6 + 0.15e-6], ons, offs, tau);  % record ends 150 ns after last edge
evE = detectGateTransitions(importCollection(fullfile(root, 'E'), cfg, S), cfg, S);
tlE = buildPulseTimeline(evE, alignCollections(evE, S), cfg, S);
check(~tlE.windows.valid(4) && tlE.windows.valid(3) && hasIssue(tlE.issues, "dpt:timeline:unusableWindow"), ...
    'adaptive window past record end: skipped and reported');
Sf = dptSettings(struct('windows', struct('fixed', struct('turnOn', [-100e-9 100e-9], ...
    'turnOff', [-100e-9 100e-9])), 'report', struct('echoWarnings', false)));
tlF = buildPulseTimeline(evE, alignCollections(evE, Sf), cfg, Sf);
check(tlF.windows.valid(4) && tlF.windows.method(4) == "fallback" && tlF.windows.method(3) == "adaptive", ...
    'fixed fallback used only where the adaptive window does not fit');
Str = dptSettings(struct('windows', struct('onInsufficientCoverage', "truncate"), 'report', struct('echoWarnings', false)));
tlTr = buildPulseTimeline(evE, alignCollections(evE, Str), cfg, Str);
check(tlTr.windows.valid(4) && tlTr.windows.truncated(4) && abs(tlTr.windows.endTime(4) - (evE.recordSpan(2) - alignCollections(evE, Str).offset)) < 1e-12, ...
    'truncate policy clips to record end');

% Boundary edges and pulse count warning
writeSynthetic(fullfile(root, 'M'), [0.02e-6 12e-6], ons, offs, tau);          % starts mid-rise
evMid = detectGateTransitions(importCollection(fullfile(root, 'M'), cfg, S), cfg, S);
check(height(evMid.edges) == 3 && height(evMid.discarded) == 1 && evMid.edges.kind(1) == "turnOff", ...
    'record starting mid-transition: edge discarded and reported');
cfg3 = cfg; cfg3.expectedPulseCount = 3;
tl3 = buildPulseTimeline(evMid, alignCollections(evMid, S), cfg3, S);
check(isnan(tl3.edges.pulseIndex(1)) && tl3.detectedPulseCount == 1 && ...
    hasIssue(tl3.issues, "dpt:timeline:pulseCountMismatch"), 'leading turn-off unpaired; count mismatch warned');
Se = dptSettings(struct('pulses', struct('incompleteEdgePolicy', "error"), 'report', struct('echoWarnings', false)));
expectError('dpt:detection:incompleteEdge', @() detectGateTransitions(importCollection(fullfile(root, 'M'), cfg, S), cfg, Se), ...
    'incomplete edge policy = error');
Ssp = dptSettings(struct('detection', struct('minEdgeSpacing', 2e-6), 'report', struct('echoWarnings', false)));
evSp = detectGateTransitions(importCollection(fullfile(root, 'R'), cfg, S), cfg, Ssp);
check(height(evSp.edges) == 2 && height(evSp.discarded) == 2, 'min edge spacing drops the 1.5 us pulse pair');

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end

function tf = hasIssue(issues, id)
tf = ~isempty(issues) && any([issues.id] == id);
end
