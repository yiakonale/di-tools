function [col, issues] = busVoltageModel(col, c, al, tl, cfg, S, bucketC)
%BUSVOLTAGEMODEL Choose and characterize the bus-voltage source V_DC(t).
%
%   [col, issues] = busVoltageModel(col, c, al, tl, cfg, S, bucketC) uses
%   the capacitance measured in the bucket's direct-source collections
%   (bucketCapacitance) in preference to cfg.circuit.Cdc.
%
%   [col, issues] = busVoltageModel(col, c, al, tl, cfg, S) selects how
%   V_DC(t) is obtained for one collection (MEASUREMENT_DESIGN.md section
%   12) and stores the model in col.busVoltage. C is the collection's
%   index in al.collections and in the timeline windows. Measurements read
%   V_DC through busVoltageAt.
%
%   Source: the first available in S.busVoltage.sources
%     busChannel   a mapped Vdc channel
%     kvl          V_DS,HS + V_DS,LS, both mapped
%     chargeDroop  V_DC0 - Q(t)/C_dc (cfg.circuit.Cdc, I_D or Iout mapped)
%     constant     V_DC0
%
%   V_DC0: the active V_DS before the first pulse. No current flows then
%   and the inductor DC-shorts the non-active device, so V_DS = V_DC with
%   no diode drop. Else cfg.nominal.busVoltage.
%
%   Q(t): the charge drawn from the DC link, i.e. the integral of the
%   active device's current over its on-state intervals only; during the
%   pulse breaks the inductor current circulates through the diode, not
%   the link. Integrating only the on-states also keeps most of the
%   sensor's off-state offset out of Q. I_D of the active device is used
%   (intervals: turn-on window start to turn-off window end), else Iout
%   (intervals: turn-on core start to turn-off core end).
%
%   Diagnostics, as issues and in col.busVoltage:
%     droop check (constant source): in a pulse break the active V_DS is
%       V_DC + V_F with V_F > 0, so a break V_DS below V_DC0 by more than
%       its noise floor proves droop -> droopDetected, maxDroop
%     C cross-check (busChannel/kvl sources): the droop measured at the
%       pulse breaks is fitted against Q, giving cEstimate, compared with
%       cfg.circuit.Cdc +/- CdcTolerance
%     implied V_F (chargeDroop source): break V_DS - model must be >= 0
%     pre-pulse current: inductor current before pulse 1 (above the noise
%       floor and S.busVoltage.prePulseCurrentFraction of the record's peak
%       current) means V_DC0 may include a diode drop
%     nominal mismatch: pre-pulse V_DS vs cfg.nominal.busVoltage

arguments
    col (1,1) struct
    c (1,1) double {mustBeInteger, mustBePositive}
    al (1,1) struct
    tl (1,1) struct
    cfg (1,1) struct
    S (1,1) struct
    bucketC = []
end

issues = dptIssue();
% Start from a clean model, so a re-run (with the bucket's C) carries no
% results of an earlier pass.
bm = col.busVoltage;
bm.source = "none";
bm.label = "none";
bm.description = "";
bm.V0 = NaN;
bm.V0source = "";
bm.currentSignal = "";
bm.signals = strings(1, 0);
bm.droopDetected = false;
bm.maxDroop = NaN;
bm.cEstimate = NaN;
bm.cEstimateRelSE = NaN;
bm.cEstimateSignal = "";
bm.breakTimes = [];
bm.breakVds = [];
k = S.measurements.common.noiseFloorMultiple;
present = [col.channels.signal];
has = @(role) any(present == resolveRole(role, cfg, S));
vA = resolveRole("drainVoltage@active", cfg, S);
vN = resolveRole("drainVoltage@nonActive", cfg, S);
W = tl.windows(tl.windows.collection == c, :);
off = al.offset(c);

%% Charge integration: on-state intervals of the active device
% I_D is zero outside conduction, so its intervals span the full event
% windows and cannot miss a slow current fall or tail. Iout keeps
% flowing (through the diode) after the turn-off, so its intervals stop
% at the gate edge cores.
P = tl.pulses(~isnan(tl.pulses.turnOffEdge), :);
useId = has("drainCurrent@active");
if useId
    bm.currentSignal = resolveRole("drainCurrent@active", cfg, S);
elseif has("outputCurrent")
    bm.currentSignal = resolveRole("outputCurrent", cfg, S);
end
on = zeros(height(P), 2);
for p = 1:height(P)
    wOn = W(W.edgeId == P.turnOnEdge(p), :);
    wOff = W(W.edgeId == P.turnOffEdge(p), :);
    if useId
        on(p, :) = [wOn.startTime, wOff.endTime] + off;
    else
        on(p, :) = [wOn.coreStartTime, wOff.coreEndTime] + off;
    end
end
bm.onIntervals = on;

%% V_DC0 from the pre-pulse segment
pre = [col.time(1), W.startTime(W.edgeId == 1) + off];
preOk = tl.edges.kind(1) == "turnOn" && pre(2) > pre(1);
if preOk && has("drainVoltage@active")
    st = statsOf(col, vA, pre, S);
    if st.n >= 3
        bm.V0 = st.mean;
        bm.V0source = "pre-pulse " + vA;
        if has("outputCurrent")
            % A probe zero offset of a few amps is not a pre-charged
            % inductor: require the current to be a meaningful fraction
            % of the test current as well as above the noise floor.
            ilName = resolveRole("outputCurrent", cfg, S);
            il = statsOf(col, ilName, pre, S);
            scale = max(abs(getSignal(col, ilName, [], S).x));
            if abs(il.mean) > max(k * il.sigma, S.busVoltage.prePulseCurrentFraction * scale)
                issues = [issues; dptIssue("dpt:busVoltage:prePulseCurrent", "warning", ...
                    "timeline", col.name, sprintf(['inductor current %.3g A flows before ' ...
                    'pulse 1, so the pre-pulse V_DS (V_DC0 = %.4g V) may include a diode ' ...
                    'drop.'], il.mean, bm.V0), S)];
            end
        end
    end
end
nominal = cfg.nominal.busVoltage;
if isnan(bm.V0) && ~isempty(nominal)
    bm.V0 = nominal;
    bm.V0source = "cfg.nominal.busVoltage";
elseif ~isnan(bm.V0) && ~isempty(nominal) && abs(bm.V0 / nominal - 1) > S.busVoltage.nominalTolerance
    issues = [issues; dptIssue("dpt:busVoltage:nominalMismatch", "warning", "timeline", ...
        col.name, sprintf(['pre-pulse V_DS (%.4g V) differs from cfg.nominal.busVoltage ' ...
        '(%.4g V) by more than %g %%; the measured value is used.'], bm.V0, nominal, ...
        100 * S.busVoltage.nominalTolerance), S)];
end

%% Source selection
% C: measured in this bucket (preferred), else cfg.circuit.Cdc.
bm.C = cfg.circuit.Cdc;
bm.Ctolerance = cfg.circuit.CdcTolerance;
bm.Csource = "";
if ~isempty(bm.C)
    bm.Csource = "cfg.circuit.Cdc";
end
if ~isempty(bucketC) && ~isnan(bucketC.value)
    bm.C = bucketC.value;
    bm.Ctolerance = bucketC.relUncertainty;
    bm.Csource = bucketC.description;
end
for src = S.busVoltage.sources
    switch src
        case "busChannel"
            ok = has("busVoltage");
        case "kvl"
            ok = has("drainVoltage@active") && has("drainVoltage@nonActive");
        case "chargeDroop"
            ok = ~isempty(bm.C) && ~isnan(bm.V0) && bm.currentSignal ~= "" && ~isempty(on);
        case "constant"
            ok = ~isnan(bm.V0);
    end
    if ok
        bm.source = src;
        break
    end
end

switch bm.source
    case "busChannel"
        bm.label = "bus channel";
        bm.signals = resolveRole("busVoltage", cfg, S);
        bm.description = "bus-voltage channel " + bm.signals;
    case "kvl"
        bm.label = "KVL";
        bm.signals = [vA, vN];
        bm.description = sprintf('V_DS,HS + V_DS,LS (%s + %s)', vN, vA);
    case "chargeDroop"
        bm.label = "charge droop";
        bm.signals = bm.currentSignal;
        bm.description = sprintf(['charge droop: V_DC0 = %.4g V (%s), C = %s +/- %.2g %% ' ...
            '(%s), charge from %s'], bm.V0, bm.V0source, engineering(bm.C, "F"), ...
            100 * bm.Ctolerance, bm.Csource, bm.currentSignal);
    case "constant"
        bm.label = "constant";
        bm.description = sprintf('constant V_DC0 = %.4g V (%s)', bm.V0, bm.V0source);
    case "none"
        bm.label = "none";
        bm.description = "no bus-voltage source: no Vdc channel, V_DS or cfg.nominal.busVoltage";
end
bm.description = string(bm.description);

%% Diagnostics at the pulse breaks (settled, just before each turn-on)
if has("drainVoltage@active") && height(P) >= 1
    turnOns = tl.pulses.turnOnEdge(2:end);
    Vb = nan(numel(turnOns), 1);
    sb = nan(numel(turnOns), 1);
    segs = nan(numel(turnOns), 2);
    for j = 1:numel(turnOns)
        w = W(W.edgeId == turnOns(j), :);
        seg = [w.territoryStartTime, w.startTime] + off;
        if seg(2) > seg(1)
            st = statsOf(col, vA, seg, S);
            Vb(j) = st.mean;
            sb(j) = st.sigma;
            segs(j, :) = seg;
        end
    end
    keep = ~isnan(Vb);
    Vb = Vb(keep); sb = sb(keep); segs = segs(keep, :);
    tb = mean(segs, 2);
    bm.breakTimes = tb;
    bm.breakVds = Vb;

    if bm.source == "constant" && ~isempty(Vb)
        deficit = bm.V0 - Vb;
        if any(deficit > k * sb)
            bm.droopDetected = true;
            bm.maxDroop = max(deficit);
            issues = [issues; dptIssue("dpt:busVoltage:droopDetected", "warning", "timeline", ...
                col.name, sprintf(['bus droop detected: the off-state V_DS in a pulse break ' ...
                'is up to %.3g V below V_DC0 = %.4g V, which a forward-biased diode cannot ' ...
                'explain. V_DC-dependent results use the constant V_DC0 and are flagged ' ...
                '"busDroopDetected". Set cfg.circuit.Cdc, or capture a Vdc channel or both ' ...
                'V_DS.'], bm.maxDroop, bm.V0), S)];
        end
    end

    if (bm.source == "busChannel" || bm.source == "kvl") && ~isempty(Vb)
        % Droop measured by the direct source vs charge drawn, on the
        % settled break segments plus the pre-pulse segment (Q = 0). The
        % pre-pulse point lets a 3-pulse train give an uncertainty and a
        % classic 2-pulse DPT an estimate at all.
        direct = col;
        direct.busVoltage = bm;
        Vd = nan(size(tb));
        Q = nan(size(tb));
        for j = 1:numel(tb)
            Vd(j) = busVoltageAt(direct, segs(j, :), S).value;
            Q(j) = chargeAt(col, bm, tb(j), S);
        end
        if preOk
            Vd = [busVoltageAt(direct, pre, S).value; Vd];
            Q = [0; Q];
        end
        if bm.currentSignal ~= "" && max(Q) > min(Q)
            fit = [Q, ones(size(Q))] \ Vd;
            if fit(1) < 0
                bm.cEstimate = -1 / fit(1);
                % Relative standard error of the fitted slope (= of C).
                if numel(Q) >= 3
                    res = Vd - [Q, ones(size(Q))] * fit;
                    se = sqrt(sum(res.^2) / (numel(Q) - 2) / sum((Q - mean(Q)).^2));
                    bm.cEstimateRelSE = se / abs(fit(1));
                end
                bm.cEstimateSignal = bm.currentSignal;
                msg = sprintf(['DC-link capacitance from the measured droop: %s ' ...
                    '(charge from %s; scales with that sensor''s calibration)'], ...
                    engineering(bm.cEstimate, "F"), bm.currentSignal);
                if numel(Q) < 3
                    msg = msg + sprintf([" from only %d points, so without an uncertainty; " ...
                        "not shared with the bucket's other collections"], numel(Q));
                end
                severity = "info";
                if ~isempty(bm.C)
                    dev = bm.cEstimate / bm.C - 1;
                    msg = sprintf('%s (cfg.circuit.Cdc = %s, %+.0f %%)', msg, ...
                        engineering(bm.C, "F"), 100 * dev);
                    if abs(dev) > bm.Ctolerance
                        severity = "warning";
                        msg = msg + ", outside the stated tolerance";
                    end
                end
                issues = [issues; dptIssue("dpt:busVoltage:capacitanceEstimate", severity, ...
                    "timeline", col.name, string(msg) + ".", S)];
            end
        end
    end

    if bm.source == "chargeDroop" && ~isempty(Vb)
        model = arrayfun(@(t0) bm.V0 - chargeAt(col, bm, t0, S) / bm.C, tb);
        vf = Vb - model;
        unc = (bm.V0 - model) * bm.Ctolerance / (1 - bm.Ctolerance);
        bad = vf < -(k * sb + unc);
        msg = sprintf('implied freewheel-diode drop in the pulse breaks: %.3g to %.3g V', ...
            min(vf), max(vf));
        if any(bad)
            issues = [issues; dptIssue("dpt:busVoltage:negativeDiodeDrop", "warning", ...
                "timeline", col.name, string(msg) + [", negative beyond the noise and " ...
                "the C tolerance: cfg.circuit.Cdc is probably too large."], S)];
        else
            issues = [issues; dptIssue("dpt:busVoltage:impliedDiodeDrop", "info", ...
                "timeline", col.name, string(msg) + ".", S)];
        end
    end
end

col.busVoltage = bm;
issues = [issues; dptIssue("dpt:busVoltage:source", "info", "timeline", col.name, ...
    "V_DC(t): " + bm.description, S)];

end

% =====================================================================
function st = statsOf(col, name, range, S)
sig = getSignal(col, name, range, S);
st.n = numel(sig.x);
st.mean = mean(sig.x);
if st.n >= 3
    st.sigma = noiseLevel(sig.x);
else
    st.sigma = NaN;
end
end

function s = engineering(value, unit)
prefixes = ["p", "n", "u", "m", "", "k", "M", "G"];
e = min(max(floor(log10(abs(value)) / 3), -4), 3);
s = sprintf('%.4g %s%s', value / 10^(3 * e), prefixes(e + 5), unit);
end
