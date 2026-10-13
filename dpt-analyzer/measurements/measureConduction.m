function results = measureConduction(def, method, ctx, sig, S)
%MEASURECONDUCTION Conduction quantities #49-54 (optional measurements).
%
%   results = measureConduction(def, method, ctx, sig, S) implements
%   registry entries VdsOn (#49), IdOn (#50), RonEff (#51), Vf (#52),
%   IfDiode (#53), PcondDevice and PcondDiode (#54).
%
%   On-state window (pulse events: turn-on edge, turn-off edge), selected
%   by S.measurements.methods.onStateWindow (the method itself for #49,
%   #50 and #54; its first entry for #51):
%     finalPortion  averagingWindow*D ending at the turn-off gate instant
%                   (V_GS 90 % falling)
%     delayToEnd    from S.measurements.params.onStateWindow.delay after
%                   V_DS reaches 10 % at turn-on ([] = the V_DS settling
%                   time) to the turn-off gate instant
%     custom        S.measurements.params.onStateWindow.custom, relative
%                   to the turn-off gate instant
%
%   Diode window (break events: turn-off of pulse k, turn-on of k+1):
%   from the settling of the non-active device's V_DS after the turn-off
%   (+ S.measurements.params.breakWindow.delay) to the next turn-on gate
%   instant (V_GS 10 % rising). The diode is the non-active device's: its
%   voltage is -V_DS and its current -I_D (sign conventions, Q1), or the
%   whole inductor current, since the active device is off.
%
%   On-state voltages read on a full-range channel are flagged
%   "resolutionLimited" when below resolutionSteps ADC steps; a clamped
%   channel (Vds-*-clamp) is used automatically when mapped.

C = S.measurements.common;
r = makeResult(def, method, ctx);
r.provenance.currentsNormalized = ctx.col.normalization.applied;

%% Window
if ctx.kind == "pulse"
    if def.methodKey == "onStateWindow"
        windowMethod = method.id;
    else
        windowMethod = S.measurements.methods.onStateWindow(1);
    end
    [range, t10, why] = onStateWindow(ctx, windowMethod, S);
    r.provenance.windowMethod = windowMethod;
else
    [range, why] = diodeWindow(ctx, sig, S);
    t10 = NaN;
end
if why ~= ""
    r.reason = why;
    results = r;
    return
end
r.provenance.window = range - ctx.edges(1).time;

%% Time-resolved R_on: one result per delay
if def.id == "RonEff" && method.id == "timeResolved"
    delays = S.measurements.params.RonEff.delays;
    if isempty(delays)
        r.status = "skipped";
        r.reason = "no delays set (S.measurements.params.RonEff.delays)";
        results = r;
        return
    end
    if isnan(t10)
        [~, t10, why] = onStateWindow(ctx, "delayToEnd", S);
        if why ~= ""
            r.reason = why;
            results = r;
            return
        end
    end
    halfWidth = C.instantHalfWidth * ctx.edges(1).D;
    results = repmat(r, 1, numel(delays));
    for k = 1:numel(delays)
        rk = r;
        w = t10 + delays(k) + [-1, 1] * halfWidth;
        rk.provenance.delay = delays(k);
        rk.provenance.window = w - ctx.edges(1).time;
        rk = ratioResult(rk, ctx, sig, w, S);
        results(k) = rk;
    end
    return
end

%% Single-valued quantities
switch def.id
    case "VdsOn"
        st = windowStats(ctx, sig.V, range, S);
        r = levelResult(r, st, st.mean, S, true);
    case "IdOn"
        st = windowStats(ctx, sig.I, range, S);
        r = levelResult(r, st, st.mean, S, false);
    case "RonEff"
        r = ratioResult(r, ctx, sig, range, S);
    case "Vf"
        st = windowStats(ctx, sig.V, range, S);
        r = levelResult(r, st, -st.mean, S, true);
    case "IfDiode"
        st = windowStats(ctx, sig.I, range, S);
        value = st.mean;
        if method.id == "measuredDiode"
            value = -value;
        end
        r = levelResult(r, st, value, S, false);
    case {"PcondDevice", "PcondDiode"}
        sv = windowStats(ctx, sig.V, range, S);
        si = windowStats(ctx, sig.I, range, S);
        if ~(sv.complete && si.complete) || sv.n ~= si.n
            r.reason = "the window lies outside the record";
        else
            v = sv.x;
            i = si.x;
            if def.id == "PcondDiode"
                v = -v;                                % diode voltage
                if endsWith(sig.IRole, "@nonActive")
                    i = -i;                            % diode current
                end
            end
            p = v .* i;
            r.value = mean(p);
            r.provenance.nSamples = sv.n;
            % A power is only as resolved as its voltage.
            r.flags = unique([valueFlags(r.value, noiseLevel(p), NaN, S), ...
                setdiff(valueFlags(mean(v), sv.sigma, sv.quantStep, S, true), ...
                "belowNoiseFloor")], 'stable');
            r.status = "ok";
        end
end
results = r;

end

% =====================================================================
function r = levelResult(r, st, value, S, checkResolution)
if ~st.complete
    r.reason = "the window lies outside the record";
    return
end
r.value = value;
r.provenance.nSamples = st.n;
r.provenance.sigma = st.sigma;
r.provenance.quantStep = st.quantStep;
r.flags = valueFlags(value, st.sigma, st.quantStep, S, checkResolution);
r.status = "ok";
end

function r = ratioResult(r, ctx, sig, range, S)
% Mean of V_DS / I_D; every current sample must be resolvable.
sv = windowStats(ctx, sig.V, range, S);
si = windowStats(ctx, sig.I, range, S);
if ~(sv.complete && si.complete) || sv.n ~= si.n
    r.reason = "the window lies outside the record";
    return
end
floorI = S.measurements.common.noiseFloorMultiple * si.sigma;
if min(abs(si.x)) < floorI
    r.reason = sprintf(['I_D falls below its noise floor (%.3g A) inside the window, ' ...
        'so V_DS/I_D is undefined there'], floorI);
    return
end
ratio = sv.x ./ si.x;
r.value = mean(ratio);
r.provenance.nSamples = sv.n;
r.flags = valueFlags(mean(sv.x), sv.sigma, sv.quantStep, S, true);   % V_DS resolution
r.status = "ok";
end

% =====================================================================
function [range, t10, why] = onStateWindow(ctx, windowMethod, S)
C = S.measurements.common;
on = ctx.edges(1);
off = ctx.edges(2);
range = [NaN NaN];
t10 = NaN;
why = "";

g90 = gateInstant(ctx, off, 0.9, S);
if ~g90.found
    why = g90.reason;
    return
end

switch windowMethod
    case "finalPortion"
        range = [g90.time - C.averagingWindow * off.D, g90.time];
    case "custom"
        custom = S.measurements.params.onStateWindow.custom;
        if isempty(custom)
            why = "no custom window set (S.measurements.params.onStateWindow.custom)";
            return
        end
        range = g90.time + custom;
    case "delayToEnd"
        vName = resolveRole("drainVoltage@active", ctx.cfg, S);
        if ~any([ctx.col.channels.signal] == vName)
            why = "needs the full-range " + vName + " for the V_DS 10 % crossing";
            return
        end
        before = windowStats(ctx, vName, [on.territory(1), on.window(1)], S);
        after = windowStats(ctx, vName, [on.core(2), on.territory(2)], S);
        if ~(before.complete && after.complete)
            why = "the turn-on territory is too short or outside the record";
            return
        end
        post = median(after.x(ceil((1 - C.settledPortion) * after.n):end));
        pre = before.median;
        level = post + 0.1 * (pre - post);           % 10 % on the amplitude scale
        v = windowStats(ctx, vName, [on.window(1), on.territory(2)], S);
        c10 = findCrossing(v.t, v.x, level, "falling", [], "first");
        if ~c10.found
            why = "V_DS does not fall to 10 % at the turn-on";
            return
        end
        t10 = c10.time;
        delay = S.measurements.params.onStateWindow.delay;
        if isempty(delay)
            band = C.settlingBand * abs(pre - post);
            [ts, si] = settlingTime(v.t, v.x, post, band, [t10, on.territory(2)]);
            if ~si.settled
                why = "V_DS does not settle after the turn-on within its territory";
                return
            end
            start = ts;
        else
            start = t10 + delay;
        end
        range = [start, g90.time];
        if range(1) >= range(2)
            why = "the delay leaves no on-state window before the turn-off";
        end
end
end

% =====================================================================
function [range, why] = diodeWindow(ctx, sig, S)
C = S.measurements.common;
off = ctx.edges(1);
on = ctx.edges(2);
range = [NaN NaN];
why = "";
before = windowStats(ctx, sig.Vref, [off.territory(1), off.window(1)], S);
after = windowStats(ctx, sig.Vref, [off.core(2), off.territory(2)], S);
if ~(before.complete && after.complete)
    why = "the turn-off territory is too short or outside the record";
    return
end
settled = median(after.x(ceil((1 - C.settledPortion) * after.n):end));
band = C.settlingBand * abs(before.median - settled);
[ts, si] = settlingTime(after.t, after.x, settled, band);
if ~si.settled
    why = "the non-active V_DS does not settle after the turn-off within its territory";
    return
end
g10 = gateInstant(ctx, on, 0.1, S);
if ~g10.found
    why = g10.reason;
    return
end
range = [ts + S.measurements.params.breakWindow.delay, g10.time];
if range(1) >= range(2)
    why = "no diode-conduction window between the settled turn-off and the next turn-on";
end
end
