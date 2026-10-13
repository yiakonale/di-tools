function test_primitives()
%TEST_PRIMITIVES Informal tests of measurements/primitives (formalized in Batch 7).
%   Exact checks on synthetic signals with known answers, then sanity
%   checks on the example record (turn-on edge 17 and turn-off edge 18,
%   pulse 9, about 500 A).

codeDir = fileparts(fileparts(mfilename('fullpath')));
addpath(codeDir, fullfile(codeDir, 'sync'), fullfile(codeDir, 'measurements', 'primitives'));
nPass = 0; nFail = 0;

    function check(cond, label)
        if cond, fprintf('pass  %s\n', label); nPass = nPass + 1;
        else, fprintf('FAIL  %s\n', label); nFail = nFail + 1; end
    end

%% findCrossing ------------------------------------------------------------
t = (0:10)'; x = t;
c = findCrossing(t, x, 3.5, "rising");
check(c.found && abs(c.time - 3.5) < 1e-12 && c.index == 4 && c.count == 1, 'crossing on a ramp, exact interpolation');
check(~findCrossing(t, x, 3.5, "falling").found, 'no falling crossing on a rising ramp');
ts = (0:0.001:2)'; xs = sin(2*pi*ts);
c1 = findCrossing(ts, xs, 0.5, "either", [], "first"); c2 = findCrossing(ts, xs, 0.5, "either", [], "last");
check(c1.count == 4 && abs(c1.time - 1/12) < 1e-6 && abs(c2.time - (1 + 5/12)) < 1e-6, 'first/last of several crossings');
check(abs(findCrossing(ts, xs, 0.5, "rising", [0.5 2]).time - (1 + 1/12)) < 1e-6, 'search range restricts');
xn = x; xn(5) = NaN;
check(~findCrossing(t, xn, 3.5, "rising").found, 'no crossing across a NaN sample');
c = findCrossing(t, x, -1, "rising");
check(~c.found && c.initialSide == 1, 'already beyond the level: initialSide reported');

%% transitionThreshold ------------------------------------------------------
th = transitionThreshold(0, 100, 10, 1, 3);
check(th.resolvable && th.direction == "rising" && abs(th.fraction - 0.1) < 1e-12 && abs(th.margin - 10/3) < 1e-12, '10 % threshold resolvable');
th = transitionThreshold(0, 100, 2, 1, 3);
check(~th.resolvable && contains(th.reason, "noise floor"), '2 % threshold below 3 sigma rejected');
th = transitionThreshold(400, 0, 8, 0.8, 3);
check(th.resolvable && th.direction == "falling", '2 % of V_DC (8 V) on a 400 V fall, sigma 0.8 V');
check(~transitionThreshold(0, 100, 150, 1, 3).resolvable, 'level outside the transition rejected');
check(~transitionThreshold(5, 5, 5, 0, 3).resolvable, 'zero-amplitude transition rejected');

%% integrateBetween -----------------------------------------------------------
t = (0:0.1:1)';
check(abs(integrateBetween(t, 2 * ones(size(t)), 0.25, 0.75) - 1) < 1e-12, 'constant between off-grid limits');
check(abs(integrateBetween(t, t, 0.15, 0.85) - (0.85^2 - 0.15^2) / 2) < 1e-12, 'linear integrand exact');
[v, info] = integrateBetween(t, t, -0.1, 0.5);
check(isnan(v) && ~info.complete, 'limits outside the record: NaN, incomplete');

%% noiseLevel -----------------------------------------------------------------
rng(2);
[s, info] = noiseLevel(0.5 * randn(1e5, 1) + (1:1e5)' * 1e-3);
check(abs(s - 0.5) < 0.025 && abs(info.slope - 1e-3) < 1e-5, 'Gaussian noise on a ramp: sigma 0.5 recovered');
xq = 2 * round(0.3 * randn(1e4, 1));            % ~90 % on code 0, the rest on +/-2
[s, info] = noiseLevel(xq);
check(info.sigmaMad < 0.01 && info.quantStep == 2 && abs(s - 2 / sqrt(12)) < 1e-12, 'quantized flat signal: quantization floor used');

%% settlingTime -----------------------------------------------------------------
tau = 20e-9; w = 2*pi*50e6; t = (0:0.1e-9:500e-9)';
x = 1 + exp(-t / tau) .* cos(w * t);
[tsl, info] = settlingTime(t, x, 1, 0.02);
after = t >= tsl;
check(info.settled && all(abs(x(after) - 1) <= 0.02) && abs(x(find(after, 1) - 1) - 1) > 0.02 && ...
    tsl <= tau * log(1 / 0.02), sprintf('damped ringing settles to 2 %% at %.1f ns', tsl * 1e9));
check(isnan(settlingTime(t, x, 1, 0.02, [0 30e-9])), 'range ends before settling: NaN');

%% filterSignal / differentiateSignal / savgolKernel -----------------------------
check(abs(sum(savgolKernel(11, 2, 0)) - 1) < 1e-12 && abs(sum(savgolKernel(11, 2, 1))) < 1e-12, 'kernel sums (smooth 1, derivative 0)');
dt = 1e-9; t = (0:dt:200e-9)'; xq2 = 3 * (t / 1e-7).^2;
y = filterSignal(xq2, "savgol", 11, 2);
check(max(abs(y(6:end-5) - xq2(6:end-5))) < 1e-10 && all(isnan(y([1:5, end-4:end]))), 'savgol preserves a quadratic; edges NaN');
d = differentiateSignal(xq2, dt, "savgol", 11, 2);
check(max(abs(d(6:end-5) - 6 * t(6:end-5) / 1e-14)) < 1e-3, 'savgol derivative of a quadratic exact');
d = differentiateSignal(5 * t, dt, "central");
check(max(abs(d(2:end-1) - 5)) < 1e-6 && isnan(d(1)) && isnan(d(end)), 'central difference of a ramp exact');
y = filterSignal(5 * t, "movmean", 7);
check(max(abs(y(4:end-3) - 5 * t(4:end-3))) < 1e-15 && nnz(isnan(y)) == 6, 'movmean preserves a ramp; edges NaN');
d = differentiateSignal(5 * t, dt, "movmeanCentral", 7);
check(max(abs(d(5:end-4) - 5)) < 1e-6, 'movmean + central difference of a ramp');

%% ringingFrequency ---------------------------------------------------------------
rng(3); dt = 0.16e-9; t = (0:dt:400e-9)'; f0 = 47e6; sigma = 0.5;
x = 400 + 60 * exp(-t / 80e-9) .* sin(2*pi*f0*t) + sigma * randn(size(t));
[f, info] = ringingFrequency(t, x, 400, 3 * sigma);
check(abs(f / f0 - 1) < 0.002 && info.nCrossings >= 10, sprintf('damped 47 MHz ringing in noise: %.2f MHz, %d crossings', f / 1e6, info.nCrossings));
check(isnan(ringingFrequency(t, 400 + sigma * randn(size(t)), 400, 5 * sigma)), 'noise only: no frequency');

%% slopeBandMax --------------------------------------------------------------------
dt = 0.01e-9; t = (-50e-9:dt:50e-9)'; A = 400; tauE = 5e-9;
x = A / 2 * (1 + tanh(t / tauE));
[s, info] = slopeBandMax(t, x, 0, A, 0.2, [0.1 0.9], 0.01);
expected = 0.2 * A / (2 * tauE * atanh(0.2));
check(abs(s / expected - 1) < 1e-3 && abs(info.position - 0.4) < 1e-9, sprintf( ...
    'tanh edge: 20 %% band max %.4g V/ns at the centre (instantaneous %.4g)', s * 1e-9, A / (2 * tauE) * 1e-9));
s2 = slopeBandMax(t, A - x, A, 0, 0.2, [0.1 0.9], 0.01);
check(abs(s2 + expected) / expected < 1e-3, 'falling edge: negative slope, same magnitude');

%% Example record: real-data sanity -------------------------------------------------
S = dptSettings(struct('report', struct('echoWarnings', false)));
cfg = validateBucketConfig(struct('bucketPath', "data/example", 'activeDevice', "LS", ...
    'expectedPulseCount', 10, 'gate', struct('nominal', struct('high', 18, 'low', -5))), S, codeDir);
col = importCollection(fullfile(cfg.bucketPath, 'collection_A'), cfg, S);
ev = detectGateTransitions(col, cfg, S); al = alignCollections(ev, S); tl = buildPulseTimeline(ev, al, cfg, S);
W = tl.windows;
for j = [17 18]
    r = [W.startTime(j) W.endTime(j)] + al.offset;
    core = [W.coreStartTime(j) W.coreEndTime(j)] + al.offset;
    v = getSignal(col, "Vds-LS", r, S);
    preSeg = v.x(v.t < core(1)); postSeg = v.x(v.t > core(2));
    pre = median(preSeg); post = median(postSeg(round(end * 0.75):end));
    [sig, ni] = noiseLevel(preSeg);
    lo = min(pre, post); hi = max(pre, post);          % amplitude scale (IEC)
    th90 = transitionThreshold(pre, post, lo + 0.9 * (hi - lo), sig, 3);
    th10 = transitionThreshold(pre, post, lo + 0.1 * (hi - lo), sig, 3);
    c90 = findCrossing(v.t, v.x, th90.level, th90.direction, core);
    c10 = findCrossing(v.t, v.x, th10.level, th10.direction, core);
    if tl.edges.kind(j) == "turnOn"
        tTrans = c10.time - c90.time;       % t_vf: 90 % -> 10 %
    else
        tTrans = c90.time - c10.time;       % t_vr: 10 % -> 90 %
    end
    avg = 0.8 * (post - pre) / tTrans;
    sb = slopeBandMax(v.t, v.x, pre, post, 0.2, [0.1 0.9], 0.01, core);
    dvdt = differentiateSignal(v.x, col.sampleInterval, "savgol", 11, 2);
    inTrans = v.t >= min(c10.time, c90.time) & v.t <= max(c10.time, c90.time);
    dmax = max(abs(dvdt(inTrans)));
    fprintf(['      edge %d (%s): Vds %.1f -> %.1f V, noise %.2f V (step %.3g V), ' ...
        '10/90 margins %.1f/%.1f, t = %.2f ns\n      dv/dt avg %.2f, 20%%-band max %.2f, ' ...
        'savgol-11 max %.2f V/ns\n'], j, tl.edges.kind(j), pre, post, sig, ni.quantStep, ...
        th10.margin, th90.margin, tTrans * 1e9, abs(avg) * 1e-9, abs(sb) * 1e-9, dmax * 1e-9);
    check(th10.resolvable && th90.resolvable && c10.found && c90.found && tTrans > 1e-9 && tTrans < 300e-9, ...
        sprintf('edge %d: 10/90 thresholds resolvable and crossed, plausible transition time', j));
    check(abs(sb) >= abs(avg) && dmax >= abs(sb), sprintf('edge %d: |avg| <= |band max| <= |instantaneous max|', j));
    if tl.edges.kind(j) == "turnOff"
        settled = median(postSeg(round(end * 0.75):end));
        % Band above the noise AND above one ADC step (2.8 V here, larger
        % than 3 sigma = 2.4 V), so a single-code flicker is not a crossing.
        [fr, ri] = ringingFrequency(v.t, v.x, settled, 3 * sig + ni.quantStep, [c90.time, r(2)]);
        fprintf('      turn-off ringing: %.1f MHz over %d crossings, half-period spread %.2f\n', ...
            fr / 1e6, ri.nCrossings, ri.halfPeriodSpread);
        check(fr > 5e6 && fr < 1e9 && ri.nCrossings >= 3, 'edge 18: turn-off ringing frequency found');
    end
end

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end
