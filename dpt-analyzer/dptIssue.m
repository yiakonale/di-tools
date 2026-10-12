function issue = dptIssue(id, severity, stage, collection, message, S)
%DPTISSUE Create an issue record (DATA_CONTRACTS.md section 0.1).
%
%   issues = dptIssue() returns an empty 0-by-1 issue array, used to
%   initialize an .issues field so later records can be appended with
%   issues = [issues; dptIssue(...)].
%
%   issue = dptIssue(id, severity, stage, collection, message, S) returns
%   one record. Issues describe conditions that leave results usable;
%   conditions that invalidate a unit of work are thrown as errors.
%
%   Echoing (records are always kept regardless):
%     "warning" -> MATLAB warning() when S.report.echoWarnings is true.
%     "info"    -> printed when S.report.verbosity is "verbose".

if nargin == 0
    issue = reshape(struct('id', {}, 'severity', {}, 'stage', {}, ...
        'collection', {}, 'message', {}), 0, 1);
    return
end

% Explicit checks: an arguments block cannot coexist with the no-input
% form above. Misuse is a programming error, so its identifiers do not
% use the "dpt:" prefix, which is reserved for problems in the data.
narginchk(6, 6);
id = string(id);
severity = string(severity);
stage = string(stage);
collection = string(collection);
message = string(message);
if ~any(severity == ["info", "warning"])
    error('dptIssue:invalidSeverity', ...
        'Issue severity must be "info" or "warning", not "%s".', severity);
end
validStages = ["discovery", "import", "detection", "alignment", "timeline", "measurement"];
if ~any(stage == validStages)
    error('dptIssue:invalidStage', 'Unknown issue stage "%s".', stage);
end

issue = struct('id', id, 'severity', severity, 'stage', stage, ...
    'collection', collection, 'message', message);

if collection == ""
    text = message;
else
    text = sprintf('[%s] %s', collection, message);
end

if severity == "warning" && S.report.echoWarnings
    % Backtrace points into analyzer internals, not at the user's data.
    previous = warning('off', 'backtrace');
    restore = onCleanup(@() warning(previous));
    warning(char(id), '%s', text);
elseif severity == "info" && S.report.verbosity == "verbose"
    fprintf('  info: %s\n', text);
end

end
