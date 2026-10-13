function c = savgolKernel(n, order, derivative)
%SAVGOLKERNEL Savitzky-Golay coefficients without the Signal Processing Toolbox.
%
%   c = savgolKernel(n, order, derivative) returns the 1-by-n weights that
%   give the DERIVATIVE-th derivative (0 = smoothed value) at the centre
%   of an n-sample window, from a least-squares polynomial of degree
%   ORDER fitted to the window:
%
%       estimate = sum(c .* window) / dt^derivative
%
%   where window is the n samples centred on the point. Window positions
%   are -m..m with m = (n-1)/2, so n must be odd and order < n.

arguments
    n (1,1) double {mustBeInteger, mustBePositive}
    order (1,1) double {mustBeInteger, mustBeNonnegative}
    derivative (1,1) double {mustBeInteger, mustBeNonnegative} = 0
end

if mod(n, 2) == 0
    error('savgolKernel:evenWindow', 'Window length n must be odd (centred).');
end
if order >= n
    error('savgolKernel:orderTooHigh', 'Polynomial order must be smaller than the window length.');
end
if derivative > order
    error('savgolKernel:derivativeTooHigh', 'Derivative order must not exceed the polynomial order.');
end

m = (n - 1) / 2;
j = (-m:m)';
V = j .^ (0:order);                         % n-by-(order+1) Vandermonde
P = pinv(V);                                % least-squares fit operator
c = factorial(derivative) * P(derivative + 1, :);

end
