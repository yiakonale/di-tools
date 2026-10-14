function test_corrections(root)
%TEST_CORRECTIONS Informal tests of zero-offset correction and the bucket
%   capacitance (formalized in Batch 7). Runs the full pipeline
%   (runPipeline) on synthetic buckets with known probe offsets and on the
%   example record.
%   test_corrections(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_corr');
end
codeDir = fileparts(fileparts(mfilename('fullpath')));
addpath(codeDir, fullfile(codeDir, 'sync'), fullfile(codeDir, 'measurements'), ...
    fullfile(codeDir, 'measurements', 'primitives'), fileparts(mfilename('fullpath')));
if isfolder(root), rmdir(root, 's'); end
mkdir(root);
nPass = 0; nFail = 0;

    function check(cond, label)
        if cond, fprintf('pass  %s\n', label); nPass = nPass + 1;
        else, fprintf('FAIL  %s\n', label); nFail = nFail + 1; end
    end

S = dptSettings(struct('report', struct('echoWarnings', false), 'measurements', struct('enableOptional', "all")));
R = measurementRegistry();
def = @(id) R([R.id] == id);

    function res = pipeline(bucket, zero, normalize, circuit)
        if nargin < 3, normalize = false; end
        if nargin < 4, circuit = struct(); end
        cfg = validateBucketConfig(struct('bucketPath', string(bucket), 'activeDevice', "LS", ...
            'deviceType', "MOSFET", 'expectedPulseCount', [], ...
            'gate', struct('nominal', struct('high', 18, 'low', -5)), 'circuit', circuit, ...
            'zeroOffsetCorrection', struct('enable', zero), ...
            'currentNormalization', struct('enable', normalize)), S, codeDir);
        res = runPipeline(cfg, S);
    end
    function r = run(res, id, c, edgeIds, kind)
        ctx = eventContext(res.collections(c), c, res.evs(c), res.al, res.tl, edgeIds, kind, res.cfg);
        r = evaluateMeasurement(def(id), ctx, S);
    end
    function v = truthMean(tr, x, w)
        k = tr.t >= w(1) & tr.t <= w(2);
        v = mean(x(k));
    end
    function tf = hasIssue(iss, id)
        tf = ~isempty(iss) && any([iss.id] == id);
    end

%% Zero-offset correction --------------------------------------------------------
offs = struct('idOffset', -3.7, 'ilOffset', -4.8, 'vdsHSOffset', -1.4);
b1 = fullfile(root, 'z1');
tr = makeSyntheticDPT(fullfile(b1, 'A'), offs);
res = pipeline(b1, true);
zo = res.collections(1).zeroOffset;
got = containers.Map(cellstr(zo.signals), num2cell(zo.offsets));
check(zo.applied && abs(got('Id-LS') + 3.7) < 1e-9 && abs(got('Iout') + 4.8) < 1e-9 && abs(got('Vds-HS') + 1.4) < 1e-9, ...
    sprintf('synthetic offsets recovered exactly: %s', strjoin(compose("%s %+.4g", zo.signals(:), zo.offsets(:)), ", ")));
check(~any(zo.signals == "Vds-LS"), 'active V_DS (reads V_DC) never zero-corrected');
r = run(res, "Ion", 1, 3, "turnOn");
check(abs(r.value - interp1(tr.t, tr.IL, tr.g10(2))) < 0.01, sprintf('I_on after correction = true I_L: %s', formatResult(r)));
r = run(res, "Vf", 1, [4 5], "break");
w = r.provenance.window + res.tl.edges.time(4) + res.al.offset;
check(abs(r.value - truthMean(tr, -tr.vdsHS, w)) < 1e-6, sprintf('V_F after correction = truth: %s', formatResult(r)));
resOff = pipeline(b1, false);
r = run(resOff, "Ion", 1, 3, "turnOn");
check(~resOff.collections(1).zeroOffset.applied && abs(r.value - (interp1(tr.t, tr.IL, tr.g10(2)) - 4.8)) < 0.01, ...
    'disabled: offsets stay in the data (I_on reads 4.8 A low)');

% Zero correction runs before normalization: the affine offset b is then ~0.
b2 = fullfile(root, 'z2');
makeSyntheticDPT(fullfile(b2, 'A'), struct('idGain', 0.95, 'idOffset', 1.5, 'ilOffset', -2));
nz = pipeline(b2, true, true).collections(1).normalization;
check(nz.applied && abs(nz.gain - 1 / 0.95) < 1e-4 && abs(nz.offset) < 1e-3, ...
    sprintf('zero correction then normalization: k = %.5f, b = %.2g A', nz.gain, nz.offset));

% Refusals.
b3 = fullfile(root, 'z3');
makeSyntheticDPT(fullfile(b3, 'A'), struct('ilOffset', 20));        % 20 A of a ~180 A peak
res = pipeline(b3, true);
zo = res.collections(1).zeroOffset;
check(~any(zo.signals == "Iout") && any(zo.signals == "Id-LS") && contains(zo.reason, "Iout") && ...
    hasIssue(res.issues, "dpt:zeroOffset:refused"), sprintf('offset > 5 %% of scale refused per channel: %s', zo.reason));
b4 = fullfile(root, 'z4');
makeSyntheticDPT(fullfile(b4, 'A'), struct('span', [3e-6 32e-6]));   % record starts inside pulse 1
res = pipeline(b4, true);
check(~res.collections(1).zeroOffset.applied && contains(res.collections(1).zeroOffset.reason, "at rest"), ...
    'record not starting at rest: not applied, reported');

%% Example record ------------------------------------------------------------------
cfgX = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", 'deviceType', "MOSFET", ...
    'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
    'zeroOffsetCorrection', struct('enable', true), 'currentNormalization', struct('enable', true)), S, codeDir);
res = runPipeline(cfgX, S);
col = res.collections(1);
got = containers.Map(cellstr(col.zeroOffset.signals), num2cell(col.zeroOffset.offsets));
check(abs(got('Iout') + 4.84) < 0.01 && abs(got('Id-LS') + 3.73) < 0.01 && abs(got('Vds-HS') + 1.42) < 0.01, ...
    'example offsets: Iout -4.84 A, Id-LS -3.73 A, Vds-HS -1.42 V');
% The pre-pulse offsets do not explain the sensors' disagreement under
% load completely: b = -0.10 + 4.84 - 1.069 * 3.73 = +0.75 A remains, below
% a fifth of one Iout ADC step (4 A) and so unresolvable on this record.
check(abs(col.normalization.offset) < 1 && abs(col.normalization.gain - 1.069) < 0.003, ...
    sprintf('example normalization after zero correction: k = %.4f, b = %.3f A (< 1/4 Iout step)', ...
    col.normalization.gain, col.normalization.offset));
r = run(res, "Ion", 1, 1, "turnOn");
check(abs(r.value) < 1, sprintf('example pulse 1 I_on now ~0: %s', formatResult(r)));
r = run(res, "Vf", 1, [res.tl.pulses.turnOffEdge(1), res.tl.pulses.turnOnEdge(2)], "break");
check(r.value > 3 && r.value < 4.2, sprintf('example V_F break 1 (was 4.8 V with the -1.42 V offset): %s', formatResult(r)));

%% Bucket capacitance ----------------------------------------------------------------
C0 = 60e-6;
full = ["Vgs-LS", "Vds-LS", "Vds-HS", "Id-LS"];
single = ["Vgs-LS", "Vds-LS", "Id-LS"];
b5 = fullfile(root, 'c1');
tr = makeSyntheticDPT(fullfile(b5, 'A_full'), struct('Cdc', C0, 'channels', full));
makeSyntheticDPT(fullfile(b5, 'B_single'), struct('Cdc', C0, 'channels', single));
res = pipeline(b5, false, false, struct('Cdc', 100e-6));     % cfg C deliberately wrong
bA = res.collections([res.collections.name] == "A_full").busVoltage;
bB = res.collections([res.collections.name] == "B_single").busVoltage;
check(bA.source == "kvl" && abs(res.bucketC.value / C0 - 1) < 0.01 && res.bucketC.collections == "A_full", ...
    sprintf('bucket C measured in the KVL collection: %.4g uF +/- %.2g %%', res.bucketC.value * 1e6, 100 * res.bucketC.relUncertainty));
check(bB.source == "chargeDroop" && bB.C == res.bucketC.value && contains(bB.Csource, "A_full") && ...
    contains(bB.description, "measured in A_full"), 'single-V_DS collection uses the bucket C, not the wrong cfg C');
cB = find([res.collections.name] == "B_single");
r = run(res, "VdcOff", cB, 6, "turnOff");
w = r.provenance.window + res.tl.edges.time(6) + res.al.offset(cB);
truth = truthMean(tr, tr.vdc, w);
check(abs(r.value - truth) < 0.1 && r.provenance.uncertainty < 0.5, sprintf( ...
    'single-V_DS V_DC,off with bucket C: %s (true %.3f V)', formatResult(r), truth));
check(~hasIssue(res.issues, "dpt:busVoltage:droopDetected"), 'no stale first-pass droop warning');

b6 = fullfile(root, 'c2');
makeSyntheticDPT(fullfile(b6, 'B_single'), struct('Cdc', C0, 'channels', single));
res = pipeline(b6, false, false, struct('Cdc', C0));
check(isnan(res.bucketC.value) && res.collections(1).busVoltage.Csource == "cfg.circuit.Cdc", ...
    'no direct-source collection: falls back to cfg.circuit.Cdc');

b7 = fullfile(root, 'c3');
makeSyntheticDPT(fullfile(b7, 'A1'), struct('Cdc', C0, 'channels', full));
makeSyntheticDPT(fullfile(b7, 'A2'), struct('Cdc', 1.1 * C0, 'channels', full));
res = pipeline(b7, false);
check(hasIssue(res.issues, "dpt:busVoltage:capacitanceSpread") && res.bucketC.relUncertainty >= 0.04, ...
    sprintf('two direct collections disagreeing by 10 %%: warned, uncertainty %.2g %%', 100 * res.bucketC.relUncertainty));

% Example record as a two-collection bucket: the full record + a single-V_DS copy.
exDir = fullfile(codeDir, 'data', 'example', 'collection_A');
b8 = fullfile(root, 'ex');
mkdir(fullfile(b8, 'full')); mkdir(fullfile(b8, 'single'));
for f = ["ch1", "ch2", "ch3", "ch4", "ch7", "math1"]
    copyfile(fullfile(exDir, "Tek000_" + f + ".mat"), fullfile(b8, 'full'));
end
copyfile(fullfile(exDir, 'channelMap.m'), fullfile(b8, 'full'));
for f = ["ch2", "ch3", "math1"]
    copyfile(fullfile(exDir, "Tek000_" + f + ".mat"), fullfile(b8, 'single'));
end
writelines(["function map = channelMap()"
    "map.channels.CH2 = struct(""signal"", ""Vgs-LS"", ""file"", ""Tek000_ch2.mat"");"
    "map.channels.CH3 = struct(""signal"", ""Vds-LS"", ""file"", ""Tek000_ch3.mat"");"
    "map.channels.MATH1 = struct(""signal"", ""Id-LS"", ""file"", ""Tek000_math1.mat"");"
    "end"], fullfile(b8, 'single', 'channelMap.m'));
res = pipeline(b8, true, true);
iF = find([res.collections.name] == "full"); iS = find([res.collections.name] == "single");
lastOff = res.tl.pulses.turnOffEdge(end);
rF = run(res, "VdcOff", iF, lastOff, "turnOff");
rS = run(res, "VdcOff", iS, lastOff, "turnOff");
check(res.collections(iS).busVoltage.source == "chargeDroop" && abs(res.bucketC.value - 0.685e-3) < 0.035e-3, ...
    sprintf('example bucket: C = %.4g mF +/- %.2g %% measured in "full", applied to "single"', ...
    res.bucketC.value * 1e3, 100 * res.bucketC.relUncertainty));
check(abs(rS.value - rF.value) < 2, sprintf('example last turn-off: single %s vs full %s', formatResult(rS), formatResult(rF)));

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end
