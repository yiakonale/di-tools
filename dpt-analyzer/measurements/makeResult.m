function r = makeResult(def, method, ctx)
%MAKERESULT Skeleton result for one measurement on one event.
%
%   r = makeResult(def, method, ctx) returns a result struct for registry
%   entry DEF evaluated with METHOD (or [] when no method applies) on the
%   event context CTX. The caller sets value, status, reason, flags and
%   provenance (MEASUREMENT_DESIGN.md section 8).
%
%   Fields
%     id, row, symbol, unit       from the registry
%     value                       NaN until set
%     status   "ok" | "skipped" (not attempted: data, configuration or
%              device type do not support it) | "failed" (attempted:
%              threshold not reached, window outside the record, ...)
%     reason   explanation for skipped/failed
%     methodId, methodTag         the method used; the tag is printed
%                                 next to every value
%     eventKind, edgeIds, pulseIndex, collection
%     flags    e.g. "belowNoiseFloor", "resolutionLimited"
%     provenance  struct: signals used, instants, windows, filters,
%                 normalization, ...

r.id = def.id;
r.row = def.row;
r.symbol = def.symbol;
r.unit = def.unit;
r.value = NaN;
r.status = "failed";
r.reason = "";
if isempty(method)
    r.methodId = "";
    r.methodTag = "";
else
    r.methodId = method.id;
    r.methodTag = method.tag;
end
r.eventKind = ctx.kind;
r.edgeIds = ctx.edgeIds;
r.pulseIndex = ctx.pulseIndex;
r.collection = ctx.collection;
r.flags = strings(1, 0);
r.noiseLimited = false;    % a failure caused only by the noise-floor rule (Q2)
r.provenance = struct();

end
