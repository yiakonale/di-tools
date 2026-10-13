function results = evaluateMeasurement(def, ctx, S)
%EVALUATEMEASUREMENT Select a method and evaluate one measurement on one event.
%
%   results = evaluateMeasurement(def, ctx, S) returns the 1-by-N result
%   structs (makeResult; N is 1 except for multi-valued methods such as
%   time-resolved R_on) of registry entry DEF on the event context CTX.
%
%   Selection (MEASUREMENT_DESIGN.md sections 2.3, 4)
%     1. Optional measurements run only if listed in
%        S.measurements.enableOptional (or "all").
%     2. Measurements restricted to a device type are skipped on others.
%     3. Methods are tried in the preference order
%        S.measurements.methods.(def.methodKey) (or the registry order if
%        the entry has no methodKey). The first method whose requirement
%        slots are all satisfied IN THIS COLLECTION is used: each slot
%        takes its first alternative present in the collection. "nominal"
%        methods also need their cfg.nominal value.
%     4. If none is available, the result is "skipped" and the reason
%        lists what each preferred method was missing.

arguments
    def (1,1) struct
    ctx (1,1) struct
    S (1,1) struct
end

cfg = ctx.cfg;
opt = S.measurements.enableOptional;
if def.optional && ~(any(opt == "all") || any(opt == def.id))
    results = skipped(def, ctx, "optional measurement, not enabled (S.measurements.enableOptional)");
    return
end
if ~isempty(def.deviceTypes) && ~any(def.deviceTypes == cfg.deviceType)
    results = skipped(def, ctx, sprintf('applies to %s only (cfg.deviceType = %s)', ...
        strjoin(def.deviceTypes, "/"), cfg.deviceType));
    return
end

known = [def.methods.id];
if def.methodKey == ""
    prefs = known;
else
    prefs = S.measurements.methods.(def.methodKey);
    unknown = setdiff(prefs, known);
    if ~isempty(unknown)
        error('dpt:settings:unknownMethod', ...
            'S.measurements.methods.%s: unknown method(s) %s for %s. Valid: %s.', ...
            def.methodKey, strjoin(unknown, ", "), def.id, strjoin(known, ", "));
    end
end

present = [ctx.col.channels.signal];
why = strings(1, 0);
for id = prefs
    m = def.methods(known == id);
    [ok, sig, missing] = available(m, present, cfg, S);
    if ok
        results = def.fn(def, m, ctx, sig, S);
        for k = 1:numel(results)
            results(k).provenance.signals = sig;
        end
        return
    end
    why(end+1) = id + " needs " + missing; %#ok<AGROW>
end
results = skipped(def, ctx, "no method available in this collection: " + strjoin(why, "; "));

end

% =====================================================================
function [ok, sig, missing] = available(m, present, cfg, S)
% Resolve every requirement slot to the first alternative present.
sig = struct();
missing = "";
if m.nominal ~= "" && isempty(cfg.nominal.(m.nominal))
    ok = false;
    missing = "cfg.nominal." + m.nominal;
    return
end
for s = m.requires
    names = strings(size(s.roles));
    for k = 1:numel(s.roles)
        names(k) = resolveRole(s.roles(k), cfg, S);
    end
    hit = find(ismember(names, present), 1);
    if isempty(hit)
        ok = false;
        missing = strjoin(names, " or ");
        return
    end
    sig.(s.slot) = names(hit);
    sig.(s.slot + "Role") = s.roles(hit);
end
ok = true;
end

function r = skipped(def, ctx, reason)
r = makeResult(def, [], ctx);
r.status = "skipped";
r.reason = string(reason);
end
