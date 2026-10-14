function sig = getSignal(col, signal, tRange, S)
%GETSIGNAL Read a signal from a collection with corrections applied.
%
%   sig = getSignal(col, signal, tRange, S) is the only way downstream
%   code reads waveform samples (DATA_CONTRACTS.md section 4.1), so
%   post-acquisition corrections are applied in one place, identically
%   everywhere. The raw samples in COL are never modified.
%
%   Inputs
%     col     collection struct from importCollection
%     signal  canonical signal name, e.g. "Vds-LS"
%     tRange  [t0 t1] in corrected scope time [s], or [] for the whole
%             record. Samples with t0 <= t <= t1 are returned.
%     S       settings (S.sampling.timeVectorRelTol sets the boundary
%             tolerance that absorbs floating-point error)
%
%   Output fields
%     signal, channel, units
%     x            corrected samples: inverted if requested, minus the
%                  zero offset (zeroOffsetCorrection), then gain * x +
%                  offset from current-sensor normalization
%     t            corrected times, col.time(index) + deskewApplied [s]
%     index        raw sample indices into the channel's data
%     complete     false if tRange extends beyond the corrected record
%     corrections  the channel's corrections, for provenance
%
%   Because applied deskew is always an integer number of samples, two
%   signals of one collection read over the same tRange share one time
%   grid and can be combined sample by sample without interpolation.

arguments
    col (1,1) struct
    signal (1,1) string
    tRange double
    S (1,1) struct
end

k = find([col.channels.signal] == signal);
if isempty(k)
    error('dpt:signal:notFound', 'Collection "%s" has no signal "%s". Available: %s.', ...
        col.name, signal, strjoin([col.channels.signal], ", "));
end
ch = col.channels(k);
c = ch.corrections;
tol = S.sampling.timeVectorRelTol * col.sampleInterval;

if isempty(tRange)
    index = (1:col.recordLength)';
    complete = true;
else
    if ~(numel(tRange) == 2 && all(isfinite(tRange)) && tRange(1) <= tRange(2))
        error('dpt:signal:invalidRange', ...
            'tRange must be [] or a finite [t0 t1] with t0 <= t1.');
    end
    % Compare in raw time: t_corrected = t_raw + deskewApplied.
    lo = tRange(1) - c.deskewApplied - tol;
    hi = tRange(2) - c.deskewApplied + tol;
    first = find(col.time >= lo, 1, 'first');
    last = find(col.time <= hi, 1, 'last');
    if isempty(first) || isempty(last) || first > last
        index = zeros(0, 1);
    else
        index = (first:last)';
    end
    complete = lo >= col.time(1) - 2 * tol && hi <= col.time(end) + 2 * tol;
end

x = ch.data(index);
if c.invert
    x = -x;
end
if c.zeroOffset ~= 0
    x = x - c.zeroOffset;               % probe zero offset (pre-pulse mean)
end
if c.gain ~= 1 || c.offset ~= 0
    x = c.gain * x + c.offset;          % current-sensor normalization
end

sig.signal = ch.signal;
sig.channel = ch.channel;
sig.units = ch.units;
sig.x = x;
sig.t = col.time(index) + c.deskewApplied;
sig.index = index;
sig.complete = complete;
sig.corrections = c;

end
