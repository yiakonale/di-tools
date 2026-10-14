function cfg = validateBucketConfig(cfg, S, baseDir)
%VALIDATEBUCKETCONFIG Validate and normalize the bucket configuration.
%
%   cfg = validateBucketConfig(cfg, S, baseDir) checks the bucket
%   configuration defined in dpt_analyzer.m (DATA_CONTRACTS.md section 1)
%   and returns it normalized:
%     - text fields become string scalars;
%     - a relative bucketPath is resolved against BASEDIR (the script's
%       folder), never against the current folder.
%
%   Unknown fields are errors, so a misspelled setting is not ignored.
%   Optional fields that are absent are filled with their defaults:
%     cfg.nominal.busVoltage / .testCurrent  [] ([Custom] references)
%     cfg.currentNormalization.enable        false
%     cfg.currentNormalization.reference     "Iout" ("Iout" | "Id")
%     cfg.circuit.Cdc                        [] (DC-link capacitance [F])
%     cfg.circuit.CdcTolerance               0.2 (its tolerance, fraction)
%     cfg.zeroOffsetCorrection.enable        false

arguments
    cfg (1,1) struct
    S (1,1) struct
    baseDir (1,1) string
end

checkFields(cfg, ["bucketPath", "activeDevice", "deviceType", "expectedPulseCount", "gate"], ...
    "cfg", ["nominal", "currentNormalization", "circuit", "zeroOffsetCorrection"]);
checkFields(cfg.gate, "nominal", "cfg.gate");
checkFields(cfg.gate.nominal, ["high", "low"], "cfg.gate.nominal");

% Bucket path
bucketPath = textScalar(cfg.bucketPath, "cfg.bucketPath");
if ~isAbsolutePath(bucketPath)
    bucketPath = fullfile(baseDir, bucketPath);
end
if ~isfolder(bucketPath)
    error('dpt:config:bucketNotFound', ...
        'Bucket folder not found: %s', bucketPath);
end
cfg.bucketPath = bucketPath;

% Active device
cfg.activeDevice = textScalar(cfg.activeDevice, "cfg.activeDevice");
if ~any(cfg.activeDevice == ["HS", "LS"])
    error('dpt:config:invalidValue', ...
        'cfg.activeDevice must be "HS" or "LS", not "%s".', cfg.activeDevice);
end

% Device type: selects device-specific measurements and flags methods
% from a standard for the other device type.
cfg.deviceType = textScalar(cfg.deviceType, "cfg.deviceType");
if ~any(cfg.deviceType == ["MOSFET", "IGBT"])
    error('dpt:config:invalidValue', ...
        'cfg.deviceType must be "MOSFET" or "IGBT", not "%s".', cfg.deviceType);
end

% Expected pulse count (advisory)
n = cfg.expectedPulseCount;
if ~isempty(n) && ~(isnumeric(n) && isscalar(n) && isreal(n) && isfinite(n) ...
        && n >= 1 && n == round(n))
    error('dpt:config:invalidValue', ...
        'cfg.expectedPulseCount must be [] or a positive integer.');
end
cfg.expectedPulseCount = double(n);

% Nominal gate levels
hi = cfg.gate.nominal.high;
lo = cfg.gate.nominal.low;
for v = {hi, lo}
    if ~(isnumeric(v{1}) && isscalar(v{1}) && isreal(v{1}) && isfinite(v{1}))
        error('dpt:config:invalidValue', ...
            'cfg.gate.nominal.high and .low must be finite real scalars [V].');
    end
end
if hi <= lo
    error('dpt:config:invalidValue', ...
        'cfg.gate.nominal.high (%g V) must be greater than .low (%g V).', hi, lo);
end
halfSwing = (hi - lo) / 2;
if S.gate.levels.tolerance >= halfSwing
    error('dpt:config:invalidValue', ...
        ['S.gate.levels.tolerance (%g V) must be smaller than half the ' ...
         'nominal gate swing (%g V), or the two levels cannot be distinguished.'], ...
        S.gate.levels.tolerance, halfSwing);
end
cfg.gate.nominal.high = double(hi);
cfg.gate.nominal.low  = double(lo);

% Nominal operating point (optional; used only by "nominal" methods)
if ~isfield(cfg, 'nominal')
    cfg.nominal = struct();
end
checkFields(cfg.nominal, strings(1, 0), "cfg.nominal", ["busVoltage", "testCurrent"]);
for f = ["busVoltage", "testCurrent"]
    if ~isfield(cfg.nominal, f)
        cfg.nominal.(f) = [];
    end
    v = cfg.nominal.(f);
    if ~isempty(v) && ~(isnumeric(v) && isscalar(v) && isreal(v) && isfinite(v) && v > 0)
        error('dpt:config:invalidValue', 'cfg.nominal.%s must be [] or a positive scalar.', f);
    end
    cfg.nominal.(f) = double(v);
end

% Current-sensor normalization (optional, opt-in)
if ~isfield(cfg, 'currentNormalization')
    cfg.currentNormalization = struct();
end
checkFields(cfg.currentNormalization, strings(1, 0), "cfg.currentNormalization", ...
    ["enable", "reference"]);
if ~isfield(cfg.currentNormalization, 'enable')
    cfg.currentNormalization.enable = false;
end
if ~isfield(cfg.currentNormalization, 'reference')
    cfg.currentNormalization.reference = "Iout";
end
if ~(islogical(cfg.currentNormalization.enable) && isscalar(cfg.currentNormalization.enable))
    error('dpt:config:invalidValue', 'cfg.currentNormalization.enable must be true or false.');
end
cfg.currentNormalization.reference = textScalar(cfg.currentNormalization.reference, ...
    "cfg.currentNormalization.reference");
if ~any(cfg.currentNormalization.reference == ["Iout", "Id"])
    error('dpt:config:invalidValue', ...
        'cfg.currentNormalization.reference must be "Iout" or "Id".');
end

% DC link (optional): capacitance and its tolerance, for the
% charge-droop bus-voltage model (MEASUREMENT_DESIGN.md section 12)
if ~isfield(cfg, 'circuit')
    cfg.circuit = struct();
end
checkFields(cfg.circuit, strings(1, 0), "cfg.circuit", ["Cdc", "CdcTolerance"]);
if ~isfield(cfg.circuit, 'Cdc')
    cfg.circuit.Cdc = [];
end
if ~isfield(cfg.circuit, 'CdcTolerance')
    cfg.circuit.CdcTolerance = 0.2;
end
v = cfg.circuit.Cdc;
if ~isempty(v) && ~(isnumeric(v) && isscalar(v) && isreal(v) && isfinite(v) && v > 0)
    error('dpt:config:invalidValue', 'cfg.circuit.Cdc must be [] or a positive capacitance [F].');
end
cfg.circuit.Cdc = double(v);
v = cfg.circuit.CdcTolerance;
if ~(isnumeric(v) && isscalar(v) && isreal(v) && v >= 0 && v < 1)
    error('dpt:config:invalidValue', 'cfg.circuit.CdcTolerance must be a fraction in [0, 1).');
end
cfg.circuit.CdcTolerance = double(v);

% Zero-offset correction from the pre-pulse segment (optional, opt-in)
if ~isfield(cfg, 'zeroOffsetCorrection')
    cfg.zeroOffsetCorrection = struct();
end
checkFields(cfg.zeroOffsetCorrection, strings(1, 0), "cfg.zeroOffsetCorrection", "enable");
if ~isfield(cfg.zeroOffsetCorrection, 'enable')
    cfg.zeroOffsetCorrection.enable = false;
end
if ~(islogical(cfg.zeroOffsetCorrection.enable) && isscalar(cfg.zeroOffsetCorrection.enable))
    error('dpt:config:invalidValue', 'cfg.zeroOffsetCorrection.enable must be true or false.');
end

end

% =====================================================================
function checkFields(s, expected, name, optional)
% EXPECTED fields are required; OPTIONAL ones may be absent.
if nargin < 4
    optional = strings(1, 0);
end
if ~(isstruct(s) && isscalar(s))
    error('dpt:config:invalidValue', '%s must be a scalar struct.', name);
end
actual = string(fieldnames(s))';
unknown = setdiff(actual, [expected, optional]);
if ~isempty(unknown)
    error('dpt:config:unknownField', 'Unknown field(s) in %s: %s.', ...
        name, strjoin(unknown, ", "));
end
missing = setdiff(expected, actual);
if ~isempty(missing)
    error('dpt:config:missingField', 'Missing field(s) in %s: %s.', ...
        name, strjoin(missing, ", "));
end
end

function s = textScalar(v, name)
if ~((isstring(v) && isscalar(v)) || (ischar(v) && isrow(v)))
    error('dpt:config:invalidValue', '%s must be text.', name);
end
s = string(v);
end

function tf = isAbsolutePath(p)
% Windows drive or UNC path, or POSIX root.
tf = startsWith(p, ["/", "\"]) || ~isempty(regexp(p, '^[A-Za-z]:[\\/]', 'once'));
end
