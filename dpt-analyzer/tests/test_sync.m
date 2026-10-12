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
check(isequal(alC.collections, ["A", "B"]) && alC.excluded(1).name == "C" && ...
    contains(alC.excluded(1).reason, "record length"), 'shorter record excluded (horizontal setup differs)');
check(isequal(alC.sourceIndex, [1 2]) && alC.reference == 1, 'sourceIndex and reference');

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
    function writeSynthetic(folder, tSpan, ons, offs, tau, opts)
        % OPTS (optional): low [V] (default -5), shift [s] trigger shift
        % applied to the time labels (default 0), dt [s] (default dt).
        if nargin < 6, opts = struct(); end
        lo = -5; sh = 0; dtS = dt;
        if isfield(opts, 'low'), lo = opts.low; end
        if isfield(opts, 'shift'), sh = opts.shift; end
        if isfield(opts, 'dt'), dtS = opts.dt; end
        mkdir(folder);
        fid = fopen(fullfile(folder, 'channelMap.m'), 'w');
        fprintf(fid, 'function map = channelMap()\nmap.channels.CH1 = "Vgs-LS";\nend\n'); fclose(fid);
        tp = (tSpan(1):dtS:tSpan(2))';                   % physical time
        g = zeros(size(tp));
        for p = 1:numel(ons)
            g = g + 0.5 * (1 + tanh((tp - ons(p)) / tau)) .* 0.5 .* (1 - tanh((tp - offs(p)) / tau));
        end
        v.time = tp + sh;
        v.data = lo + (18 - lo) * g;
        v.sampleInterval = dtS; v.verticalUnits = 'V'; v.horizontalUnits = 's';
        v.waveformSource = 'CH1'; v.recordLength = numel(v.time);
        save(fullfile(folder, 'CH1.mat'), '-struct', 'v');
    end

% Classic DPT: long first pulse, short second pulse.
ons = [0, 8e-6]; offs = [5e-6, 9.5e-6]; tau = 50e-9;
writeSynthetic(fullfile(root, 'R'), [-2e-6 12e-6], ons, offs, tau);
evR = detectGateTransitions(importCollection(fullfile(root, 'R'), cfg, S), cfg, S);
    function ev = synth(name, varargin)
        writeSynthetic(fullfile(root, name), [-2e-6 12e-6], varargin{:});
        ev = detectGateTransitions(importCollection(fullfile(root, name), cfg, S), cfg, S);
    end
evX = synth('X', [ons 11e-6], [offs 11.5e-6], tau);                    % extra pulse, same setup
evY = synth('Y', ons, offs, tau, struct('shift', 123.4e-9));           % trigger varied
evL = synth('L', ons, offs, tau, struct('low', -4.1));                 % gate levels differ
evQ = synth('Q', ons, offs, tau, struct('shift', 2e-6));               % implausible trigger shift
evZ = synth('Z', ons, offs, tau, struct('dt', 2e-9));                  % different horizontal scale

alX = alignCollections([evR, evX, evY], S);
check(isequal(alX.collections, ["R", "Y"]) && contains(alX.excluded(1).reason, "edge sequence"), ...
    'extra pulse with identical setup: excluded (edge sequence)');
check(abs(alX.offset(2) - alX.offset(1) - 123.4e-9) < 1e-12 && max(abs(alX.residual(:))) < 1e-12, ...
    'trigger variation absorbed by one constant offset');
alX2 = alignCollections([evX, evR, evY], S);
check(alX2.collections(alX2.reference) == "R" && alX2.excluded(1).name == "X", ...
    'majority sequence chosen as reference regardless of order');
Sl = dptSettings(struct('gate', struct('levels', struct('tolerance', 0.5)), 'report', struct('echoWarnings', false)));
alL = alignCollections([evR, evL], Sl);
check(numel(alL.collections) == 2 && hasIssue(alL.issues, "dpt:alignment:gateLevelsDiffer"), ...
    'gate levels differing between collections: warned, kept');
alQ = alignCollections([evR, evQ], S);
check(numel(alQ.collections) == 2 && hasIssue(alQ.issues, "dpt:alignment:largeOffset"), ...
    'implausible trigger shift: warned');
alZ = alignCollections([evR, evZ], S);
check(isscalar(alZ.collections) && contains(alZ.excluded(1).reason, "sample interval"), ...
    'different sample interval: excluded');

% Windows: default adaptive, limiting, fallback and coverage.
D = 2 * tau * atanh(0.7);                              % 15 %-85 % duration
tlR = buildPulseTimeline(evR, alignCollections(evR, S), cfg, S);
w = tlR.windows;
check(height(tlR.pulses) == 2 && abs(tlR.pulses.onTime(2) - 1.5e-6) < 1e-9, 'pulses and on-time');
check(abs((w.coreEndTime(1) - w.coreStartTime(1)) - D) < 2 * dt, sprintf('core duration = D (%.1f ns)', D * 1e9));
Dc = w.coreEndTime(1) - w.coreStartTime(1);
check(abs((w.coreStartTime(1) - w.startTime(1)) - Dc) < 1e-15 && ...
    abs((w.endTime(1) - w.coreEndTime(1)) - 2 * Dc) < 1e-15, 'adaptive margins pre = 1 D, post = 2 D');

Sp = dptSettings(struct('windows', struct('adaptive', struct('post', 50)), 'report', struct('echoWarnings', false)));
tlL = buildPulseTimeline(evR, alignCollections(evR, Sp), cfg, Sp);
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
