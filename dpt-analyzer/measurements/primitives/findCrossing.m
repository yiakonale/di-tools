function c = findCrossing(t, x, level, direction, searchRange, occurrence)
%FINDCROSSING Interpolated time at which a waveform crosses a level.
%
%   c = findCrossing(t, x, level, direction, searchRange, occurrence)
%
%   Inputs
%     t, x         column vectors of equal length (time [s], samples)
%     level        crossing level, in the units of x
%     direction    "rising"  : x(k) <  level and x(k+1) >= level
%                  "falling" : x(k) >  level and x(k+1) <= level
%                  "either"  : both
%     searchRange  [t0 t1] [s]: only sample pairs with both samples
%                  inside the range are considered; [] = whole vector
%     occurrence   "first" (default) | "last"
%
%   Output struct
%     found        true if at least one crossing exists in the range
%     time         interpolated crossing time [s] (linear between the two
%                  bracketing samples), NaN if not found
%     index        k: the crossing lies between samples k and k+1, NaN
%                  if not found
%     count        number of crossings in the requested direction(s)
%     initialSide  sign(x(first) - level) at the start of the range: +1
%                  above, -1 below, 0 on the level. Lets the caller explain
%                  a missing crossing ("already beyond the level").
%
%   NaN samples never form a crossing, so filter edges marked NaN are
%   skipped rather than misread.

arguments
    t (:,1) double
    x (:,1) double
    level (1,1) double
    direction (1,1) string {mustBeMember(direction, ["rising", "falling", "either"])}
    searchRange double = []
    occurrence (1,1) string {mustBeMember(occurrence, ["first", "last"])} = "first"
end

if numel(t) ~= numel(x)
    error('findCrossing:sizeMismatch', 't and x must have the same length.');
end

c = struct('found', false, 'time', NaN, 'index', NaN, 'count', 0, 'initialSide', NaN);

[i0, i1] = rangeIndices(t, searchRange);
if isempty(i0) || i1 - i0 < 1
    return
end
c.initialSide = sign(x(i0) - level);

a = x(i0:i1-1);
b = x(i0+1:i1);
switch direction
    case "rising"
        hit = a < level & b >= level;
    case "falling"
        hit = a > level & b <= level;
    case "either"
        hit = (a < level & b >= level) | (a > level & b <= level);
end
k = find(hit);
c.count = numel(k);
if isempty(k)
    return
end
if occurrence == "first"
    k = k(1);
else
    k = k(end);
end
j = i0 + k - 1;
c.found = true;
c.index = j;
c.time = t(j) + (level - x(j)) / (x(j+1) - x(j)) * (t(j+1) - t(j));

end

% =====================================================================
function [i0, i1] = rangeIndices(t, r)
if isempty(r)
    i0 = 1;
    i1 = numel(t);
    return
end
if numel(r) ~= 2 || r(1) > r(2)
    error('findCrossing:invalidRange', 'searchRange must be [] or [t0 t1] with t0 <= t1.');
end
i0 = find(t >= r(1), 1, 'first');
i1 = find(t <= r(2), 1, 'last');
end
