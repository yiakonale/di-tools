function st = windowStats(ctx, name, range, S)
%WINDOWSTATS Samples and statistics of one signal over a time range.
%
%   st = windowStats(ctx, name, range, S) reads signal NAME of the event's
%   collection over RANGE (corrected time [s]) through getSignal, so all
%   corrections are applied, and summarizes it.
%
%   Output struct
%     signal, range, t, x, n
%     complete   the range lies inside the record and has >= 3 samples
%     mean, median
%     sigma      noise (noiseLevel: MAD after a linear detrend, with a
%                quantization floor), NaN if fewer than 3 samples
%     quantStep  ADC step of the samples (NaN if not determinable)
%     corrections  the channel's corrections, for provenance

arguments
    ctx (1,1) struct
    name (1,1) string
    range (1,2) double
    S (1,1) struct
end

sig = getSignal(ctx.col, name, range, S);
st.signal = name;
st.range = range;
st.t = sig.t;
st.x = sig.x;
st.n = numel(sig.x);
st.complete = sig.complete && st.n >= 3;
st.mean = mean(sig.x);
st.median = median(sig.x);
st.corrections = sig.corrections;
if st.n >= 3
    [st.sigma, info] = noiseLevel(sig.x);
    st.quantStep = info.quantStep;
else
    st.sigma = NaN;
    st.quantStep = NaN;
end

end
