function [s, info] = slopeBandMax(t, x, pre, post, band, span, step, searchRange)
%SLOPEBANDMAX Steepest average slope over any amplitude band of a transition.
%
%   [s, info] = slopeBandMax(t, x, pre, post, band, span, step, searchRange)
%   slides an amplitude band of width BAND (fraction of the swing) across
%   the transition from PRE to POST and returns the steepest average
%   slope over any band position (MEASUREMENT_DESIGN.md Q10). It sits
%   between the 10-90 % average, which smooths away the fastest part, and
%   the instantaneous maximum, which is noise-sensitive.
%
%   For each band position p (lower edge, fraction of the swing):
%       la = pre + p * A,  lb = pre + (p + band) * A,  A = post - pre
%       ta = first crossing of la in the transition direction
%       tb = first crossing of lb after ta
%       slope(p) = (lb - la) / (tb - ta)
%   s is the slope with the largest magnitude; its sign follows A.
%
%   Inputs
%     t, x         column vectors of equal length
%     pre, post    transition levels (0 % and 100 %)
%     band         band width, fraction of the swing, 0 < band <= span width
%     span         [lo hi] fractions the band may cover, e.g. [0.1 0.9]
%     step         spacing of band positions, fraction of the swing
%     searchRange  [t0 t1] [s] containing the transition, or []
%
%   Output info: position (lower edge of the steepest band), levels
%   [la lb], times [ta tb], positions (all), slopes (all, NaN where a
%   crossing was not found)

arguments
    t (:,1) double
    x (:,1) double
    pre (1,1) double
    post (1,1) double
    band (1,1) double {mustBePositive}
    span (1,2) double
    step (1,1) double {mustBePositive}
    searchRange double = []
end

if ~(span(1) >= 0 && span(2) <= 1 && span(2) - span(1) >= band)
    error('slopeBandMax:invalidSpan', ...
        'span must satisfy 0 <= lo, hi <= 1 and hi - lo >= band.');
end
A = post - pre;
if A == 0
    error('slopeBandMax:zeroAmplitude', 'The transition has zero amplitude.');
end
if A > 0
    direction = "rising";
else
    direction = "falling";
end
if isempty(searchRange)
    searchRange = [t(1), t(end)];
end

% Positions from span(1) to span(2) - band; the tolerance keeps the last
% position when (span width - band) is a multiple of step.
positions = (span(1):step:(span(2) - band + 1e-12 * step))';
slopes = nan(size(positions));
ta = nan(size(positions));
tb = nan(size(positions));
for k = 1:numel(positions)
    la = pre + positions(k) * A;
    lb = pre + (positions(k) + band) * A;
    ca = findCrossing(t, x, la, direction, searchRange, "first");
    if ~ca.found
        continue
    end
    cb = findCrossing(t, x, lb, direction, [ca.time, searchRange(2)], "first");
    if ~cb.found || cb.time <= ca.time
        continue
    end
    ta(k) = ca.time;
    tb(k) = cb.time;
    slopes(k) = (lb - la) / (tb(k) - ta(k));
end

[~, best] = max(abs(slopes));
if isempty(best) || isnan(slopes(best))
    s = NaN;
    best = NaN;
    info.position = NaN;
    info.levels = [NaN NaN];
    info.times = [NaN NaN];
else
    s = slopes(best);
    info.position = positions(best);
    info.levels = pre + [positions(best), positions(best) + band] * A;
    info.times = [ta(best), tb(best)];
end
info.positions = positions;
info.slopes = slopes;

end
