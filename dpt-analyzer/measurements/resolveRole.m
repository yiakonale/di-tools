function name = resolveRole(role, cfg, S)
%RESOLVEROLE Canonical signal name for a measurement role.
%
%   name = resolveRole(role, cfg, S) maps a role to the catalog name of
%   the signal that plays it in this bucket (MEASUREMENT_DESIGN.md 2.2):
%
%     "<quantity>"            device-independent, e.g. "outputCurrent",
%                             "busVoltage"
%     "<quantity>@active"     the active device's signal, e.g.
%                             "drainVoltage@active" -> "Vds-LS" when the
%                             LS device is active
%     "<quantity>@nonActive"  the complementary device's signal
%
%   Requirements are written as roles, so one registry entry serves both
%   HS-active and LS-active buckets.

arguments
    role (1,1) string
    cfg (1,1) struct
    S (1,1) struct
end

parts = split(role, "@");
quantity = parts(1);
if isscalar(parts)
    device = "";
else
    switch parts(2)
        case "active"
            device = cfg.activeDevice;
        case "nonActive"
            device = setdiff(["HS", "LS"], cfg.activeDevice);
        otherwise
            error('resolveRole:invalidRole', ...
                'Role "%s": the device part must be "active" or "nonActive".', role);
    end
end

C = S.signals.catalog;
hit = C.name(C.quantity == quantity & C.device == device);
if numel(hit) ~= 1
    error('resolveRole:unknownRole', 'Role "%s" matches no catalog signal.', role);
end
name = hit;

end
