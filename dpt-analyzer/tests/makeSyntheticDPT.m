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
%     Id-HS               -(1 - s) * I_L (freewheel current, positive
%                         drain -> source), if listed in channels
%     Vdc                 V_DC(t) = vdc + vdcSlope * t   (bus droop), or,
%                         if opts.Cdc is set, vdc - Q(t)/Cdc with Q the
%                         charge drawn by the LS device (capacitor droop)
%     Vds-LS-clamp        min(Vds-LS, clampLevel)
%     V_F                 vf0 + vfSlope * I_L
%
%   OPTS fields (all optional): dt, span, ons, width, vdc, vdcSlope, L,
%   Ron, vf0, vfSlope, tauGate, tauSwitch, tdOn, tdOff, clampLevel, Cdc,
%   channels (string array of signals to write), idGain, idOffset
%   (sensor error on Id-LS), idClip (sensor saturation), idInvert,
%   ilOffset, vdsHSOffset (probe zero offsets of Iout and Vds-HS),
%   deadTime (of the complementary HS gate, written when "Vgs-HS" is in
%   channels), vdsHSGain (probe gain error of Vds-HS), Rbus (DC-link and
%   busbar resistance: the terminal V_DC sags by Rbus * bus current),
%   ringV / ringI ([amplitude, frequency, tau]: damped sine added to Vds-LS
%   after each turn-off / to Id-LS after each turn-on switching instant),
%   vgsBump ([amplitude, sigma]: Gaussian overshoot of Vgs-LS 3 tauGate
%   after each turn-on), vgsNBump ([amplitude, sigma]: cross-talk on
%   Vgs-HS, + at each LS turn-on and - at each turn-off switching instant).

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
% Complementary HS gate (synchronous mode): on outside the LS pulses
% widened by the dead time on both sides.
hsOn = ones(size(t));
for k = 1:numel(o.ons)
    hsOn = hsOn - 0.25 * (1 + tanh((t - o.ons(k) + o.deadTime) / o.tauGate)) .* ...
        (1 - tanh((t - offs(k) - o.deadTime) / o.tauGate));
end
vgsHS = -5 + 23 * hsOn;
vdc = o.vdc + o.vdcSlope * t;

IL = zeros(size(t));
Q = 0;
% The diode conducts above 1 mA, so the femtoamp tails of the smooth
% switch model cannot switch on a full V_F before the first pulse.
iOn = 1e-3;
if ~isempty(o.Cdc)
    vdc(:) = o.vdc;                             % capacitor droop replaces the slope
end
for k = 2:numel(t)
    if ~isempty(o.Cdc)
        Q = Q + s(k-1) * IL(k-1) * o.dt;        % charge drawn from the link
        vdc(k) = o.vdc - Q / o.Cdc;
    end
    vf = o.vf0 + o.vfSlope * IL(k-1);
    dI = (s(k-1) * (vdc(k-1) - o.Ron * IL(k-1)) - (1 - s(k-1)) * vf * (IL(k-1) > iOn)) / o.L;
    IL(k) = max(IL(k-1) + dI * o.dt, 0);
end
vf = (o.vf0 + o.vfSlope * IL) .* (IL > iOn);
% Resistance of DC link and busbar: the leg's terminal voltage sags by
% Rbus times the bus current (the LS current while it conducts).
vdc = vdc - o.Rbus * s .* IL;
id = s .* IL;
vdsLS = (1 - s) .* (vdc + vf) + s .* o.Ron .* IL;
vdsHS = s .* (vdc - o.Ron * IL) - (1 - s) .* vf;

% Optional parasitic effects on the LS device (stress tests, #29-38):
% damped sines [amplitude, frequency, tau] starting at each switching
% instant, and Gaussian gate bumps [amplitude, sigma].
ringV = zeros(size(t));
ringI = zeros(size(t));
bumpG = zeros(size(t));
bumpN = zeros(size(t));
for k = 1:numel(o.ons)
    if ~isempty(o.ringV)
        ringV = ringV + damped(t, offs(k) + o.tdOff, o.ringV);
    end
    if ~isempty(o.ringI)
        ringI = ringI + damped(t, o.ons(k) + o.tdOn, o.ringI);
    end
    if ~isempty(o.vgsBump)          % active gate overshoot after the turn-on
        bumpG = bumpG + o.vgsBump(1) * exp(-0.5 * ((t - o.ons(k) - 3 * o.tauGate) / o.vgsBump(2)).^2);
    end
    if ~isempty(o.vgsNBump)         % cross-talk: + at the LS turn-on, - at the turn-off
        bumpN = bumpN + o.vgsNBump(1) * (exp(-0.5 * ((t - o.ons(k) - o.tdOn) / o.vgsNBump(2)).^2) - ...
            exp(-0.5 * ((t - offs(k) - o.tdOff) / o.vgsNBump(2)).^2));
    end
end
vdsLS = vdsLS + ringV;
id = id + ringI;
vgs = vgs + bumpG;
vgsHS = vgsHS + bumpN;

idSensor = o.idGain * id + o.idOffset;
if ~isempty(o.idClip)
    idSensor = min(idSensor, o.idClip);
end
if o.idInvert
    idSensor = -idSensor;
end

signals = struct('name', {"Vgs-LS", "Vds-LS", "Id-LS", "Iout", "Vdc", "Vds-HS", "Vds-LS-clamp", "Vgs-HS", "Id-HS"}, ...
    'data', {vgs, vdsLS, idSensor, IL + o.ilOffset, vdc, o.vdsHSGain * vdsHS + o.vdsHSOffset, min(vdsLS, o.clampLevel), vgsHS, ...
    -(1 - s) .* IL}, ...
    'units', {'V', 'V', 'A', 'A', 'V', 'V', 'V', 'V', 'A'});
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
truth.vgs = vgs;
truth.vgsHS = vgsHS;
truth.ringV = ringV;
truth.ringI = ringI;
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
d.Cdc = [];
d.ilOffset = 0;               % probe zero offset of Iout [A]
d.vdsHSOffset = 0;            % probe zero offset of Vds-HS [V]
d.deadTime = 100e-9;
d.vdsHSGain = 1;              % probe gain error of Vds-HS
d.Rbus = 0;                   % DC-link + busbar resistance [Ohm]
d.ringV = [];                 % [A f tau] V_DS ringing after each turn-off
d.ringI = [];                 % [A f tau] I_D ringing after each turn-on
d.vgsBump = [];               % [A sigma] active gate overshoot
d.vgsNBump = [];              % [A sigma] non-active gate cross-talk
for f = string(fieldnames(d))'
    if ~isfield(o, f)
        o.(f) = d.(f);
    end
end
end

function y = damped(t, t0, p)
% p = [amplitude, frequency, tau]; zero before t0.
u = max(t - t0, 0);
y = p(1) * sin(2 * pi * p(2) * u) .* exp(-u / p(3));
end
