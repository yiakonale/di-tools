function r = measureEnergy(def, method, ctx, sig, S)
%MEASUREENERGY Switching energy and power, #5-12.
%
%   r = measureEnergy(def, method, ctx, sig, S) implements:
%     Eon, Eoff (#5, #6)  integral of V_DS * I_D over the method's window:
%                         two declared thresholds (resolveThreshold), a
%                         gate threshold plus params.energy.fixedDuration,
%                         or custom thresholds. Every method belongs to a
%                         method set (method.params.set).
%     Esw (#7)            E_off of pulse k + E_on of pulse k+1 (pair event,
%                         same operating point); refused unless both come
%                         from the same method set
%     Eio (#8)            integral of V_DC * I_D - I_L * V_DS,N from the gate
%                         instant until V_DS,N has settled (+ settleDelay);
%                         V_DC from the bus model, held at its value over
%                         the averaging window before the edge
%     EioPair (#8)        the same across both events of a pair
%     EswNonActive (#9)   direct: integral of V_DS,N * I_D,N over the active
%                         E window; indirect: E_io - E_on/E_off
%     Pon, Poff (#10, 11) E / window length, or peak V_DS * I_D in the window
%     Psw (#12)           cfg.switchingFrequency * E_sw, per switch, or
%                         * (E_sw + E_rr) of the complementary diode at the
%                         pair's turn-on (phase leg)
%
%   Composites evaluate their inputs through evaluateMeasurement, so they
%   use exactly the methods selected for #5 and #6, and say so in the tag.
%   Integration limits fall between samples; integrateBetween interpolates.

switch def.id
    case {"Eon", "Eoff"}
        r = energy(def, method, ctx, sig, S);
    case {"Pon", "Poff"}
        r = power(def, method, ctx, S);
    case "Esw"
        r = switchingEnergy(def, method, ctx, S);
    case {"Eio", "EioPair"}
        r = energyBalance(def, method, ctx, sig, S);
    case "EswNonActive"
        r = nonActiveEnergy(def, method, ctx, sig, S);
    case "Psw"
        r = switchingLoss(def, method, ctx, S);
end

end

% =====================================================================
function r = energy(def, method, ctx, sig, S)
r = makeResult(def, method, ctx);
p = method.params;
start = p.start;
stop = p.stop;
if isempty(start)                                   % custom
    c = S.measurements.params.custom.(def.id);
    if isempty(c)
        r.status = "skipped";
        r.reason = "no custom thresholds set (S.measurements.params.custom." + def.id + ")";
        return
    end
    if ~(isstruct(c) && isfield(c, 'start') && isfield(c, 'stop'))
        r.reason = "S.measurements.params.custom." + def.id + " must be struct('start', thr, 'stop', thr)";
        return
    end
    start = spec(c.start);
    stop = spec(c.stop);
end

a = resolveThreshold(ctx, start, -Inf, S);
if ~a.found
    r.reason = "start: " + a.reason;
    return
end
if isempty(stop)                                    % fixed duration
    t1 = a.time + S.measurements.params.energy.fixedDuration;
    if t1 > ctx.edges(1).territory(2)
        r.reason = sprintf(['the fixed %.3g us window runs past the edge''s territory (into ' ...
            'the next event); shorten S.measurements.params.energy.fixedDuration'], ...
            S.measurements.params.energy.fixedDuration * 1e6);
        return
    end
    b = struct('time', t1, 'level', NaN, 'margin', NaN);
else
    b = resolveThreshold(ctx, stop, a.time, S);
    if ~b.found
        r.reason = "stop: " + b.reason;
        return
    end
end

[E, peak, ok] = integrate(ctx, sig.V, sig.I, [a.time, b.time], S);
if ~ok
    r.reason = "the integration window lies outside the record";
    return
end
t0 = ctx.edges(1).time;
r.value = E;
r.provenance.window = [a.time, b.time] - t0;
r.provenance.peakPower = peak;
r.provenance.set = p.set;
r.provenance.levels = [a.level, b.level];
r.status = "ok";
end

% =====================================================================
function r = power(def, method, ctx, S)
r = makeResult(def, method, ctx);
eDef = registryEntry("E" + extractAfter(def.id, 1)); % "Pon" -> "Eon", "Poff" -> "Eoff"
er = evaluateMeasurement(eDef, ctx, S);
r = inherit(r, er, eDef.symbol);
if r.status ~= "ok"
    return
end
w = er.provenance.window;
if method.id == "average"
    r.value = er.value / (w(2) - w(1));
else
    r.value = er.provenance.peakPower;
end
r.provenance.window = w;
end

% =====================================================================
function r = switchingEnergy(def, method, ctx, S)
r = makeResult(def, method, ctx);
eOff = evaluateMeasurement(registryEntry("Eoff"), subContext(ctx, 1), S);
eOn = evaluateMeasurement(registryEntry("Eon"), subContext(ctx, 2), S);
if eOff.status ~= "ok" || eOn.status ~= "ok"
    r.status = worst(eOff.status, eOn.status);
    r.reason = "E_off: " + statusText(eOff) + "; E_on: " + statusText(eOn);
    return
end
if eOff.provenance.set ~= eOn.provenance.set
    r.reason = sprintf(['E_on (%s) and E_off (%s) come from different method sets; ' ...
        'choose a matching pair for #5 and #6'], eOn.methodTag, eOff.methodTag);
    return
end
r.value = eOn.value + eOff.value;
r.methodTag = sprintf('%s, %s', r.methodTag, eOn.methodTag);
r.flags = unique([eOn.flags, eOff.flags], 'stable');
r.provenance.Eon = eOn.value;
r.provenance.Eoff = eOff.value;
r.provenance.set = eOn.provenance.set;
r.status = "ok";
end

% =====================================================================
function r = energyBalance(def, method, ctx, sig, S)
r = makeResult(def, method, ctx);
C = S.measurements.common;
eStart = ctx.edges(1);
eEnd = ctx.edges(end);

p = 0.1 * (eStart.kind == "turnOn") + 0.9 * (eStart.kind == "turnOff");
g = gateInstant(ctx, eStart, p, S);
if ~g.found
    r.reason = g.reason;
    return
end
bv = busVoltageAt(ctx.col, [g.time - C.averagingWindow * eStart.D, g.time], S);
if isnan(bv.value)
    r.reason = "no bus voltage before the edge";
    return
end

% End: V_DS of the non-active device settled after the last edge.
sa = settledAfter(ctx, eEnd, sig.VN, S);
if ~sa.settled
    r.reason = "V_DS of the non-active device does not settle within the territory";
    return
end
ts = sa.time;
t1 = ts + S.measurements.params.Eio.settleDelay;
if t1 > eEnd.territory(2)
    r.reason = "the settling delay runs past the territory";
    return
end

range = [g.time, t1];
dt = ctx.col.sampleInterval;
id = getSignal(ctx.col, sig.I, range + [-dt, dt], S);
il = getSignal(ctx.col, sig.IL, range + [-dt, dt], S);
vN = getSignal(ctx.col, sig.VN, range + [-dt, dt], S);
if ~(numel(id.x) == numel(il.x) && numel(il.x) == numel(vN.x))
    r.reason = "the signals do not share one time grid over the window";
    return
end
[E, info] = integrateBetween(id.t, bv.value * id.x - il.x .* vN.x, range(1), range(2));
if ~info.complete
    r.reason = "the integration window lies outside the record";
    return
end
r.value = E;
r.methodTag = r.methodTag + ", V_DC from " + bv.label;
r.flags = bv.flags;
r.provenance.window = range - eStart.time;
r.provenance.Vdc = bv.value;
r.provenance.busVoltage = bv.description;
r.status = "ok";
end

% =====================================================================
function r = nonActiveEnergy(def, method, ctx, sig, S)
r = makeResult(def, method, ctx);
if ctx.kind == "turnOn"
    kindDef = registryEntry("Eon");
else
    kindDef = registryEntry("Eoff");
end
er = evaluateMeasurement(kindDef, ctx, S);
if er.status ~= "ok"
    r.status = er.status;
    r.reason = kindDef.symbol + ": " + er.reason;
    return
end
if method.id == "direct"
    w = er.provenance.window + ctx.edges(1).time;
    vName = sig.VN;
    iName = sig.IN;
    [E, ~, ok] = integrate(ctx, vName, iName, w, S);
    if ~ok
        r.reason = "the integration window lies outside the record";
        return
    end
    r.value = E;
    r.provenance.window = er.provenance.window;
else
    io = evaluateMeasurement(registryEntry("Eio"), ctx, S);
    if io.status ~= "ok"
        r.status = io.status;
        r.reason = "E_io: " + io.reason;
        return
    end
    r.value = io.value - er.value;
    r.provenance.Eio = io.value;
end
r.methodTag = sprintf('%s (%s %s)', r.methodTag, kindDef.symbol, er.methodTag);
r.provenance.Eactive = er.value;
r.status = "ok";
end

% =====================================================================
function r = switchingLoss(def, method, ctx, S)
r = makeResult(def, method, ctx);
es = evaluateMeasurement(registryEntry("Esw"), ctx, S);
if es.status ~= "ok"
    r.status = es.status;
    r.reason = "E_sw: " + es.reason;
    return
end
E = es.value;
r.methodTag = sprintf('%s, f_s = %.4g kHz, %s', r.methodTag, ctx.cfg.switchingFrequency / 1e3, es.methodTag);
r.flags = es.flags;
r.provenance.Esw = es.value;
if method.id == "phaseLeg"
    % E_rr of the same operating point: the diode recovers at the pair's
    % turn-on (MEASUREMENT_SPEC.md row 12).
    er = evaluateMeasurement(registryEntry("Err"), subContext(ctx, 2), S);
    if er.status ~= "ok"
        r.status = er.status;
        r.reason = "E_rr: " + er.reason;
        return
    end
    E = E + er.value;
    r.methodTag = sprintf('%s, E_rr %s', r.methodTag, er.methodTag);
    r.flags = unique([r.flags, er.flags], 'stable');
    r.provenance.Err = er.value;
end
r.value = ctx.cfg.switchingFrequency * E;
r.status = "ok";
end

% =====================================================================
function [E, peak, ok] = integrate(ctx, vName, iName, w, S)
% Integral and peak of v * i over w; one sample of margin for the
% interpolated limits.
dt = ctx.col.sampleInterval;
v = getSignal(ctx.col, vName, w + [-dt, dt], S);
i = getSignal(ctx.col, iName, w + [-dt, dt], S);
E = NaN;
peak = NaN;
ok = numel(v.x) == numel(i.x) && numel(v.x) >= 2;
if ~ok
    return
end
p = v.x .* i.x;
[E, info] = integrateBetween(v.t, p, w(1), w(2));
ok = info.complete;
inside = v.t >= w(1) & v.t <= w(2);
if any(inside)
    peak = max(p(inside));
end
end

function def = registryEntry(id)
persistent R
if isempty(R)
    R = measurementRegistry();
end
def = R([R.id] == id);
end

function sub = subContext(ctx, k)
% Single-edge context for edge k of a pair event.
sub = ctx;
sub.edges = ctx.edges(k);
sub.kind = ctx.edges(k).kind;
sub.edgeIds = ctx.edgeIds(k);
sub.pulseIndex = ctx.edges(k).pulseIndex;
end

function r = inherit(r, er, symbol)
% Status, flags and tag of the energy a power is derived from.
if er.status ~= "ok"
    r.status = er.status;
    r.reason = symbol + ": " + er.reason;
    return
end
r.methodTag = sprintf('%s (%s %s)', r.methodTag, symbol, er.methodTag);
r.flags = er.flags;
r.status = "ok";
end

function s = worst(a, b)
if a == "failed" || b == "failed"
    s = "failed";
else
    s = "skipped";
end
end

function s = statusText(r)
if r.status == "ok"
    s = "ok";
else
    s = r.status + " (" + r.reason + ")";
end
end

function s = spec(t)
edge = 1;
if isfield(t, 'edge')
    edge = t.edge;
end
s = struct('signal', string(t.signal), 'level', double(t.level), 'basis', string(t.basis), 'edge', edge);
end
