function [ts, info] = settlingTime(t, x, level, band, searchRange)
%SETTLINGTIME Time after which a waveform stays within a band of a level.
%
%   [ts, info] = settlingTime(t, x, level, band, searchRange) returns the
%   earliest time ts in the search range such that |x - level| <= band
%   for every sample from ts to the end of the range. This is the
%   "ringing has decayed" criterion of MEASUREMENT_DESIGN.md section 6.3.
%
%   Inputs
%     t, x         column vectors of equal length
%     level        settled level (e.g. median of the range's final part)
%     band         half-width of the band, > 0, units of x
%     searchRange  [t0 t1] [s], or [] for the whole vector
%
%   Output
%     ts    settling time [s], resolved to the sample grid; t(first) if
%           the signal is inside the band throughout; NaN if the last
%           sample of the range is still outside (never settles here)
%     info  struct: settled (logical), lastOutside (time of the last
%           sample outside the band, NaN if none)

arguments
    t (:,1) double
    x (:,1) double
    level (1,1) double
    band (1,1) double {mustBePositive}
    searchRange double = []
end

if numel(t) ~= numel(x)
    error('settlingTime:sizeMismatch', 't and x must have the same length.');
end

if isempty(searchRange)
    idx = (1:numel(t))';
else
    idx = find(t >= searchRange(1) & t <= searchRange(2));
end
info = struct('settled', false, 'lastOutside', NaN);
ts = NaN;
if isempty(idx)
    return
end

outside = abs(x(idx) - level) > band | isnan(x(idx));
last = find(outside, 1, 'last');
if isempty(last)
    ts = t(idx(1));
    info.settled = true;
elseif last < numel(idx)
    ts = t(idx(last + 1));
    info.settled = true;
    info.lastOutside = t(idx(last));
else
    info.lastOutside = t(idx(last));
end

end
