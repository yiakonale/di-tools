function [col, issues] = normalizeCurrentSensors(col, c, al, tl, cfg, S)
%NORMALIZECURRENTSENSORS Calibrate I_D and I_L against each other (opt-in).
%
%   [col, issues] = normalizeCurrentSensors(col, c, al, tl, cfg, S)
%   calibrates the active device's drain-current sensor and the inductor
%   (Iout) sensor of one collection against each other, as specified in
%   MEASUREMENT_DESIGN.md section 7.3. C is the collection's index in
%   al.collections and in the timeline windows.
%
%   During the active device's on-state all inductor current flows
%   through it, so I_D,active = I_L. On the on-state segment of every
%   pulse (end of the turn-on window to the start of the turn-off window,
%   which excludes recovery and ringing) the affine model
%
%       I_ref = k * I_other + b
%
%   is fitted by least squares over all pulses. A multi-pulse train spans
%   the whole current range, so k and b are well conditioned.
%   cfg.currentNormalization.reference names the sensor taken as truth.
%
%   The fit is applied, as a declared correction of the non-reference
%   channel (corrections.gain/offset, applied by getSignal; raw samples
%   are untouched), only if it passes both acceptance checks:
%     - residual rms <= S.measurements.normalization.maxResidualRatio
%       times the residual expected from the two sensors' own noise and
%       quantization (noiseLevel on each segment);
%     - every pulse's gain (mean(I_ref) - b) / mean(I_other) is within
%       S.measurements.normalization.maxGainSpread of k. A larger spread
%       means saturation or droop, which one gain cannot correct.
%   A negative k (opposite probe polarities) is refused as well.
%
%   col.normalization records the outcome: applied, reference, adjusted,
%   gain, offset, residualRms, expectedRms, pulseGains, gainSpread,
%   nPulses, reason.

arguments
    col (1,1) struct
    c (1,1) double {mustBeInteger, mustBePositive}
    al (1,1) struct
    tl (1,1) struct
    cfg (1,1) struct
    S (1,1) struct
end

issues = dptIssue();
info = col.normalization;
info.reference = cfg.currentNormalization.reference;

if ~cfg.currentNormalization.enable
    info.reason = "disabled (cfg.currentNormalization.enable = false)";
    col.normalization = info;
    return
end

catalog = S.signals.catalog;
idName = catalog.name(catalog.quantity == "drainCurrent" & catalog.device == cfg.activeDevice);
ilName = catalog.name(catalog.quantity == "outputCurrent");
present = [col.channels.signal];
if ~all(ismember([idName, ilName], present))
    info.reason = string(sprintf('collection lacks %s', strjoin(setdiff([idName, ilName], present), ' and ')));
    col.normalization = info;
    issues = [issues; dptIssue("dpt:normalization:notApplied", "warning", "import", ...
        col.name, "Current sensors not normalized: " + info.reason + ...
        ". Its current-based results are reported as not normalized.", S)];
    return
end
if info.reference == "Iout"
    refName = ilName;
    otherName = idName;
else
    refName = idName;
    otherName = ilName;
end
info.adjusted = otherName;

%% On-state segments of every pulse
W = tl.windows(tl.windows.collection == c, :);
P = tl.pulses(~isnan(tl.pulses.turnOffEdge), :);
ref = {};
other = {};
for p = 1:height(P)
    wOn = W(W.edgeId == P.turnOnEdge(p), :);
    wOff = W(W.edgeId == P.turnOffEdge(p), :);
    if ~(wOn.valid && wOff.valid) || wOn.endTime >= wOff.startTime
        continue
    end
    r = [wOn.endTime, wOff.startTime] + al.offset(c);
    sr = getSignal(col, refName, r, S);
    so = getSignal(col, otherName, r, S);
    if numel(sr.x) >= 3 && numel(sr.x) == numel(so.x)
        ref{end+1} = sr.x; %#ok<AGROW>
        other{end+1} = so.x; %#ok<AGROW>
    end
end
info.nPulses = numel(ref);

if info.nPulses < 2
    info.reason = string(sprintf(['needs on-state segments of at least two pulses for an ' ...
        'affine fit; found %d'], info.nPulses));
    col.normalization = info;
    issues = [issues; dptIssue("dpt:normalization:refused", "warning", "import", ...
        col.name, "Current-sensor normalization refused: " + info.reason + ".", S)];
    return
end

%% Fit and acceptance
y = vertcat(ref{:});
x = vertcat(other{:});
coef = [x, ones(size(x))] \ y;
k = coef(1);
b = coef(2);
info.gain = k;
info.offset = b;
info.residualRms = rms(y - (k * x + b));

sigmaRef = cellfun(@noiseLevel, ref);
sigmaOther = cellfun(@noiseLevel, other);
info.expectedRms = sqrt(median(sigmaRef)^2 + (k * median(sigmaOther))^2);
info.pulseGains = cellfun(@(r, o) (mean(r) - b) / mean(o), ref, other);
info.gainSpread = max(abs(info.pulseGains / k - 1));

N = S.measurements.normalization;
if k <= 0
    info.reason = sprintf(['fitted gain %.4g is not positive: the two sensors have ' ...
        'opposite polarity. Fix the probe orientation with "invert" in channelMap.m'], k);
elseif info.residualRms > N.maxResidualRatio * info.expectedRms
    info.reason = sprintf(['fit residual %.3g A rms exceeds %g x the expected %.3g A ' ...
        'from sensor noise'], info.residualRms, N.maxResidualRatio, info.expectedRms);
elseif info.gainSpread > N.maxGainSpread
    info.reason = sprintf(['per-pulse gain varies by up to %.3g %% (limit %.3g %%): ' ...
        'the sensors disagree non-linearly (saturation or droop), which one gain ' ...
        'cannot correct'], 100 * info.gainSpread, 100 * N.maxGainSpread);
else
    info.reason = "";
end

summary = sprintf(['%s = %.5g x %s %+.4g A (reference %s): residual %.3g A rms ' ...
    '(expected %.3g), per-pulse gain spread %.3g %% over %d pulses'], refName, k, ...
    otherName, b, refName, info.residualRms, info.expectedRms, 100 * info.gainSpread, ...
    info.nPulses);
if info.reason ~= ""
    info.reason = string(info.reason);
    col.normalization = info;
    issues = [issues; dptIssue("dpt:normalization:refused", "warning", "import", ...
        col.name, "Current-sensor normalization refused: " + info.reason + ...
        ". Fit: " + summary + ".", S)];
    return
end

%% Apply to the non-reference channel: its corrected value becomes k*x + b
j = find(present == otherName);
col.channels(j).corrections.gain = k;
col.channels(j).corrections.offset = b;
info.applied = true;
col.normalization = info;
issues = [issues; dptIssue("dpt:normalization:applied", "info", "import", col.name, ...
    "Current sensors normalized: " + summary + ".", S)];

end
