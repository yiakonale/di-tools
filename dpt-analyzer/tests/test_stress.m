function test_stress(root)
%TEST_STRESS Informal tests of Batch 5f: voltage, current and gate stress
%   #29-38 (formalized in Batch 7). Synthetic truth (makeSyntheticDPT with
%   damped V_DS / I_D ringing and gate bumps): peaks, windows, references
%   and percentages, ratings, the capture event, ringingNotDecayed; and
%   physical consistency on the example record.
%   test_stress(root) uses ROOT as the scratch folder.

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_stress');
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
    function Sx = withMethod(id, m, params)
        o = base;
        o.measurements.methods.(id) = m;
        if nargin > 2, o.measurements.params = params; end
        Sx = dptSettings(o);
    end
    function [v, t] = truthMax(tr, x, w, fn)
        % Extremum of truth vector X over the universal window W.
        m = tr.t >= w(1) & tr.t <= w(2);
        [v, k] = fn(x(m));
        tt = tr.t(m);
        t = tt(k);
    end
    function e = edgeOf(res, id, kind)
        ctx = eventContext(res.collections(1), 1, res.evs(1), res.al, res.tl, id, kind, res.cfg);
        e = ctx.edges(1);
    end
    function t = absTime(res, r, tRel)
        t = tRel + res.tl.edges.time(r.edgeIds(1)) + res.al.offset;
    end

%% Synthetic bucket: damped ringing and gate bumps
ringV = [60, 50e6, 40e-9];  ringI = [20, 50e6, 40e-9];
b1 = fullfile(root, 'syn');
tr = makeSyntheticDPT(fullfile(b1, 'A'), struct('channels', ...
    ["Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vdc", "Vds-HS", "Vgs-HS"], 'ringV', ringV, 'ringI', ringI, ...
    'vgsBump', [3, 5e-9], 'vgsNBump', [6, 5e-9]));
res = pipeline(b1, struct('ratings', struct('VdsMax', 1200, 'VgsMax', 20, 'VgsMin', -8, 'VgsThMin', 0.5), ...
    'nominal', struct('busVoltage', 400, 'testCurrent', 50)));
on2 = 3; off2 = 4; off3 = 6;                  % edges of pulse 2 (and the 3rd turn-off)
tOff = tr.offs(2) + tr.tdOff;  tOn = tr.ons(2) + tr.tdOn;
wOff = tOff + [-50e-9, 6 * ringV(3)];  wOn = tOn + [-50e-9, 6 * ringI(3)];

%% V_DS,max (#29)
r = run(res, "VdsMax", off2, "turnOff");
[vt, tt] = truthMax(tr, tr.vdsLS, wOff, @max);
check(r.status == "ok" && abs(r.value - vt) < 0.05 && abs(absTime(res, r, r.provenance.time) - tt) < 2e-9, ...
    sprintf('V_DS,max until settled = truth %.2f V: %s', vt, formatResult(r)));
check(~any(r.flags == "ringingNotDecayed") && ~any(r.flags == "exceedsRating") && ...
    r.provenance.rating.value == 1200, 'decayed ringing, below the 1200 V rating: no flags');
w = absTime(res, r, r.provenance.window);
check(w(2) < tOff + 10 * ringV(3), sprintf('window ends once the ringing decays (%.0f ns after the switching instant)', ...
    (w(2) - tOff) * 1e9));
r90 = run(res, "VdsMax", off2, "turnOff", withMethod("VdsMax", "after90"));
c = edgeOf(res, off2, "turnOff");
check(r90.status == "ok" && abs(r90.value - vt) < 0.05 && ...
    abs(diff(r90.provenance.window) - min(2 * c.D, c.territory(2) - c.time - r90.provenance.window(1))) < 1e-12, ...
    sprintf('after90: window 2 D from V_DS 90 %%, same peak: %s', formatResult(r90)));
rc = run(res, "VdsMax", off2, "turnOff", withMethod("VdsMax", "custom"));
check(rc.status == "skipped" && contains(rc.reason, "custom"), 'custom without a window: skipped');
rc = run(res, "VdsMax", off2, "turnOff", withMethod("VdsMax", "custom", struct('custom', struct('VdsMax', [0 30e-9]))));
check(rc.status == "ok" && abs(diff(rc.provenance.window) - 30e-9) < 1e-12 && rc.value <= vt, ...
    sprintf('custom 30 ns window: %s', formatResult(rc)));
res.cfg.ratings.VdsMax = 430;
r = run(res, "VdsMax", off2, "turnOff");
check(any(r.flags == "exceedsRating"), sprintf('rating 430 V: exceedsRating (%s)', formatResult(r)));
res.cfg.ratings.VdsMax = 1200;

%% Over- and undershoot of V_DS (#30, #31)
r = run(res, "dVdsOver", off2, "turnOff");
tp = absTime(res, r, r.provenance.time);
own = interp1(tr.t, tr.vdc + tr.vf, tp);
check(r.status == "ok" && abs(r.value - (vt - own)) < 0.3, ...
    sprintf('dV_DS,over vs own settled level = %.2f V (truth): %s', vt - own, formatResult(r)));
check(abs(r.provenance.percent - 100 * r.value / r.provenance.reference) < 1e-9 && r.provenance.extremum == vt, ...
    'percent = 100 * value / reference; extremum is the #29 peak');
check(contains(r.methodTag, "until ringing decays"), 'method tag names the peak window');
rb = run(res, "dVdsOver", off2, "turnOff", withMethod("dVdsOver", "busModel"));
check(rb.status == "ok" && abs((rb.value - r.value) - interp1(tr.t, tr.vf, tp)) < 0.3, ...
    sprintf('busModel reference V_DC excludes V_F: %.2f V larger (%s)', rb.value - r.value, formatResult(rb)));
rn = run(res, "dVdsOver", off2, "turnOff", withMethod("dVdsOver", "nominal"));
check(rn.status == "ok" && abs(rn.value - (vt - 400)) < 1e-9, sprintf('nominal 400 V reference: %s', formatResult(rn)));
r = run(res, "dVdsUnder", off2, "turnOff");
tp = absTime(res, r, r.provenance.time);
m = tr.t >= tt & tr.t <= tt + 6 * ringV(3);
ut = min(tr.vdsLS(m) - (tr.vdc(m) + tr.vf(m)));
check(r.status == "ok" && r.value < 0 && abs(r.value - ut) < 0.3 && tp > tt, ...
    sprintf('dV_DS,under after the peak = %.2f V (truth): %s', ut, formatResult(r)));
r = run(res, "dVdsUnder", on2, "turnOn");
check(r.status == "ok" && r.provenance.window(1) < r.provenance.window(2), ...
    sprintf('turn-on dip within the current rise: %s', formatResult(r)));

%% I_D,max and current over/undershoot (#32-34)
r = run(res, "IdMax", on2, "turnOn");
[it, ti] = truthMax(tr, tr.id, wOn, @max);
check(r.status == "ok" && abs(r.value - it) < 0.05 && abs(absTime(res, r, r.provenance.time) - ti) < 2e-9, ...
    sprintf('I_D,max = truth %.2f A: %s', it, formatResult(r)));
check(isempty(r.flags), 'I_D settles on its ramp: no flags');
r = run(res, "dIdOver", on2, "turnOn");
own = interp1(tr.t, tr.IL, ti);
check(r.status == "ok" && abs(r.value - (it - own)) < 0.3, ...
    sprintf('dI_D,over vs own ramp at the peak = %.2f A (truth): %s', it - own, formatResult(r)));
ri = run(res, "dIdOver", on2, "turnOn", withMethod("dIdOver", "Ion"));
ion = run(res, "Ion", on2, "turnOn");
check(ri.status == "ok" && ri.provenance.reference == ion.value && ri.value > r.value, ...
    sprintf('Ion reference = I_on (#4) %.2f A, before the ramp moves on: %s', ion.value, formatResult(ri)));
r = run(res, "dIdUnder", on2, "turnOn");
m = tr.t >= ti & tr.t <= ti + 6 * ringI(3);
ut = min(tr.id(m) - tr.IL(m));
check(r.status == "ok" && abs(r.value - ut) < 0.3, sprintf('dI_D,under after the turn-on = %.2f A (truth): %s', ut, formatResult(r)));
r = run(res, "dIdUnder", off2, "turnOff", withMethod("dIdUnder", "Ion"));
check(r.status == "skipped" && contains(r.reason, "off-state"), ...
    sprintf('turn-off current undershoot vs I_off: refused (%s)', r.reason));
r = run(res, "dIdUnder", off2, "turnOff");
a = absTime(res, r, r.provenance.window);
check(r.status == "ok" && ~isfield(r.provenance, 'percent') && a(2) > a(1) && r.value <= 0.05, ...
    sprintf('turn-off undershoot vs the ~0 A level: <= 0, no percentage (%s)', formatResult(r)));
rn = run(res, "dIdOver", on2, "turnOn", withMethod("dIdOver", "nominal"));
check(rn.status == "ok" && abs(rn.value - (it - 50)) < 1e-9, sprintf('nominal 50 A reference: %s', formatResult(rn)));

%% Gate stress (#35-38)
r = run(res, "VgsMax", on2, "turnOn");
[gt, ~] = truthMax(tr, tr.vgs, tr.ons(2) + [-200e-9, 400e-9], @max);
check(r.status == "ok" && abs(r.value - gt) < 0.05 && gt > 20.5, sprintf('V_GS,max with a 3 V overshoot = %.2f V: %s', gt, formatResult(r)));
check(any(r.flags == "exceedsRating"), 'above the 20 V rating: exceedsRating');
r = run(res, "VgsMax", off2, "turnOff");
check(r.status == "ok" && r.value < 18.1 && ~any(r.flags == "exceedsRating"), sprintf('turn-off window has no overshoot: %s', formatResult(r)));
rc = run(res, "VgsMax", [], "capture");
check(rc.status == "ok" && abs(rc.value - max(tr.vgs)) < 0.05 && isempty(rc.pulseIndex), ...
    sprintf('capture: max over the whole record = %.2f V: %s', max(tr.vgs), formatResult(rc)));
rc = run(res, "VgsMin", [], "capture");
check(rc.status == "ok" && abs(rc.value - min(tr.vgs)) < 0.05 && ~any(rc.flags == "exceedsRating"), ...
    sprintf('capture V_GS,min within the -8 V rating: %s', formatResult(rc)));
res.cfg.ratings.VgsMin = -4.5;
rc = run(res, "VgsMin", [], "capture");
check(any(rc.flags == "exceedsRating"), 'rating -4.5 V: V_GS,min below it is flagged');
res.cfg.ratings.VgsMin = -8;
r = run(res, "VgsNMax", on2, "turnOn");
[nt, ~] = truthMax(tr, tr.vgsHS, tOn + [-20e-9, 20e-9], @max);
check(r.status == "ok" && abs(r.value - nt) < 0.05 && any(r.flags == "exceedsRating"), ...
    sprintf('V_GS,N,max cross-talk = %.2f V above V_GS,th,min 0.5 V: %s', nt, formatResult(r)));
r = run(res, "VgsNMin", off3, "turnOff");
[nt, ~] = truthMax(tr, tr.vgsHS, tr.offs(3) + tr.tdOff + [-20e-9, 20e-9], @min);
check(r.status == "ok" && abs(r.value - nt) < 0.05 && any(r.flags == "exceedsRating"), ...
    sprintf('V_GS,N,min cross-talk = %.2f V below -8 V: %s', nt, formatResult(r)));
res.cfg.ratings = struct('VdsMax', [], 'VgsMax', [], 'VgsMin', [], 'VgsThMin', []);
r = run(res, "VgsNMin", off3, "turnOff");
check(r.status == "ok" && ~any(r.flags == "exceedsRating") && isempty(r.provenance.rating.value), ...
    'no ratings set: no exceedsRating flag');

%% Ringing that outlasts the territory
b2 = fullfile(root, 'slow');
makeSyntheticDPT(fullfile(b2, 'A'), struct('ringV', [60, 50e6, 3e-6]));
res2 = pipeline(b2);
r = run(res2, "VdsMax", off2, "turnOff");
c = edgeOf(res2, off2, "turnOff");
check(r.status == "ok" && any(r.flags == "ringingNotDecayed") && ...
    abs(r.provenance.window(2) - (c.territory(2) - c.time)) < 1e-12, ...
    'slowly decaying ringing: window ends at the territory, ringingNotDecayed');
r = run(res2, "dVdsOver", off2, "turnOff");
check(any(r.flags == "ringingNotDecayed"), 'the overshoot inherits ringingNotDecayed from #29');
b3 = fullfile(root, 'noId');
makeSyntheticDPT(fullfile(b3, 'A'), struct('channels', ["Vgs-LS", "Vds-LS", "Iout", "Vdc"]));
rr = run(pipeline(b3), "dVdsUnder", on2, "turnOn");
check(rr.status == "failed" && contains(rr.reason, "current-rise"), ...
    'turn-on dip without an I_D channel: refused (needs the current-rise phase)');

%% Example record
ex = fullfile(codeDir, 'data', 'example');
if isfolder(ex)
    cfg = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", 'deviceType', "MOSFET", ...
        'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5)), ...
        'zeroOffsetCorrection', struct('enable', true), 'currentNormalization', struct('enable', true)), S, codeDir);
    rx = runPipeline(cfg, S);
    P = rx.tl.pulses;
    ok = true; okI = true; okG = true; txt = "";
    for p = 1:height(P)
        v = run(rx, "dVdsOver", P.turnOffEdge(p), "turnOff");
        ok = ok && v.status == "ok" && v.value > 0 && ~any(v.flags == "ringingNotDecayed");
        i = run(rx, "IdMax", P.turnOnEdge(p), "turnOn");
        ion = run(rx, "Ion", P.turnOnEdge(p), "turnOn");
        e = edgeOf(rx, P.turnOnEdge(p), "turnOn");
        % The peak is the recovery peak inside the switching core, not the
        % end of the ramp (the noise floor of the settling band, design 15.3).
        okp = i.status == "ok" && i.value > ion.value && i.provenance.time < e.core(2) - e.time && ...
            i.provenance.window(2) < e.territory(2) - e.time - e.D;
        if ~okp
            fprintf('      pulse %d: %s, I_on %.1f A, window %s ns, core end %.0f ns\n', p, formatResult(i), ...
                ion.value, mat2str(round(i.provenance.window * 1e9)), (e.core(2) - e.time) * 1e9);
        end
        okI = okI && okp;
        g = run(rx, "VgsNMax", P.turnOnEdge(p), "turnOn");
        okG = okG && g.status == "ok" && g.value < 5;
        txt = txt + sprintf(' %.0f', i.value);
    end
    check(ok, 'example: positive V_DS overshoot at every turn-off, ringing decays');
    check(okI, "example: I_D,max above I_on, peak inside the core, window ends before the ramp (A:" + txt + ")");
    check(okG, 'example: cross-talk V_GS,N,max below 5 V at every turn-on');
    rc = run(rx, "VgsMax", [], "capture");
    rp = run(rx, "VgsMax", P.turnOnEdge(3), "turnOn");
    check(rc.status == "ok" && rc.value >= rp.value, sprintf('example: capture V_GS,max %s >= per-event', formatResult(rc)));
end

fprintf('\n%d passed, %d failed\n', nPass, nFail);
if nFail > 0
    error('test_stress:failed', '%d test(s) failed.', nFail);
end
end
