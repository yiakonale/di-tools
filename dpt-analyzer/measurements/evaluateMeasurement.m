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
%        methods also need their cfg.nominal value; bus-model methods need
%        a bus-voltage model (col.busVoltage, busVoltageModel).
%     4. If none is available, the result is "skipped" and the reason
%        lists what each preferred method was missing.
%     5. Noise-limited fallback (user decision 2026-10-20, design 17.5): a
%        method that FAILS only because the noise-floor rule refused one of
%        its levels (result.noiseLimited) is followed by the next available
%        method in the preference order. A result reached this way is
%        flagged "methodFallback"; provenance.fallbackFrom lists each method
%        passed over and why. A fallback never moves to a method of the
%        other device type's standard (IEC-9 on a MOSFET). If every method
%        fails, the first failure is returned with the others' reasons
%        appended.
%     6. Event-specific methods (method.events, e.g. the #47 dip at
%        turn-on only) are unavailable on other event kinds, and a method
%        that reports itself "skipped" (e.g. no capacitance known for the
%        #47 ringing method) is passed over like an unavailable one
%        (design 18.1); if nothing else succeeds, the first such skip is
%        returned.
%
%   Presets: a "preset" entry in the preference list is replaced by
%   def.presets.(IEC8|IEC9) for S.measurements.preset ("auto" follows
%   cfg.deviceType), or the first registry method for "none". A result
%   whose method comes from the other device type's standard is flagged
%   "methodDeviceMismatch".

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
    prefs = expandPreset(prefs, def, cfg, S);
    unknown = setdiff(prefs, known);
    if ~isempty(unknown)
        error('dpt:settings:unknownMethod', ...
            'S.measurements.methods.%s: unknown method(s) %s for %s. Valid: %s.', ...
            def.methodKey, strjoin(unknown, ", "), def.id, strjoin(known, ", "));
    end
end

present = [ctx.col.channels.signal];
why = strings(1, 0);
passed = struct('method', {}, 'tag', {}, 'reason', {});
first = [];
firstSkip = [];
for id = prefs
    m = def.methods(known == id);
    mismatch = (m.standard == "IEC-8" && cfg.deviceType == "IGBT") || ...
        (m.standard == "IEC-9" && cfg.deviceType == "MOSFET");
    if ~isempty(first) && mismatch
        continue        % a fallback never moves to the other device's standard
    end
    [ok, sig, missing] = available(m, present, ctx, cfg, S);
    if ok
        results = def.fn(def, m, ctx, sig, S);
        for k = 1:numel(results)
            results(k).provenance.signals = sig;
            results(k).provenance.preset = presetName(cfg, S);
            if mismatch
                results(k).flags = unique([results(k).flags, "methodDeviceMismatch"], 'stable');
            end
        end
        if all([results.status] == "failed") && (any([results.noiseLimited]) || ~isempty(first))
            % Refused by the noise floor only (or a later link of such a
            % fallback chain failed): try the next method.
            if isempty(first)
                first = results;
            end
            passed(end+1) = struct('method', m.id, 'tag', string(results(1).methodTag), ...
                'reason', string(results(1).reason)); %#ok<AGROW>
            continue
        end
        if all([results.status] == "skipped")
            % The method found itself inapplicable here: like unavailable.
            if isempty(firstSkip)
                firstSkip = results;
            end
            why(end+1) = id + ": " + results(1).reason; %#ok<AGROW>
            continue
        end
        if ~isempty(passed) && any([results.status] == "ok")
            for k = 1:numel(results)
                results(k).flags = unique([results(k).flags, "methodFallback"], 'stable');
                results(k).provenance.fallbackFrom = passed;
            end
        end
        return
    end
    why(end+1) = id + " needs " + missing; %#ok<AGROW>
end
if ~isempty(first)
    results = first;
    if numel(passed) > 1
        more = arrayfun(@(p) p.method + ": " + p.reason, passed(2:end));
        results(1).reason = results(1).reason + "; also tried " + strjoin(more, "; ");
    end
    return
end
if ~isempty(firstSkip)
    results = firstSkip;
    others = unique(why(~endsWith(why, ": " + firstSkip(1).reason)), 'stable');
    if ~isempty(others)
        results(1).reason = results(1).reason + "; other methods: " + strjoin(others, "; ");
    end
    return
end
results = skipped(def, ctx, "no method available in this collection: " + strjoin(why, "; "));

end

% =====================================================================
function [ok, sig, missing] = available(m, present, ctx, cfg, S)
% Resolve every requirement slot to the first alternative present.
sig = struct();
missing = "";
col = ctx.col;
if ~isempty(m.events) && ~any(m.events == ctx.kind)
    ok = false;
    missing = "a " + strjoin(m.events, " or ") + " event";
    return
end
if m.nominal ~= "" && isempty(cfg.nominal.(m.nominal))
    ok = false;
    missing = "cfg.nominal." + m.nominal;
    return
end
if m.requiresCfg ~= "" && isempty(cfg.(m.requiresCfg))
    ok = false;
    missing = "cfg." + m.requiresCfg;
    return
end
if m.busModel && col.busVoltage.source == "none"
    ok = false;
    missing = "a bus-voltage source (Vdc channel, a V_DS before the first pulse, or cfg.nominal.busVoltage)";
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

function prefs = expandPreset(prefs, def, cfg, S)
% Replace "preset" by the registry's method for the active standard,
% followed by every other registry method as a fallback (capability
% driven: attempt whatever the collection supports). "custom" and
% "nominal" need user input, so they are used only when listed.
k = find(prefs == "preset");
if isempty(k)
    return
end
preset = presetName(cfg, S);
ids = [def.methods.id];
fallback = ids(~ismember(ids, ["custom", "nominal"]));
if preset ~= "none" && isfield(def.presets, erase(preset, "-"))
    first = def.presets.(erase(preset, "-"));
else
    first = fallback(1);
end
prefs = unique([prefs(1:k-1), first, fallback, prefs(k+1:end)], 'stable');
end

function p = presetName(cfg, S)
p = S.measurements.preset;
if p == "auto"
    if cfg.deviceType == "IGBT"
        p = "IEC-9";
    else
        p = "IEC-8";
    end
end
end

function r = skipped(def, ctx, reason)
r = makeResult(def, [], ctx);
r.status = "skipped";
r.reason = string(reason);
end
