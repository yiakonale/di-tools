function r = measureDeadTime(def, method, ctx, sig, S)
%MEASUREDEADTIME Half-bridge dead time between the complementary gates (#23).
%
%   r = measureDeadTime(def, method, ctx, sig, S) measures, on one edge of
%   the active device, the time from the outgoing gate's falling crossing
%   to the incoming gate's rising crossing:
%     turn-on   outgoing = non-active gate, incoming = active gate
%     turn-off  outgoing = active gate, incoming = non-active gate
%   Both transitions are thus reported as separate events, labelled e.g.
%   "HS->LS" in the provenance. A negative value (overlap) is reported as
%   measured and flagged "negativeDeadTime".
%
%   Only meaningful in synchronous mode: the measurement is skipped when
%   the complementary gate is not actively driven, i.e. it does not spend
%   at least one gate-edge duration D on each side of its nominal midpoint
%   within the edge's territory.
%
%   Levels: "conv" at 50 % of each gate's own swing; "custom" from
%   S.measurements.params.custom.deadTime = struct('level', v, 'basis', b),
%   b = "swing" (fraction of each gate's swing) or "absolute" (volts, e.g.
%   the datasheet V_GS(th), applied to both gates).

r = makeResult(def, method, ctx);
e = ctx.edges(1);
dt = ctx.col.sampleInterval;
cfg = ctx.cfg;

level = 0.5;
basis = "swing";
if method.id == "custom"
    c = S.measurements.params.custom.deadTime;
    if isempty(c)
        r.status = "skipped";
        r.reason = "no custom level set (S.measurements.params.custom.deadTime)";
        return
    end
    if ~(isstruct(c) && isfield(c, 'level') && isfield(c, 'basis') && any(string(c.basis) == ["swing", "absolute"]))
        r.reason = 'S.measurements.params.custom.deadTime must be struct(''level'', v, ''basis'', "swing"|"absolute")';
        return
    end
    level = double(c.level);
    basis = string(c.basis);
end

%% Is the complementary gate driven?
n = e.smoothingSamples;
gN = getSignal(ctx.col, sig.gateN, e.territory, S);
xN = filterSignal(gN.x, "movmean", n);
mid = (cfg.gate.nominal.high + cfg.gate.nominal.low) / 2;
minSamples = e.D / dt;
if nnz(xN >= mid) < minSamples || nnz(xN < mid) < minSamples
    r.status = "skipped";
    r.reason = sprintf(['the complementary gate %s is not actively driven (it does not stay ' ...
        'on both sides of its nominal midpoint, %.3g V, for at least one gate-edge duration)'], ...
        sig.gateN, mid);
    return
end
lowN = median(xN(xN < mid));
highN = median(xN(xN >= mid));

%% Levels of both gates
lvA = ctx.ev.levels;
if basis == "swing"
    levelN = lowN + level * (highN - lowN);
    pA = level;
else
    levelN = level;
    if S.measurements.common.gateBasis == "swing"
        pA = (level - lvA.low) / (lvA.high - lvA.low);
    else
        pA = level / lvA.high;
    end
end
if ~(pA > 0 && pA < 1 && levelN > lowN && levelN < highN)
    r.reason = "the dead-time level lies outside one of the gate swings";
    return
end

%% Crossings
gA = gateInstant(ctx, e, pA, S);
if ~gA.found
    r.reason = gA.reason;
    return
end
active = cfg.activeDevice;
other = setdiff(["HS", "LS"], active);
% The complementary gate's crossing is searched over the whole territory,
% so an overlap (it switches after the active gate) is found too.
if e.kind == "turnOn"
    c = findCrossing(gN.t, xN, levelN, "falling", e.territory, "first");
    tOut = c.time;
    tIn = gA.time;
    label = other + "->" + active;
else
    c = findCrossing(gN.t, xN, levelN, "rising", e.territory, "first");
    tOut = gA.time;
    tIn = c.time;
    label = active + "->" + other;
end
if ~c.found
    r.reason = sprintf('the complementary gate does not cross %.3g V around this edge', levelN);
    return
end

r.value = tIn - tOut;
r.provenance.transition = label;
r.provenance.levels = struct('active', gA.level, 'nonActive', levelN);
r.provenance.times = [tOut, tIn] - e.time;
if r.value < 0
    r.flags = "negativeDeadTime";
end
r.status = "ok";

end
