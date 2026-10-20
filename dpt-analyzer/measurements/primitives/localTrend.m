function y = localTrend(x, n)
%LOCALTREND Moving least-squares line through a signal, at every sample.
%
%   y = localTrend(x, n) fits a straight line to each centred window of n
%   samples (shrinking at the ends, like movsum) and evaluates it at the
%   window's own sample. In the interior this is the centred moving mean;
%   near the ends, where the window is one-sided, the local slope removes
%   the bias a moving mean would have on a ramp. A ramp passes unchanged;
%   oscillations much shorter than n samples are averaged out; at a kink
%   of slope change dS the error is dS * n * dt / 8.
%
%   Inputs
%     x   column vector (uniform sampling)
%     n   window length in samples, >= 2
%
%   Used for the "ringing has decayed" test on a ramping current
%   (settledAfter) and for the smooth inductor current of the derived
%   diode current (measureRecovery).

arguments
    x (:,1) double
    n (1,1) double {mustBeInteger, mustBeGreaterThanOrEqual(n, 2)}
end

k = (1:numel(x))';
S0 = movsum(ones(size(x)), n);
Sk = movsum(k, n);
Sx = movsum(x, n);
Skk = movsum(k.^2, n);
Skx = movsum(k .* x, n);
den = S0 .* Skk - Sk.^2;
slope = (S0 .* Skx - Sk .* Sx) ./ den;
slope(den == 0) = 0;
y = Sx ./ S0 + slope .* (k - Sk ./ S0);

end
