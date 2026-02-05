function S = dptSettings()
%DPTSETTINGS Global analyzer configuration for DPT waveform analysis
%
% This file defines analyzer-wide behavior that should rarely change.
% It contains NO experiment-specific configuration.

%% ------------------------
% Gate drive levels
%% ------------------------

S.Vgs.high = +20;      % [V]
S.Vgs.low  = -5;       % [V]
S.Vgs.tol  = 0.5;      % [V] tolerance for level detection

%% ------------------------
% Gate transition detection
%% ------------------------

S.transition.minSlope = 5e7;      % [V/s] reject slow/noisy edges
S.transition.minSeparation = 200e-9;  % [s] minimum pulse spacing
S.transition.edgeOrder = ["rising", "falling"];

%% ------------------------
% Pulse capture windows
%% ------------------------

% Default windows relative to detected transition
S.windows.turnOn  = [-200e-9, +600e-9];   % [s]
S.windows.turnOff = [-400e-9, +800e-9];   % [s]

% Allow override via settings only (not main)
S.windows.allowOverride = true;

%% ------------------------
% Energy calculation behavior
%% ------------------------

S.energy.includeReverseRecovery = true;
S.energy.currentSignConvention  = "positive_into_device";

%% ------------------------
% Sampling & alignment checks
%% ------------------------

S.sampling.requireCommonDt = true;
S.sampling.dtTolerance     = 1e-12;

%% ------------------------
% Pulse expectations (advisory only)
%% ------------------------

S.pulseExpectation.warnOnly = true;

%% ------------------------
% Reporting & verbosity
%% ------------------------

S.report.showSkippedMeasurements = true;
S.report.showWarnings            = true;
S.report.units                   = "SI";

end