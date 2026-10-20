function test_energy(root)
%TEST_ENERGY Informal tests of Batch 5e: switching energy and power #5-12
%   (formalized in Batch 7). Synthetic truth (makeSyntheticDPT: V and I
%   switch with one tanh, tauS = 5 ns, so the IEC-8 E_on and E_off are
%   0.4 * V0 * I_L * tauS), method sets, composites and fallbacks, and
%   physical consistency on the example record.
%   test_energy(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_energy');
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
    function res = pipeline(bucket, fs, Sx)
        if nargin < 3, Sx = S; end
        cfg = validateBucketConfig(struct('bucketPath', string(bucket), 'activeDevice', "LS", ...
            'deviceType', "MOSFET", 'expectedPulseCount', [], ...
            'gate', struct('nominal', struct('high', 18, 'low', -5)), 'switchingFrequency', fs), Sx, codeDir);
        res = runPipeline(cfg, Sx);
    end
    function r = run(res, id, edgeIds, kind, Sx)
        if nargin < 5, Sx = S; end
        ctx = eventContext(res.collections(1), 1, res.evs(1), res.al, res.tl, edgeIds, kind, res.cfg);
        r = evaluateMeasurement(def(id), ctx, Sx);
    end
    function E = truthIntegral(tr, p, w)
        % Same interpolated limits as the implementation (integrateBetween).
        E = integrateBetween(tr.t, p, w(1), w(2));
    end
    function w = absWindow(res, r)
        w = r.provenance.window + res.tl.edges.time(r.edgeIds(1)) + res.al.offset;
    end

b1 = fullfile(root, 'syn');
tr = makeSyntheticDPT(fullfile(b1, 'A'), struct('channels', ...
    ["Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vdc", "Vds-HS", "Id-HS"]));
res = pipeline(b1, 20e3);
on2 = 3; off2 = 4; tauS = 5e-9;
pLS = tr.vdsLS .* tr.id;
pHS = tr.vdsHS .* (-(1 - tr.s) .* tr.IL);

%% E_on / E_off (#5, #6)
r = run(res, "Eon", on2, "turnOn");
w = absWindow(res, r);
V0 = interp1(tr.t, tr.vdsLS, w(1) - 50e-9);  I0 = interp1(tr.t, tr.IL, w(1));
check(abs(r.value / truthIntegral(tr, pLS, w) - 1) < 0.002, sprintf('E_on IEC-8 = integral over its window: %s', formatResult(r)));
check(abs(r.value / (0.4 * V0 * I0 * tauS) - 1) < 0.02, sprintf('E_on IEC-8 vs analytic 0.4 V0 I tauS = %.4g uJ', 0.4 * V0 * I0 * tauS * 1e6));
r = run(res, "Eoff", off2, "turnOff");
w = absWindow(res, r);
V0 = interp1(tr.t, tr.vdsLS, w(2) + 50e-9);  I0 = interp1(tr.t, tr.IL, w(1));
check(abs(r.value / (0.4 * V0 * I0 * tauS) - 1) < 0.02, sprintf('E_off IEC-8 vs analytic: %s (%.4g uJ)', ...
    formatResult(r), 0.4 * V0 * I0 * tauS * 1e6));
S9 = dptSettings(struct('report', base.report, 'measurements', struct('preset', "IEC-9")));
r9 = run(res, "Eon", on2, "turnOn", S9);
check(r9.status == "ok" && any(r9.flags == "methodDeviceMismatch") && r9.value > run(res, "Eon", on2, "turnOn").value, ...
    sprintf('IEC-9 E_on (V_GS 10 %% to V_DS 2 %% of V_DC) is wider, so larger: %s', formatResult(r9)));
Sf = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('Eon', "fixed"))));
r = run(res, "Eon", on2, "turnOn", Sf);
check(r.status == "failed" && contains(r.reason, "territory"), 'fixed 10 us window past the territory: refused');
Sf1 = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('Eon', "fixed"), ...
    'params', struct('energy', struct('fixedDuration', 1e-6)))));
r = run(res, "Eon", on2, "turnOn", Sf1);
check(r.status == "ok" && abs(diff(r.provenance.window) - 1e-6) < 1e-12, sprintf('fixed 1 us window: %s', formatResult(r)));

%% E_sw (#7) and method sets
eOn = run(res, "Eon", on2, "turnOn"); eOffPrev = run(res, "Eoff", 2, "turnOff");
r = run(res, "Esw", [2, on2], "pair");
check(abs(r.value - (eOn.value + eOffPrev.value)) < 1e-15 && contains(r.methodTag, "IEC 60747-8"), ...
    sprintf('E_sw = E_off(k) + E_on(k+1): %s', formatResult(r)));
Smix = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('Eon', "IEC9", 'Eoff', "IEC8"))));
r = run(res, "Esw", [2, on2], "pair", Smix);
check(r.status == "failed" && contains(r.reason, "different method sets"), 'mixed method sets refused');
Sconv = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('Eon', "convI10V2", 'Eoff', "convV10I2"))));
check(run(res, "Esw", [2, on2], "pair", Sconv).status == "ok", 'matching conventional pair accepted');

%% E_io (#8), E_sw,N (#9)
r = run(res, "Eio", on2, "turnOn");
w = absWindow(res, r);
check(abs(r.value / truthIntegral(tr, pLS + pHS, w) - 1) < 0.005 && contains(r.methodTag, "bus channel"), ...
    sprintf('E_io = integral of P_LS + P_HS over its window: %s', formatResult(r)));
rp = run(res, "EioPair", [2, on2], "pair");
w = absWindow(res, rp);
check(abs(rp.value / truthIntegral(tr, pLS + pHS, w) - 1) < 0.005, sprintf('E_io across both events: %s', formatResult(rp)));
r = run(res, "EswNonActive", on2, "turnOn");
w = absWindow(res, r);
check(r.methodId == "direct" && abs(r.value - truthIntegral(tr, pHS, w)) < 1e-3 * abs(r.value) + 1e-9, ...
    sprintf('E_sw,N direct = integral of V_DS,HS * I_D,HS over the E_on window: %s', formatResult(r)));
Si = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('EswNonActive', "indirect"))));
r = run(res, "EswNonActive", on2, "turnOn", Si);
check(abs(r.value - (run(res, "Eio", on2, "turnOn").value - eOn.value)) < 1e-15, 'E_sw,N indirect = E_io - E_on');

%% P_on / P_off (#10, #11), P_sw (#12)
r = run(res, "Pon", on2, "turnOn");
check(abs(r.value - eOn.value / diff(eOn.provenance.window)) < 1e-9 * r.value, sprintf('P_on = E_on / window: %s', formatResult(r)));
Sp = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('Pon', "peak"))));
r = run(res, "Pon", on2, "turnOn", Sp);
check(abs(r.value / (0.25 * interp1(tr.t, tr.vdsLS, absWindow(res, eOn) * [1; 0] - 50e-9) * ...
    interp1(tr.t, tr.IL, absWindow(res, eOn) * [1; 0])) - 1) < 0.02, sprintf('P_on peak = V0 I / 4 at s = 0.5: %s', formatResult(r)));
r = run(res, "Psw", [2, on2], "pair");
check(abs(r.value - 20e3 * (eOn.value + eOffPrev.value)) < 1e-9 * r.value, sprintf('P_sw = f_s E_sw: %s', formatResult(r)));
resNoF = pipeline(b1, []);
r = run(resNoF, "Psw", [2, on2], "pair");
check(r.status == "skipped" && contains(r.reason, "switchingFrequency"), 'P_sw without cfg.switchingFrequency: skipped');

%% Example record: physical consistency
cfgX = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", 'deviceType', "MOSFET", ...
    'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
    'zeroOffsetCorrection', struct('enable', true), 'currentNormalization', struct('enable', true)), S, codeDir);
resX = runPipeline(cfgX, S);
P = resX.tl.pulses;
% E_io adds the HS device's losses, so at pair level (the spec's built-in
% check) E_io,off(k) + E_io,on(k+1) should not fall below E_sw. Per event
% this is not guaranteed: E_io is a small difference of two ~140 mJ
% integrals, so a 1 % probe mismatch moves it by ~1.4 mJ.
okIo = true; okSum = true; grows = true; prevOn = 0; ratio = zeros(1, height(P) - 1);
for p = 2:height(P)
    a = run(resX, "Eon", P.turnOnEdge(p), "turnOn"); b = run(resX, "Eio", P.turnOnEdge(p), "turnOn");
    grows = grows && a.value > prevOn;
    prevOn = a.value;
    c = run(resX, "Eoff", P.turnOffEdge(p - 1), "turnOff"); d = run(resX, "Esw", [P.turnOffEdge(p - 1), P.turnOnEdge(p)], "pair");
    okSum = okSum && abs(d.value - (a.value + c.value)) < 1e-15;
    e = run(resX, "Eio", P.turnOffEdge(p - 1), "turnOff");
    ratio(p - 1) = (b.value + e.value) / d.value;
    okIo = okIo && ratio(p - 1) >= 0.99;
end
fprintf('      example (E_io,off + E_io,on) / E_sw per pair: %s\n', sprintf('%.3f ', ratio));
check(okIo, 'example, every pair: E_io (both events) >= E_sw (adds the HS device''s losses)');
check(grows, 'example: E_on grows monotonically with current over pulses 2-10');
check(okSum, 'example: E_sw = E_off(k) + E_on(k+1) on every pair');
r1 = run(resX, "Eon", P.turnOnEdge(1), "turnOn");
r1g = run(resX, "Eon", P.turnOnEdge(1), "turnOn", S9);
check(r1.status == "failed" && contains(r1.reason, "noise floor") && r1g.status == "ok", sprintf( ...
    'example zero-current pulse 1: IEC-8 E_on refused (current threshold), IEC-9 gives %s', formatResult(r1g)));
% Noise-limited fallback (design 17.5) never moves to the other device's
% standard: the refusal keeps the IEC-8 reason and lists the Conv methods.
check(startsWith(r1.methodTag, "IEC 60747-8") && contains(r1.reason, "also tried") && ...
    ~contains(r1.reason, "IEC9") && ~any(r1.flags == "methodDeviceMismatch"), ...
    'example pulse 1: fallback skips IEC-9 on a MOSFET, keeps the IEC-8 refusal');

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end
