function r = measureRecovery(def, method, ctx, sig, S)
%MEASURERECOVERY Reverse recovery of the non-active device's diode, #39-46.
%
%   r = measureRecovery(def, method, ctx, sig, S) evaluates one row on the
%   active device's turn-on, where the complementary diode recovers
%   (MEASUREMENT_DESIGN.md section 17).
%
%   Diode current I_F (forward positive), as a virtual channel
%   "diodeCurrent" in a copy of the collection, so every helper reads it
%   like a measured signal:
%     measured  -I_D of the non-active device
%     derived   I_L - I_D of the active device, only with
%               cfg.diodeCurrent.allowDerived. I_L is replaced by its local
%               linear trend over averagingWindow*D: the inductor current
%               is continuous and the recovery never passes through it, so
%               this removes the I_L sensor's noise without biasing the
%               recovery (design 17). Refused when the largest conduction-
%               phase mismatch, smoothed over D, exceeds
%               params.recovery.derivedMismatch * I_rrm (design Q5)
%
%   Common to every row (recoveryCore):
%     I_F0   forward current at the turn-on gate instant (V_GS 10 %); the
%            event is skipped if it is within the noise floor
%     t0     first zero crossing of I_F after the gate instant
%     ts     I_F settled after the recovery (settledAfter, from t0); the
%            territory end otherwise, flagged "ringingNotDecayed"
%     lobe   the recovery lobe: t0 until I_F first rises back above
%            +noiseFloorMultiple*sigma (or ts if it does not)
%     I_rrm  -min(I_F) over the lobe, raw samples, with its time tp
%   A level p*I_rrm on the recovering slope is used only if
%   min(p, 1 - p) * I_rrm is at least noiseFloorMultiple * sigma (Q2);
%   a refusal sets r.noiseLimited, so evaluateMeasurement falls back to
%   the next method (design 17.5).
%
%   Rows
%     Irrm (#39)   raw or smoothed (Savitzky-Golay) peak, positive
%     trr (#40)    t0 to the end point: IEC-2 / JEDEC / custom line to zero,
%                  25 % direct crossing, or the second zero crossing
%     ta, tb (#41, #42)  t0 -> tp, tp -> t_rr end (the #40 method)
%     Srr (#43)    t_b / t_a; the IEC-2 S_rr is deferred (skipped)
%     Qrr (#44)    integral of -I_F from t0 to 2 % of I_rrm / the t_rr end /
%                  a custom end; or the triangle t_rr * I_rrm / 2
%     Err (#45)    integral of v_F * i_F (v_F = -V_DS of the non-active
%                  device), from t0 or from V_DS,N at 10 % of V_DC, to 2 %
%                  of I_rrm, to the t_rr end (#40), or a custom end;
%                  positive
%     didtRR (#46) |di_F/dt|: line fit through the zero crossing, peak
%                  |di/dt| during t_b, or between custom levels

r = makeResult(def, method, ctx);
[rc, r] = recoveryCore(r, ctx, sig, S);
if isempty(rc)
    return
end
switch def.id
    case "Irrm"
        r = peakCurrent(r, method, rc, S);
    case "trr"
        r = recoveryTime(r, method, rc, S);
    case "ta"
        r.value = rc.tp - rc.t0;
        r = done(r, rc);
    case "tb"
        r = fallTime(r, rc, ctx, S);
    case "Srr"
        r = softness(r, method, ctx, S);
    case "Qrr"
        r = charge(r, method, rc, ctx, S);
    case "Err"
        r = recoveryEnergy(r, method, rc, sig, ctx, S);
    case "didtRR"
        r = slewRate(r, method, rc, ctx, S);
end
end

% =====================================================================
function [rc, r] = recoveryCore(r, ctx, sig, S)
% Diode current, forward current, zero crossing, settling and peak.
rc = [];
C = S.measurements.common;
e = ctx.edges(1);
g = gateInstant(ctx, e, 0.1, S);
if ~g.found
    r.reason = "V_GS 10 %: " + g.reason;
    return
end
[ctxV, src, why] = withDiodeCurrent(ctx, sig, S);
if why ~= ""
    r.status = "skipped";
    r.reason = why;
    return
end
lv = eventLevels(ctxV, e, "diodeCurrent", S);
if isnan(lv.pre)
    r.reason = "diode current: " + lv.reason;
    return
end
sigma = lv.sigma;
k = C.noiseFloorMultiple;
if lv.pre < k * sigma
    r.status = "skipped";
    r.reason = sprintf(['no forward diode current before the turn-on (I_F = %.3g A, noise floor %.3g A): ' ...
        'no reverse recovery to measure'], lv.pre, k * sigma);
    return
end
s = getSignal(ctxV.col, "diodeCurrent", [g.time, e.territory(2)], S);
z = findCrossing(s.t, s.x, 0, "falling", [], "first");
if ~z.found
    r.reason = "the diode current does not reverse after the turn-on";
    return
end
sa = settledAfter(ctxV, e, "diodeCurrent", S, start=z.time);
ts = e.territory(2);
if sa.settled
    ts = sa.time;
end
% The recovery lobe ends where the current first comes back above zero
% (with a noise margin, so jitter at the zero crossing does not end it).
up = findCrossing(s.t, s.x, k * sigma, "rising", [z.time, ts], "first");
tLobe = ts;
if up.found
    tLobe = up.time;
end
m = s.t >= z.time & s.t <= tLobe;
if nnz(m) < 3
    r.reason = "the recovery window is shorter than three samples";
    return
end
[mn, j] = min(s.x(m));
tm = s.t(m);
rc.e = e;
rc.ctxV = ctxV;
rc.source = src;
rc.g = g.time;
rc.IF0 = lv.pre;
rc.sigma = sigma;
rc.k = k;
rc.t0 = z.time;
rc.tp = tm(j);
rc.Irrm = -mn;
rc.ts = ts;
rc.settled = sa.settled;
rc.t = s.t;
rc.x = s.x;
rc.dt = ctx.col.sampleInterval;
rc.resolvable = rc.Irrm >= k * sigma;

% Derived current: refused when the two sensors disagree in conduction
% by more than a fraction of the recovery current (Q5). The largest
% disagreement, smoothed over D, catches a drifting sensor that a mean
% over the segment would average out.
rc.mismatch = NaN;
if src == "derived"
    seg = s.t >= max(ts, e.core(2)) & s.t <= e.territory(2);
    if nnz(seg) < 3
        r.reason = "no settled conduction segment to check the derived diode current";
        return
    end
    nD = max(2, round(C.averagingWindow * e.D / ctx.col.sampleInterval));
    sm = movmean(s.x(seg), nD, 'omitnan');
    [~, jm] = max(abs(sm));
    rc.mismatch = sm(jm);
    lim = S.measurements.params.recovery.derivedMismatch * rc.Irrm;
    if abs(rc.mismatch) > lim
        r.reason = sprintf(['derived diode current refused: I_L - I_D reaches %.3g A in conduction, more than ' ...
            '%g %% of I_rrm (%.3g A); enable current normalization or measure the non-active I_D'], ...
            rc.mismatch, 100 * S.measurements.params.recovery.derivedMismatch, lim);
        rc = [];
        return
    end
end
r.provenance.diodeCurrent = struct('source', src, 'forwardCurrent', rc.IF0, ...
    'conductionMismatch', rc.mismatch, 'sigma', sigma);
r.provenance.zeroCrossing = rc.t0 - e.time;
r.provenance.peakTime = rc.tp - e.time;
if ~rc.settled
    r.flags = "ringingNotDecayed";
end
end

% =====================================================================
function [ctxV, src, why] = withDiodeCurrent(ctx, sig, S)
% Copy of the context whose collection holds the diode current I_F as
% channel "diodeCurrent", with neutral corrections (already applied).
ctxV = ctx;
why = "";
col = ctx.col;
names = [col.channels.signal];
if sig.IFRole == "drainCurrent@nonActive"
    src = "measured";
    a = getSignal(col, sig.IF, [], S);
    x = -a.x;
    base = find(names == sig.IF, 1);
else
    src = "derived";
    if ~ctx.cfg.diodeCurrent.allowDerived
        why = "the diode current needs the non-active device's I_D, or cfg.diodeCurrent.allowDerived " + ...
            "for I_L - I_D of the active device";
        return
    end
    iName = resolveRole("drainCurrent@active", ctx.cfg, S);
    kI = find(names == iName, 1);
    base = find(names == sig.IF, 1);
    if isempty(kI)
        why = "the derived diode current needs " + iName;
        return
    end
    % Both read over the range they share in corrected time, so they lie
    % on one grid (integer-sample deskew, getSignal).
    dL = col.channels(base).corrections.deskewApplied;
    dI = col.channels(kI).corrections.deskewApplied;
    range = [col.time(1) + max(dL, dI), col.time(end) + min(dL, dI)];
    a = getSignal(col, sig.IF, range, S);
    b = getSignal(col, iName, range, S);
    % I_L is continuous and carries no recovery current: its local linear
    % trend over averagingWindow*D removes its sensor noise; the error at
    % the slope change is dS * D / 8 (localTrend).
    e = ctx.edges(1);
    n = max(2, round(S.measurements.common.averagingWindow * e.D / col.sampleInterval));
    x = localTrend(a.x, n) - b.x;
end
ch = col.channels(base);
data = NaN(col.recordLength, 1);
data(a.index) = x;
ch.signal = "diodeCurrent";
ch.data = data;
ch.units = "A";
ch.corrections.invert = false;
ch.corrections.zeroOffset = 0;
ch.corrections.gain = 1;
ch.corrections.offset = 0;
ch.corrections.deskewApplied = a.corrections.deskewApplied;
col.channels(end + 1) = ch;
ctxV.col = col;
end

% =====================================================================
function r = peakCurrent(r, method, rc, S)
r.value = rc.Irrm;
r.provenance.time = rc.tp - rc.e.time;
if method.id == "smoothed"
    P = S.measurements.params;
    n = max(P.derivative.minSamples, round(P.recovery.smoothFraction * (rc.tp - rc.t0) / rc.dt));
    n = n + (mod(n, 2) == 0);
    pad = ((n - 1) / 2 + 1) * rc.dt;
    s = getSignal(rc.ctxV.col, "diodeCurrent", [rc.t0 - pad, rc.ts + pad], S);
    y = filterSignal(s.x, "savgol", n, 2);
    m = s.t >= rc.t0 & s.t <= rc.ts & ~isnan(y);
    tm = s.t(m);
    [mn, j] = min(y(m));
    r.value = -mn;
    r.provenance.time = tm(j) - rc.e.time;
    r.methodTag = sprintf('%s (Savitzky-Golay order 2, %d samples = %.3g ns)', r.methodTag, n, n * rc.dt * 1e9);
    r.provenance.filter = struct('method', "savgol", 'order', 2, 'samples', n);
end
if ~rc.resolvable
    r.flags = unique([r.flags, "belowNoiseFloor"], 'stable');
end
r = done(r, rc);
end

% =====================================================================
function r = recoveryTime(r, method, rc, S)
if ~rc.resolvable
    r.reason = noRecovery(rc);
    r.noiseLimited = true;
    return
end
[tEnd, info, why, status, noisy] = trrEnd(method.id, rc, S);
if why ~= ""
    r.status = status;
    r.reason = why;
    r.noiseLimited = noisy;
    return
end
r.value = tEnd - rc.t0;
r.provenance.endTime = tEnd - rc.e.time;
r.provenance.endPoints = info;
r = done(r, rc);
end

function [tEnd, info, why, status, noisy] = trrEnd(id, rc, S)
% End point of t_rr by method; info holds the construction points
% (times relative to the edge, levels in A). noisy: refused only by the
% noise-floor rule.
tEnd = NaN;
info = struct();
why = "";
status = "failed";
noisy = false;
switch id
    case "IEC2"
        [tEnd, info, why, noisy] = lineToZero(rc, [0.9, 0.25], S);
    case "JEDEC"
        [t25, why, noisy] = recovering(rc, 0.25, S);
        if why == ""
            tEnd = t25 + (t25 - rc.tp) * 0.25 / 0.75;
            info = struct('times', [rc.tp, t25] - rc.e.time, 'levels', -[1, 0.25] * rc.Irrm);
        end
    case "conv25"
        [tEnd, why, noisy] = recovering(rc, 0.25, S);
        info = struct('times', tEnd - rc.e.time, 'levels', -0.25 * rc.Irrm);
    case "zero2"
        c = findCrossing(rc.t, rc.x, 0, "rising", [rc.tp, rc.e.territory(2)], "first");
        if c.found
            tEnd = c.time;
        else
            why = "the diode current does not cross zero again within the territory";
        end
    case "custom"
        L = S.measurements.params.custom.trrLevels;
        if isempty(L)
            status = "skipped";
            why = "no custom levels set (S.measurements.params.custom.trrLevels)";
            return
        end
        [tEnd, info, why, noisy] = lineToZero(rc, L, S);
end
end

function [tEnd, info, why, noisy] = lineToZero(rc, L, S)
% Zero crossing of the line through the recovering current at -L(1) and
% -L(2) of I_rrm.
tEnd = NaN;
info = struct();
[t1, why, noisy] = recovering(rc, L(1), S);
if why ~= ""
    return
end
[t2, why, noisy] = recovering(rc, L(2), S);
if why ~= ""
    return
end
tEnd = t2 + (t2 - t1) * L(2) / (L(1) - L(2));
info = struct('times', [t1, t2] - rc.e.time, 'levels', -L * rc.Irrm);
end

function [t, why, noisy] = recovering(rc, p, S) %#ok<INUSD>
% Time the recovering current rises through -p * I_rrm after the peak,
% searched to the territory end (design 12.7): a low level such as 2 % of
% I_rrm can lie inside the settling band.
t = NaN;
why = "";
noisy = false;
if min(p, 1 - p) * rc.Irrm < rc.k * rc.sigma
    noisy = true;
    why = sprintf(['%g %% of I_rrm is within the noise floor (%.3g A from the peak or zero, ' ...
        'noise floor %.3g A)'], 100 * p, min(p, 1 - p) * rc.Irrm, rc.k * rc.sigma);
    return
end
c = findCrossing(rc.t, rc.x, -p * rc.Irrm, "rising", [rc.tp, rc.e.territory(2)], "first");
if ~c.found
    why = sprintf('the current does not recover to %g %% of I_rrm within the territory', 100 * p);
    return
end
t = c.time;
end

% =====================================================================
function r = fallTime(r, rc, ctx, S)
tr = evaluateMeasurement(registryEntry("trr"), ctx, S);
if tr.status ~= "ok"
    r.status = tr.status;
    r.reason = "t_rr: " + tr.reason;
    r.noiseLimited = tr.noiseLimited;
    return
end
r.value = tr.provenance.endTime + rc.e.time - rc.tp;
r.methodTag = sprintf('%s (%s)', r.methodTag, tr.methodTag);
r.flags = unique([r.flags, tr.flags], 'stable');
r.status = "ok";
end

function r = softness(r, method, ctx, S)
if method.id == "IEC2"
    r.status = "skipped";
    r.reason = "the IEC 60747-2 S_rr is deferred until its formula is confirmed (MEASUREMENT_SPEC.md row 43)";
    return
end
ta = evaluateMeasurement(registryEntry("ta"), ctx, S);
tb = evaluateMeasurement(registryEntry("tb"), ctx, S);
if ta.status ~= "ok" || tb.status ~= "ok"
    r.status = "failed";
    if ta.status == "skipped" && tb.status == "skipped", r.status = "skipped"; end
    r.reason = "t_a: " + statusText(ta) + "; t_b: " + statusText(tb);
    r.noiseLimited = ta.noiseLimited || tb.noiseLimited;
    return
end
r.value = tb.value / ta.value;
r.methodTag = sprintf('%s (t_b %s)', r.methodTag, tb.methodTag);
r.flags = unique([ta.flags, tb.flags], 'stable');
r.provenance.ta = ta.value;
r.provenance.tb = tb.value;
r.status = "ok";
end

% =====================================================================
function r = charge(r, method, rc, ctx, S)
if ~rc.resolvable
    r.reason = noRecovery(rc);
    r.noiseLimited = true;
    return
end
if method.id == "triangle"
    tr = evaluateMeasurement(registryEntry("trr"), ctx, S);
    ir = evaluateMeasurement(registryEntry("Irrm"), ctx, S);
    if tr.status ~= "ok" || ir.status ~= "ok"
        r.status = "failed";
        r.reason = "t_rr: " + statusText(tr) + "; I_rrm: " + statusText(ir);
        r.noiseLimited = tr.noiseLimited || ir.noiseLimited;
        return
    end
    r.value = tr.value * ir.value / 2;
    r.methodTag = sprintf('%s (t_rr %s, I_rrm %s)', r.methodTag, tr.methodTag, ir.methodTag);
    r.flags = unique([tr.flags, ir.flags], 'stable');
    r.status = "ok";
    return
end
[t1, why, status, extra, noisy, inner] = recoveryEnd(method.id, rc, ctx, S);
if why ~= ""
    r.status = status;
    r.reason = why;
    r.noiseLimited = noisy;
    return
end
s = getSignal(rc.ctxV.col, "diodeCurrent", [rc.t0, t1] + [-rc.dt, rc.dt], S);
[Q, info] = integrateBetween(s.t, -s.x, rc.t0, t1);
if ~info.complete || isnan(Q)
    r.reason = "the integration window lies outside the record";
    return
end
r.value = Q;
r.provenance.window = [rc.t0, t1] - rc.e.time;
if extra ~= ""
    r.methodTag = sprintf('%s (%s)', r.methodTag, extra);
end
r.flags = unique([r.flags, inner], 'stable');
r = done(r, rc);
end

function [t1, why, status, extra, noisy, flags] = recoveryEnd(id, rc, ctx, S)
% End of the Q_rr / E_rr integral by method; flags are those of an inner
% result used for the end (e.g. methodFallback of #40).
t1 = NaN;
why = "";
status = "failed";
extra = "";
noisy = false;
flags = strings(1, 0);
switch id
    case {"IEC2", "vdc10"}
        [t1, why, noisy] = recovering(rc, 0.02, S);
    case "trrEnd"
        tr = evaluateMeasurement(registryEntry("trr"), ctx, S);
        if tr.status ~= "ok"
            status = tr.status;
            why = "t_rr: " + tr.reason;
            noisy = tr.noiseLimited;
            return
        end
        t1 = tr.provenance.endTime + rc.e.time;
        extra = "t_rr " + tr.methodTag;
        flags = tr.flags;
    case "custom"
        P = S.measurements.params.custom;
        if ~isempty(P.recoveryEnd)
            [t1, why, noisy] = recovering(rc, P.recoveryEnd, S);
        elseif ~isempty(P.recoveryDuration)
            t1 = rc.t0 + P.recoveryDuration;
            if t1 > rc.e.territory(2)
                why = "the custom recovery duration runs past the edge's territory";
            end
        else
            status = "skipped";
            why = "no custom end set (S.measurements.params.custom.recoveryEnd or .recoveryDuration)";
        end
end
end

% =====================================================================
function r = recoveryEnergy(r, method, rc, sig, ctx, S)
if ~rc.resolvable
    r.reason = noRecovery(rc);
    r.noiseLimited = true;
    return
end
[t1, why, status, extra, noisy, inner] = recoveryEnd(method.id, rc, ctx, S);
if why ~= ""
    r.status = status;
    r.reason = why;
    r.noiseLimited = noisy;
    return
end
t0 = rc.t0;
if method.id == "vdc10"
    % Start where the diode's reverse voltage reaches 10 % of V_DC.
    e = rc.e;
    bv = busVoltageAt(ctx.col, [rc.g - S.measurements.common.averagingWindow * e.D, rc.g], S);
    if isnan(bv.value)
        r.reason = "no bus voltage before the edge";
        return
    end
    v = getSignal(ctx.col, sig.VN, [rc.g, t1], S);
    c = findCrossing(v.t, v.x, 0.1 * bv.value, "rising", [], "first");
    if ~c.found
        r.reason = "the non-active V_DS does not reach 10 % of V_DC before the recovery ends";
        return
    end
    t0 = c.time;
    r.flags = unique([r.flags, bv.flags], 'stable');
    r.provenance.busVoltage = bv.value;
end
if t1 <= t0
    r.reason = "the window is empty (its start lies after its end)";
    return
end
w = [t0, t1] + [-rc.dt, rc.dt];
v = getSignal(rc.ctxV.col, sig.VN, w, S);
i = getSignal(rc.ctxV.col, "diodeCurrent", w, S);
if numel(v.x) ~= numel(i.x)
    r.reason = "the diode voltage and current do not share one time grid";
    return
end
% Diode convention: v_F = -V_DS,N and i_F; both negative while it recovers.
[E, info] = integrateBetween(v.t, (-v.x) .* i.x, t0, t1);
if ~info.complete || isnan(E)
    r.reason = "the integration window lies outside the record";
    return
end
r.value = E;
r.provenance.window = [t0, t1] - rc.e.time;
if extra ~= ""
    r.methodTag = sprintf('%s (%s)', r.methodTag, extra);
end
r.flags = unique([r.flags, inner], 'stable');
r = done(r, rc);
end

% =====================================================================
function r = slewRate(r, method, rc, ctx, S)
P = S.measurements.params;
switch method.id
    case "zeroCrossing"
        L = P.recovery.didtLevels;
        a = findCrossing(rc.t, rc.x, L(1) * rc.IF0, "falling", [rc.g, rc.t0], "last");
        b = findCrossing(rc.t, rc.x, -L(2) * rc.Irrm, "falling", [rc.t0, rc.tp], "first");
        if ~(a.found && b.found)
            r.reason = sprintf('the diode current does not cross %g %% of I_F and -%g %% of I_rrm around zero', ...
                100 * L(1), 100 * L(2));
            return
        end
        if ~rc.resolvable || L(2) * rc.Irrm < rc.k * rc.sigma
            r.reason = noRecovery(rc);
            r.noiseLimited = true;
            return
        end
        m = rc.t >= a.time & rc.t <= b.time;
        if nnz(m) < 3
            r.reason = "fewer than three samples through the zero crossing";
            return
        end
        c = [rc.t(m) - mean(rc.t(m)), ones(nnz(m), 1)] \ rc.x(m);
        r.value = abs(c(1));
        r.provenance.window = [a.time, b.time] - rc.e.time;
    case "peakTb"
        tr = evaluateMeasurement(registryEntry("trr"), ctx, S);
        if tr.status ~= "ok"
            r.status = tr.status;
            r.reason = "t_rr: " + tr.reason;
            r.noiseLimited = tr.noiseLimited;
            return
        end
        tEnd = tr.provenance.endTime + rc.e.time;
        r.flags = unique([r.flags, tr.flags], 'stable');
        n = max(P.derivative.minSamples, round(P.recovery.derivativeFraction * (tEnd - rc.tp) / rc.dt));
        n = n + (mod(n, 2) == 0);
        pad = ((n - 1) / 2 + 1) * rc.dt;
        s = getSignal(rc.ctxV.col, "diodeCurrent", [rc.tp - pad, tEnd + pad], S);
        d = differentiateSignal(s.x, rc.dt, "savgol", n, P.derivative.order);
        m = s.t >= rc.tp & s.t <= tEnd & ~isnan(d);
        if ~any(m)
            r.reason = "the derivative window is longer than t_b";
            return
        end
        [r.value, j] = max(abs(d(m)));
        tm = s.t(m);
        r.provenance.time = tm(j) - rc.e.time;
        r.methodTag = sprintf('%s (Savitzky-Golay order %d, %d samples = %.3g ns; t_rr %s)', r.methodTag, ...
            P.derivative.order, n, n * rc.dt * 1e9, tr.methodTag);
        r.provenance.derivative = struct('order', P.derivative.order, 'samples', n);
    case "custom"
        L = P.custom.didtRR;
        if isempty(L)
            r.status = "skipped";
            r.reason = "no custom levels set (S.measurements.params.custom.didtRR)";
            return
        end
        a = findCrossing(rc.t, rc.x, max(L), "falling", [rc.g, rc.tp], "first");
        b = findCrossing(rc.t, rc.x, min(L), "falling", [rc.g, rc.tp], "first");
        if ~(a.found && b.found)
            r.reason = sprintf('the diode current does not fall through %.3g A and %.3g A before the peak', ...
                max(L), min(L));
            return
        end
        r.value = abs((max(L) - min(L)) / (b.time - a.time));
        r.provenance.window = [a.time, b.time] - rc.e.time;
end
r = done(r, rc);
end

% =====================================================================
function r = done(r, rc)
% Result complete: state the diode-current source in the tag.
if rc.source == "derived"
    r.methodTag = r.methodTag + ", I_F = I_L - I_D";
else
    r.methodTag = r.methodTag + ", I_F = -I_D,N";
end
r.status = "ok";
end

function s = noRecovery(rc)
s = sprintf('no measurable reverse recovery: I_rrm (%.3g A) is within the noise floor (%.3g A)', ...
    rc.Irrm, rc.k * rc.sigma);
end

function s = statusText(r)
if r.status == "ok"
    s = "ok";
else
    s = r.status + " (" + r.reason + ")";
end
end

function def = registryEntry(id)
persistent R
if isempty(R)
    R = measurementRegistry();
end
def = R([R.id] == id);
end
