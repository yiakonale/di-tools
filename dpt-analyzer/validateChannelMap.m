function map = validateChannelMap(rawMap, S, label)
%VALIDATECHANNELMAP Validate a channel map and normalize it to long form.
%
%   map = validateChannelMap(rawMap, S) checks the struct returned by a
%   collection's channelMap.m against DATA_CONTRACTS.md section 2 and
%   returns it normalized:
%
%     map.description            string ("" if not given)
%     map.channels.<key>.signal  canonical signal name (string)
%     map.channels.<key>.file    file name, default "<key>.mat" (string)
%     map.channels.<key>.deskew  post-acquisition deskew [s], default 0
%     map.channels.<key>.invert  post-acquisition inversion, default false
%
%   Each entry may be given in short form (map.channels.CH2 = "Vgs-LS")
%   or long form (map.channels.CH2.signal = "Vgs-LS", plus optional
%   fields). Unknown fields are errors. Whether the files exist is not
%   checked here; importCollection does that.
%
%   map = validateChannelMap(rawMap, S, label) prefixes error messages
%   with LABEL (default "channel map").

arguments
    rawMap
    S (1,1) struct
    label (1,1) string = "channel map"
end

if ~(isstruct(rawMap) && isscalar(rawMap))
    fail('dpt:map:invalidMap', label, 'must return a scalar struct.');
end
rejectUnknown(rawMap, ["channels", "description"], label, "map");

% Description
if isfield(rawMap, 'description')
    description = textScalar(rawMap.description, label, "map.description");
else
    description = "";
end

% Channels
if ~isfield(rawMap, 'channels')
    fail('dpt:map:missingChannels', label, 'must define map.channels.');
end
channels = rawMap.channels;
if ~(isstruct(channels) && isscalar(channels)) || isempty(fieldnames(channels))
    fail('dpt:map:missingChannels', label, ...
        'map.channels must be a scalar struct with at least one channel.');
end

keys = string(fieldnames(channels))';
if numel(unique(upper(keys))) < numel(keys)
    fail('dpt:map:duplicateChannel', label, sprintf( ...
        'channel keys differ only in case: %s.', strjoin(keys, ", ")));
end

catalogNames = S.signals.catalog.name;
entries = struct();
signals = strings(size(keys));
files = strings(size(keys));

for k = 1:numel(keys)
    key = keys(k);
    where = "map.channels." + key;
    e = channels.(key);

    if (isstring(e) && isscalar(e)) || (ischar(e) && isrow(e))
        e = struct('signal', string(e));
    elseif ~(isstruct(e) && isscalar(e))
        fail('dpt:map:invalidEntry', label, sprintf( ...
            '%s must be a signal name or a scalar struct.', where));
    end
    rejectUnknown(e, ["signal", "file", "deskew", "invert"], label, where);

    % signal (required)
    if ~isfield(e, 'signal')
        fail('dpt:map:invalidEntry', label, sprintf('%s.signal is required.', where));
    end
    signal = textScalar(e.signal, label, where + ".signal");
    if ~any(catalogNames == signal)
        fail('dpt:map:unknownSignal', label, sprintf( ...
            '%s.signal "%s" is not a canonical signal. Valid: %s.', ...
            where, signal, strjoin(catalogNames, ", ")));
    end

    % file (optional)
    if isfield(e, 'file')
        file = textScalar(e.file, label, where + ".file");
        if contains(file, ["/", "\"])
            fail('dpt:map:invalidEntry', label, sprintf( ...
                '%s.file must be a file name inside the collection folder, not a path.', where));
        end
        if ~endsWith(lower(file), ".mat")
            fail('dpt:map:invalidEntry', label, sprintf( ...
                '%s.file must be a .mat file.', where));
        end
    else
        file = key + ".mat";
    end

    % deskew (optional) [s]
    deskew = 0;
    if isfield(e, 'deskew')
        deskew = e.deskew;
        if ~(isnumeric(deskew) && isscalar(deskew) && isreal(deskew) && isfinite(deskew))
            fail('dpt:map:invalidEntry', label, sprintf( ...
                '%s.deskew must be a finite real scalar in seconds.', where));
        end
        deskew = double(deskew);
    end

    % invert (optional)
    invert = false;
    if isfield(e, 'invert')
        invert = e.invert;
        if ~(islogical(invert) && isscalar(invert))
            fail('dpt:map:invalidEntry', label, sprintf( ...
                '%s.invert must be true or false.', where));
        end
    end

    entries.(key) = struct('signal', signal, 'file', file, ...
        'deskew', deskew, 'invert', invert);
    signals(k) = signal;
    files(k) = file;
end

dupSignals = duplicates(signals);
if ~isempty(dupSignals)
    fail('dpt:map:duplicateSignal', label, sprintf( ...
        'each signal may be mapped once per collection; repeated: %s.', ...
        strjoin(dupSignals, ", ")));
end
dupFiles = duplicates(lower(files));
if ~isempty(dupFiles)
    fail('dpt:map:duplicateFile', label, sprintf( ...
        'several channels refer to the same file: %s.', strjoin(dupFiles, ", ")));
end

map.description = description;
map.channels = entries;

end

% =====================================================================
function fail(id, label, msg)
error(id, '%s: %s', label, msg);
end

function rejectUnknown(s, allowed, label, where)
unknown = setdiff(string(fieldnames(s))', allowed);
if ~isempty(unknown)
    fail('dpt:map:unknownField', label, sprintf( ...
        'unknown field(s) in %s: %s. Allowed: %s.', where, ...
        strjoin(unknown, ", "), strjoin(allowed, ", ")));
end
end

function s = textScalar(v, label, where)
if ~((isstring(v) && isscalar(v)) || (ischar(v) && isrow(v)))
    fail('dpt:map:invalidEntry', label, sprintf('%s must be text.', where));
end
s = string(v);
end

function d = duplicates(values)
[u, ~, idx] = unique(values);
d = u(accumarray(idx(:), 1) > 1);
end
