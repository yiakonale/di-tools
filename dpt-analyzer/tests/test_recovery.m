function test_recovery(root)
%TEST_RECOVERY Informal tests of Batch 5g: reverse recovery #39-46 and the
%   phase-leg P_sw (formalized in Batch 7). Synthetic truth
%   (makeSyntheticDPT with a recovery hump on the HS diode), evaluated by
%   independent code on the noise-free diode current; measured against
%   derived diode current; the Q5 refusal; eligibility; the example.
%   test_recovery(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_recovery');
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

R = measurementRegistry();
def = @(id) R([R.id] == id);
base = struct('report', struct('echoWarnings', false));
S = dptSettings(base);
    function res = pipeline(bucket, extra)
        c = struct('bucketPath', string(bucket), 'activeDevice', "LS", 'deviceType', "MOSFET", ...
            'expectedPulseCount', [], 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
            'switchingFrequency', 20e3);
        if nargin > 1
            for f = string(fieldnames(extra))'
                c.(f) = extra.(f);
            end
        end
        res = runPipeline(validateBucketConfig(c, S, codeDir), S);
    end
    function r = run(res, id, edgeIds, kind, Sx)
        if nargin < 5, Sx = S; end
        ctx = eventContext(res.collections(1), 1, res.evs(1), res.al, res.tl, edgeIds, kind, res.cfg);
        r = evaluateMeasurement(def(id), ctx, Sx);
    end
    function Sx = with(id, m, params)
        o = base;
        if id ~= "", o.measurements.methods.(id) = m; end
        if nargin > 2, o.measurements.params = params; end
        Sx = dptSettings(o);
    end
    function t = rel(res, edgeId, tAbs)
        % Truth time (universal = collection time for one collection) relative to the edge.
        t = tAbs - res.tl.edges.time(edgeId) - res.al.offset;
    end
    function c = crossAfter(t, x, level, dir, t0, t1)
        % Independent interpolated crossing (truth side).
        m = find(t >= t0 & t <= t1);
        c = NaN;
        for j = m(1):m(end) - 1
            if (dir == "rising" && x(j) < level && x(j + 1) >= level) || ...
                    (dir == "falling" && x(j) > level && x(j + 1) <= level)
                c = t(j) + (level - x(j)) / (x(j + 1) - x(j)) * (t(j + 1) - t(j));
                return
            end
        end
    end
    function v = integ(t, y, a, b)
        % Trapezoid with linear end interpolation (truth side).
        m = t > a & t < b;
        tt = [a; t(m); b];
        yy = [interp1(t, y, a); y(m); interp1(t, y, b)];
        v = trapz(tt, yy);
    end

%% Synthetic: measured diode current (Id-HS) ------------------------------------
A = 15; rec = [A, 3e-9, 6e-9, 10e-9];
chans = ["Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vdc", "Vds-HS", "Id-HS"];
b1 = fullfile(root, 'measured');
tr = makeSyntheticDPT(fullfile(b1, 'A'), struct('channels', chans, 'dt', 0.2e-9, 'recovery', rec));
res = pipeline(b1);
P = res.tl.pulses;
on2 = P.turnOnEdge(2);  k2 = 2;

% Truth on the noise-free diode current
g10 = tr.g10(k2);
t0 = crossAfter(tr.t, tr.iF, 0, "falling", g10, g10 + 200e-9);
m = tr.t >= t0 & tr.t <= t0 + 200e-9;
[mn, j] = min(tr.iF(m)); tm = tr.t(m); tp = tm(j); Irrm = -mn;
tAt = @(p) crossAfter(tr.t, tr.iF, -p * Irrm, "rising", tp, tp + 300e-9);
t90 = tAt(0.9); t25 = tAt(0.25); t02 = tAt(0.02);
endIEC = t25 + (t25 - t90) * 0.25 / 0.65;
endJEDEC = t25 + (t25 - tp) * 0.25 / 0.75;
tc = tr.ons(k2) + tr.tdOn + rec(4);
IrrmAnalytic = A - interp1(tr.t, (1 - tr.s) .* tr.IL, tc);

r = run(res, "Irrm", on2, "turnOn");
check(r.status == "ok" && abs(r.value - Irrm) < 1e-9 && contains(r.methodTag, "-I_D,N"), ...
    sprintf('I_rrm raw = truth %.3f A (measured diode current): %s', Irrm, formatResult(r)));
check(abs(r.value - IrrmAnalytic) < 0.5, sprintf('I_rrm vs analytic A - (1-s) I_L at the hump peak = %.2f A', IrrmAnalytic));
check(abs(r.provenance.zeroCrossing - rel(res, on2, t0)) < 1e-12 && abs(r.provenance.peakTime - rel(res, on2, tp)) < 1e-12, ...
    'zero crossing and peak time = truth');
rs = run(res, "Irrm", on2, "turnOn", with("Irrm", "smoothed"));
check(rs.status == "ok" && rs.value <= r.value + 1e-9 && rs.value > 0.97 * r.value && contains(rs.methodTag, "Savitzky-Golay"), ...
    sprintf('smoothed I_rrm slightly below raw, filter stated: %s', formatResult(rs)));
r = run(res, "ta", on2, "turnOn");
check(abs(r.value - (tp - t0)) < 1e-12, sprintf('t_a = truth %.3f ns: %s', (tp - t0) * 1e9, formatResult(r)));

r = run(res, "trr", on2, "turnOn");
check(r.status == "ok" && abs(r.value - (endIEC - t0)) < 1e-12 && contains(r.methodTag, "IEC 60747-2"), ...
    sprintf('t_rr IEC-2 (preset) = truth %.3f ns: %s', (endIEC - t0) * 1e9, formatResult(r)));
r = run(res, "trr", on2, "turnOn", with("trr", "JEDEC"));
check(abs(r.value - (endJEDEC - t0)) < 1e-12, sprintf('t_rr JEDEC = truth %.3f ns', (endJEDEC - t0) * 1e9));
r = run(res, "trr", on2, "turnOn", with("trr", "conv25"));
check(abs(r.value - (t25 - t0)) < 1e-12, sprintf('t_rr 25 %% direct = truth %.3f ns', (t25 - t0) * 1e9));
r = run(res, "trr", on2, "turnOn", with("trr", "zero2"));
check(r.status == "failed" && contains(r.reason, "does not cross zero again"), ...
    'second zero crossing: none for a soft recovery, refused');
r = run(res, "trr", on2, "turnOn", with("trr", "custom"));
check(r.status == "skipped", 'custom t_rr without levels: skipped');
rc = run(res, "trr", on2, "turnOn", with("trr", "custom", struct('custom', struct('trrLevels', [0.9 0.25]))));
check(abs(rc.value - (endIEC - t0)) < 1e-12, 'custom levels [0.9 0.25] = IEC-2');
rb = run(res, "tb", on2, "turnOn");
check(abs(rb.value - (endIEC - tp)) < 1e-12 && contains(rb.methodTag, "IEC 60747-2"), ...
    sprintf('t_b inherits the #40 method: %s', formatResult(rb)));
rS = run(res, "Srr", on2, "turnOn");
check(abs(rS.value - (endIEC - tp) / (tp - t0)) < 1e-9, sprintf('S = t_b / t_a: %s', formatResult(rS)));
rS = run(res, "Srr", on2, "turnOn", with("Srr", "IEC2"));
check(rS.status == "skipped" && contains(rS.reason, "deferred"), 'IEC-2 S_rr: deferred (skipped)');

Qt = integ(tr.t, -tr.iF, t0, t02);
r = run(res, "Qrr", on2, "turnOn");
check(r.status == "ok" && abs(r.value / Qt - 1) < 1e-6, sprintf('Q_rr IEC-2 (to 2 %% of I_rrm) = truth %.4g nC: %s', Qt * 1e9, formatResult(r)));
r = run(res, "Qrr", on2, "turnOn", with("Qrr", "trrEnd"));
check(abs(r.value / integ(tr.t, -tr.iF, t0, endIEC) - 1) < 1e-6, 'Q_rr to the t_rr end = truth');
r = run(res, "Qrr", on2, "turnOn", with("Qrr", "triangle"));
check(abs(r.value - (endIEC - t0) * Irrm / 2) < 1e-15, sprintf('Q_rr triangle = t_rr I_rrm / 2: %s', formatResult(r)));
r = run(res, "Qrr", on2, "turnOn", with("Qrr", "custom", struct('custom', struct('recoveryEnd', 0.02))));
check(abs(r.value / Qt - 1) < 1e-6, 'custom end 2 % = IEC-2');
r = run(res, "Qrr", on2, "turnOn", with("Qrr", "custom", struct('custom', struct('recoveryDuration', 20e-9))));
check(abs(r.value / integ(tr.t, -tr.iF, t0, t0 + 20e-9) - 1) < 1e-6, 'custom 20 ns duration = truth');

pF = (-tr.vdsHS) .* tr.iF;                         % diode v_F * i_F
Et = integ(tr.t, pF, t0, t02);
r = run(res, "Err", on2, "turnOn");
check(r.status == "ok" && r.value > 0 && abs(r.value / Et - 1) < 1e-6, ...
    sprintf('E_rr IEC-2 = truth %.4g uJ: %s', Et * 1e6, formatResult(r)));
v10 = crossAfter(tr.t, tr.vdsHS, 0.1 * interp1(tr.t, tr.vdc, g10), "rising", g10, t02);
r = run(res, "Err", on2, "turnOn", with("Err", "vdc10"));
check(r.status == "ok" && abs(r.value / integ(tr.t, pF, v10, t02) - 1) < 2e-3, ...
    sprintf('E_rr from V_F at 10 %% of V_DC = truth: %s', formatResult(r)));

r = run(res, "didtRR", on2, "turnOn");
ta_ = crossAfter(tr.t, tr.iF, 0.5 * interp1(tr.t, tr.iF, g10), "falling", g10, t0 + 1e-12);
tb_ = crossAfter(tr.t, tr.iF, -0.5 * Irrm, "falling", t0, tp);
mm = tr.t >= ta_ & tr.t <= tb_;
cf = [tr.t(mm) - mean(tr.t(mm)), ones(nnz(mm), 1)] \ tr.iF(mm);
check(r.status == "ok" && abs(r.value / abs(cf(1)) - 1) < 0.02, sprintf('di_F/dt through zero = truth %.3g A/ns: %s', ...
    abs(cf(1)) * 1e-9, formatResult(r)));
r = run(res, "didtRR", on2, "turnOn", with("didtRR", "peakTb"));
check(r.status == "ok" && r.value > 0 && contains(r.methodTag, "Savitzky-Golay"), sprintf('peak di/dt in t_b: %s', formatResult(r)));

r = run(res, "Irrm", P.turnOnEdge(1), "turnOn");
check(r.status == "skipped" && contains(r.reason, "no forward diode current"), ...
    'pulse 1 (no freewheeling current before it): skipped');

rp = run(res, "Psw", [P.turnOffEdge(1), on2], "pair", with("Psw", "phaseLeg"));
es = run(res, "Esw", [P.turnOffEdge(1), on2], "pair");
er = run(res, "Err", on2, "turnOn");
check(rp.status == "ok" && abs(rp.value - 20e3 * (es.value + er.value)) < 1e-9, ...
    sprintf('P_sw phase leg = f_s (E_sw + E_rr): %s', formatResult(rp)));

%% Synthetic: derived diode current (no Id-HS) -----------------------------------
b2 = fullfile(root, 'derived');
makeSyntheticDPT(fullfile(b2, 'A'), struct('channels', chans(1:end - 1), 'dt', 0.2e-9, 'recovery', rec));
r = run(pipeline(b2), "Irrm", on2, "turnOn");
check(r.status == "skipped" && contains(r.reason, "allowDerived"), 'no Id-HS, derived not allowed: skipped');
res2 = pipeline(b2, struct('diodeCurrent', struct('allowDerived', true)));
r = run(res2, "Irrm", on2, "turnOn");
check(r.status == "ok" && abs(r.value - Irrm) < 0.3 && contains(r.methodTag, "I_L - I_D"), ...
    sprintf('derived I_rrm within 0.3 A of the measured (smooth I_L): %s', formatResult(r)));
r = run(res2, "trr", on2, "turnOn");
check(r.status == "ok" && abs(r.value - (endIEC - t0)) < 0.3e-9, sprintf('derived t_rr within 0.3 ns: %s', formatResult(r)));
r = run(res2, "Qrr", on2, "turnOn");
check(r.status == "ok" && abs(r.value / Qt - 1) < 0.03, sprintf('derived Q_rr within 3 %%: %s', formatResult(r)));

b3 = fullfile(root, 'gainError');
makeSyntheticDPT(fullfile(b3, 'A'), struct('channels', chans(1:end - 1), 'dt', 0.2e-9, 'recovery', rec, 'idGain', 1.1));
r = run(pipeline(b3, struct('diodeCurrent', struct('allowDerived', true))), "Irrm", on2, "turnOn");
check(r.status == "failed" && contains(r.reason, "refused"), ...
    sprintf('Id-LS 10 %% high, derived: refused (Q5): %s', r.reason));
r = run(pipeline(b3, struct('diodeCurrent', struct('allowDerived', true), ...
    'currentNormalization', struct('enable', true))), "Irrm", on2, "turnOn");
check(r.status == "ok" && abs(r.value - Irrm) < 0.5, sprintf('with current normalization: accepted, %s', formatResult(r)));

%% Example (derived, normalization on) --------------------------------------------
ex = fullfile(codeDir, 'data', 'example');
if isfolder(ex)
    cfg = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", 'deviceType', "MOSFET", ...
        'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
        'zeroOffsetCorrection', struct('enable', true), 'currentNormalization', struct('enable', true), ...
        'diodeCurrent', struct('allowDerived', true)), S, codeDir);
    rx = runPipeline(cfg, S);
    P = rx.tl.pulses;
    okI = true; okJ = true; okX = true; txt = "";
    for p = 2:9
        i = run(rx, "Irrm", P.turnOnEdge(p), "turnOn");
        j = run(rx, "trr", P.turnOnEdge(p), "turnOn", with("trr", "JEDEC"));
        o = run(rx, "dIdOver", P.turnOnEdge(p), "turnOn");
        okI = okI && i.status == "ok" && i.value > 20 && i.value < 50;
        okJ = okJ && j.status == "ok" && j.value > 15e-9 && j.value < 60e-9;
        % Built-in check of the spec: dI_D,over at turn-on ~ I_rrm.
        okX = okX && abs(o.value - i.value) < 10;
        txt = txt + sprintf(' %.1f', i.value);
    end
    check(okI, "example: I_rrm 20-50 A on pulses 2-9 (A:" + txt + ")");
    check(okJ, 'example: JEDEC t_rr 15-60 ns on pulses 2-9');
    check(okX, 'example: dI_D,over within 10 A of I_rrm (spec built-in check)');
    r = run(rx, "trr", P.turnOnEdge(3), "turnOn");
    check(r.status == "failed" && contains(r.reason, "noise floor"), ...
        sprintf('example: IEC-2 t_rr refused, 90 %% of I_rrm within the noise (%s)', r.reason));
    r = run(rx, "Irrm", P.turnOnEdge(10), "turnOn");
    check(r.status == "failed" && contains(r.reason, "refused"), ...
        'example: pulse 10 derived current refused (I_D sensor drift, Q5)');
end

fprintf('\n%d passed, %d failed\n', nPass, nFail);
if nFail > 0
    error('test_recovery:failed', '%d test(s) failed.', nFail);
end
end
