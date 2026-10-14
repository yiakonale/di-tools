function r = measureInterval(def, method, ctx, sig, S) %#ok<INUSD>
%MEASUREINTERVAL Time between two declared thresholds (#13-22).
%
%   r = measureInterval(def, method, ctx, sig, S) evaluates the start and
%   stop thresholds of METHOD (method.params.start/stop, see
%   resolveThreshold) and returns their time difference [s]. The stop
%   threshold is searched after the start, up to the end of its edge's
%   territory (design 12.7).
%
%   "custom" methods read their thresholds from
%   S.measurements.params.custom.(id) = struct('start', thr, 'stop', thr),
%   with thr = struct('signal', role, 'level', p, 'basis', b) and an
%   optional 'edge'; the result is skipped while that is not set.

r = makeResult(def, method, ctx);
p = method.params;

if isfield(p, 'customKey')
    c = S.measurements.params.custom.(p.customKey);
    if isempty(c)
        r.status = "skipped";
        r.reason = "no custom thresholds set (S.measurements.params.custom." + p.customKey + ")";
        return
    end
    [start, stop, why] = customSpecs(c);
    if why ~= ""
        r.reason = "S.measurements.params.custom." + p.customKey + ": " + why;
        return
    end
else
    start = p.start;
    stop = p.stop;
end

a = resolveThreshold(ctx, start, -Inf, S);
if ~a.found
    r.reason = "start: " + a.reason;
    return
end
b = resolveThreshold(ctx, stop, a.time, S);
if ~b.found
    r.reason = "stop: " + b.reason;
    return
end

r.value = b.time - a.time;
t0 = ctx.edges(1).time;
r.provenance.start = struct('time', a.time - t0, 'level', a.level, 'signal', a.signal, 'margin', a.margin);
r.provenance.stop = struct('time', b.time - t0, 'level', b.level, 'signal', b.signal, 'margin', b.margin);
r.status = "ok";

end

% =====================================================================
function [start, stop, why] = customSpecs(c)
start = [];
stop = [];
why = "";
if ~(isstruct(c) && isscalar(c) && isfield(c, 'start') && isfield(c, 'stop'))
    why = "must be struct('start', thr, 'stop', thr)";
    return
end
[start, why] = spec(c.start);
if why == ""
    [stop, why] = spec(c.stop);
end
end

function [s, why] = spec(t)
s = [];
why = "";
if ~(isstruct(t) && all(isfield(t, {'signal', 'level', 'basis'})))
    why = "a threshold needs signal, level and basis";
    return
end
if ~any(string(t.basis) == ["transition", "Vdc", "gate", "absolute"])
    why = "basis must be transition, Vdc, gate or absolute";
    return
end
edge = 1;
if isfield(t, 'edge')
    edge = t.edge;
end
s = struct('signal', string(t.signal), 'level', double(t.level), 'basis', string(t.basis), 'edge', edge);
end
