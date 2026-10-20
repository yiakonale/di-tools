function r = measureParasitics(def, method, ctx, sig, S)
%MEASUREPARASITICS Switching-loop inductance #47 and parasitic capacitance #55.
%
%   r = measureParasitics(def, method, ctx, sig, S) implements
%     Lloop (#47)
%       dip        turn-on: L = integral (V_DS,pre - V_DS) dt / Delta I_D over
%                  I_D 10-90 %, V_DS,pre = the active V_DS's own pre-switching
%                  level (V_DC + V_F: the diode still conducts while the
%                  current rises). The integral is L * Delta I exactly for
%                  any di/dt shape, without differentiating noise.
%       dipVdc     the same against V_DC(t) before the edge (the spec's
%                  literal form; includes V_F)
%       ringing    turn-off: L = 1 / ((2 pi f_r)^2 C), f_r of the active V_DS
%                  ringing from its first crossing after the #29 peak to the
%                  end of the #29 window, C = cfg.circuit.Coss (the active
%                  device's small-signal C_oss at V_DC); skipped without it.
%                  Not the #55 charge-based C: that is the non-active
%                  device's large-signal C_eq (on the example ~half the
%                  resonant C, giving twice the dip's L; design 18.3)
%       overshoot  turn-off: dV_DS,over (#30) / di/dt (#25), flagged
%                  "includesCapacitiveCharging" (spec: less reliable)
%     Cpar (#55)
%       LC         turn-off: C = 1 / ((2 pi f_r)^2 L), L from #47 by the dip
%                  at the same pulse's turn-on, else by this edge's
%                  overshoot (never by ringing: no cycle)
%       charge     C_eq = Q_oss (#48) / its V_DS,N swing (non-active device)
%   The model is stated in the tag (MEASUREMENT_DESIGN.md section 18).

r = makeResult(def, method, ctx);
switch def.id
    case "Lloop"
        switch method.id
            case {"dip", "dipVdc"}
                r = dipInductance(r, method, ctx, sig, S);
            case "ringing"
                r = ringingInductance(r, ctx, sig, S);
            case "overshoot"
                r = overshootInductance(r, ctx, S);
        end
    case "Cpar"
        if method.id == "LC"
            r = lcCapacitance(r, ctx, sig, S);
        else
            r = chargeCapacitance(r, ctx, S);
        end
end
end

% =====================================================================
function r = dipInductance(r, method, ctx, sig, S)
C = S.measurements.common;
e = ctx.edges(1);
g = gateInstant(ctx, e, 0.1, S);
if ~g.found
    r.reason = "V_GS 10 %: " + g.reason;
    return
end
spec = @(p) struct('signal', "drainCurrent@active", 'level', p, 'basis', "transition", 'edge', 1);
a = resolveThreshold(ctx, spec(0.1), g.time, S);
if ~a.found
    r.reason = "I_D 10 %: " + a.reason;
    r.noiseLimited = a.noiseLimited;
    return
end
b = resolveThreshold(ctx, spec(0.9), a.time, S);
if ~b.found
    r.reason = "I_D 90 %: " + b.reason;
    r.noiseLimited = b.noiseLimited;
    return
end
lv = eventLevels(ctx, e, sig.V, S);
if ~lv.ok
    r.reason = sig.V + ": " + lv.reason;
    return
end
if method.id == "dip"
    ref = lv.pre;
    r.provenance.reference = "own pre-switching V_DS";
else
    bv = busVoltageAt(ctx.col, [g.time - C.averagingWindow * e.D, g.time], S);
    if isnan(bv.value)
        r.reason = "no bus voltage before the edge";
        return
    end
    ref = bv.value;
    r.flags = bv.flags;
    r.provenance.reference = "V_DC: " + bv.description;
end
dt = ctx.col.sampleInterval;
v = getSignal(ctx.col, sig.V, [a.time, b.time] + [-dt, dt], S);
if numel(v.x) < 3
    r.reason = "the current rise is shorter than three samples";
    return
end
inWin = v.t >= a.time & v.t <= b.time;
if min(v.x(inWin)) < lv.pre - 0.5 * lv.amplitude
    r.reason = ['V_DS collapses during the current rise (I_D 10-90 %): the dip method needs ' ...
        'V_DS clamped by the conducting diode (hard switching)'];
    return
end
[flux, info] = integrateBetween(v.t, ref - v.x, a.time, b.time);
dI = b.level - a.level;
if ~info.complete || ~(flux > 0) || ~(dI > 0)
    r.reason = "no V_DS dip during the current rise";
    return
end
r.value = flux / dI;
r.provenance.window = [a.time, b.time] - e.time;
r.provenance.flux = flux;
r.provenance.deltaI = dI;
r.provenance.referenceVoltage = ref;
r.status = "ok";
end

% =====================================================================
function r = ringingInductance(r, ctx, sig, S)
[Cval, src, why, status, flags] = knownCapacitance(ctx, S);
if why ~= ""
    r.status = status;
    r.reason = why;
    return
end
[f, rf, why] = turnOffRinging(ctx, sig, S);
if why ~= ""
    r.reason = why;
    r.noiseLimited = rf.noiseLimited;     % ringing below the noise: try the next method
    return
end
r.value = 1 / ((2 * pi * f)^2 * Cval);
r.methodTag = sprintf('%s (f_r = %.4g MHz, C = %.4g pF from %s)', r.methodTag, f / 1e6, Cval * 1e12, src);
r.flags = unique([r.flags, flags], 'stable');
r.provenance.ringingFrequency = f;
r.provenance.ringing = rf;
r.provenance.capacitance = Cval;
r.provenance.capacitanceSource = src;
r.status = "ok";
end

function [Cval, src, why, status, flags] = knownCapacitance(ctx, S) %#ok<INUSD>
% C for the ringing model: the active device's C_oss at V_DC (datasheet).
Cval = NaN;
src = "";
why = "";
status = "skipped";
flags = strings(1, 0);
if ~isempty(ctx.cfg.circuit.Coss)
    Cval = ctx.cfg.circuit.Coss;
    src = "cfg.circuit.Coss";
    return
end
why = "no C_oss known for the ringing model (set cfg.circuit.Coss to the active device's C_oss at V_DC)";
end

function [f, rf, why] = turnOffRinging(ctx, sig, S)
% Ringing frequency of the active V_DS after the turn-off peak, inside the
% #29 window (until the ringing decays), about its settled level. The fit
% starts at the first crossing of the settled level after the peak: the
% peak lobe carries the L di/dt bump that excites the ringing and is not
% a clean half-period.
f = NaN;
rf = struct('noiseLimited', false);
why = "";
e = ctx.edges(1);
pk = evaluateMeasurement(registryEntry("VdsMax"), ctx, S);
if pk.status ~= "ok"
    why = "V_DS,max (#29): " + pk.reason;
    return
end
lv = eventLevels(ctx, e, sig.V, S);
if ~lv.ok
    why = sig.V + ": " + lv.reason;
    return
end
range = [pk.provenance.time, pk.provenance.window(2)] + e.time;
s = getSignal(ctx.col, sig.V, range, S);
c1 = findCrossing(s.t, s.x, lv.post, "falling", [], "first");
if c1.found
    range(1) = c1.time;
    s = getSignal(ctx.col, sig.V, range, S);
end
q = lv.quantStep;
if isnan(q), q = 0; end
hyst = max(S.measurements.common.noiseFloorMultiple * lv.sigma, 1.5 * q);
if ~(hyst > 0)
    hyst = eps(lv.post);
end
[f, info] = ringingFrequency(s.t, s.x, lv.post, hyst, []);
if isnan(f)
    why = sprintf(['fewer than three ringing crossings of the settled V_DS (%.4g V, dead band +/- %.3g V) ' ...
        'between the peak and the end of the ringing'], lv.post, hyst);
    rf.noiseLimited = true;
    return
end
rf = struct('window', range - e.time, 'level', lv.post, 'hysteresis', hyst, ...
    'nCrossings', info.nCrossings, 'halfPeriodSpread', info.halfPeriodSpread, 'noiseLimited', false);
end

% =====================================================================
function r = overshootInductance(r, ctx, S)
ov = evaluateMeasurement(registryEntry("dVdsOver"), ctx, S);
di = evaluateMeasurement(registryEntry("didt"), ctx, S);
if ov.status ~= "ok" || di.status ~= "ok"
    r.status = "failed";
    if ov.status == "skipped" || di.status == "skipped", r.status = "skipped"; end
    r.reason = "dV_DS,over: " + statusText(ov) + "; di/dt: " + statusText(di);
    r.noiseLimited = ov.noiseLimited || di.noiseLimited;
    return
end
r.value = ov.value / di.value;
r.methodTag = sprintf('%s (dV_DS,over %s; di/dt %s)', r.methodTag, ov.methodTag, di.methodTag);
r.flags = unique([ov.flags, di.flags, "includesCapacitiveCharging"], 'stable');
r.provenance.overshoot = ov.value;
r.provenance.didt = di.value;
r.status = "ok";
end

% =====================================================================
function r = lcCapacitance(r, ctx, sig, S)
[f, rf, why] = turnOffRinging(ctx, sig, S);
if why ~= ""
    r.reason = why;
    r.noiseLimited = rf.noiseLimited;
    return
end
% L by the dip at the same pulse's turn-on, else by this edge's overshoot.
Lr = [];
P = ctx.tl.pulses;
k = find(P.pulseIndex == ctx.pulseIndex, 1);
if ~isempty(k) && isfinite(P.turnOnEdge(k))
    Sx = S;
    Sx.measurements.methods.Lloop = ["dip", "dipVdc"];
    Lr = evaluateMeasurement(registryEntry("Lloop"), relatedContext(ctx, P.turnOnEdge(k), "turnOn"), Sx);
    where = sprintf('pulse %d turn-on', ctx.pulseIndex);
end
if isempty(Lr) || Lr.status ~= "ok"
    dipWhy = "";
    if ~isempty(Lr), dipWhy = " (dip: " + Lr.reason + ")"; end
    Sx = S;
    Sx.measurements.methods.Lloop = "overshoot";
    Lr = evaluateMeasurement(registryEntry("Lloop"), ctx, Sx);
    where = "this turn-off" + dipWhy;
    if Lr.status ~= "ok"
        r.status = Lr.status;
        r.reason = "L_loop: " + Lr.reason;
        return
    end
end
r.value = 1 / ((2 * pi * f)^2 * Lr.value);
r.methodTag = sprintf('%s: C = 1/((2 pi f_r)^2 L), f_r = %.4g MHz, L = %.4g nH (%s, %s)', r.methodTag, ...
    f / 1e6, Lr.value * 1e9, Lr.methodTag, where);
r.flags = unique(Lr.flags, 'stable');
r.provenance.ringingFrequency = f;
r.provenance.ringing = rf;
r.provenance.inductance = Lr.value;
r.status = "ok";
end

function r = chargeCapacitance(r, ctx, S)
q = evaluateMeasurement(registryEntry("Qoss"), ctx, S);
if q.status ~= "ok"
    r.status = q.status;
    r.reason = "Q_oss (#48): " + q.reason;
    r.noiseLimited = q.noiseLimited;
    return
end
dV = q.provenance.deltaV;
if ~(abs(dV) > 0)
    r.reason = "the V_DS,N swing of the Q_oss window is zero";
    return
end
r.value = q.value / abs(dV);
r.methodTag = sprintf('%s: C_eq = Q_oss / dV, dV = %.4g V (Q_oss %s)', r.methodTag, abs(dV), q.methodTag);
r.flags = q.flags;
r.provenance.Qoss = q.value;
r.provenance.deltaV = dV;
r.status = "ok";
end

% =====================================================================
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
