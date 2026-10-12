function [collections, issues] = discoverCollections(bucketPath, S)
%DISCOVERCOLLECTIONS Find the collection folders inside a bucket.
%
%   [collections, issues] = discoverCollections(bucketPath, S) returns a
%   1-by-K struct array with fields
%     name : folder name (string)
%     path : absolute folder path (string)
%   sorted by name. A collection is a direct subfolder that contains a
%   channelMap.m file. Other subfolders and loose .mat files in the
%   bucket root are skipped and reported as warnings, since they usually
%   mean a collection was set up incompletely.

arguments
    bucketPath (1,1) string
    S (1,1) struct
end

issues = dptIssue();

if ~isfolder(bucketPath)
    error('dpt:discovery:bucketNotFound', 'Bucket folder not found: %s', bucketPath);
end

listing = dir(bucketPath);
isSub = [listing.isdir] & ~startsWith({listing.name}, '.');
names = sort(string({listing(isSub).name}));

keep = false(size(names));
for k = 1:numel(names)
    keep(k) = isfile(fullfile(bucketPath, names(k), 'channelMap.m'));
    if ~keep(k)
        issues = [issues; dptIssue("dpt:discovery:noChannelMap", "warning", ...
            "discovery", "", sprintf('Folder "%s" skipped: it has no channelMap.m.', ...
            names(k)), S)]; %#ok<AGROW>
    end
end

loose = dir(fullfile(bucketPath, '*.mat'));
if ~isempty(loose)
    issues = [issues; dptIssue("dpt:discovery:looseFiles", "warning", "discovery", "", ...
        sprintf('.mat files in the bucket root are ignored (not in a collection): %s', ...
        strjoin(string({loose.name}), ", ")), S)];
end

names = names(keep);
if isempty(names)
    error('dpt:discovery:noCollections', ...
        'No collection folders (subfolders containing channelMap.m) in %s', bucketPath);
end

collections = struct('name', num2cell(names), ...
    'path', num2cell(fullfile(bucketPath, names)));

end
