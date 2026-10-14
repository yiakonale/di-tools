function test_operating_point(root)
%TEST_OPERATING_POINT Informal tests of Batch 5c (formalized in Batch 7).
%   Current-sensor normalization, operating point (#1-4) and conduction
%   (#49-54): exact checks against synthetic DPT collections with known
%   truth (makeSyntheticDPT), method selection and fallbacks, and sanity
%   checks on the example record.
%   test_operating_point(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_op');
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

    function [col, ev, al, tl, cfg] = pipeline(folder, Sx, normalize, reference)
        if nargin < 3, normalize = false; end
        if nargin < 4, reference = "Iout"; end
        cfg = validateBucketConfig(struct('bucketPath', string(fileparts(folder)), 'activeDevice', "LS", ...
            'deviceType', "MOSFET", 'expectedPulseCount', [], ...
            'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
            'currentNormalization', struct('enable', normalize, 'reference', reference), ...
            'nominal', struct('busVoltage', 400, 'testCurrent', 100)), Sx, codeDir);
        col = importCollection(folder, cfg, Sx);
        ev = detectGateTransitions(col, cfg, Sx);
        al = alignCollections(ev, Sx);
        tl = buildPulseTimeline(ev, al, cfg, Sx);
        col = normalizeCurrentSensors(col, 1, al, tl, cfg, Sx);
        col = busVoltageModel(col, 1, al, tl, cfg, Sx);
    end
    function r = run(id, col, ev, al, tl, cfg, edgeIds, kind, Sx)
        if nargin < 9, Sx = S; end
        ctx = eventContext(col, 1, ev, al, tl, edgeIds, kind, cfg);
        r = evaluateMeasurement(def(id), ctx, Sx);
    end
    function v = truthAt(tr, x, t0)
        v = interp1(tr.t, x, t0);
    end
    function v = truthMean(tr, x, w)
        k = tr.t >= w(1) & tr.t <= w(2);
        v = mean(x(k));
    end

%% Synthetic collection with every channel -----------------------------------
fA = fullfile(root, 'bucketA', 'A');
tr = makeSyntheticDPT(fA);
[col, ev, al, tl, cfg] = pipeline(fA, S);
off0 = al.offset;                          % universal = corrected - offset
check(height(tl.edges) == 6 && tl.detectedPulseCount == 3, 'synthetic: 3 pulses, 6 edges');

% Gate instants match the analytic tanh crossings.
ctx = eventContext(col, 1, ev, al, tl, 3, "turnOn", cfg);
g = gateInstant(ctx, ctx.edges(1), 0.1, S);
check(abs(g.time - tr.g10(2)) < 0.05e-9, sprintf('V_GS 10 %% instant within 0.05 ns of analytic (%.3f ns)', (g.time - tr.g10(2)) * 1e9));
ctx = eventContext(col, 1, ev, al, tl, 4, "turnOff", cfg);
g = gateInstant(ctx, ctx.edges(1), 0.9, S);
check(abs(g.time - tr.g90(2)) < 0.05e-9, 'V_GS 90 % instant within 0.05 ns of analytic');

% #3/#4 from the inductor current at the gate instant.
r = run("Ion", col, ev, al, tl, cfg, 3, "turnOn");
check(r.methodId == "inductorAtInstant" && abs(r.value - truthAt(tr, tr.IL, tr.g10(2))) < 0.01, ...
    sprintf('I_on = I_L(V_GS 10 %%): %s', formatResult(r)));
r = run("Ioff", col, ev, al, tl, cfg, 4, "turnOff");
check(abs(r.value - truthAt(tr, tr.IL, tr.g90(2))) < 0.01, sprintf('I_off = I_L(V_GS 90 %%): %s', formatResult(r)));
r1 = run("Ion", col, ev, al, tl, cfg, 1, "turnOn");
check(any(r1.flags == "belowNoiseFloor") || abs(r1.value) < 1e-6, 'first turn-on at zero current: value ~0 (kept, not clamped)');

% #1/#2 from the bus channel (preferred when mapped).
r = run("VdcOff", col, ev, al, tl, cfg, 4, "turnOff");
check(r.methodId == "model" && contains(r.methodTag, "bus channel") && abs(r.value - truthAt(tr, tr.vdc, tr.g90(2) - 0.5 * ctx.edges(1).D)) < 1e-3, ...
    sprintf('V_DC,off from the bus channel: %s', formatResult(r)));
r = run("VdcOn", col, ev, al, tl, cfg, 3, "turnOn");
check(r.methodId == "model" && contains(r.methodTag, "bus channel"), sprintf('V_DC,on from the bus channel: %s', formatResult(r)));

% V_DS-based fallbacks read V_DC + V_F.
Sv = dptSettings(struct('report', base.report, 'measurements', struct('enableOptional', "all", ...
    'methods', struct('VdcOff', "settledVds", 'VdcOn', "offStateVds"))));
r = run("VdcOff", col, ev, al, tl, cfg, 4, "turnOff", Sv);
w = r.provenance.window + ctx.edges(1).time;
check(abs(r.value - truthMean(tr, tr.vdc + tr.vf, w)) < 0.05, sprintf('settled V_DS = V_DC + V_F: %s', formatResult(r)));
r = run("VdcOn", col, ev, al, tl, cfg, 3, "turnOn", Sv);
check(abs(r.value - (truthAt(tr, tr.vdc, tr.g10(2)) + truthAt(tr, tr.vf, tr.g10(2)))) < 0.05, ...
    sprintf('off-state V_DS = V_DC + V_F: %s', formatResult(r)));

% Extrapolated I_on: the settled ramp back to the gate instant. It
% undershoots I_L(gate instant) by the ramp over the time to the actual
% current rise (~ 10 A/us x 52 ns).
Se = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('Ion', "extrapolatedId"))));
r = run("Ion", col, ev, al, tl, cfg, 3, "turnOn", Se);
check(r.status == "ok" && abs(r.value - truthAt(tr, tr.IL, tr.g10(2))) < 1, ...
    sprintf('extrapolated I_on within 1 A of I_L: %s', formatResult(r)));

% Nominal methods only when listed, and only with cfg.nominal set.
Sn = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('Ion', "nominal"))));
r = run("Ion", col, ev, al, tl, cfg, 3, "turnOn", Sn);
check(r.value == 100 && r.methodTag == "Custom: nominal I_test", sprintf('nominal method: %s', formatResult(r)));

% Conduction (#49-54).
r = run("VdsOn", col, ev, al, tl, cfg, [3 4], "pulse");
w = r.provenance.window + tl.edges.time(3) + off0;
check(r.provenance.signals.V == "Vds-LS-clamp" && abs(r.value - truthMean(tr, tr.vdsLS, w)) < 1e-6 && ...
    ~any(r.flags == "resolutionLimited"), sprintf('V_DS(on) from the clamped channel: %s', formatResult(r)));
r = run("RonEff", col, ev, al, tl, cfg, [3 4], "pulse");
check(abs(r.value - tr.Ron) < 1e-9, sprintf('R_on,eff = Ron: %s', formatResult(r)));
r = run("IdOn", col, ev, al, tl, cfg, [3 4], "pulse");
check(abs(r.value - truthMean(tr, tr.id, w)) < 1e-6, sprintf('I_D(on): %s', formatResult(r)));
r = run("PcondDevice", col, ev, al, tl, cfg, [3 4], "pulse");
check(abs(r.value - truthMean(tr, tr.Ron * tr.id.^2, w)) / r.value < 1e-6, sprintf('P_cond device: %s', formatResult(r)));
r = run("Vf", col, ev, al, tl, cfg, [4 5], "break");
wb = r.provenance.window + tl.edges.time(4) + off0;
check(abs(r.value - truthMean(tr, -tr.vdsHS, wb)) < 1e-6 && abs(r.value - truthMean(tr, tr.vf, wb)) < 0.01, ...
    sprintf('V_F = -V_DS(HS) over the break: %s', formatResult(r)));
check(wb(2) - tr.g10(3) < 0.1e-9 && wb(1) > tr.offs(2), 'diode window: after the settled turn-off, ends at the next V_GS 10 %');
r = run("IfDiode", col, ev, al, tl, cfg, [4 5], "break");
check(r.methodId == "inductorDuringBreak" && abs(r.value - truthMean(tr, tr.IL, wb)) < 1e-6, sprintf('I_F = I_L: %s', formatResult(r)));
r = run("PcondDiode", col, ev, al, tl, cfg, [4 5], "break");
check(abs(r.value - truthMean(tr, -tr.vdsHS .* tr.IL, wb)) / r.value < 1e-6, sprintf('P_cond diode: %s', formatResult(r)));
Sd = dptSettings(struct('report', base.report, 'measurements', struct('enableOptional', "all", ...
    'methods', struct('onStateWindow', "delayToEnd", 'RonEff', "timeResolved"), ...
    'params', struct('RonEff', struct('delays', [0.5e-6, 2e-6])))));
r = run("VdsOn", col, ev, al, tl, cfg, [3 4], "pulse", Sd);
check(r.status == "ok" && r.provenance.window(2) - r.provenance.window(1) > 4e-6, sprintf('delayToEnd window: %s', formatResult(r)));
r = run("RonEff", col, ev, al, tl, cfg, [3 4], "pulse", Sd);
check(numel(r) == 2 && all(abs([r.value] - tr.Ron) < 1e-9) && r(2).provenance.delay == 2e-6, ...
    'time-resolved R_on: one result per delay');
r = run("VdsOn", col, ev, al, tl, cfg, [3 4], "pulse", dptSettings(struct('report', base.report)));
check(r.status == "skipped" && contains(r.reason, "not enabled"), 'optional measurement skipped unless enabled');

%% Method fallback and skipping by available signals ------------------------------
fB = fullfile(root, 'bucketB', 'B');
trB = makeSyntheticDPT(fB, struct('channels', ["Vgs-LS", "Vds-LS", "Id-LS"]));
[colB, evB, alB, tlB, cfgB] = pipeline(fB, S);
r = run("Ion", colB, evB, alB, tlB, cfgB, 3, "turnOn");
check(r.methodId == "extrapolatedId" && abs(r.value - truthAt(trB, trB.IL, trB.g10(2))) < 1, ...
    sprintf('no Iout: I_on falls back to extrapolated I_D: %s', formatResult(r)));
r = run("VdcOff", colB, evB, alB, tlB, cfgB, 4, "turnOff");
check(r.methodId == "model" && contains(r.methodTag, "constant"), ...
    sprintf('no Vdc channel, one V_DS, no C: V_DC(t) constant: %s', formatResult(r)));
r = run("VdsOn", colB, evB, alB, tlB, cfgB, [3 4], "pulse");
check(r.provenance.signals.V == "Vds-LS", 'no clamp channel: full-range V_DS used');
r = run("Vf", colB, evB, alB, tlB, cfgB, [4 5], "break");
check(r.methodId == "busModel" && any(r.flags == "modelBased"), ...
    sprintf('no non-active V_DS: V_F falls back to V_DS - V_DC(t): %s', formatResult(r)));

%% Current-sensor normalization ----------------------------------------------------
fN = fullfile(root, 'bucketN', 'N');
trN = makeSyntheticDPT(fN, struct('idGain', 0.95, 'idOffset', 1.5));
rng(4);
colN = pipeline(fN, S, true);
nz = colN.normalization;
check(nz.applied && abs(nz.gain - 1 / 0.95) < 1e-4 && abs(nz.offset + 1.5 / 0.95) < 1e-3, ...
    sprintf('Id sensor error (x0.95 + 1.5 A) recovered: k = %.5f, b = %.4f', nz.gain, nz.offset));
[colN, evN, alN, tlN, cfgN] = pipeline(fN, S, true);
r = run("IdOn", colN, evN, alN, tlN, cfgN, [3 4], "pulse");
w = r.provenance.window + tlN.edges.time(3) + alN.offset;
check(abs(r.value - truthMean(trN, trN.id, w)) < 1e-3 && r.provenance.currentsNormalized, ...
    'after normalization I_D(on) equals the true current');
colR = pipeline(fN, S, true, "Id");
check(colR.normalization.applied && colR.normalization.adjusted == "Iout" && abs(colR.normalization.gain - 0.95) < 1e-4, ...
    'reference "Id": the Iout channel is adjusted instead');

makeSyntheticDPT(fullfile(root, 'bucketC', 'C'), struct('idClip', 120));
colC = pipeline(fullfile(root, 'bucketC', 'C'), S, true);
check(~colC.normalization.applied && contains(colC.normalization.reason, "non-linearly"), ...
    sprintf('saturating sensor refused: %s', colC.normalization.reason));
makeSyntheticDPT(fullfile(root, 'bucketI', 'I'), struct('idInvert', true));
colI = pipeline(fullfile(root, 'bucketI', 'I'), S, true);
check(~colI.normalization.applied && contains(colI.normalization.reason, "polarity"), 'inverted sensor refused');
makeSyntheticDPT(fullfile(root, 'bucketS', 'S1'), struct('ons', 0, 'span', [-2e-6 10e-6]));
colS = pipeline(fullfile(root, 'bucketS', 'S1'), S, true);
check(~colS.normalization.applied && contains(colS.normalization.reason, "two pulses"), 'single pulse refused');
colB2 = pipeline(fB, S, true);
check(~colB2.normalization.applied && contains(colB2.normalization.reason, "lacks Iout"), 'missing Iout: not applied, reported');

%% Example record ---------------------------------------------------------------------
cfgX = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", 'deviceType', "MOSFET", ...
    'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
    'currentNormalization', struct('enable', true)), S, codeDir);
colX = importCollection(fullfile(cfgX.bucketPath, 'collection_A'), cfgX, S);
evX = detectGateTransitions(colX, cfgX, S); alX = alignCollections(evX, S); tlX = buildPulseTimeline(evX, alX, cfgX, S);
colX = normalizeCurrentSensors(colX, 1, alX, tlX, cfgX, S);
check(colX.normalization.applied && abs(colX.normalization.gain - 1.069) < 0.002, 'example: normalization applied, k = 1.069');
P = tlX.pulses;
gap = zeros(1, height(P) - 1);
for p = 1:height(P) - 1
    a = run("Ioff", colX, evX, alX, tlX, cfgX, P.turnOffEdge(p), "turnOff");
    b = run("Ion", colX, evX, alX, tlX, cfgX, P.turnOnEdge(p + 1), "turnOn");
    gap(p) = b.value - a.value;
end
fprintf('      example I_on(k+1) - I_off(k): %s A\n', sprintf('%.2f ', gap));
check(all(abs(gap) < 4), 'example: current changes < 4 A across each pulse break');
r = run("Ion", colX, evX, alX, tlX, cfgX, P.turnOnEdge(1), "turnOn");
check(any(r.flags == "belowNoiseFloor"), sprintf('example pulse 1 turn-on flagged: %s', formatResult(r)));
r = run("VdsOn", colX, evX, alX, tlX, cfgX, [P.turnOnEdge(9), P.turnOffEdge(9)], "pulse");
check(any(r.flags == "resolutionLimited"), sprintf('example V_DS(on) on the 2.8 V-step channel flagged: %s', formatResult(r)));
r = run("PcondDevice", colX, evX, alX, tlX, cfgX, [P.turnOnEdge(9), P.turnOffEdge(9)], "pulse");
check(any(r.flags == "resolutionLimited"), 'example device P_cond inherits the V_DS resolution flag');

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end
