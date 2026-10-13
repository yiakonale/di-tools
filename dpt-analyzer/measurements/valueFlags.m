function flags = valueFlags(value, sigma, quantStep, S, checkResolution)
%VALUEFLAGS Quality flags of a level-type result (never alters the value).
%
%   flags = valueFlags(value, sigma, quantStep, S, checkResolution)
%
%     "belowNoiseFloor"    |value| < k * sigma (k = noiseFloorMultiple):
%                          the value cannot be told apart from zero, e.g.
%                          I_on of a zero-current first pulse. The value
%                          is kept as measured, not clamped (Q2).
%     "resolutionLimited"  (only if CHECKRESOLUTION) |value| is smaller
%                          than resolutionSteps ADC steps of its channel,
%                          e.g. V_F or V_DS(on) read on a full-range V_DS
%                          channel; use a clamped channel instead.

arguments
    value (1,1) double
    sigma (1,1) double
    quantStep (1,1) double
    S (1,1) struct
    checkResolution (1,1) logical = false
end

C = S.measurements.common;
flags = strings(1, 0);
if ~isnan(sigma) && abs(value) < C.noiseFloorMultiple * sigma
    flags(end+1) = "belowNoiseFloor";
end
if checkResolution && ~isnan(quantStep) && abs(value) < C.resolutionSteps * quantStep
    flags(end+1) = "resolutionLimited";
end

end
