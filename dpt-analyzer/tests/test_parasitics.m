function test_parasitics(root)
%TEST_PARASITICS Informal tests of Batch 5h: loop inductance #47, output
%   charge #48 and parasitic capacitance #55 (formalized in Batch 7).
%   Synthetic truth (makeSyntheticDPT with V-I phase shift, loop
%   inductance, HS output capacitance and V_DS ringing), event-specific
%   methods, the skipped-method fall-through, and example consistency.
%   test_parasitics(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_parasitics');
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
base = struct('report', struct('echoWarnings', false), 'measurements', struct('enableOptional', "all"));
S = dptSettings(base);
    function res = pipeline(bucket, extra)
        c = struct('bucketPath', string(bucket), 'activeDevice', "LS", 'deviceType', "MOSFET", ...
            'expectedPulseCount', [], 'gate', struct('nominal', struct('high', 18, 'low', -5)));
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
    function Sx = with(id, m, optional)
        o = base;
        o.measurements.methods.(id) = m;
        if nargin > 2, o.measurements.enableOptional = optional; end
        Sx = dptSettings(o);
    end

L0 = 20e-9; C0 = 1e-9;
chans = ["Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vdc", "Vds-HS", "Id-HS"];
opt = struct('channels', chans, 'dt', 0.2e-9, 'vShift', [25e-9 25e-9], 'Lloop', L0, 'CossHS', C0);

%% Synthetic without ringing: dip, overshoot, Q_oss, charge-based C -------------
b1 = fullfile(root, 'plain');
tr = makeSyntheticDPT(fullfile(b1, 'A'), opt);
res = pipeline(b1);
P = res.tl.pulses;
on2 = P.turnOnEdge(2); off2 = P.turnOffEdge(2);

r = run(res, "Lloop", on2, "turnOn");
check(r.status == "ok" && r.methodId == "dip" && abs(r.value / L0 - 1) < 0.03, ...
    sprintf('L_loop turn-on dip = %.0f nH truth: %s', L0 * 1e9, formatResult(r)));
rv = run(res, "Lloop", on2, "turnOn", with("Lloop", "dipVdc"));
check(rv.status == "ok" && rv.value < r.value, sprintf('dip vs V_DC excludes V_F, so smaller: %s', formatResult(rv)));
r = run(res, "Lloop", off2, "turnOff");
check(r.status == "ok" && r.methodId == "overshoot" && ~any(r.flags == "methodFallback") && ...
    any(r.flags == "includesCapacitiveCharging"), ...
    'turn-off, no cfg C_oss: ringing skips itself, overshoot used (no fallback flag)');
check(r.value / L0 > 2, sprintf(['with 1 nF of HS C_oss the external I_D drops by C dV/dt before the current ' ...
    'fall, so the overshoot method overestimates L (spec: less reliable): %s'], formatResult(r)));
b5 = fullfile(root, 'noCoss');
o5 = opt; o5.CossHS = 0;
makeSyntheticDPT(fullfile(b5, 'A'), o5);
r = run(pipeline(b5), "Lloop", off2, "turnOff");
check(r.status == "ok" && r.methodId == "overshoot" && r.value / L0 > 1.2 && r.value / L0 < 1.5, ...
    sprintf('without C_oss currents: overshoot L ~1.37 L (peak vs average di/dt of a tanh edge): %s', formatResult(r)));
r = run(res, "Lloop", off2, "turnOff", with("Lloop", "dip"));
check(r.status == "skipped" && contains(r.reason, "turnOn event"), 'dip at a turn-off: not available (event-specific)');

% Q_oss at turn-off: purely capacitive, C * 98 % of V_DS,N
vPre = interp1(tr.t, tr.vdsHS, tr.offs(2) - 100e-9);
r = run(res, "Qoss", off2, "turnOff");
check(r.status == "ok" && r.methodId == "turnOffDischarge" && abs(r.value / (C0 * 0.98 * vPre) - 1) < 0.01, ...
    sprintf('Q_oss turn-off discharge = C 0.98 V = %.4g nC: %s', C0 * 0.98 * vPre * 1e9, formatResult(r)));
r = run(res, "Qoss", on2, "turnOn");
check(r.status == "ok" && r.methodId == "zeroTo90" && abs(r.value / (C0 * r.provenance.deltaV) - 1) < 0.02, ...
    sprintf('Q_oss turn-on (zero crossing to 90 %% of peak) = C dV: %s', formatResult(r)));
r = run(res, "Qoss", on2, "turnOn", with("Qoss", "preset", strings(1, 0)));
check(r.status == "skipped" && contains(r.reason, "optional"), 'Q_oss is optional: skipped unless enabled');
rc = run(res, "Cpar", off2, "turnOff", with("Cpar", "charge"));
check(rc.status == "ok" && abs(rc.value / C0 - 1) < 0.01, sprintf('C_par charge-based at turn-off = %.0f pF: %s', C0 * 1e12, formatResult(rc)));
rc = run(res, "Cpar", on2, "turnOn");
check(rc.status == "ok" && rc.methodId == "charge" && abs(rc.value / C0 - 1) < 0.02, ...
    sprintf('C_par at turn-on: LC unavailable, charge-based = C: %s', formatResult(rc)));

% Derived diode current (no Id-HS)
b2 = fullfile(root, 'derived');
o2 = opt; o2.channels = chans(1:end - 1);
makeSyntheticDPT(fullfile(b2, 'A'), o2);
res2 = pipeline(b2, struct('diodeCurrent', struct('allowDerived', true)));
r = run(res2, "Qoss", off2, "turnOff");
check(r.status == "ok" && abs(r.value / (C0 * 0.98 * vPre) - 1) < 0.03 && contains(r.methodTag, "I_L - I_D"), ...
    sprintf('derived: Q_oss turn-off within 3 %%: %s', formatResult(r)));

% V_DS collapsing during the current rise (no V-I shift): dip refused
b3 = fullfile(root, 'noShift');
o3 = opt; o3.vShift = [0 0];
makeSyntheticDPT(fullfile(b3, 'A'), o3);
r = run(pipeline(b3), "Lloop", on2, "turnOn");
check(r.status == "failed" && contains(r.reason, "collapses"), sprintf('V and I switching together: dip refused (%s)', r.reason));

%% Synthetic with turn-off ringing: ringing L, LC capacitance --------------------
f0 = 50e6;
b4 = fullfile(root, 'ringing');
o4 = opt; o4.ringV = [30, f0, 40e-9];
makeSyntheticDPT(fullfile(b4, 'A'), o4);
Ck = 500e-12;
res4 = pipeline(b4, struct('circuit', struct('Coss', Ck)));
r = run(res4, "Lloop", off2, "turnOff");
Lf = 1 / ((2 * pi * f0)^2 * Ck);
check(r.status == "ok" && r.methodId == "ringing" && abs(r.provenance.ringingFrequency / f0 - 1) < 0.01 && ...
    abs(r.value / Lf - 1) < 0.03 && contains(r.methodTag, "cfg.circuit.Coss"), ...
    sprintf('L_loop ringing with cfg C_oss: f_r = 50 MHz, L = %.2f nH: %s', Lf * 1e9, formatResult(r)));
r = run(pipeline(b5, struct('circuit', struct('Coss', Ck))), "Lloop", off2, "turnOff");
check(r.status == "ok" && r.methodId == "overshoot" && any(r.flags == "methodFallback") && ...
    r.provenance.fallbackFrom(1).method == "ringing" && contains(r.provenance.fallbackFrom(1).reason, "crossings"), ...
    'C_oss known but no ringing above the noise: noise-limited, falls back to overshoot (flagged)');
rl = run(res4, "Cpar", off2, "turnOff");
check(rl.status == "ok" && rl.methodId == "LC" && contains(rl.methodTag, "turn-on dip") && ...
    abs(rl.value - 1 / ((2 * pi * rl.provenance.ringingFrequency)^2 * rl.provenance.inductance)) < 1e-18 && ...
    abs(rl.provenance.inductance / L0 - 1) < 0.03, ...
    sprintf('C_par LC with L from the same pulse''s turn-on dip: %s', formatResult(rl)));

%% Example (derived, normalization on) --------------------------------------------
ex = fullfile(codeDir, 'data', 'example');
if isfolder(ex)
    cfg = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", 'deviceType', "MOSFET", ...
        'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
        'zeroOffsetCorrection', struct('enable', true), 'currentNormalization', struct('enable', true), ...
        'voltageNormalization', struct('enable', true), 'diodeCurrent', struct('allowDerived', true)), S, codeDir);
    rx = runPipeline(cfg, S);
    P = rx.tl.pulses;
    okD = true; okO = true; okC = true; okQ = true; txt = ""; txtO = '';
    for p = 2:8
        d = run(rx, "Lloop", P.turnOnEdge(p), "turnOn");
        o = run(rx, "Lloop", P.turnOffEdge(p), "turnOff", with("Lloop", "overshoot"));
        c = run(rx, "Cpar", P.turnOffEdge(p), "turnOff");
        okD = okD && d.status == "ok" && d.value > 4e-9 && d.value < 12e-9;
        okO = okO && o.status == "ok" && abs(o.value / d.value - 1) < 0.25;
        txtO = sprintf('%s %.1f', txtO, o.value * 1e9);
        okC = okC && c.status == "ok" && c.value > 1e-9 && c.value < 2.5e-9;
        txt = txt + sprintf(' %.1f', d.value * 1e9);
        if p >= 3 && p <= 6
            qn = run(rx, "Qoss", P.turnOnEdge(p), "turnOn");
            qf = run(rx, "Qoss", P.turnOffEdge(p), "turnOff");
            okQ = okQ && qf.status == "ok" && qf.value > 200e-9 && qf.value < 500e-9 && qn.value > qf.value;
        end
    end
    check(okD, "example: L_loop dip 4-12 nH on pulses 2-8 (nH:" + txt + ")");
    check(okO, "example: turn-off overshoot L within 25 % of the dip L (independent methods agree; nH:" + txtO + ")");
    check(okC, 'example: C_par LC 1-2.5 nF on pulses 2-8');
    check(okQ, ['example: turn-off Q_oss 200-500 nC on pulses 3-6, below the turn-on charge ' ...
        '(which includes recovery)']);
end

fprintf('\n%d passed, %d failed\n', nPass, nFail);
if nFail > 0
    error('test_parasitics:failed', '%d test(s) failed.', nFail);
end
end
