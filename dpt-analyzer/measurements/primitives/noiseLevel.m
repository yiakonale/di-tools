function [sigma, info] = noiseLevel(x)
%NOISELEVEL Robust noise estimate of a settled (flat or ramping) segment.
%
%   [sigma, info] = noiseLevel(x) estimates the noise standard deviation
%   of a segment that is expected to be flat or linear, such as a
%   settled level or the inductor-current ramp during the on-time.
%
%   Method
%     1. Remove a least-squares straight line, so a ramp is not counted
%        as noise.
%     2. sigmaMad = 1.4826 * median(|r - median(r)|), the MAD estimate,
%        which ignores isolated spikes.
%     3. Quantization floor: an ADC with step q contributes q/sqrt(12)
%        even when the MAD is zero (a quantized flat signal that sits on
%        one code). q is the smallest step between distinct sample values.
%     sigma = max(sigmaMad, q / sqrt(12)).
%
%   Output info: sigmaMad, quantStep (q, NaN if fewer than 2 distinct
%   values), quantSigma (q/sqrt(12)), slope (per sample), nSamples.

arguments
    x (:,1) double
end

x = x(~isnan(x));
n = numel(x);
if n < 3
    error('noiseLevel:tooShort', 'noiseLevel needs at least 3 non-NaN samples.');
end

k = (1:n)';
p = [k, ones(n, 1)] \ x;
r = x - (p(1) * k + p(2));
info.sigmaMad = 1.4826 * median(abs(r - median(r)));

info.quantStep = quantizationStep(x);
if isnan(info.quantStep)
    info.quantSigma = 0;
else
    info.quantSigma = info.quantStep / sqrt(12);
end
info.slope = p(1);
info.nSamples = n;

sigma = max(info.sigmaMad, info.quantSigma);

end

% =====================================================================
function q = quantizationStep(x)
% Smallest non-negligible step between distinct values. Steps below
% 1e-9 of the value range are floating-point representation noise of
% the same ADC code, not separate codes.
u = unique(x);
if numel(u) < 2
    q = NaN;
    return
end
d = diff(u);
d = d(d > 1e-9 * (u(end) - u(1)));
q = min(d);
end
