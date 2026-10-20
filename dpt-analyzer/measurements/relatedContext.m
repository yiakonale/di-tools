function sub = relatedContext(ctx, edgeIds, kind)
%RELATEDCONTEXT Event context of another event in the same collection.
%
%   sub = relatedContext(ctx, edgeIds, kind) opens the event KIND on the
%   universal edges EDGEIDS of ctx's collection, e.g. the turn-on of the
%   same pulse for a measurement made at its turn-off (#55 takes L_loop
%   from the turn-on dip, design 18).

arguments
    ctx (1,1) struct
    edgeIds (1,:) double
    kind (1,1) string
end

sub = eventContext(ctx.col, ctx.c, ctx.ev, ctx.al, ctx.tl, edgeIds, kind, ctx.cfg);

end
