function g = gateInstant(ctx, e, p, S)
%GATEINSTANT Time at which the active gate crosses p % on one of its edges.
%
%   g = gateInstant(ctx, e, p, S) returns the crossing of the active
%   gate's p % level on edge E of the event context CTX, e.g. p = 0.1 on a
%   turn-on ("V_GS 10 % rising") or p = 0.9 on a turn-off.
%
%   Level: amplitude scale (MEASUREMENT_DESIGN.md 5.4) on the basis
%   S.measurements.common.gateBasis (Q3), using the gate levels measured
%   at detection:
%     "swing": low + p * (high - low)     "zero": p * high
%
%   Timing: the same local, zero-phase smoothing as the gate edge's own
%   reference crossing (e.smoothingSamples, S.detection.timingSmoothing),
%   so gate-referenced measurement instants get the same noise immunity.
%   The search runs from the event window's start to the end of the
%   qualified edge; the last crossing in the edge's direction is used,
%   as in detection.
%
%   Output struct: found, time [s, corrected], level [V], basis,
%   smoothingSamples, reason ("" when found).

arguments
    ctx (1,1) struct
    e (1,1) struct
    p (1,1) double {mustBeInRange(p, 0, 1)}
    S (1,1) struct
end

lv = ctx.ev.levels;
basis = S.measurements.common.gateBasis;
if basis == "swing"
    level = lv.low + p * (lv.high - lv.low);
else
    level = p * lv.high;
end

n = e.smoothingSamples;
pad = (n - 1) / 2 * ctx.col.sampleInterval;
search = [e.window(1), e.core(2)];
sig = getSignal(ctx.col, ctx.ev.signal, search + [-pad, pad], S);
x = filterSignal(sig.x, "movmean", n);
c = findCrossing(sig.t, x, level, e.direction, search, "last");

g.found = c.found;
g.time = c.time;
g.level = level;
g.basis = basis;
g.smoothingSamples = n;
if c.found
    g.reason = "";
else
    g.reason = sprintf('the gate does not cross its %g %% level (%.3g V, %s basis) %s on edge %d', ...
        100 * p, level, basis, e.direction, e.edgeId);
end
g.reason = string(g.reason);

end
