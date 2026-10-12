function test_settings()
%TEST_SETTINGS Informal dptSettings validation cases (formalized in Batch 7).

addpath(fileparts(fileparts(mfilename('fullpath'))));
S = dptSettings(); fprintf('defaults OK, schema %s\n', S.schemaVersion);
ov = struct(); ov.gate.levels.tolerance = 0.5; ov.detection.reference.fraction = 0.3;
S2 = dptSettings(ov); assert(S2.gate.levels.tolerance == 0.5 && S2.gate.activeLevel == "high" && S2.detection.reference.fraction == 0.3); fprintf('override merge OK\n');
cases = {
  'typo',           struct('gate', struct('nominal', struct('hgih', 1)))
  'group as value', struct('gate', 5)
  'fraction out',   struct('detection', struct('reference', struct('fraction', 0.1)))
  'bad option',     struct('detection', struct('reference', struct('strategy', "slope")))
  'cond no window', struct('conditioning', struct('method', "movmean"))
  'abs missing',    struct('detection', struct('reference', struct('strategy', "absolute")))
  'bad window',     struct('windows', struct('fixed', struct('turnOn', [100e-9 200e-9])))
  'not struct',     5
};
for k = 1:size(cases,1)
  try, dptSettings(cases{k,2}); fprintf('FAIL (no error): %s\n', cases{k,1});
  catch e, fprintf('%-15s -> %s: %s\n', cases{k,1}, e.identifier, e.message); end
end
ok = struct('detection', struct('reference', struct('strategy', "absolute", 'absolute', 3)));
dptSettings(ok); fprintf('absolute OK\n');
ok = struct('conditioning', struct('method', 'movmedian', 'windowDuration', 2e-9)); dptSettings(ok); fprintf('char option + movmedian OK\n');
ok = struct('measurements', struct('swEnergy', struct('x', 1))); S3 = dptSettings(ok); assert(S3.measurements.swEnergy.x == 1); fprintf('open measurements group OK\n');
disp(S.signals.catalog); fprintf('tolerance %.2f V\n', S.gate.levels.tolerance);
bad = S.signals.catalog; bad.name(2) = "Vgs-HS";
try, dptSettings(struct('signals', struct('catalog', bad))); fprintf('FAIL dup\n'); catch e, fprintf('dup name -> %s\n', e.message); end
try, dptSettings(struct('gate', struct('nominal', struct('high', 18)))); fprintf('FAIL nominal\n'); catch e, fprintf('nominal removed -> %s\n', e.message); end

end
