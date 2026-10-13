function [f, info] = ringingFrequency(t, x, level, hysteresis, searchRange)
%RINGINGFREQUENCY Oscillation frequency of a ringing waveform about a level.
%
%   [f, info] = ringingFrequency(t, x, level, hysteresis, searchRange)
%   estimates the frequency of the oscillation of x about LEVEL (usually
%   the settled level) inside the search range.
%
%   A crossing counts only when x travels from below level - hysteresis
%   to above level + hysteresis, or back, so noise around the level
%   cannot create crossings (the same principle as gate-edge
%   qualification). Each counted crossing is timed at the midpoint of the
%   first and last interpolated crossings of LEVEL inside that excursion:
%   noise moves the first crossing early and the last one late by about
%   the same amount, so the midpoint is unbiased, whereas either end
%   alone drifts as the ringing decays and the crossing slope falls.
%
%   The half-period is the least-squares slope of crossing time against
%   crossing number, so every crossing contributes rather than only the
%   first and last:
%
%       f = 1 / (2 * halfPeriod)
%
%   At least three crossings (one full period) are required; otherwise
%   f = NaN.
%
%   Inputs
%     t, x         column vectors of equal length
%     level        oscillation centre
%     hysteresis   half-width of the dead band, > 0. It must exceed both
%                  the noise (e.g. 3 sigma) and one ADC step, or a
%                  single-code flicker around LEVEL counts as a crossing.
%     searchRange  [t0 t1] [s], or [] for the whole vector
%
%   Output info: nCrossings, crossingTimes [s], halfPeriods [s],
%   halfPeriodSpread (max/min - 1; large values mean the waveform is not
%   a single clean oscillation)

arguments
    t (:,1) double
    x (:,1) double
    level (1,1) double
    hysteresis (1,1) double {mustBePositive}
    searchRange double = []
end

if numel(t) ~= numel(x)
    error('ringingFrequency:sizeMismatch', 't and x must have the same length.');
end
if isempty(searchRange)
    idx = (1:numel(t))';
else
    idx = find(t >= searchRange(1) & t <= searchRange(2));
end
ts = t(idx);
xs = x(idx) - level;

% Hysteresis state: +1 above the band, -1 below, carried through the band.
state = nan(size(xs));
state(xs >= hysteresis) = 1;
state(xs <= -hysteresis) = -1;
state = fillmissing(state, 'previous');
change = find(diff(state) ~= 0 & ~isnan(state(1:end-1)) & ~isnan(state(2:end)));

times = nan(numel(change), 1);
for k = 1:numel(change)
    arrive = change(k) + 1;                         % first sample on the far side
    if state(arrive) == 1
        leave = find(xs(1:arrive) <= -hysteresis, 1, 'last');
    else
        leave = find(xs(1:arrive) >= hysteresis, 1, 'last');
    end
    a = xs(leave:arrive-1);
    b = xs(leave+1:arrive);
    j = leave - 1 + find((a < 0 & b >= 0) | (a > 0 & b <= 0));
    tc = ts(j) - xs(j) ./ (xs(j+1) - xs(j)) .* (ts(j+1) - ts(j));
    times(k) = (tc(1) + tc(end)) / 2;
end

info.nCrossings = numel(times);
info.crossingTimes = times;
info.halfPeriods = diff(times);
if numel(info.halfPeriods) >= 2
    info.halfPeriodSpread = max(info.halfPeriods) / min(info.halfPeriods) - 1;
else
    info.halfPeriodSpread = NaN;
end

if info.nCrossings >= 3
    n = (0:info.nCrossings - 1)';
    p = [n, ones(size(n))] \ times;                 % times = p(1) * n + p(2)
    f = 1 / (2 * p(1));
else
    f = NaN;
end

end
