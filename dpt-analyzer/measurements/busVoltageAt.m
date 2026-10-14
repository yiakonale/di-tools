function bv = busVoltageAt(col, range, S)
%BUSVOLTAGEAT Bus voltage V_DC over a time range, from the collection's model.
%
%   bv = busVoltageAt(col, range, S) returns the mean V_DC over RANGE
%   (corrected time [s]) from col.busVoltage (busVoltageModel). Every
%   measurement that needs V_DC reads it here, so all of them use the
%   same source and state it.
%
%   Output struct
%     value        mean V_DC over the range [V]
%     uncertainty  [V]: chargeDroop -> the largest error for any true C
%                  within C*(1 -/+ tol): droop = Q/C, so the worst case is
%                  C*(1 - tol), an error of droop * tol / (1 - tol)
%                  (25 % of the droop for tol = 20 %);
%                  NaN for measured sources (their own noise applies) and
%                  for "constant" (droop unknown; see flags)
%     source, label, description   from the model
%     flags        "busDroopDetected" when a constant V_DC0 is used on a
%                  record that demonstrably droops
%
%   The kvl source is valid on settled segments only: during switching
%   transients the loop's L*di/dt adds to V_DS,HS + V_DS,LS.

arguments
    col (1,1) struct
    range (1,2) double
    S (1,1) struct
end

bm = col.busVoltage;
bv.value = NaN;
bv.uncertainty = NaN;
bv.source = bm.source;
bv.label = bm.label;
bv.description = bm.description;
bv.flags = strings(1, 0);

switch bm.source
    case "busChannel"
        bv.value = mean(getSignal(col, bm.signals(1), range, S).x);
    case "kvl"
        a = getSignal(col, bm.signals(1), range, S).x;
        b = getSignal(col, bm.signals(2), range, S).x;
        if numel(a) == numel(b)
            bv.value = mean(a + b);
        end
    case "chargeDroop"
        q = (chargeAt(col, bm, range(1), S) + chargeAt(col, bm, range(2), S)) / 2;
        bv.value = bm.V0 - q / bm.C;
        bv.uncertainty = q / bm.C * bm.Ctolerance / (1 - bm.Ctolerance);
    case "constant"
        bv.value = bm.V0;
        if bm.droopDetected
            bv.flags = "busDroopDetected";
        end
end

end
