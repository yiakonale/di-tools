function th = transitionThreshold(pre, post, level, sigma, k)
%TRANSITIONTHRESHOLD Check that a threshold level is resolvable above noise.
%
%   th = transitionThreshold(pre, post, level, sigma, k) describes the
%   threshold LEVEL on a transition from PRE to POST and applies the
%   noise-floor rule (MEASUREMENT_DESIGN.md section 10.1, Q2): a threshold
%   is used only if it lies strictly between the two levels and at least
%   k*sigma away from both,
%
%       min(|level - pre|, |level - post|) >= k * sigma.
%
%   For a percent threshold this is min(p, 1 - p) * |post - pre| >= k*sigma.
%   The rule scales automatically: a 2 % threshold needs a much cleaner
%   transition than a 10 % one. LEVEL is absolute, so every basis
%   ("transition", "x % of V_DC", absolute volts) is checked the same way.
%
%   Percent convention (IEC, and MEASUREMENT_SPEC.md): percentages are on
%   the AMPLITUDE scale of the transition, independent of its direction:
%
%       level(p) = low + p * (high - low),  low/high = min/max(pre, post)
%
%   so "V_DS falls to 90 %" is near the START of a falling edge and
%   "V_DS falls to 10 %" near its end. It is not "90 % of the transition
%   completed".
%
%   Inputs
%     pre, post  levels before and after the transition
%     level      threshold level (absolute, units of pre/post)
%     sigma      noise of the signal (e.g. from noiseLevel), >= 0
%     k          noise-floor multiple, > 0
%
%   Output struct
%     level, direction ("rising" if post > pre, else "falling")
%     amplitude    |post - pre|
%     fraction     (level - low) / (high - low): the percent position on
%                  the amplitude scale (see the convention above)
%     margin       min distance to pre/post divided by k*sigma (>= 1 is
%                  resolvable; Inf when sigma = 0)
%     resolvable   true if the rule holds
%     noiseLimited true if the level lies inside the transition but too
%                  close to a level for the noise (the only failure that a
%                  cleaner signal or another method could avoid)
%     reason       explanation when not resolvable, "" otherwise

arguments
    pre (1,1) double
    post (1,1) double
    level (1,1) double
    sigma (1,1) double {mustBeNonnegative}
    k (1,1) double {mustBePositive}
end

th.level = level;
if post > pre
    th.direction = "rising";
else
    th.direction = "falling";
end
th.amplitude = abs(post - pre);
if th.amplitude > 0
    th.fraction = (level - min(pre, post)) / th.amplitude;
else
    th.fraction = NaN;
end

distance = min(abs(level - pre), abs(level - post));
floorLevel = k * sigma;
if floorLevel > 0
    th.margin = distance / floorLevel;
else
    th.margin = Inf;
end

inside = th.amplitude > 0 && th.fraction > 0 && th.fraction < 1;
th.resolvable = inside && distance >= floorLevel;
th.noiseLimited = inside && ~th.resolvable;

if th.amplitude == 0
    th.reason = "the transition has zero amplitude";
elseif ~inside
    th.reason = sprintf('level %.4g lies outside the transition %.4g -> %.4g', level, pre, post);
elseif ~th.resolvable
    th.reason = sprintf(['level %.4g is %.3g from the nearest transition level, below ' ...
        'the noise floor %g x sigma = %.3g'], level, distance, k, floorLevel);
else
    th.reason = "";
end
th.reason = string(th.reason);

end
