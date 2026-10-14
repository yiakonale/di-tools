function test_timing(root)
%TEST_TIMING Informal tests of Batch 5d: timing #13-23, slew rates #24-28,
%   presets (formalized in Batch 7). Analytic truth on synthetic edges
%   (makeSyntheticDPT: tanh gate tau = 20 ns, tanh switch tauS = 5 ns,
%   delays 30 / 60 ns), preset and custom-method behaviour, and
%   consistency checks on the example record.
%   test_timing(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_timing');
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
    function res = pipeline(bucket, device, Sx)
        cfg = validateBucketConfig(struct('bucketPath', string(bucket), 'activeDevice', "LS", ...
            'deviceType', device, 'expectedPulseCount', [], ...
            'gate', struct('nominal', struct('high', 18, 'low', -5))), Sx, codeDir);
        res = runPipeline(cfg, Sx);
    end
    function r = run(res, id, edgeIds, kind, Sx)
        ctx = eventContext(res.collections(1), 1, res.evs(1), res.al, res.tl, edgeIds, kind, res.cfg);
        r = evaluateMeasurement(def(id), ctx, Sx);
    end
    function check_near(r, truth, tol, label)
        check(r.status == "ok" && abs(r.value - truth) <= tol, sprintf('%s: %s (truth %.4g)', ...
            label, formatResult(r), truth));
    end

S = dptSettings(base);
tau = 20e-9; tauS = 5e-9; a8 = atanh(0.8);
b1 = fullfile(root, 'sync');
makeSyntheticDPT(fullfile(b1, 'A'), struct('channels', ["Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vds-HS", "Vgs-HS"]));
res = pipeline(b1, "MOSFET", S);
on2 = 3; off2 = 4;                                   % pulse 2 edges

%% Timing against analytic truth (IEC-8 preset for a MOSFET)
check_near(run(res, "tdOn", on2, "turnOn", S), 30e-9 + (tau - tauS) * a8, 0.1e-9, 't_d(on) IEC-8');
check_near(run(res, "tdOff", off2, "turnOff", S), 60e-9 + (tau - tauS) * a8, 0.1e-9, 't_d(off) IEC-8');
check_near(run(res, "tvf", on2, "turnOn", S), 2 * tauS * a8, 0.1e-9, 't_vf IEC-8');
check_near(run(res, "tvr", off2, "turnOff", S), 2 * tauS * a8, 0.1e-9, 't_vr IEC-8');
check_near(run(res, "tir", on2, "turnOn", S), 2 * tauS * a8, 0.2e-9, 't_ir (Conv, MOSFET)');
check_near(run(res, "tif", off2, "turnOff", S), 2 * tauS * a8, 0.2e-9, 't_if (Conv, MOSFET)');
check_near(run(res, "tOn", on2, "turnOn", S), 30e-9 + (tau + tauS) * a8, 0.1e-9, 't_on IEC-8');
check_near(run(res, "tOff", off2, "turnOff", S), 60e-9 + (tau + tauS) * a8, 0.1e-9, 't_off IEC-8');
check_near(run(res, "tBreak", [off2, 5], "break", S), 4e-6, 0.1e-9, 't_break (V_GS 50 %)');
r = run(res, "tz", off2, "turnOff", S);
check(r.status == "skipped" && contains(r.reason, "IGBT"), 'tail time skipped on a MOSFET');

%% Slew rates
dV = 400;                                            % V_DS swing (V_DC + V_F - Ron I)
r = run(res, "dvdt", on2, "turnOn", S);
check(abs(r.value / (0.8 * r.provenance.levels(1) / (2 * tauS * a8)) - 1) < 0.01, ...
    sprintf('dv/dt 10-90 %% average: %s', formatResult(r)));
Sb = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('dvdt', "bandMax"))));
r = run(res, "dvdt", on2, "turnOn", Sb);
swing = abs(diff(r.provenance.levels));
check(abs(r.value / (0.2 * swing / (2 * tauS * atanh(0.2))) - 1) < 0.01 && contains(r.methodTag, "20 % band"), ...
    sprintf('dv/dt band maximum: %s', formatResult(r)));
r = run(res, "dvdtMax", on2, "turnOn", S);
check(abs(r.value / (swing / (2 * tauS)) - 1) < 0.03 && contains(r.methodTag, "Savitzky-Golay"), ...
    sprintf('max dv/dt vs analytic %.4g V/ns: %s', swing / (2 * tauS) * 1e-9, formatResult(r)));
r = run(res, "dvgsdt", on2, "turnOn", S);
check_near(r, 0.8 * 23 / (2 * tau * a8), 0.005 * 0.8 * 23 / (2 * tau * a8), 'dV_GS/dt 10-90 % (rising)');
r = run(res, "dvgsdt", off2, "turnOff", S);
check(r.status == "ok" && r.provenance.direction == "falling", sprintf('dV_GS/dt on the falling edge: %s', formatResult(r)));
r = run(res, "didt", off2, "turnOff", S);
check(r.status == "ok" && r.provenance.direction == "falling", sprintf('di/dt at turn-off (falling): %s', formatResult(r)));

%% Dead time (synchronous synthetic: 100 ns both ways)
r = run(res, "deadTime", on2, "turnOn", S);
check_near(r, 100e-9, 0.1e-9, 'dead time HS->LS at turn-on');
check(r.provenance.transition == "HS->LS", 'dead-time direction label at turn-on');
r = run(res, "deadTime", off2, "turnOff", S);
check_near(r, 100e-9, 0.1e-9, 'dead time LS->HS at turn-off');
b2 = fullfile(root, 'overlap');
makeSyntheticDPT(fullfile(b2, 'A'), struct('deadTime', -20e-9, 'channels', ["Vgs-LS", "Vds-LS", "Id-LS", "Vgs-HS"]));
r = run(pipeline(b2, "MOSFET", S), "deadTime", on2, "turnOn", S);
check(abs(r.value + 20e-9) < 0.1e-9 && any(r.flags == "negativeDeadTime"), 'gate overlap: negative dead time flagged');

%% Presets and overrides
S9 = dptSettings(struct('report', base.report, 'measurements', struct('preset', "IEC-9")));
r = run(res, "tdOn", on2, "turnOn", S9);
check(r.methodTag == "IEC 60747-9" && any(r.flags == "methodDeviceMismatch"), ...
    'IEC-9 preset on a MOSFET: IEC 60747-9 method, flagged methodDeviceMismatch');
check_near(r, 30e-9 + (tau - tauS) * a8, 0.2e-9, 't_d(on) IEC-9 (V_GS 10 % to I_D 10 %)');
r = run(res, "tvf", on2, "turnOn", S9);
check(r.methodTag == "Conv: V_DS 90-10 %" && ~any(r.flags == "methodDeviceMismatch"), ...
    'IEC-9 preset: voltage fall time from the Conv same-level method, no mismatch');
resI = pipeline(b1, "IGBT", S);
r = run(resI, "tz", off2, "turnOff", S);
check(r.methodTag == "IEC 60747-9" && r.status ~= "skipped", sprintf('IGBT, preset auto: tail time attempted: %s', formatResult(r)));
r = run(resI, "tir", on2, "turnOn", S);
check(r.methodTag == "IEC 60747-9", 'IGBT, preset auto: t_ir uses IEC 60747-9');
So = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('tvf', "conv8020"))));
r = run(res, "tvf", on2, "turnOn", So);
check_near(r, 2 * tauS * atanh(0.6), 0.1e-9, 'explicit override: t_vf 80-20 %');

%% Custom methods
thr = @(sig, p, b) struct('signal', sig, 'level', p, 'basis', b);
Sc = dptSettings(struct('report', base.report, 'measurements', struct( ...
    'methods', struct('tdOn', "custom", 'dvdt', "custom"), ...
    'params', struct('custom', struct('tdOn', struct('start', thr("gateVoltage@active", 0.5, "gate"), ...
    'stop', thr("drainVoltage@active", 0.5, "transition")), 'dvdt', [0.3 0.7])))));
r = run(res, "tdOn", on2, "turnOn", Sc);
check_near(r, 30e-9, 0.1e-9, 'custom t_d(on): V_GS 50 % to V_DS 50 %');
r = run(res, "dvdt", on2, "turnOn", Sc);
check(r.methodTag == "Custom: user levels" && abs(r.value / (0.4 * r.provenance.levels(1) / (2 * tauS * atanh(0.4))) - 1) < 0.01, ...
    sprintf('custom dv/dt 30-70 %%: %s', formatResult(r)));
Su = dptSettings(struct('report', base.report, 'measurements', struct('methods', struct('tdOn', "custom"))));
r = run(res, "tdOn", on2, "turnOn", Su);
check(r.status == "skipped" && contains(r.reason, "custom.tdOn"), 'custom without thresholds: skipped with a pointer');

%% Example record: consistency
Sx = dptSettings(base);
cfgX = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", 'deviceType', "MOSFET", ...
    'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
    'zeroOffsetCorrection', struct('enable', true), 'currentNormalization', struct('enable', true)), Sx, codeDir);
resX = runPipeline(cfgX, Sx);
ok = true; okOff = true; order = true;
for p = 2:height(resX.tl.pulses)
    eOn = resX.tl.pulses.turnOnEdge(p); eOff = resX.tl.pulses.turnOffEdge(p);
    a = run(resX, "tdOn", eOn, "turnOn", Sx); b = run(resX, "tvf", eOn, "turnOn", Sx); c = run(resX, "tOn", eOn, "turnOn", Sx);
    ok = ok && abs(a.value + b.value - c.value) < 1e-12;
    a = run(resX, "tdOff", eOff, "turnOff", Sx); b = run(resX, "tvr", eOff, "turnOff", Sx); c = run(resX, "tOff", eOff, "turnOff", Sx);
    okOff = okOff && abs(a.value + b.value - c.value) < 1e-12;
    avg = run(resX, "dvdt", eOn, "turnOn", Sx).value;
    bm = run(resX, "dvdt", eOn, "turnOn", Sb).value;
    mx = run(resX, "dvdtMax", eOn, "turnOn", Sx).value;
    order = order && avg <= bm && bm <= mx * 1.02;
end
check(ok, 'example, pulses 2-10: t_on = t_d(on) + t_vf exactly (shared IEC-8 end points)');
check(okOff, 'example, pulses 2-10: t_off = t_d(off) + t_vr exactly');
check(order, 'example: dv/dt average <= band maximum <= instantaneous maximum (2 % margin)');
r = run(resX, "deadTime", resX.tl.pulses.turnOnEdge(5), "turnOn", Sx);
check(r.status == "skipped" && contains(r.reason, "not actively driven"), 'example: HS gate not driven, dead time skipped');
r = run(resX, "dvgsdt", resX.tl.pulses.turnOnEdge(5), "turnOn", Sx);
check(r.status == "ok", sprintf('example dV_GS/dt (90 %% beyond the hysteresis arm): %s', formatResult(r)));

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end
