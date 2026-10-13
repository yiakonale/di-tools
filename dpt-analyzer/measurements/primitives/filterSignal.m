function y = filterSignal(x, method, n, order)
%FILTERSIGNAL Zero-phase smoothing of a measurement signal.
%
%   y = filterSignal(x, method, n, order) returns a smoothed COPY of x.
%   All methods are centred (zero phase), so they do not shift threshold
%   times. Results that use a filter must state it (method, n, order).
%
%   Inputs
%     x       column vector
%     method  "none"    : y = x
%             "movmean" : centred moving average of n samples
%             "savgol"  : Savitzky-Golay, polynomial ORDER over n samples
%                         (preserves peaks better than a moving average)
%     n       odd window length in samples (ignored for "none")
%     order   polynomial order for "savgol" (default 2)
%
%   The first and last (n-1)/2 samples have no complete window and are
%   returned as NaN, so edge effects never enter a result silently.
%   Callers read the signal with at least half a window of margin.

arguments
    x (:,1) double
    method (1,1) string {mustBeMember(method, ["none", "movmean", "savgol"])}
    n (1,1) double {mustBeInteger, mustBePositive} = 1
    order (1,1) double {mustBeInteger, mustBeNonnegative} = 2
end

if method == "none" || n == 1
    y = x;
    return
end
if mod(n, 2) == 0
    error('filterSignal:evenWindow', 'Window length n must be odd (centred).');
end

h = (n - 1) / 2;
y = nan(size(x));
if numel(x) < n
    return
end

switch method
    case "movmean"
        y = movmean(x, n, 'Endpoints', 'fill');
    case "savgol"
        c = savgolKernel(n, order, 0);
        y(h+1:end-h) = conv(x, flip(c(:)), 'valid');
end

end
