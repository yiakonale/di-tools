function [bucketC, issues] = bucketCapacitance(collections, cfg, S)
%BUCKETCAPACITANCE DC-link capacitance measured in the bucket's own data.
%
%   [bucketC, issues] = bucketCapacitance(collections, cfg, S) combines the
%   capacitance estimates of the bucket's collections whose bus voltage is
%   measured directly (busVoltageModel source "busChannel" or "kvl"),
%   where the droop is fitted against the charge drawn from the DC link.
%   All collections of a bucket share one setup, so this C applies to the
%   bucket's other collections, which have only one V_DS: in effect, a
%   collection that captures Vdc or both V_DS is the bucket's calibration
%   run. busVoltageModel then prefers it over cfg.circuit.Cdc.
%
%   Combination: inverse-variance weighted mean of the estimates (each
%   with the standard error of its droop fit). Uncertainty: 2 standard
%   errors (95 %), or the largest deviation of an individual estimate from
%   the mean if that is larger; the estimates are expected to agree, and
%   a spread beyond their errors is reported.
%
%   The estimate is "droop per charge measured with sensor X": a target
%   collection whose charge comes from the same signal cancels that
%   sensor's gain error; a different signal does not, which is reported.
%
%   Output struct (value NaN when no collection measures V_DC directly)
%     value, relUncertainty, collections (contributors), signal
%     (current signal of the estimates), description

arguments
    collections (1,:) struct
    cfg (1,1) struct
    S (1,1) struct
end

issues = dptIssue();
bucketC = struct('value', NaN, 'relUncertainty', NaN, 'collections', strings(1, 0), ...
    'signal', "", 'description', "");

bms = [collections.busVoltage];
use = ismember([bms.source], ["busChannel", "kvl"]) & ~isnan([bms.cEstimate]) & ...
    ~isnan([bms.cEstimateRelSE]);
if ~any(use)
    return
end
est = [bms(use).cEstimate];
% A noise-free droop fits exactly (SE = 0); a floor keeps the weights finite.
se = max([bms(use).cEstimateRelSE], 1e-6) .* est;
names = [collections(use).name];
signals = unique([bms(use).cEstimateSignal]);

w = 1 ./ se.^2;
value = sum(w .* est) / sum(w);
relUnc = 2 * sqrt(1 / sum(w)) / value;
spread = max(abs(est / value - 1));
if numel(est) > 1 && spread > relUnc
    issues = [issues; dptIssue("dpt:busVoltage:capacitanceSpread", "warning", "timeline", "", ...
        sprintf(['DC-link capacitance estimates disagree beyond their fit errors (%s); ' ...
        'the spread (%.2g %%) is used as the uncertainty.'], ...
        strjoin(compose("%s %.4g uF", names(:), est(:) * 1e6), ", "), 100 * spread), S)];
    relUnc = spread;
end
if numel(signals) > 1
    issues = [issues; dptIssue("dpt:busVoltage:capacitanceSignals", "warning", "timeline", "", ...
        "DC-link capacitance estimates use different current signals (" + strjoin(signals, ", ") + ...
        "); their calibration differences add to the error. Enable current normalization.", S)];
end

bucketC.value = value;
bucketC.relUncertainty = relUnc;
bucketC.collections = names;
bucketC.signal = strjoin(signals, "/");
bucketC.description = sprintf('measured in %s', strjoin(names, ", "));

msg = sprintf('DC-link capacitance measured in this bucket: %.4g uF +/- %.2g %% (%s), used for its single-V_DS collections', ...
    value * 1e6, 100 * relUnc, bucketC.description);
if ~isempty(cfg.circuit.Cdc)
    msg = sprintf('%s; cfg.circuit.Cdc = %.4g uF (%+.0f %%) is used only where no measurement exists', ...
        msg, cfg.circuit.Cdc * 1e6, 100 * (value / cfg.circuit.Cdc - 1));
end
issues = [issues; dptIssue("dpt:busVoltage:bucketCapacitance", "info", "timeline", "", ...
    string(msg) + ".", S)];

end
