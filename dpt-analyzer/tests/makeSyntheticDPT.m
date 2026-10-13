function truth = makeSyntheticDPT(folder, opts)
%MAKESYNTHETICDPT Write a synthetic LS-active multi-pulse DPT collection.
%
%   truth = makeSyntheticDPT(folder, opts) writes one collection (channel
%   files + channelMap.m) into FOLDER and returns the ground truth used to
%   generate it. The waveforms are physically consistent, so measurement
%   results can be checked against known values:
%
%     switch state s(t)   smooth step (tanh, tauSwitch) delayed by tdOn /
%                         tdOff after each gate edge
%     I_L                 integrated: dI/dt = V_DC/L while s = 1, -V_F/L
%                         while s = 0 (inductor current is continuous)
%     Id-LS               s * I_L (no reverse recovery)
%     Vds-LS              (1 - s) * (V_DC + V_F) + s * Ron * I_L
%     Vds-HS              s * (V_DC - Ron * I_L) - (1 - s) * V_F
%     Vdc                 V_DC(t) = vdc + vdcSlope * t   (bus droop)
%     Vds-LS-clamp        min(Vds-LS, clampLevel)
%     V_F                 vf0 + vfSlope * I_L
%
%   OPTS fields (all optional): dt, span, ons, width, vdc, vdcSlope, L,
%   Ron, vf0, vfSlope, tauGate, tauSwitch, tdOn, tdOff, clampLevel,
%   channels (string array of signals to write), idGain, idOffset
%   (sensor error on Id-LS), idClip (sensor saturation), idInvert.

if nargin < 2
    opts = struct();
end
o = defaults(opts);

t = (o.span(1):o.dt:o.span(2))';
offs = o.ons + o.width;
gate = zeros(size(t));
s = zeros(size(t));
for k = 1:numel(o.ons)
    gate = gate + 0.25 * (1 + tanh((t - o.ons(k)) / o.tauGate)) .* (1 - tanh((t - offs(k)) / o.tauGate));
    s = s + 0.25 * (1 + tanh((t - o.ons(k) - o.tdOn) / o.tauSwitch)) .* ...
        (1 - tanh((t - offs(k) - o.tdOff) / o.tauSwitch));
end
vgs = -5 + 23 * gate;
vdc = o.vdc + o.vdcSlope * t;

IL = zeros(size(t));
for k = 2:numel(t)
    vf = o.vf0 + o.vfSlope * IL(k-1);
    dI = (s(k-1) * (vdc(k-1) - o.Ron * IL(k-1)) - (1 - s(k-1)) * vf * (IL(k-1) > 0)) / o.L;
    IL(k) = max(IL(k-1) + dI * o.dt, 0);
end
vf = (o.vf0 + o.vfSlope * IL) .* (IL > 0);
id = s .* IL;
vdsLS = (1 - s) .* (vdc + vf) + s .* o.Ron .* IL;
vdsHS = s .* (vdc - o.Ron * IL) - (1 - s) .* vf;

idSensor = o.idGain * id + o.idOffset;
if ~isempty(o.idClip)
    idSensor = min(idSensor, o.idClip);
end
if o.idInvert
    idSensor = -idSensor;
end

signals = struct('name', {"Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vdc", "Vds-HS", "Vds-LS-clamp"}, ...
    'data', {vgs, vdsLS, idSensor, IL, vdc, vdsHS, min(vdsLS, o.clampLevel)}, ...
    'units', {'V', 'V', 'A', 'A', 'V', 'V', 'V'});
if ~isfolder(folder)
    mkdir(folder);
end
lines = "function map = channelMap()";
k = 0;
for sg = signals
    if ~any(o.channels == sg.name)
        continue
    end
    k = k + 1;
    ch = sprintf('CH%d', k);
    v.data = sg.data;
    v.time = t;
    v.sampleInterval = o.dt;
    v.recordLength = numel(t);
    v.verticalUnits = sg.units;
    v.horizontalUnits = 's';
    v.waveformSource = ch;
    save(fullfile(folder, [ch '.mat']), '-struct', 'v');
    lines(end+1) = sprintf('map.channels.%s = "%s";', ch, sg.name); %#ok<AGROW>
end
lines(end+1) = "end";
writelines(lines, fullfile(folder, 'channelMap.m'));

truth = o;
truth.t = t;
truth.offs = offs;
truth.IL = IL;
truth.id = id;
truth.vdc = vdc;
truth.vf = vf;
truth.vdsLS = vdsLS;
truth.vdsHS = vdsHS;
truth.s = s;
% Gate instants (swing basis): tanh crossing of 10 % / 90 %.
truth.g10 = o.ons - o.tauGate * atanh(0.8);
truth.g90 = offs - o.tauGate * atanh(0.8);

end

% =====================================================================
function o = defaults(o)
d.dt = 1e-9;
d.span = [-2e-6, 32e-6];
d.ons = [0, 10e-6, 20e-6];
d.width = 6e-6;
d.vdc = 400;
d.vdcSlope = -0.2e6;          % -0.2 V/us bus droop
d.L = 40e-6;                  % 10 A/us ramp at 400 V
d.Ron = 2e-3;
d.vf0 = 1.5;
d.vfSlope = 4e-3;
d.tauGate = 20e-9;
d.tauSwitch = 5e-9;
d.tdOn = 30e-9;
d.tdOff = 60e-9;
d.clampLevel = 10;
d.channels = ["Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vdc", "Vds-HS", "Vds-LS-clamp"];
d.idGain = 1;
d.idOffset = 0;
d.idClip = [];
d.idInvert = false;
for f = string(fieldnames(d))'
    if ~isfield(o, f)
        o.(f) = d.(f);
    end
end
end
