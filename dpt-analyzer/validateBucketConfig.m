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

arguments
    cfg (1,1) struct
    S (1,1) struct
    baseDir (1,1) string
end

checkFields(cfg, ["bucketPath", "activeDevice", "expectedPulseCount", "gate"], "cfg");
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

end

% =====================================================================
function checkFields(s, expected, name)
if ~(isstruct(s) && isscalar(s))
    error('dpt:config:invalidValue', '%s must be a scalar struct.', name);
end
actual = string(fieldnames(s))';
unknown = setdiff(actual, expected);
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
