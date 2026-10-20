function r = measureSwitchingCurrent(def, method, ctx, sig, S)
%MEASURESWITCHINGCURRENT Current at turn-off (#3) or turn-on (#4).
%
%   r = measureSwitchingCurrent(def, method, ctx, sig, S) implements the
%   methods of registry entries Ioff and Ion. The gate instant is V_GS 90 %
%   falling at turn-off and V_GS 10 % rising at turn-on.
%
%     inductorAtInstant  mean of I_L over +/- instantHalfWidth*D around the
%                        gate instant (default; MEASUREMENT_DESIGN.md 5.2)
%     idAtGate90         (#3) mean of I_D over the same window
%     filteredIdPre      (#3) mean of I_D over averagingWindow*D ending at
%                        the gate instant
%     loadPre            (#4) mean of the load current, else of the
%                        measured diode current (-I_D of the non-active
%                        device), over averagingWindow*D ending at it
%     extrapolatedId     (#4) I_D after the turn-on ringing: a line is
%                        fitted to the territory's final settledPortion;
%                        the settling time is when I_D stays within
%                        settlingBand of that line; a line fitted over
%                        extrapolationFit*D from there is evaluated at the
%                        gate instant
%     nominal            cfg.nominal.testCurrent
%
%   A centred mean on the linear inductor ramp equals the instantaneous
%   value, without its sample noise and quantization.

r = makeResult(def, method, ctx);
e = ctx.edges(1);
C = S.measurements.common;
r.provenance.currentsNormalized = ctx.col.normalization.applied;

if method.id == "nominal"
    r.value = ctx.cfg.nominal.testCurrent;
    r.status = "ok";
    r.provenance.source = "cfg.nominal.testCurrent";
    return
end

p = 0.9 * (e.kind == "turnOff") + 0.1 * (e.kind == "turnOn");
g = gateInstant(ctx, e, p, S);
if ~g.found
    r.reason = g.reason;
    return
end
r.provenance.gateInstant = g.time - e.time;
r.provenance.gateLevel = g.level;

switch method.id
    case {"inductorAtInstant", "idAtGate90"}
        range = g.time + [-1, 1] * C.instantHalfWidth * e.D;
    case {"filteredIdPre", "loadPre"}
        range = [g.time - C.averagingWindow * e.D, g.time];
    case "extrapolatedId"
        [r, st] = extrapolated(r, ctx, e, sig, g, C, S);
        if r.status ~= "ok"
            return
        end
end

if method.id ~= "extrapolatedId"
    st = windowStats(ctx, sig.I, range, S);
    if ~st.complete
        r.reason = "the averaging window lies outside the record";
        return
    end
    r.value = st.mean;
    if isfield(sig, 'IRole') && endsWith(sig.IRole, "@nonActive")
        r.value = -r.value;      % diode current = -I_D of the non-active device
    end
    r.provenance.window = range - e.time;
end

r.provenance.nSamples = st.n;
r.provenance.sigma = st.sigma;
r.flags = valueFlags(r.value, st.sigma, st.quantStep, S);
r.status = "ok";

end

% =====================================================================
function [r, st] = extrapolated(r, ctx, e, sig, g, C, S)
st = windowStats(ctx, sig.I, [e.core(2), e.territory(2)], S);
if ~st.complete
    r.reason = "the territory after the turn-on is too short or outside the record";
    return
end
sa = settledAfter(ctx, e, sig.I, S, trend=true);
if ~sa.settled
    r.reason = sprintf('I_D does not settle to within +/- %.3g A of its trend', sa.band);
    return
end
ts = sa.time;
fitRange = [ts, min(ts + C.extrapolationFit * e.D, e.territory(2))];
fitSt = windowStats(ctx, sig.I, fitRange, S);
if ~fitSt.complete
    r.reason = "too few samples to fit the settled current";
    return
end
line = [fitSt.t, ones(fitSt.n, 1)] \ fitSt.x;
r.value = line(1) * g.time + line(2);
r.provenance.settlingTime = ts - e.time;
r.provenance.fitWindow = fitRange - e.time;
r.provenance.slope = line(1);
st = fitSt;
r.status = "ok";
end
