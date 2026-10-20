function st = settledAfter(ctx, e, name, S, opts)
%SETTLEDAFTER When a signal has settled after an edge ("ringing has decayed").
%
%   st = settledAfter(ctx, e, name, S) returns when signal NAME settles
%   after edge E of the event context: the earliest time after which every
%   sample until the end of the edge's territory lies within the settling
%   band of its settled level (MEASUREMENT_DESIGN.md §6.3, refined in §16.3).
%   It is the one settling test of all measurements.
%
%   st = settledAfter(..., opts) with optional fields
%     trend   true for a ramping current: settle on a local linear trend
%             (moving least-squares line over averagingWindow*D) instead
%             of a constant level (default false)
%     start   search start [s, corrected time] (default the end of the
%             edge's core, e.core(2))
%
%   Settled level and noise come from [e.core(2), e.territory(2)]: the
%   level is the median of its final settledPortion (or 0 about the local
%   trend). The band half-width is
%     max(settlingBand * amplitude, k * sigma)
%   with amplitude the transition of the signal's own levels (eventLevels)
%   and the noise floor of §16.3:
%     k      max(noiseFloorMultiple, sqrt(2 ln N)), N the samples searched:
%            the test is a LAST exit, so the floor is the expected maximum
%            of N noise samples, not the per-sample 3 sigma
%     sigma  noise of the final settledPortion, unless it exceeds
%            tailNoiseRatio times the quiet pre-switching noise (max of
%            sigma and the ADC step over averagingWindow*D before the gate
%            instant): then the tail still rings and the pre-switching
%            sigma is used, so the ringing is not taken for noise
%
%   Output struct: time (NaN if it never settles), settled (logical),
%   level (settled level; NaN with trend), band, sigma, amplitude, reason.

arguments
    ctx (1,1) struct
    e (1,1) struct
    name (1,1) string
    S (1,1) struct
    opts.trend (1,1) logical = false
    opts.start double = []
end

C = S.measurements.common;
st = struct('time', NaN, 'settled', false, 'level', NaN, 'band', NaN, 'sigma', NaN, ...
    'amplitude', NaN, 'reason', "");

s = getSignal(ctx.col, name, [e.core(2), e.territory(2)], S);
if numel(s.x) < 3
    st.reason = "the territory after the edge is too short or outside the record";
    return
end
tail = ceil((1 - C.settledPortion) * numel(s.x)):numel(s.x);
if opts.trend
    n = max(3, round(C.averagingWindow * e.D / median(diff(s.t))));
    y = s.x - localTrend(s.x, n);
    level = 0;
else
    y = s.x;
    level = median(s.x(tail));
    st.level = level;
end

lv = eventLevels(ctx, e, name, S);
st.amplitude = lv.amplitude;
sigma = noiseLevel(y(tail));
p = 0.1 * (e.kind == "turnOn") + 0.9 * (e.kind == "turnOff");
g = gateInstant(ctx, e, p, S);
if g.found
    pre = windowStats(ctx, name, [g.time - C.averagingWindow * e.D, g.time], S);
    if pre.complete && sigma > C.tailNoiseRatio * max(pre.sigma, pre.quantStep)
        sigma = pre.sigma;
    end
end
st.sigma = sigma;

if isempty(opts.start)
    m = true(size(s.t));
else
    m = s.t >= opts.start;
end
if nnz(m) < 2
    st.reason = "the search starts after the end of the territory";
    return
end
k = max(C.noiseFloorMultiple, sqrt(2 * log(nnz(m))));
st.band = max(C.settlingBand * lv.amplitude, k * sigma);
if ~(st.band > 0)
    st.reason = "the signal neither changes across the edge nor shows noise";
    return
end
[ts, info] = settlingTime(s.t(m), y(m), level, st.band);
if info.settled
    st.time = ts;
    st.settled = true;
else
    st.reason = sprintf('%s does not settle to within +/- %.3g of its settled level before the territory ends', ...
        name, st.band);
end

end
