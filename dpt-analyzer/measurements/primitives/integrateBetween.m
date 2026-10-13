function [value, info] = integrateBetween(t, y, t0, t1)
%INTEGRATEBETWEEN Trapezoidal integral of y dt between two arbitrary times.
%
%   [value, info] = integrateBetween(t, y, t0, t1) integrates y from t0 to
%   t1. The integrand is linearly interpolated at t0 and t1, so threshold
%   times between samples are honoured exactly instead of being rounded
%   to the sample grid (at 160 ps sampling and ~10 ns energy windows,
%   rounding would cost up to a few percent).
%
%   Inputs
%     t   column vector, strictly increasing [s]
%     y   integrand, same length (e.g. V_DS .* I_D on the shared grid)
%     t0, t1  integration limits [s], t0 <= t1
%
%   Outputs
%     value  the integral (NaN if the limits are outside t, or if y has
%            NaN inside the limits)
%     info   struct: complete (limits inside t), nSamples (interior
%            samples used), duration (t1 - t0)

arguments
    t (:,1) double
    y (:,1) double
    t0 (1,1) double
    t1 (1,1) double
end

if numel(t) ~= numel(y)
    error('integrateBetween:sizeMismatch', 't and y must have the same length.');
end
if t0 > t1
    error('integrateBetween:invalidLimits', 't0 must not exceed t1.');
end

info.complete = t0 >= t(1) && t1 <= t(end);
info.duration = t1 - t0;
info.nSamples = 0;
if ~info.complete
    value = NaN;
    return
end

inside = t > t0 & t < t1;
info.nSamples = nnz(inside);
y0 = interp1(t, y, t0, 'linear');
y1 = interp1(t, y, t1, 'linear');
value = trapz([t0; t(inside); t1], [y0; y(inside); y1]);

end
