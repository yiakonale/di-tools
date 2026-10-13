function dx = differentiateSignal(x, dt, method, n, order)
%DIFFERENTIATESIGNAL Time derivative of a uniformly sampled signal.
%
%   dx = differentiateSignal(x, dt, method, n, order) returns dx/dt [units
%   of x per second]. Results that use a derivative must state the method
%   and its parameters (MEASUREMENT_SPEC.md rows 27, 28, 46).
%
%   Methods
%     "central"        : (x(k+1) - x(k-1)) / (2 dt). No smoothing; at
%                        fine sampling it amplifies quantization noise.
%     "movmeanCentral" : centred moving average of n samples, then central
%                        difference.
%     "savgol"         : Savitzky-Golay first derivative, polynomial ORDER
%                        (default 2) over n samples.
%
%   Samples without a complete stencil are NaN (see filterSignal).

arguments
    x (:,1) double
    dt (1,1) double {mustBePositive}
    method (1,1) string {mustBeMember(method, ["central", "movmeanCentral", "savgol"])}
    n (1,1) double {mustBeInteger, mustBePositive} = 1
    order (1,1) double {mustBeInteger, mustBeNonnegative} = 2
end

switch method
    case "central"
        dx = centralDifference(x, dt);
    case "movmeanCentral"
        dx = centralDifference(filterSignal(x, "movmean", n), dt);
    case "savgol"
        dx = nan(size(x));
        if mod(n, 2) == 0
            error('differentiateSignal:evenWindow', 'Window length n must be odd (centred).');
        end
        h = (n - 1) / 2;
        if numel(x) >= n
            c = savgolKernel(n, order, 1);
            dx(h+1:end-h) = conv(x, flip(c(:)), 'valid') / dt;
        end
end

end

% =====================================================================
function dx = centralDifference(x, dt)
dx = nan(size(x));
if numel(x) >= 3
    dx(2:end-1) = (x(3:end) - x(1:end-2)) / (2 * dt);
end
end
