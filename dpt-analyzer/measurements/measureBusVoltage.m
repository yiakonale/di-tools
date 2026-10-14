function r = measureBusVoltage(def, method, ctx, sig, S)
%MEASUREBUSVOLTAGE Bus voltage at turn-off (#1) or turn-on (#2).
%
%   r = measureBusVoltage(def, method, ctx, sig, S) implements the
%   methods of registry entries VdcOff and VdcOn:
%
%     model        the bus-voltage model V_DC(t) (busVoltageModel,
%                  busVoltageAt) averaged over averagingWindow*D ending at
%                  the gate instant (V_GS 90 % falling at turn-off, 10 %
%                  rising at turn-on). The model's source (bus channel,
%                  KVL, charge droop, constant) is appended to the tag, and
%                  its uncertainty and flags are carried over.
%     offStateVds  (#2) the same window on the active device's V_DS, which
%                  is off during the pulse break
%     settledVds   (#1) mean of V_DS after the turn-off ringing has
%                  settled to within settlingBand of its settled level
%                  (median of the territory's final settledPortion),
%                  until the end of the territory
%     nominal      cfg.nominal.busVoltage
%
%   With the freewheel diode conducting, the off-state V_DS of the active
%   device is V_DC + V_F of that diode, so the V_DS-based methods read
%   high by V_F; the model does not (its constant V_DC0 comes from before
%   the first pulse, when no diode conducts).

r = makeResult(def, method, ctx);
e = ctx.edges(1);
C = S.measurements.common;

switch method.id
    case "nominal"
        r.value = ctx.cfg.nominal.busVoltage;
        r.status = "ok";
        r.provenance.source = "cfg.nominal.busVoltage";
        return

    case "model"
        p = 0.9 * (e.kind == "turnOff") + 0.1 * (e.kind == "turnOn");
        g = gateInstant(ctx, e, p, S);
        if ~g.found
            r.reason = g.reason;
            return
        end
        range = [g.time - C.averagingWindow * e.D, g.time];
        bv = busVoltageAt(ctx.col, range, S);
        if isnan(bv.value)
            r.reason = "the bus-voltage model gives no value over the averaging window";
            return
        end
        r.value = bv.value;
        r.methodTag = r.methodTag + " from " + bv.label;
        r.flags = bv.flags;
        r.provenance.busVoltage = bv.description;
        r.provenance.uncertainty = bv.uncertainty;
        r.provenance.gateInstant = g.time - e.time;
        r.provenance.window = range - e.time;
        r.status = "ok";
        return

    case "offStateVds"
        p = 0.9 * (e.kind == "turnOff") + 0.1 * (e.kind == "turnOn");
        g = gateInstant(ctx, e, p, S);
        if ~g.found
            r.reason = g.reason;
            return
        end
        range = [g.time - C.averagingWindow * e.D, g.time];
        st = windowStats(ctx, sig.V, range, S);
        if ~st.complete
            r.reason = "the averaging window lies outside the record";
            return
        end
        r.value = st.mean;
        r.provenance.gateInstant = g.time - e.time;
        r.provenance.gateLevel = g.level;
        r.provenance.window = range - e.time;

    case "settledVds"
        after = windowStats(ctx, sig.V, [e.core(2), e.territory(2)], S);
        before = windowStats(ctx, sig.V, [e.territory(1), e.window(1)], S);
        if ~(after.complete && before.complete)
            r.reason = "the territory around the edge is too short or outside the record";
            return
        end
        tail = after.x(ceil((1 - C.settledPortion) * after.n):end);
        settled = median(tail);
        band = C.settlingBand * abs(settled - before.median);
        [ts, si] = settlingTime(after.t, after.x, settled, band);
        if ~si.settled
            r.reason = sprintf(['V_DS does not settle to within +/- %.3g V of %.4g V ' ...
                'before the territory ends'], band, settled);
            return
        end
        st = windowStats(ctx, sig.V, [ts, e.territory(2)], S);
        r.value = st.mean;
        r.provenance.settlingTime = ts - e.time;
        r.provenance.settlingBand = band;
        r.provenance.window = [ts, e.territory(2)] - e.time;
end

r.provenance.nSamples = st.n;
r.provenance.sigma = st.sigma;
r.flags = valueFlags(r.value, st.sigma, st.quantStep, S);
r.status = "ok";

end
