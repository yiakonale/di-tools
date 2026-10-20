function th = resolveThreshold(ctx, spec, after, S)
%RESOLVETHRESHOLD Time at which a declared threshold is crossed.
%
%   th = resolveThreshold(ctx, spec, after, S) evaluates one threshold of
%   a declarative method (MEASUREMENT_DESIGN.md 3.1) on the event context.
%
%   SPEC fields
%     signal     role, e.g. "drainVoltage@active", "gateVoltage@active"
%     level      p: fraction (0..1) for bases "transition", "Vdc", "gate";
%                volts or amps for "absolute"
%     basis      "transition": amplitude scale of the signal's own levels
%                              (eventLevels): low + p*(high - low)
%                "Vdc"       : p * V_DC (busVoltageAt, averaging window
%                              before the gate instant)
%                "gate"      : V_GS on S.measurements.common.gateBasis,
%                              timed by gateInstant (only for the active
%                              gate, in the edge's direction)
%                "absolute"  : the level itself
%     edge       which edge of the context (1, or 2 for pulse/break events)
%
%   Search: from AFTER (or the event window start) to the end of the
%   edge's territory (design 12.7), first crossing in the transition's
%   direction. Percent thresholds must pass the noise-floor rule
%   (transitionThreshold, k = noiseFloorMultiple).
%
%   Output struct: found, time [s, corrected], level, signal, reason,
%   noiseLimited (true when the noise-floor rule refused the level),
%   levels (eventLevels output, or [] for gate thresholds), margin.

arguments
    ctx (1,1) struct
    spec (1,1) struct
    after (1,1) double
    S (1,1) struct
end

if ~isfield(spec, 'edge')
    spec.edge = 1;
end
e = ctx.edges(spec.edge);
name = resolveRole(spec.signal, ctx.cfg, S);
th = struct('found', false, 'time', NaN, 'level', NaN, 'signal', name, ...
    'reason', "", 'levels', [], 'margin', NaN, 'noiseLimited', false);

%% Gate thresholds: timed like the gate edge itself
if spec.basis == "gate"
    if name ~= ctx.ev.signal
        th.reason = "a gate-basis threshold applies only to the active gate";
        return
    end
    g = gateInstant(ctx, e, spec.level, S);
    th.found = g.found;
    th.time = g.time;
    th.level = g.level;
    th.reason = g.reason;
    return
end

if ~any([ctx.col.channels.signal] == name)
    th.reason = "signal " + name + " is not in this collection";
    return
end

%% Level
lv = eventLevels(ctx, e, name, S);
th.levels = lv;
if ~lv.ok
    th.reason = name + ": " + lv.reason;
    return
end
switch spec.basis
    case "transition"
        level = lv.low + spec.level * lv.amplitude;
    case "Vdc"
        bv = busVoltageAt(ctx.col, [lv.gateTime - S.measurements.common.averagingWindow * e.D, ...
            lv.gateTime], S);
        if isnan(bv.value)
            th.reason = "no bus voltage for a V_DC-based threshold";
            return
        end
        level = spec.level * bv.value;
    case "absolute"
        level = spec.level;
    otherwise
        th.reason = "unknown threshold basis " + spec.basis;
        return
end
th.level = level;

chk = transitionThreshold(lv.pre, lv.post, level, lv.sigma, S.measurements.common.noiseFloorMultiple);
th.margin = chk.margin;
if ~chk.resolvable
    th.reason = name + ": " + chk.reason;
    th.noiseLimited = chk.noiseLimited;
    return
end

%% Crossing
t0 = max(after, e.window(1));
range = [t0, e.territory(2)];
if range(2) <= range(1)
    th.reason = "no search range left in the edge's territory";
    return
end
sig = getSignal(ctx.col, name, range, S);
c = findCrossing(sig.t, sig.x, level, lv.direction, [], "first");
th.found = c.found;
th.time = c.time;
if ~c.found
    th.reason = sprintf('%s never reaches %.4g %s (%s) before the territory ends', ...
        name, level, ctx.col.channels([ctx.col.channels.signal] == name).units, describe(spec));
    if spec.basis == "Vdc" && spec.level <= 0.05
        th.reason = th.reason + "; for IGBTs at high current the on-state voltage may " + ...
            "exceed it: consider the measured on-state level as 0 %";
    end
    th.reason = string(th.reason);
end

end

% =====================================================================
function s = describe(spec)
switch spec.basis
    case "transition", s = sprintf('%g %% of its transition', 100 * spec.level);
    case "Vdc",        s = sprintf('%g %% of V_DC', 100 * spec.level);
    otherwise,         s = "absolute level";
end
end
