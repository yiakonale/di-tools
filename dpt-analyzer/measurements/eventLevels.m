function lv = eventLevels(ctx, e, name, S)
%EVENTLEVELS Pre- and post-switching levels of a signal around one edge.
%
%   lv = eventLevels(ctx, e, name, S) returns the 0 % / 100 % reference
%   levels of signal NAME for edge E of the event context, as used by
%   percent thresholds (MEASUREMENT_SPEC.md: "percent levels refer to the
%   transition between the pre- and post-switching levels of the named
%   signal"). The signal's OWN levels are used, so thresholds stay
%   consistent with the signal even when two current sensors disagree.
%
%   Both levels are evaluated at the gate instant of the edge (V_GS 10 %
%   rising at a turn-on, 90 % falling at a turn-off), from straight-line
%   fits, so a ramping signal (the inductor current) is not biased:
%     pre   fit over averagingWindow*D ending at the gate instant
%     post  fit over the final settledPortion of [end of the gate edge,
%           end of the territory], extrapolated back to the gate instant
%
%   Output struct: pre, post, low, high (min/max of pre, post), amplitude,
%   direction ("rising"|"falling"), sigma (larger noise of the two fit
%   segments, noiseLevel), quantStep, gateTime, ok, reason.

arguments
    ctx (1,1) struct
    e (1,1) struct
    name (1,1) string
    S (1,1) struct
end

C = S.measurements.common;
lv = struct('pre', NaN, 'post', NaN, 'low', NaN, 'high', NaN, 'amplitude', NaN, ...
    'direction', "", 'sigma', NaN, 'quantStep', NaN, 'gateTime', NaN, 'ok', false, 'reason', "");

p = 0.1 * (e.kind == "turnOn") + 0.9 * (e.kind == "turnOff");
g = gateInstant(ctx, e, p, S);
if g.found
    t0 = g.time;
else
    t0 = e.time;                       % fall back to the edge's reference crossing
end
lv.gateTime = t0;

a = windowStats(ctx, name, [t0 - C.averagingWindow * e.D, t0], S);
b = windowStats(ctx, name, [e.core(2), e.territory(2)], S);
if ~(a.complete && b.complete)
    lv.reason = "the segments before or after the edge are outside the record";
    return
end
tail = ceil((1 - C.settledPortion) * b.n):b.n;
lv.pre = lineAt(a.t, a.x, t0);
lv.post = lineAt(b.t(tail), b.x(tail), t0);
lv.low = min(lv.pre, lv.post);
lv.high = max(lv.pre, lv.post);
lv.amplitude = lv.high - lv.low;
if lv.post > lv.pre
    lv.direction = "rising";
else
    lv.direction = "falling";
end
sb = noiseLevel(b.x(tail));
lv.sigma = max(a.sigma, sb);
lv.quantStep = min(a.quantStep, b.quantStep);
lv.ok = lv.amplitude > 0;
if ~lv.ok
    lv.reason = "the signal does not change across the edge";
end

end

% =====================================================================
function y = lineAt(t, x, t0)
% Least-squares line through (t, x), evaluated at t0 (centred for
% numerical conditioning).
tm = mean(t);
c = [t - tm, ones(size(t))] \ x;
y = c(1) * (t0 - tm) + c(2);
end
