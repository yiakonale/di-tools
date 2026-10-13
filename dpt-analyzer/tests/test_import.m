function test_import(root)
%TEST_IMPORT Informal import and validation cases (formalized in Batch 7).
%   test_import() builds synthetic collections in a temporary folder,
%   runs every import/validation path, and prints pass/fail per case.
%   test_import(root) uses ROOT as the scratch folder (deleted first).

if nargin < 1
    root = fullfile(tempdir, 'dpt_test_import');
end
addpath(fileparts(fileparts(mfilename('fullpath'))));
S = dptSettings(struct('report', struct('echoWarnings', false)));
cfg = struct('bucketPath', "", 'activeDevice', "LS", 'deviceType', "MOSFET", 'expectedPulseCount', [], ...
    'gate', struct('nominal', struct('high', 18, 'low', -5)));
if isfolder(root), rmdir(root, 's'); end
mkdir(root);
N = 1000; dt = 1.6e-10; t = ((0:N-1)' - 400) * dt;
nPass = 0; nFail = 0;

    function writeCh(folder, file, src, units, x, varargin)
        v.data = x; v.time = t; v.sampleInterval = dt; v.recordLength = N; v.zeroIndex = 400;
        v.verticalUnits = units; v.horizontalUnits = 's'; v.waveformSource = src; v.model = 'SYN';
        for q = 1:2:numel(varargin), v.(varargin{q}) = varargin{q+1}; end
        save(fullfile(folder, file), '-struct', 'v');
    end
    function folder = makeCol(name, mapBody)
        folder = fullfile(root, name); mkdir(folder);
        fid = fopen(fullfile(folder, 'channelMap.m'), 'w');
        fprintf(fid, 'function map = channelMap()\n%s\nend\n', mapBody); fclose(fid);
        writeCh(folder, 'CH1.mat', 'CH1', 'V', sin((1:N)'/50) * 10);
        writeCh(folder, 'CH2.mat', 'CH2', 'V', (1:N)');
        writeCh(folder, 'CH3.mat', 'CH3', 'A', (1:N)' * 2);
    end
    function expectError(id, f, label)
        try
            f(); fprintf('FAIL  %-32s no error (expected %s)\n', label, id); nFail = nFail + 1;
        catch ME
            if strcmp(ME.identifier, id)
                fprintf('pass  %-32s %s\n', label, ME.message); nPass = nPass + 1;
            else
                fprintf('FAIL  %-32s got %s: %s\n', label, ME.identifier, ME.message); nFail = nFail + 1;
            end
        end
    end
    function check(cond, label)
        if cond, fprintf('pass  %s\n', label); nPass = nPass + 1;
        else, fprintf('FAIL  %s\n', label); nFail = nFail + 1; end
    end

base = 'map.channels.CH1 = "Vgs-LS"; map.channels.CH2 = "Vds-LS"; map.channels.CH3 = "Id-LS";';

% 1. Happy path: short form, plus a struct-layout file in long form
f = makeCol('ok', [base ' map.channels.CH4.signal = "Iout"; map.channels.CH4.file = "out.mat";']);
rec = struct('data', (1:N)', 'time', t, 'sampleInterval', dt, 'verticalUnits', 'A', 'waveformSource', 'CH4');
save(fullfile(f, 'out.mat'), 'rec');
writeCh(f, 'extra.mat', 'CH9', 'V', zeros(N,1));
col = importCollection(f, cfg, S);
check(numel(col.channels) == 4 && col.channels(4).layout == "struct", 'happy path, struct layout');
check(isequal(col.unmappedFiles, "extra.mat") && col.issues(1).id == "dpt:import:unmappedFiles", 'unmapped file reported');
check(~isfield(col.channels, 'time') && numel(col.time) == N, 'single shared time vector');

% 2-11. Collection errors
expectError('dpt:import:missingActiveGate', @() importCollection(makeCol('nogate', ...
    'map.channels.CH2 = "Vds-LS";'), cfg, S), 'missing active gate');
f = makeCol('units', base); writeCh(f, 'CH3.mat', 'CH3', 'V', (1:N)');
expectError('dpt:import:unitMismatch', @() importCollection(f, cfg, S), 'unit mismatch');
f = makeCol('dt', base); writeCh(f, 'CH2.mat', 'CH2', 'V', (1:N)', 'sampleInterval', 2*dt, 'time', t*2);
expectError('dpt:import:sampleIntervalMismatch', @() importCollection(f, cfg, S), 'dt mismatch');
f = makeCol('tshift', base); writeCh(f, 'CH2.mat', 'CH2', 'V', (1:N)', 'time', t + dt);
expectError('dpt:import:timeVectorMismatch', @() importCollection(f, cfg, S), 'time vector mismatch');
expectError('dpt:map:unknownField', @() importCollection(makeCol('unk', ...
    [base ' map.channels.CH1 = struct("signal", "Vgs-LS", "sgnal", 1);']), cfg, S), 'unknown map field');
expectError('dpt:map:duplicateSignal', @() importCollection(makeCol('dup', ...
    [base ' map.channels.CH3 = "Vds-LS";']), cfg, S), 'duplicate signal');
expectError('dpt:map:unknownSignal', @() importCollection(makeCol('badsig', ...
    'map.channels.CH1 = "Vgs-LS"; map.channels.CH2 = "Vce-LS";'), cfg, S), 'unknown signal');
f = makeCol('src', base); writeCh(f, 'CH2.mat', 'CH5', 'V', (1:N)');
expectError('dpt:import:sourceMismatch', @() importCollection(f, cfg, S), 'source mismatch');
expectError('dpt:import:missingFile', @() importCollection(makeCol('nofile', ...
    [base ' map.channels.CH6 = "Iout";']), cfg, S), 'missing file');
f = makeCol('nan', base); x = (1:N)'; x(5) = NaN; writeCh(f, 'CH2.mat', 'CH2', 'V', x);
expectError('dpt:import:invalidData', @() importCollection(f, cfg, S), 'NaN in data');
f = makeCol('nonuni', base); tt = t; tt(500:end) = tt(500:end) + dt/2; writeCh(f, 'CH2.mat', 'CH2', 'V', (1:N)', 'time', tt);
expectError('dpt:import:nonUniformTime', @() importCollection(f, cfg, S), 'non-uniform time');
f = makeCol('rl', base); writeCh(f, 'CH2.mat', 'CH2', 'V', (1:N)', 'recordLength', N+1);
expectError('dpt:import:recordLengthMismatch', @() importCollection(f, cfg, S), 'recordLength metadata');
expectError('dpt:map:evaluationFailed', @() importCollection(makeCol('maperr', ...
    'error("boom");'), cfg, S), 'channelMap throws');

% 12. Deskew: integer shift, non-integer rounding, error policy
f = makeCol('deskew', [base ' map.channels.CH2 = struct("signal","Vds-LS","deskew",3*1.6e-10); ' ...
    'map.channels.CH3 = struct("signal","Id-LS","deskew",-2.4e-10,"invert",true);']);
col = importCollection(f, cfg, S);
c2 = col.channels(2).corrections; c3 = col.channels(3).corrections;
ids = [col.issues.id]; msgs = [col.issues.message];
check(c2.shift == 3 && ~any(ids == "dpt:import:deskewRounded" & contains(msgs, "CH2")), 'integer deskew, no rounding issue');
check(abs(c3.shift) == 2 || abs(c3.shift) == 1, sprintf('-1.5 samples rounded to %d', c3.shift));
check(any(ids == "dpt:import:deskewRounded"), 'rounding reported');
check(sum(ids == "dpt:import:correctionApplied") == 2, 'corrections reported');
Se = dptSettings(struct('corrections', struct('nonIntegerDeskew', "error"), 'report', struct('echoWarnings', false)));
expectError('dpt:import:nonIntegerDeskew', @() importCollection(f, cfg, Se), 'non-integer deskew policy=error');

% 13. getSignal grid alignment and corrections
r = [t(100) t(200)];
v = getSignal(col, "Vds-LS", r, S); i = getSignal(col, "Id-LS", r, S); g = getSignal(col, "Vgs-LS", r, S);
check(numel(v.x) == numel(i.x) && numel(v.x) == numel(g.x) && numel(g.x) == 101, 'same sample count across deskewed channels');
check(max(abs(v.t - g.t)) < 1e-6*dt && max(abs(i.t - g.t)) < 1e-6*dt, 'shared corrected time grid');
check(isequal(v.index, (97:197)') && v.x(1) == 97, 'Vds +3 samples -> raw index shifted by -3');
check(all(i.x == -2*i.index), 'Id inverted on read');
check(col.channels(3).data(10) == 20, 'raw data untouched');
e = getSignal(col, "Vds-LS", [t(1) t(50)], S);
check(~e.complete && e.index(1) == 1, 'range beyond corrected record -> complete=false');
check(getSignal(col, "Vgs-LS", [], S).complete, 'full record complete');
expectError('dpt:signal:notFound', @() getSignal(col, "Iout", [], S), 'unknown signal in getSignal');

% 14. Map caching across collections in one bucket + discovery
bucket = fullfile(root, 'bucket'); mkdir(bucket);
movefile(fullfile(root, 'ok'), fullfile(bucket, 'collection_A'));
fB = fullfile(bucket, 'collection_B'); mkdir(fB);
fid = fopen(fullfile(fB, 'channelMap.m'), 'w'); fprintf(fid, 'function map = channelMap()\nmap.channels.CH1 = "Vgs-LS";\nend\n'); fclose(fid);
writeCh(fB, 'CH1.mat', 'CH1', 'V', zeros(N,1));
mkdir(fullfile(bucket, 'notes'));
[found, iss] = discoverCollections(bucket, S);
check(isequal([found.name], ["collection_A", "collection_B"]) && any([iss.id] == "dpt:discovery:noChannelMap"), 'discovery + skipped folder warning');
A = importCollection(found(1).path, cfg, S); B = importCollection(found(2).path, cfg, S); A2 = importCollection(found(1).path, cfg, S);
check(numel(A.channels) == 4 && numel(B.channels) == 1 && numel(A2.channels) == 4, 'no channelMap cache bleed between collections');
try
    importCollection(fullfile(root, 'units'), cfg, S); msg = "";
catch ME
    msg = string(ME.message);
end
check(startsWith(msg, 'Collection "units"'), 'error names the collection');
mkdir(fullfile(root, 'empty'));
expectError('dpt:discovery:noCollections', @() discoverCollections(fullfile(root, 'empty'), S), 'empty bucket');

% 15. Bucket config
c = cfg; c.bucketPath = "bucket"; cOut = validateBucketConfig(c, S, root);
check(isfolder(cOut.bucketPath), 'relative bucketPath resolved against base dir');
c = cfg; c.bucketPath = bucket; c.extra = 1;
expectError('dpt:config:unknownField', @() validateBucketConfig(c, S, root), 'unknown cfg field');
c = cfg; c.bucketPath = bucket; c.gate.nominal.high = 1; c.gate.nominal.low = 0;
expectError('dpt:config:invalidValue', @() validateBucketConfig(c, S, root), 'tolerance >= half swing');
c = cfg; c.bucketPath = bucket; c.activeDevice = "MS";
expectError('dpt:config:invalidValue', @() validateBucketConfig(c, S, root), 'bad active device');
c = cfg; c.bucketPath = "nope";
expectError('dpt:config:bucketNotFound', @() validateBucketConfig(c, S, root), 'missing bucket');

fprintf('\n%d passed, %d failed\n', nPass, nFail);
end
