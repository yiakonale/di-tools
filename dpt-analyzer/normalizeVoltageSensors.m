function [col, issues] = normalizeVoltageSensors(col, c, al, tl, cfg, S)
%NORMALIZEVOLTAGESENSORS Calibrate the two V_DS probes against each other (opt-in).
%
%   [col, issues] = normalizeVoltageSensors(col, c, al, tl, cfg, S)
%   estimates the relative gain error of the two V_DS probes of one
%   collection and records it as a declared correction of the
%   non-reference probe (corrections.gain, applied by getSignal; raw
%   samples are untouched). C is the collection's index in al.collections
%   and the timeline windows. Runs after zero-offset correction and
%   current normalization, before the bus-voltage model.
%
%   Principle (KVL: V_DS,A + V_DS,N = V_DC at every settled moment). Across
%   each turn-off the two probes swap roles: in the on-state V_DS,N
%   carries nearly all of V_DC, in the pulse break V_DS,A does. V_DC
%   itself is continuous across the turn-off (the break draws no charge
%   from the DC link), except that the bus current I stops, so the
%   resistive drop R*I of the DC link and busbar disappears. With
%   V_DS,N reading (1 + eps) times its true value, the jump of the
%   measured sum across turn-off k is
%
%       d_k = sum(on-state, end) - sum(break, start) = eps * V_DC - R * I_k
%
%   Both sums are straight-line fits of their segments evaluated at the
%   instant just before the turn-off, so droop within the segments does
%   not bias them; zero offsets cancel in d_k. eps and R are fitted over
%   all pulses: eps scales with V_DC and R with the current, which varies
%   tenfold across a multi-pulse train, so the two are separable.
%
%   cfg.voltageNormalization.reference names the probe taken as truth:
%   "active" (default: every active-device result stays unchanged) or
%   "nonActive". Refused with fewer than 3 pulses, or if |eps| exceeds
%   S.measurements.voltageNormalization.maxGainError (a wrong probe
%   attenuation, not a calibration). R is reported as a diagnostic.
%
%   col.voltageNormalization records the outcome: applied, reference,
%   adjusted, gainError (eps), busResistance (R), residualRms, nPulses,
%   currentSignal, reason.

arguments
    col (1,1) struct
    c (1,1) double {mustBeInteger, mustBePositive}
    al (1,1) struct
    tl (1,1) struct
    cfg (1,1) struct
    S (1,1) struct
end

issues = dptIssue();
info = col.voltageNormalization;
info.reference = cfg.voltageNormalization.reference;
if ~cfg.voltageNormalization.enable
    info.reason = "disabled (cfg.voltageNormalization.enable = false)";
    col.voltageNormalization = info;
    return
end

present = [col.channels.signal];
vA = resolveRole("drainVoltage@active", cfg, S);
vN = resolveRole("drainVoltage@nonActive", cfg, S);
if ~all(ismember([vA, vN], present))
    info.reason = "collection lacks " + strjoin(setdiff([vA, vN], present), " and ");
    col.voltageNormalization = info;
    issues = [issues; dptIssue("dpt:voltageNormalization:notApplied", "warning", "import", ...
        col.name, "V_DS probes not normalized: " + info.reason + ".", S)];
    return
end
iName = "";
for role = ["outputCurrent", "drainCurrent@active"]
    if any(present == resolveRole(role, cfg, S))
        iName = resolveRole(role, cfg, S);
        break
    end
end
info.currentSignal = iName;

%% Jump of the KVL sum across every turn-off
W = tl.windows(tl.windows.collection == c, :);
P = tl.pulses(~isnan(tl.pulses.turnOffEdge), :);
off = al.offset(c);
d = []; V = []; I = [];
for k = 1:height(P)
    wOn = W(W.edgeId == P.turnOnEdge(k), :);
    wOff = W(W.edgeId == P.turnOffEdge(k), :);
    t0 = wOff.startTime + off;
    segOn = [wOn.endTime, wOff.startTime] + off;
    next = W(W.edgeId == P.turnOffEdge(k) + 1, :);
    if isempty(next)
        segBr = [wOff.endTime, wOff.territoryEndTime] + off;
    else
        segBr = [wOff.endTime, next.startTime] + off;
    end
    if ~(wOn.valid && wOff.valid) || segOn(2) <= segOn(1) || segBr(2) <= segBr(1)
        continue
    end
    sOn = sumAt(col, vA, vN, segOn, t0, S);
    sBr = sumAt(col, vA, vN, segBr, t0, S);
    if isnan(sOn) || isnan(sBr)
        continue
    end
    d(end+1, 1) = sOn - sBr; %#ok<AGROW>
    V(end+1, 1) = sBr; %#ok<AGROW>
    if iName ~= ""
        g = getSignal(col, iName, [t0 - (wOff.coreStartTime - wOff.startTime), t0], S);   % 1 D before
        I(end+1, 1) = mean(g.x); %#ok<AGROW>
    end
end
info.nPulses = numel(d);
if info.nPulses < 3
    info.reason = string(sprintf('needs at least three pulses for the fit; found %d', info.nPulses));
    col.voltageNormalization = info;
    issues = [issues; dptIssue("dpt:voltageNormalization:refused", "warning", "import", ...
        col.name, "V_DS probes not normalized: " + info.reason + ".", S)];
    return
end

%% Fit d = eps * V - R * I
if iName ~= ""
    A = [V, -I];
else
    A = V;                         % no current: gain only
end
coef = A \ d;
eps = coef(1);
info.gainError = eps;
if iName ~= ""
    info.busResistance = coef(2);
end
info.residualRms = rms(d - A * coef);

if abs(eps) > S.measurements.voltageNormalization.maxGainError
    info.reason = string(sprintf(['relative gain error %.3g %% exceeds %.3g %%: check the ' ...
        'probe attenuation settings rather than calibrating'], 100 * eps, ...
        100 * S.measurements.voltageNormalization.maxGainError));
    col.voltageNormalization = info;
    issues = [issues; dptIssue("dpt:voltageNormalization:refused", "warning", "import", ...
        col.name, "V_DS probes not normalized: " + info.reason + ".", S)];
    return
end

%% Apply to the non-reference probe
if info.reference == "active"
    adjusted = vN;
    gain = 1 / (1 + eps);
else
    adjusted = vA;
    gain = 1 + eps;
end
j = find(present == adjusted);
col.channels(j).corrections.gain = col.channels(j).corrections.gain * gain;
info.adjusted = adjusted;
info.applied = true;
info.reason = "";
col.voltageNormalization = info;

msg = sprintf(['V_DS probes normalized (reference %s): %s reads %+.3g %% relative to %s, ' ...
    'corrected by x %.5f; residual %.3g V rms over %d pulses'], info.reference, vN, 100 * eps, ...
    vA, gain, info.residualRms, info.nPulses);
if iName ~= ""
    msg = sprintf('%s. DC-link and busbar resistance %.3g mOhm (from %s)', msg, ...
        1e3 * info.busResistance, iName);
end
issues = [issues; dptIssue("dpt:voltageNormalization:applied", "info", "import", col.name, ...
    string(msg) + ".", S)];

end

% =====================================================================
function v = sumAt(col, vA, vN, seg, t0, S)
% Straight-line fit of V_DS,A + V_DS,N over SEG, evaluated at T0.
a = getSignal(col, vA, seg, S);
b = getSignal(col, vN, seg, S);
v = NaN;
if numel(a.x) < 3 || numel(a.x) ~= numel(b.x)
    return
end
c = [a.t - t0, ones(size(a.t))] \ (a.x + b.x);
v = c(2);
end
