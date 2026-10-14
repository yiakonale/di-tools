function test_bus_voltage(root)
%TEST_BUS_VOLTAGE Informal tests of the bus-voltage model V_DC(t) (formalized in Batch 7).
%   Every source of the chain (bus channel, KVL, charge droop, constant)
%   on synthetic collections with a known capacitor droop, the
%   diagnostics (droop check, C cross-check, implied V_F, nominal
%   mismatch), the rewired #1/#2/#52 methods, and the example record
%   both with both V_DS channels and as a single-V_DS copy.
%   test_bus_voltage(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_bus');
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

base = struct('report', struct('echoWarnings', false), 'measurements', struct('enableOptional', "all"));
S = dptSettings(base);
R = measurementRegistry();
def = @(id) R([R.id] == id);
C0 = 60e-6;                                     % synthetic DC link: ~27 V droop

    function [col, ev, al, tl, cfg, iss] = pipeline(folder, circuit, nominal, normalize, Sx)
        if nargin < 2, circuit = struct(); end
        if nargin < 3, nominal = struct(); end
        if nargin < 4, normalize = false; end
        if nargin < 5, Sx = S; end
        cfg = validateBucketConfig(struct('bucketPath', string(fileparts(folder)), 'activeDevice', "LS", ...
            'deviceType', "MOSFET", 'expectedPulseCount', [], ...
            'gate', struct('nominal', struct('high', 18, 'low', -5)), 'circuit', circuit, ...
            'nominal', nominal, 'currentNormalization', struct('enable', normalize)), Sx, codeDir);
        col = importCollection(folder, cfg, Sx);
        ev = detectGateTransitions(col, cfg, Sx);
        al = alignCollections(ev, Sx);
        tl = buildPulseTimeline(ev, al, cfg, Sx);
        col = normalizeCurrentSensors(col, 1, al, tl, cfg, Sx);
        [col, iss] = busVoltageModel(col, 1, al, tl, cfg, Sx);
    end
    function r = run(id, col, ev, al, tl, cfg, edgeIds, kind)
        r = evaluateMeasurement(def(id), eventContext(col, 1, ev, al, tl, edgeIds, kind, cfg), S);
    end
    function v = truthMean(tr, x, w)
        k = tr.t >= w(1) & tr.t <= w(2);
        v = mean(x(k));
    end
    function tf = hasIssue(iss, id, severity)
        tf = ~isempty(iss) && any([iss.id] == id & [iss.severity] == severity);
    end
    function w = window(r, tl, al)
        w = r.provenance.window + tl.edges.time(r.edgeIds(1)) + al.offset;
    end

%% 1. Bus channel ------------------------------------------------------------------
f = fullfile(root, 'b1', 'A');
tr = makeSyntheticDPT(f, struct('Cdc', C0));
[col, ev, al, tl, cfg] = pipeline(f);
check(col.busVoltage.source == "busChannel", "all channels: source = bus channel");
r = run("VdcOff", col, ev, al, tl, cfg, 6, "turnOff");
check(abs(r.value - truthMean(tr, tr.vdc, window(r, tl, al))) < 1e-6 && contains(r.methodTag, "bus channel"), ...
    sprintf('V_DC,off from the bus channel: %s', formatResult(r)));
check(tr.vdc(end) < tr.vdc(1) - 20, sprintf('synthetic droop %.1f V', tr.vdc(1) - tr.vdc(end)));

%% 2. KVL ---------------------------------------------------------------------------
f = fullfile(root, 'b2', 'A');
tr = makeSyntheticDPT(f, struct('Cdc', C0, 'channels', ["Vgs-LS", "Vds-LS", "Vds-HS", "Id-LS", "Iout"]));
[col, ev, al, tl, cfg, iss] = pipeline(f, struct('Cdc', C0));
check(col.busVoltage.source == "kvl", "no Vdc channel, both V_DS: source = KVL");
r = run("VdcOff", col, ev, al, tl, cfg, 6, "turnOff");
check(abs(r.value - truthMean(tr, tr.vdc, window(r, tl, al))) < 1e-6 && contains(r.methodTag, "KVL"), ...
    sprintf('V_DC,off from KVL: %s', formatResult(r)));
check(abs(col.busVoltage.cEstimate / C0 - 1) < 0.02 && hasIssue(iss, "dpt:busVoltage:capacitanceEstimate", "info"), ...
    sprintf('C estimated from the KVL droop: %.4g uF (true %.4g)', col.busVoltage.cEstimate * 1e6, C0 * 1e6));
[~, ~, ~, ~, ~, iss] = pipeline(f, struct('Cdc', 100e-6));
check(hasIssue(iss, "dpt:busVoltage:capacitanceEstimate", "warning"), 'cfg C 67 % off: cross-check warns');

%% 3. Charge droop --------------------------------------------------------------------
f = fullfile(root, 'b3', 'A');
tr = makeSyntheticDPT(f, struct('Cdc', C0, 'channels', ["Vgs-LS", "Vds-LS", "Id-LS"]));
[col, ev, al, tl, cfg, iss] = pipeline(f, struct('Cdc', C0));
check(col.busVoltage.source == "chargeDroop" && abs(col.busVoltage.V0 - 400) < 1e-6, ...
    sprintf('single V_DS + I_D + C: charge droop, V_DC0 = %.4g V from the pre-pulse V_DS', col.busVoltage.V0));
r = run("VdcOff", col, ev, al, tl, cfg, 6, "turnOff");
truth = truthMean(tr, tr.vdc, window(r, tl, al));
check(abs(r.value - truth) < 0.005 * (400 - truth) + 0.05, sprintf('V_DC,off from charge droop: %s (true %.3f V)', ...
    formatResult(r), truth));
check(abs(r.provenance.uncertainty - 0.25 * (400 - r.value)) < 1e-9, sprintf( ...
    'uncertainty = droop x 0.2/(1-0.2) (worst case C at -20 %%): %.3g V', r.provenance.uncertainty));
check(hasIssue(iss, "dpt:busVoltage:impliedDiodeDrop", "info"), 'implied V_F reported, non-negative');
[col2, ev2, al2, tl2, cfg2] = pipeline(f, struct('Cdc', 1.2 * C0));
r2 = run("VdcOff", col2, ev2, al2, tl2, cfg2, 6, "turnOff");
check(abs(r2.value - truth) <= r2.provenance.uncertainty, sprintf( ...
    'C 20 %% high: error %.2f V within the reported %.2f V', r2.value - truth, r2.provenance.uncertainty));
r = run("Vf", col, ev, al, tl, cfg, [4 5], "break");
truthVf = truthMean(tr, tr.vf, window(r, tl, al));
check(r.methodId == "busModel" && any(r.flags == "modelBased") && contains(r.methodTag, "charge droop") && ...
    abs(r.value - truthVf) < 0.05, sprintf('V_F from V_DS - V_DC(t) without the non-active V_DS: %s (true %.3f V)', ...
    formatResult(r), truthVf));

f = fullfile(root, 'b3b', 'A');
tr = makeSyntheticDPT(f, struct('Cdc', C0, 'channels', ["Vgs-LS", "Vds-LS", "Iout"]));
[col, ev, al, tl, cfg] = pipeline(f, struct('Cdc', C0));
r = run("VdcOff", col, ev, al, tl, cfg, 6, "turnOff");
truth = truthMean(tr, tr.vdc, window(r, tl, al));
check(col.busVoltage.currentSignal == "Iout" && abs(r.value - truth) < 0.01 * (400 - truth) + 0.05, ...
    sprintf('charge from Iout (no I_D): %s (true %.3f V)', formatResult(r), truth));

%% 4. Constant with the droop check ------------------------------------------------------
f = fullfile(root, 'b4', 'A');
makeSyntheticDPT(f, struct('Cdc', C0, 'channels', ["Vgs-LS", "Vds-LS", "Id-LS"]));
[col, ev, al, tl, cfg, iss] = pipeline(f);
r = run("VdcOff", col, ev, al, tl, cfg, 6, "turnOff");
check(col.busVoltage.source == "constant" && col.busVoltage.droopDetected && any(r.flags == "busDroopDetected") && ...
    hasIssue(iss, "dpt:busVoltage:droopDetected", "warning"), sprintf('no C: constant, droop detected (>= %.1f V): %s', ...
    col.busVoltage.maxDroop, formatResult(r)));
f = fullfile(root, 'b4b', 'A');
makeSyntheticDPT(f, struct('Cdc', 1, 'channels', ["Vgs-LS", "Vds-LS", "Id-LS"]));
col = pipeline(f);
check(col.busVoltage.source == "constant" && ~col.busVoltage.droopDetected, 'large DC link: constant, no droop flagged');

%% 5. Nominal and missing sources -----------------------------------------------------------
f = fullfile(root, 'b5', 'A');
makeSyntheticDPT(f, struct('channels', ["Vgs-LS", "Id-LS"]));
[col, ev, al, tl, cfg] = pipeline(f, struct(), struct('busVoltage', 400));
check(col.busVoltage.source == "constant" && col.busVoltage.V0source == "cfg.nominal.busVoltage", ...
    'no V_DS: constant from cfg.nominal.busVoltage');
[col, ev, al, tl, cfg] = pipeline(f);
r = run("VdcOff", col, ev, al, tl, cfg, 6, "turnOff");
check(col.busVoltage.source == "none" && r.status == "skipped" && contains(r.reason, "bus-voltage source"), ...
    sprintf('no source at all: V_DC skipped: %s', r.reason));
f3 = fullfile(root, 'b3', 'A');
[~, ~, ~, ~, ~, iss] = pipeline(f3, struct('Cdc', C0), struct('busVoltage', 450));
check(hasIssue(iss, "dpt:busVoltage:nominalMismatch", "warning"), 'pre-pulse V_DS vs nominal 450 V: mismatch warned');

%% 6. Spec V_DS methods still available, labelled as including V_F --------------------------
Sv = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('VdcOff', "settledVds"))));
[col, ev, al, tl, cfg] = pipeline(f3, struct('Cdc', C0));
r = evaluateMeasurement(def("VdcOff"), eventContext(col, 1, ev, al, tl, 6, "turnOff", cfg), Sv);
check(r.methodId == "settledVds" && contains(def("VdcOff").methods([def("VdcOff").methods.id] == "settledVds").description, "V_DC + V_F"), ...
    'settled V_DS method kept, documented as V_DC + V_F');

%% 7. Example record ----------------------------------------------------------------------------
cfgX = @(circuit, normalize) validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", ...
    'deviceType', "MOSFET", 'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
    'circuit', circuit, 'currentNormalization', struct('enable', normalize)), S, codeDir);
    function [col, ev, al, tl, cfg, iss] = example(folder, circuit)
        cfg = cfgX(circuit, true);
        col = importCollection(folder, cfg, S);
        ev = detectGateTransitions(col, cfg, S); al = alignCollections(ev, S); tl = buildPulseTimeline(ev, al, cfg, S);
        col = normalizeCurrentSensors(col, 1, al, tl, cfg, S);
        [col, iss] = busVoltageModel(col, 1, al, tl, cfg, S);
    end
exFolder = fullfile(codeDir, 'data', 'example', 'collection_A');
[col, ev, al, tl, cfg, iss] = example(exFolder, struct('Cdc', 680e-6));
lastOff = tl.pulses.turnOffEdge(end);
rK = run("VdcOff", col, ev, al, tl, cfg, lastOff, "turnOff");
check(col.busVoltage.source == "kvl" && abs(col.busVoltage.V0 - 403.0) < 0.5 && ...
    ~hasIssue(iss, "dpt:busVoltage:prePulseCurrent", "warning"), ...
    sprintf('example: KVL, V_DC0 = %.2f V, no false pre-pulse-current warning', col.busVoltage.V0));
check(abs(col.busVoltage.cEstimate - 0.685e-3) < 0.035e-3 && hasIssue(iss, "dpt:busVoltage:capacitanceEstimate", "info"), ...
    sprintf('example: C from droop = %.4g mF (normalized currents), within 20 %% of 0.68 mF', col.busVoltage.cEstimate * 1e3));
check(abs(rK.value - 374) < 3, sprintf('example last turn-off: %s', formatResult(rK)));

% Single-V_DS copy of the example (Vgs-LS, Vds-LS, MATH1 = Id-LS).
single = fullfile(root, 'exSingle', 'A');
mkdir(single);
for name = ["Tek000_ch2.mat", "Tek000_ch3.mat", "Tek000_math1.mat"]
    copyfile(fullfile(exFolder, name), single);
end
writelines(["function map = channelMap()"
    "map.channels.CH2 = struct(""signal"", ""Vgs-LS"", ""file"", ""Tek000_ch2.mat"");"
    "map.channels.CH3 = struct(""signal"", ""Vds-LS"", ""file"", ""Tek000_ch3.mat"");"
    "map.channels.MATH1 = struct(""signal"", ""Id-LS"", ""file"", ""Tek000_math1.mat"");"
    "end"], fullfile(single, 'channelMap.m'));
[col, ev, al, tl, cfg] = example(single, struct('Cdc', 0.685e-3));
rC = run("VdcOff", col, ev, al, tl, cfg, lastOff, "turnOff");
check(col.busVoltage.source == "chargeDroop" && abs(rC.value - rK.value) < 3, sprintf( ...
    'example single V_DS + C: %s vs KVL %.1f V', formatResult(rC), rK.value));
[col, ev, al, tl, cfg, iss] = example(single, struct());
rS = run("VdcOff", col, ev, al, tl, cfg, lastOff, "turnOff");
check(col.busVoltage.droopDetected && col.busVoltage.maxDroop > 15 && any(rS.flags == "busDroopDetected"), ...
    sprintf('example single V_DS, no C: droop of >= %.1f V detected: %s', col.busVoltage.maxDroop, formatResult(rS)));

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end
