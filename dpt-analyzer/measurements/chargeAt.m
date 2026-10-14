function q = chargeAt(col, bm, t, S)
%CHARGEAT Charge drawn from the DC link up to time t.
%
%   q = chargeAt(col, bm, t, S) integrates the active device's current
%   (bm.currentSignal) over the parts of its on-state intervals
%   (bm.onIntervals, corrected time) that lie before T [C]. During the
%   pulse breaks the inductor current circulates through the diode and
%   draws nothing from the link, so only the on-states count; this also
%   keeps the sensor's off-state offset out of the integral.

arguments
    col (1,1) struct
    bm (1,1) struct
    t (1,1) double
    S (1,1) struct
end

q = 0;
for k = 1:size(bm.onIntervals, 1)
    a = bm.onIntervals(k, 1);
    b = min(bm.onIntervals(k, 2), t);
    if b <= a
        break
    end
    sig = getSignal(col, bm.currentSignal, [a, b], S);
    if numel(sig.x) >= 2
        q = q + integrateBetween(sig.t, sig.x, sig.t(1), sig.t(end));
    end
end

end
