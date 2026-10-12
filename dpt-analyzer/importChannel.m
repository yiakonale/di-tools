function ch = importChannel(filePath, S)
%IMPORTCHANNEL Load and validate one exported oscilloscope channel.
%
%   ch = importChannel(filePath, S) loads a channel .mat file and returns
%   the channel struct of DATA_CONTRACTS.md section 3:
%
%     file            absolute path (string)
%     layout          "flat" | "struct"
%     data            N-by-1 double, raw samples [units]
%     time            N-by-1 double, raw scope time [s]
%     sampleInterval  [s]
%     recordLength    N
%     units           vertical units (string)
%     source          waveformSource, or "" if not recorded
%     zeroIndex       as recorded (0-based on Tek exports), or []
%     meta            every recorded variable except data and time
%
%   Accepted layouts:
%     "flat"  : separate top-level variables (Tektronix MSO5/6 export)
%     "struct": exactly one top-level scalar struct holding the fields
%
%   Required variables: data, time, sampleInterval, verticalUnits.
%   Samples are never modified; row vectors become columns and other
%   numeric classes become double, both lossless.

arguments
    filePath (1,1) string
    S (1,1) struct
end

if ~isfile(filePath)
    error('dpt:import:fileNotFound', 'Channel file not found: %s', filePath);
end
info = dir(filePath);
file = string(fullfile(info.folder, info.name));

try
    vars = load(file);
catch ME
    error('dpt:import:loadFailed', 'Could not load %s: %s', file, ME.message);
end
if ~isstruct(vars)
    error('dpt:import:unrecognizedLayout', '%s is not a MAT-file.', file);
end

% Layout
names = fieldnames(vars);
if isfield(vars, 'data')
    layout = "flat";
    rec = vars;
elseif isscalar(names) && isstruct(vars.(names{1})) && isscalar(vars.(names{1})) ...
        && isfield(vars.(names{1}), 'data')
    layout = "struct";
    rec = vars.(names{1});
else
    error('dpt:import:unrecognizedLayout', ...
        ['%s: expected a "data" variable, or a single struct containing ' ...
         'one. Found variables: %s.'], file, strjoin(names, ', '));
end

required = {'data', 'time', 'sampleInterval', 'verticalUnits'};
missing = required(~isfield(rec, required));
if ~isempty(missing)
    error('dpt:import:missingVariable', '%s: missing required variable(s): %s.', ...
        file, strjoin(missing, ', '));
end

% Samples
x = rec.data;
if ~(isnumeric(x) && isreal(x) && isvector(x) && numel(x) >= 2)
    error('dpt:import:invalidData', ...
        '%s: data must be a real numeric vector with at least 2 samples.', file);
end
x = double(x(:));
nBad = nnz(~isfinite(x));
if nBad > 0
    error('dpt:import:invalidData', '%s: data contains %d non-finite sample(s).', ...
        file, nBad);
end
N = numel(x);

% Time vector
t = rec.time;
if ~(isnumeric(t) && isreal(t) && isvector(t) && numel(t) == N)
    error('dpt:import:invalidTime', ...
        '%s: time must be a real numeric vector with the same length as data (%d).', ...
        file, N);
end
t = double(t(:));
if ~all(isfinite(t))
    error('dpt:import:invalidTime', '%s: time contains non-finite values.', file);
end

dt = rec.sampleInterval;
if ~(isnumeric(dt) && isscalar(dt) && isreal(dt) && isfinite(dt) && dt > 0)
    error('dpt:import:invalidSampleInterval', ...
        '%s: sampleInterval must be a positive finite scalar.', file);
end
dt = double(dt);

d = diff(t);
if any(d <= 0)
    error('dpt:import:invalidTime', '%s: time is not strictly increasing.', file);
end
deviation = max(abs(d - dt)) / dt;
if deviation > S.sampling.timeVectorRelTol
    error('dpt:import:nonUniformTime', ...
        ['%s: time steps deviate from sampleInterval by up to %.3g (relative), ' ...
         'above S.sampling.timeVectorRelTol = %.3g.'], ...
        file, deviation, S.sampling.timeVectorRelTol);
end

% Metadata
if isfield(rec, 'recordLength')
    n = rec.recordLength;
    if ~(isnumeric(n) && isscalar(n) && double(n) == N)
        error('dpt:import:recordLengthMismatch', ...
            '%s: recordLength does not match the %d samples in data.', file, N);
    end
end

if isfield(rec, 'horizontalUnits')
    hu = textValue(rec.horizontalUnits, 'horizontalUnits', file);
    if hu ~= "s"
        error('dpt:import:invalidUnits', ...
            '%s: horizontalUnits must be "s", not "%s".', file, hu);
    end
end

units = textValue(rec.verticalUnits, 'verticalUnits', file);

source = "";
if isfield(rec, 'waveformSource')
    source = textValue(rec.waveformSource, 'waveformSource', file);
end

zeroIndex = [];
if isfield(rec, 'zeroIndex')
    z = rec.zeroIndex;
    if ~(isnumeric(z) && isscalar(z) && isreal(z) && isfinite(z))
        error('dpt:import:invalidMetadata', '%s: zeroIndex must be a finite scalar.', file);
    end
    zeroIndex = double(z);
end

ch.file = file;
ch.layout = layout;
ch.data = x;
ch.time = t;
ch.sampleInterval = dt;
ch.recordLength = N;
ch.units = units;
ch.source = source;
ch.zeroIndex = zeroIndex;
ch.meta = rmfield(rec, {'data', 'time'});

end

% =====================================================================
function s = textValue(v, name, file)
if ~((isstring(v) && isscalar(v)) || (ischar(v) && (isrow(v) || isempty(v))))
    error('dpt:import:invalidMetadata', '%s: %s must be text.', file, name);
end
s = strtrim(string(v));
end
