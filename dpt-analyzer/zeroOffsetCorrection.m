function [col, issues] = zeroOffsetCorrection(col, c, al, tl, cfg, S)
%ZEROOFFSETCORRECTION Remove probe zero offsets measured before pulse 1 (opt-in).
%
%   [col, issues] = zeroOffsetCorrection(col, c, al, tl, cfg, S) measures
%   the zero offset of every channel whose true value before the first
%   pulse is zero, and records it as a declared correction
%   (corrections.zeroOffset, subtracted by getSignal; raw samples are
%   untouched). C is the collection's index in al.collections and in the
%   timeline windows. Runs before current-sensor normalization.
%
%   Why these channels read zero: before the first pulse of a DPT the
%   inductor is at rest and both devices are off, so every device current
%   and the inductor current are zero, and the inductor DC-shorts the
%   non-active device, so its V_DS is zero too. The roles are listed in
%   S.zeroOffset.roles. The active V_DS reads V_DC there and is never
%   corrected.
%
%   Pre-pulse segment: from the start of the record to the start of the
%   first edge's event window. Required: the first edge is a turn-on (the
%   record starts at rest).
%
%   A channel is left uncorrected, and reported, when its pre-pulse mean
%   exceeds S.zeroOffset.maxFraction of its scale: that is a real signal
%   (e.g. a pre-charged inductor), not an offset. Scale: the channel's
%   peak for currents; the active device's pre-pulse V_DS (V_DC) for
%   voltages.
%
%   col.zeroOffset records the outcome: applied, signals, offsets, reason.

arguments
    col (1,1) struct
    c (1,1) double {mustBeInteger, mustBePositive}
    al (1,1) struct
    tl (1,1) struct
    cfg (1,1) struct
    S (1,1) struct
end

issues = dptIssue();
info = col.zeroOffset;
if ~cfg.zeroOffsetCorrection.enable
    info.reason = "disabled (cfg.zeroOffsetCorrection.enable = false)";
    col.zeroOffset = info;
    return
end

W = tl.windows(tl.windows.collection == c, :);
pre = [col.time(1), W.startTime(W.edgeId == 1) + al.offset(c)];
if tl.edges.kind(1) ~= "turnOn" || pre(2) <= pre(1)
    info.reason = "the record does not start at rest before a turn-on";
    col.zeroOffset = info;
    issues = [issues; dptIssue("dpt:zeroOffset:notApplied", "warning", "import", ...
        col.name, "Zero offsets not corrected: " + info.reason + ".", S)];
    return
end

present = [col.channels.signal];
vActive = resolveRole("drainVoltage@active", cfg, S);
voltScale = NaN;
if any(present == vActive)
    voltScale = abs(mean(getSignal(col, vActive, pre, S).x));
end

refused = strings(1, 0);
for role = S.zeroOffset.roles
    name = resolveRole(role, cfg, S);
    j = find(present == name);
    if isempty(j)
        continue
    end
    sig = getSignal(col, name, pre, S);
    if numel(sig.x) < 3
        continue
    end
    offset = mean(sig.x);
    if startsWith(role, "drainVoltage")
        scale = voltScale;
    else
        scale = max(abs(getSignal(col, name, [], S).x));
    end
    if ~isnan(scale) && abs(offset) > S.zeroOffset.maxFraction * scale
        refused(end+1) = sprintf('%s (%.4g %s is %.2g %% of its scale)', name, offset, ...
            col.channels(j).units, 100 * abs(offset) / scale); %#ok<AGROW>
        continue
    end
    col.channels(j).corrections.zeroOffset = col.channels(j).corrections.zeroOffset + offset;
    info.signals(end+1) = name;
    info.offsets(end+1) = offset;
end

info.applied = ~isempty(info.signals);
if isempty(refused)
    info.reason = "";
else
    info.reason = "not corrected: " + strjoin(refused, "; ");
    issues = [issues; dptIssue("dpt:zeroOffset:refused", "warning", "import", col.name, ...
        "Zero offset too large to be a probe offset, channel left uncorrected: " + ...
        strjoin(refused, "; ") + ".", S)];
end
col.zeroOffset = info;
if info.applied
    parts = arrayfun(@(k) sprintf('%s %+.3g', info.signals(k), info.offsets(k)), ...
        1:numel(info.signals), 'UniformOutput', false);
    issues = [issues; dptIssue("dpt:zeroOffset:applied", "info", "import", col.name, ...
        "Zero offsets removed (pre-pulse mean): " + strjoin(string(parts), ", ") + ".", S)];
end

end
