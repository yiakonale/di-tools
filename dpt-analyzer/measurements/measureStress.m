function r = measureStress(def, method, ctx, sig, S)
%MEASURESTRESS Voltage, current and gate stress, #29-38.
%
%   r = measureStress(def, method, ctx, sig, S) implements
%     VdsMax (#29)     max V_DS after the turn-off gate instant until the
%                      ringing decays ("untilSettled"), within
%                      params.stress.after90Window D after V_DS 90 %
%                      ("after90"), or in a custom window
%     dVdsOver (#30)   V_DS,max - reference
%     dVdsUnder (#31)  turn-off: min V_DS after the peak, until the ringing
%                      decays, - reference; turn-on: the dip, min V_DS
%                      during the current rise (I_D 10 % to 90 %), -
%                      reference
%     IdMax (#32)      max I_D after the turn-on gate instant until I_D
%                      settles on its linear trend, or in a custom window
%     dIdOver (#33)    I_D,max - reference
%     dIdUnder (#34)   turn-on: min I_D after the peak; turn-off: min I_D
%                      after it falls to 10 %; both until settled, minus
%                      the reference
%     VgsMax, VgsMin (#35, #36)  max / min V_GS of the active device in its
%                      own switching window, or over the whole capture
%     VgsNMin, VgsNMax (#37, #38) min V_GS of the non-active device during
%                      the active turn-off, max during the active turn-on,
%                      each until the active V_DS settles
%
%   Over/undershoot methods choose the reference (design 15.2):
%     ownLevel  the signal's own level: settled after the edge, or the
%               pre-switching level for the turn-on dip (default)
%     busModel  V_DC(t) before the edge         (voltages)
%     Ion       I_on / I_off of the event      (currents)
%     nominal   cfg.nominal.busVoltage / testCurrent
%   Undershoots are negative below the reference; the percentage of the
%   reference is in provenance.percent. Peaks are raw samples. Ratings
%   (cfg.ratings) set the flag "exceedsRating"; a window that ends because
%   the territory ends, not because the ringing decayed, is flagged
%   "ringingNotDecayed".

switch def.id
    case "VdsMax"
        r = peak(def, method, ctx, sig.V, "VdsMax", false, S);
        r = rate(r, ctx.cfg.ratings.VdsMax, "VdsMax", "above");
    case "IdMax"
        r = peak(def, method, ctx, sig.I, "IdMax", true, S);
    case {"dVdsOver", "dIdOver", "dVdsUnder", "dIdUnder"}
        r = excursion(def, method, ctx, sig, S);
    case {"VgsMax", "VgsMin"}
        r = gatePeak(def, method, ctx, sig.gate, S);
    case {"VgsNMin", "VgsNMax"}
        r = crosstalk(def, method, ctx, sig, S);
end

end

% =====================================================================
function r = peak(def, method, ctx, name, key, isCurrent, S)
% Maximum of NAME over the method's window; also returns the window.
r = makeResult(def, method, ctx);
e = ctx.edges(1);
g = gateTime(ctx, e, S);
settled = true;
switch method.id
    case "untilSettled"
        [ts, settled] = settledEnd(ctx, e, name, isCurrent, S);
        range = [g, ts];
    case "after90"
        spec = struct('signal', "drainVoltage@active", 'level', 0.9, 'basis', "transition", 'edge', 1);
        c90 = resolveThreshold(ctx, spec, g, S);
        if ~c90.found
            r.reason = "V_DS 90 %: " + c90.reason;
            return
        end
        range = [c90.time, min(c90.time + S.measurements.params.stress.after90Window * e.D, ...
            e.territory(2))];
    case "custom"
        w = S.measurements.params.custom.(key);
        if isempty(w)
            r.status = "skipped";
            r.reason = "no custom window set (S.measurements.params.custom." + key + ")";
            return
        end
        range = g + double(w(:)');
end
s = getSignal(ctx.col, name, range, S);
if numel(s.x) < 2
    r.reason = "the peak window is empty or outside the record";
    return
end
[r.value, k] = max(s.x);
r.provenance.time = s.t(k) - e.time;
r.provenance.window = range - e.time;
if ~settled
    r.flags = "ringingNotDecayed";
end
r.status = "ok";
end

% =====================================================================
function r = excursion(def, method, ctx, sig, S)
r = makeResult(def, method, ctx);
e = ctx.edges(1);
isCurrent = startsWith(def.id, "dId");
name = sig.x;
peakId = "VdsMax";
if isCurrent
    peakId = "IdMax";
end
lv = eventLevels(ctx, e, name, S);
g = gateTime(ctx, e, S);
over = endsWith(def.id, "Over");

%% Extremum and its window
if over || (~isCurrent && e.kind == "turnOff") || (isCurrent && e.kind == "turnOn")
    % Use the matching peak measurement's window (#29 / #32).
    pk = evaluateMeasurement(registryEntry(peakId), ctx, S);
    if pk.status ~= "ok"
        r.status = pk.status;
        r.reason = registryEntry(peakId).symbol + ": " + pk.reason;
        return
    end
    w = pk.provenance.window + e.time;
    r.flags = pk.flags(pk.flags == "ringingNotDecayed");
    r.methodTag = r.methodTag + " (" + pk.methodTag + ")";
    if over
        x = pk.value;
        r.provenance.time = pk.provenance.time;
    else
        s = getSignal(ctx.col, name, [pk.provenance.time + e.time, w(2)], S);
        [x, k] = min(s.x);
        r.provenance.time = s.t(k) - e.time;
    end
    r.provenance.window = w - e.time;
    ownSide = "post";
elseif ~isCurrent                      % turn-on dip: current-rise phase
    iName = resolveRole("drainCurrent@active", ctx.cfg, S);
    if ~any([ctx.col.channels.signal] == iName)
        r.reason = "the turn-on dip window needs " + iName + " (the current-rise phase)";
        return
    end
    a = resolveThreshold(ctx, struct('signal', "drainCurrent@active", 'level', 0.1, 'basis', "transition", 'edge', 1), g, S);
    b = resolveThreshold(ctx, struct('signal', "drainCurrent@active", 'level', 0.9, 'basis', "transition", 'edge', 1), a.time, S);
    if ~(a.found && b.found)
        r.reason = "current-rise phase: " + strjoin([a.reason, b.reason], "; ");
        return
    end
    s = getSignal(ctx.col, name, [a.time, b.time], S);
    [x, k] = min(s.x);
    r.provenance.time = s.t(k) - e.time;
    r.provenance.window = [a.time, b.time] - e.time;
    ownSide = "pre";
else                                   % current undershoot after a turn-off
    a = resolveThreshold(ctx, struct('signal', "drainCurrent@active", 'level', 0.1, 'basis', "transition", 'edge', 1), g, S);
    if ~a.found
        r.reason = "I_D 10 %: " + a.reason;
        return
    end
    [ts, settled] = settledEnd(ctx, e, name, true, S);
    % The settling time is where the falling current ENTERS the band, so
    % search one averaging window beyond it: after ts the current stays
    % within the band, and the minimum is not cut off at the band edge.
    tEnd = min(max(ts, a.time) + S.measurements.common.averagingWindow * e.D, e.territory(2));
    s = getSignal(ctx.col, name, [a.time, tEnd], S);
    [x, k] = min(s.x);
    r.provenance.time = s.t(k) - e.time;
    r.provenance.window = [a.time, tEnd] - e.time;
    if ~settled
        r.flags = "ringingNotDecayed";
    end
    ownSide = "post";
end

%% Reference
if isCurrent && e.kind == "turnOff" && method.id ~= "ownLevel"
    % After a turn-off the current settles at 0 A: an undershoot below
    % I_off or the test current would only restate that current.
    r.status = "skipped";
    r.reason = "a turn-off current undershoot is relative to the off-state level (ownLevel) only";
    return
end
switch method.id
    case "ownLevel"
        % The signal's own level at the moment of the extremum: a ramping
        % current has moved on since the gate instant.
        lvAt = eventLevels(ctx, e, name, S, r.provenance.time + e.time);
        ref = lvAt.(ownSide);
        refOk = abs(ref) > S.measurements.common.noiseFloorMultiple * lv.sigma;
    case "busModel"
        bv = busVoltageAt(ctx.col, [g - S.measurements.common.averagingWindow * e.D, g], S);
        ref = bv.value;
        r.flags = unique([r.flags, bv.flags], 'stable');
        refOk = true;
    case "Ion"
        if e.kind == "turnOn", opId = "Ion"; else, opId = "Ioff"; end
        op = evaluateMeasurement(registryEntry(opId), ctx, S);
        if op.status ~= "ok"
            r.status = op.status;
            r.reason = op.symbol + ": " + op.reason;
            return
        end
        ref = op.value;
        refOk = true;
    case "nominal"
        if isCurrent, ref = ctx.cfg.nominal.testCurrent; else, ref = ctx.cfg.nominal.busVoltage; end
        refOk = true;
end
r.value = x - ref;
r.provenance.extremum = x;
r.provenance.reference = ref;
if refOk && ref ~= 0
    r.provenance.percent = 100 * r.value / abs(ref);
end
if isnan(r.value)
    r.reason = "no reference value";
    return
end
r.status = "ok";
end

% =====================================================================
function r = gatePeak(def, method, ctx, name, S)
r = makeResult(def, method, ctx);
if ctx.kind == "capture"
    s = getSignal(ctx.col, name, [], S);
    t0 = 0;
else
    e = ctx.edges(1);
    s = getSignal(ctx.col, name, e.window, S);
    t0 = e.time;
end
if def.id == "VgsMax"
    [r.value, k] = max(s.x);
    r = rate(r, ctx.cfg.ratings.VgsMax, "VgsMax", "above");
else
    [r.value, k] = min(s.x);
    r = rate(r, ctx.cfg.ratings.VgsMin, "VgsMin", "below");
end
r.provenance.time = s.t(k) - t0;
r.status = "ok";
end

% =====================================================================
function r = crosstalk(def, method, ctx, sig, S)
r = makeResult(def, method, ctx);
e = ctx.edges(1);
g = gateTime(ctx, e, S);
[ts, settled] = settledEnd(ctx, e, sig.V, false, S);
s = getSignal(ctx.col, sig.gateN, [g, ts], S);
if numel(s.x) < 2
    r.reason = "the window is empty or outside the record";
    return
end
if def.id == "VgsNMax"
    [r.value, k] = max(s.x);
    r = rate(r, ctx.cfg.ratings.VgsThMin, "VgsThMin", "above");
else
    [r.value, k] = min(s.x);
    r = rate(r, ctx.cfg.ratings.VgsMin, "VgsMin", "below");
end
r.provenance.time = s.t(k) - e.time;
r.provenance.window = [g, ts] - e.time;
if ~settled
    r.flags = unique([r.flags, "ringingNotDecayed"], 'stable');
end
r.status = "ok";
end

% =====================================================================
function r = rate(r, limit, name, side)
% Boolean rating check (no transient limits, design 15.2).
r.provenance.rating = struct('name', string(name), 'value', limit);
if isempty(limit) || isnan(r.value)
    return
end
if (side == "above" && r.value > limit) || (side == "below" && r.value < limit)
    r.flags = unique([r.flags, "exceedsRating"], 'stable');
end
end

function g = gateTime(ctx, e, S)
p = 0.1 * (e.kind == "turnOn") + 0.9 * (e.kind == "turnOff");
gi = gateInstant(ctx, e, p, S);
if gi.found
    g = gi.time;
else
    g = e.time;
end
end

function [ts, settled] = settledEnd(ctx, e, name, trend, S)
% End of the ringing (settledAfter; a ramping current settles on its local
% trend). Falls back to the territory end when it never settles.
st = settledAfter(ctx, e, name, S, trend=trend);
settled = st.settled;
if settled
    ts = st.time;
else
    ts = e.territory(2);
end
end

function def = registryEntry(id)
persistent R
if isempty(R)
    R = measurementRegistry();
end
def = R([R.id] == id);
end
