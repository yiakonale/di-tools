function ctx = eventContext(col, c, ev, al, tl, edgeIds, kind, cfg)
%EVENTCONTEXT Everything a measurement needs about one event in one collection.
%
%   ctx = eventContext(col, c, ev, al, tl, edgeIds, kind, cfg)
%
%   Inputs
%     col      collection (importCollection, after normalizeCurrentSensors)
%     c        index of the collection in al.collections / tl.windows
%     ev       its gate events (detectGateTransitions)
%     al, tl   alignment and timeline
%     edgeIds  universal edge ids: one for "turnOn"/"turnOff" events; two
%              for "pulse" (turn-on, turn-off), and for "break" and "pair"
%              (turn-off of pulse k, turn-on of pulse k+1). A "pair" is the
%              same operating point switched off and on again (E_sw, P_sw);
%              a "break" is the time between them (t_break, V_F, I_F).
%     kind     "turnOn" | "turnOff" | "pulse" | "break" | "pair" | "capture"
%              ("capture": the whole record, edgeIds = [])
%     cfg      bucket configuration
%
%   Output ctx: kind, collection, c, col, ev, al, tl, cfg, offset, edgeIds,
%   pulseIndex (al and tl let a measurement open a related event, e.g. the
%   turn-on of the same pulse: relatedContext), and edges (1-by-1 or
%   1-by-2) with, per edge, in the
%   collection's CORRECTED time:
%     edgeId, kind, direction, pulseIndex
%     time              gate reference crossing
%     core              [start end] of the qualified gate edge
%     D                 core duration (scales all relative lengths)
%     window, windowValid, windowNote   Batch 4 event window
%     territory         midpoint-to-neighbour region, clipped to the record
%     smoothingSamples  local timing smoothing of this gate edge

arguments
    col (1,1) struct
    c (1,1) double
    ev (1,1) struct
    al (1,1) struct
    tl (1,1) struct
    edgeIds (1,:) double
    kind (1,1) string {mustBeMember(kind, ["turnOn", "turnOff", "pulse", "break", "pair", "capture"])}
    cfg (1,1) struct
end

ctx.kind = kind;
ctx.collection = col.name;
ctx.c = c;
ctx.col = col;
ctx.ev = ev;
ctx.al = al;
ctx.tl = tl;
ctx.cfg = cfg;
ctx.offset = al.offset(c);
ctx.edgeIds = edgeIds;
% Pulse events belong to one pulse; break events span two (k, k+1).
ctx.pulseIndex = tl.edges.pulseIndex(edgeIds)';
if kind == "pulse"
    ctx.pulseIndex = ctx.pulseIndex(1);
end

edges = cell(1, numel(edgeIds));
for k = 1:numel(edgeIds)
    j = edgeIds(k);
    row = ev.edges(al.match(j, c), :);
    w = tl.windows(tl.windows.edgeId == j & tl.windows.collection == c, :);
    e.edgeId = j;
    e.kind = tl.edges.kind(j);
    e.direction = tl.edges.direction(j);
    e.pulseIndex = tl.edges.pulseIndex(j);
    e.time = row.time;
    e.core = [row.startTime, row.endTime];
    e.D = row.endTime - row.startTime;
    e.window = [w.startTime, w.endTime] + ctx.offset;
    e.windowValid = w.valid;
    e.windowNote = w.note;
    e.territory = [w.territoryStartTime, w.territoryEndTime] + ctx.offset;
    e.smoothingSamples = row.smoothingSamples;
    edges{k} = e;
end
if isempty(edges)
    ctx.edges = struct([]);         % "capture": no edge
    ctx.pulseIndex = [];
else
    ctx.edges = [edges{:}];
end

end
