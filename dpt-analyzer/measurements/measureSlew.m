function r = measureSlew(def, method, ctx, sig, S) %#ok<INUSD>
%MEASURESLEW Slew rates #24-28 of V_DS, I_D or V_GS on one edge.
%
%   r = measureSlew(def, method, ctx, sig, S) implements three kinds
%   (method.params.kind), on the amplitude scale of the signal's own
%   transition (eventLevels; for the gate its measured levels on
%   S.measurements.common.gateBasis). Values are magnitudes; the
%   direction is in the provenance. Turn-on and turn-off are separate
%   results because they are separate events.
%
%     average        |level_b - level_a| / (t_b - t_a) between the two
%                    levels (method.params.levels, e.g. [0.1 0.9])
%     bandMax        steepest average slope over any band of
%                    S.measurements.params.slew.band of the swing inside
%                    the levels (slopeBandMax, Q10)
%     maxDerivative  max |dx/dt| between the two level crossings, from a
%                    Savitzky-Golay derivative whose window is
%                    windowBandFactor x the time the signal takes to cross
%                    the steepest band (at least minSamples), or
%                    S.measurements.params.derivative.windowDuration. The
%                    filter is stated in the tag.
%
%   "custom" methods read [lo hi] from S.measurements.params.custom.(id).

r = makeResult(def, method, ctx);
p = method.params;
e = ctx.edges(1);
P = S.measurements.params;
dt = ctx.col.sampleInterval;

levels = p.levels;
if isempty(levels)
    levels = P.custom.(def.id);
    if isempty(levels)
        r.status = "skipped";
        r.reason = "no custom levels set (S.measurements.params.custom." + def.id + ")";
        return
    end
    if ~(isnumeric(levels) && numel(levels) == 2 && levels(1) >= 0 && levels(2) <= 1 && levels(1) < levels(2))
        r.reason = "S.measurements.params.custom." + def.id + " must be [lo hi] fractions, lo < hi";
        return
    end
end
levels = double(levels(:)');
name = resolveRole(p.signal, ctx.cfg, S);
isGate = name == ctx.ev.signal;

%% Transition levels and the signal
if isGate
    lv = ctx.ev.levels;
    if S.measurements.common.gateBasis == "swing"
        low = lv.low;
    else
        low = 0;
    end
    high = lv.high;
    if e.direction == "rising"
        pre = low; post = high;
    else
        pre = high; post = low;
    end
    n = e.smoothingSamples;
    pad = (n - 1) / 2 * dt;
    range = [e.window(1), e.window(2)];
    s = getSignal(ctx.col, name, range + [-pad, pad], S);
    x = filterSignal(s.x, "movmean", n);
    t = s.t;
else
    lv = eventLevels(ctx, e, name, S);
    if ~lv.ok
        r.reason = name + ": " + lv.reason;
        return
    end
    chk = transitionThreshold(lv.pre, lv.post, lv.low + min(levels) * lv.amplitude, ...
        lv.sigma, S.measurements.common.noiseFloorMultiple);
    if ~chk.resolvable
        r.reason = name + ": " + chk.reason;
        r.noiseLimited = chk.noiseLimited;
        return
    end
    pre = lv.pre; post = lv.post;
    range = [e.window(1), e.territory(2)];
    s = getSignal(ctx.col, name, range, S);
    x = s.x;
    t = s.t;
end
low = min(pre, post);
amp = abs(post - pre);
direction = "rising";
if post < pre
    direction = "falling";
end
r.provenance.direction = direction;
r.provenance.levels = [pre, post];

% Crossing times of the two levels, in the order the transition meets them.
if direction == "rising"
    order = levels;
else
    order = fliplr(levels);
end
la = low + order(1) * amp;
lb = low + order(2) * amp;
ca = findCrossing(t, x, la, direction, range, "first");
if ~ca.found
    r.reason = sprintf('%s does not cross %g %% of its transition', name, 100 * order(1));
    return
end
cb = findCrossing(t, x, lb, direction, [ca.time, range(2)], "first");
if ~cb.found
    r.reason = sprintf('%s does not cross %g %% of its transition after %g %%', name, ...
        100 * order(2), 100 * order(1));
    return
end
r.provenance.window = [ca.time, cb.time] - e.time;

switch p.kind
    case "average"
        r.value = abs(lb - la) / (cb.time - ca.time);

    case "bandMax"
        [sb, bi] = slopeBandMax(t, x, pre, post, P.slew.band, levels, P.slew.bandStep, range);
        if isnan(sb)
            r.reason = "no band of the swing is crossed within the levels";
            return
        end
        r.value = abs(sb);
        r.methodTag = sprintf('Custom: max over %g %% band', 100 * P.slew.band);
        r.provenance.band = struct('position', bi.position, 'times', bi.times - e.time);

    case "maxDerivative"
        [sb, ~] = slopeBandMax(t, x, pre, post, P.slew.band, levels, P.slew.bandStep, range);
        if isempty(P.derivative.windowDuration)
            if isnan(sb)
                r.reason = "no band of the swing is crossed, so no derivative window";
                return
            end
            bandTime = P.slew.band * amp / abs(sb);
            nWin = round(P.derivative.windowBandFactor * bandTime / dt);
        else
            nWin = round(P.derivative.windowDuration / dt);
        end
        undersampled = nWin < P.derivative.minSamples;
        nWin = max(nWin, P.derivative.minSamples);
        nWin = nWin + (mod(nWin, 2) == 0);
        pad = ((nWin - 1) / 2 + 1) * dt;
        sd = getSignal(ctx.col, name, [ca.time - pad, cb.time + pad], S);
        d = differentiateSignal(sd.x, dt, "savgol", nWin, P.derivative.order);
        k = sd.t >= ca.time & sd.t <= cb.time;
        if ~any(k & ~isnan(d))
            r.reason = "the derivative window is longer than the transition";
            return
        end
        [r.value, j] = max(abs(d(k)));
        tk = sd.t(k);
        r.methodTag = sprintf('%s (Savitzky-Golay order %d, %d samples = %.3g ns)', ...
            r.methodTag, P.derivative.order, nWin, nWin * dt * 1e9);
        r.provenance.derivative = struct('order', P.derivative.order, 'samples', nWin, ...
            'duration', nWin * dt, 'time', tk(j) - e.time);
        if undersampled
            r.flags = "derivativeUndersampled";      % filter-limited: biased low
        end
end
r.status = "ok";

end
