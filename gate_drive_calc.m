addpath(genpath(pwd))
clear; clc; close all;

%% Define Parameters

load_params;
load_pwr = "FS200R12PT4"; % - powerstage
pwr = powerstage(params.(load_pwr));
load_gd = 'UCC21755';
gd = gdic(params.(load_gd));
load_pcb = 'GDBMK1'; % - gate driver ic
pcb = pcba(params.(load_pcb));
fsw = 20e3; % - switching frequency

%% Minimum gate resistor

Ltot = pcb.Lgs + pwr.Lgs();
%Ltot = 60.1*10^-9; % - in nH - total stray inductance

rmin = 2*sqrt(Ltot/pwr.Ciss);
disp("Minimum gate resistance is " + round(rmin,1) + " ohm");

if isempty(pwr.RgInt)
    disp("WARNING: NO internal resistance defined! Defaulting to 0 ohm.");
    pwr.RgInt = 0;
end
rgminH = max(rmin-pwr.RgInt-gd.RoutH, 0);
rgminL = max(rmin-pwr.RgInt-gd.RoutL, 0);
disp("Minimum ON gate resistor is " + round(rgminH,1) + " ohm");
disp("Minimum OFF gate resistor is " + round(rgminL,1) + " ohm");

%% Average power and current

Ron = 1;
Roff = 1;

Vdrv = pcb.VgH-pcb.VgL;
Qg = pwr.Qg*Vdrv/(pwr.VgeH-pwr.VgeL); % - gate charge estimation

Epos = Qg * pcb.VgH;
Eneg = abs(Qg * pcb.VgL);
Eg = Epos + Eneg;
%Eg = Qg*Vdrv;

Ppos = Epos*fsw;
Pneg = Eneg*fsw;
Pavg = Ppos + Pneg;
%Pavg = Eg*fsw;

Iavg = Qg*fsw;
disp("Gate driver average current is " + round(Iavg*1e3,1) + " mA");

PdrvOn = Ppos*gd.RoutH/(gd.RoutH+Ron+pwr.RgInt);
PdrvOff = Pneg*gd.RoutL/(gd.RoutL+Roff+pwr.RgInt);
Pdrv = PdrvOn + PdrvOff;
Pq = gd.Iq*Vdrv;
Ptot = Pdrv + Pq;
disp("Gate driver average power dissipation is " + round(Ptot,2) + " W");

PrOn = Ppos*Ron/(gd.RoutH+Ron+pwr.RgInt);
PrOff = Pneg*Roff/(gd.RoutL+Roff+pwr.RgInt);
disp("Gate ON resistor average power dissipation is " + round(PrOn,2) + " W");
disp("Gate OFF resistor average power dissipation is " + round(PrOff,2) + " W");

%% Peak power and current

IpkOn = Vdrv/(gd.RoutH+Ron+pwr.RgInt);
IpkOff = Vdrv/(gd.RoutL+Roff+pwr.RgInt);
disp("Gate driver peak ON current is " + round(IpkOn,1) + " A");
disp("Gate driver peak OFF current is " + round(IpkOff,1) + " A");

PkdrvOn = IpkOn^2*gd.RoutH;
PkdrvOff = IpkOff^2*gd.RoutL;
disp("Gate driver peak ON power dissipation is " + round(PkdrvOn,2) + " W");
disp("Gate driver peak OFF power dissipation is " + round(PkdrvOff,2) + " W");

PkRon = IpkOn^2*Ron;
PkRoff = IpkOff^2*Roff;
disp("Gate resistor peak ON power dissipation is " + round(PkRon,2) + " W");
disp("Gate resistor peak OFF power dissipation is " + round(PkRoff,2) + " W");

%% Bias supply requirements

VdropOn = 0.1; % - max. allowable voltage drop on positive rail
VdropOff = 0.5; % - max. allwable voltage drop on negative rail

disp("Bias supply needs at least " + round(Pavg,1) + " W output power");

CminPos = Qg/VdropOn;
CminNeg = Qg/VdropOff;
%CminPos = Epos/(pcb.VgH*VdropOn-0.5*VdropOn^2);
%CminNeg = Eneg/(pcb.VgL*VdropOff-0.5*VdropOff^2);

disp("Bias supply positive rail needs at least " + round(CminPos*1e6,1) + " uF");
disp("Bias supply negative rail needs at least " + round(CminNeg*1e6,1) + " uF");

Ipos = CminPos*VdropOn*fsw;
Ineg = CminNeg*VdropOff*fsw;
disp("Positive bias supply needs at least " + round(Ipos*1e3,1) + " mA output current");
disp("Negative bias supply needs at least " + round(Ineg*1e3,1) + " mA output current");

%% Desat circuit

Vdst = 3.1; % - Vds or Vce at sc current
Idst = 420; % - target sc current
%Vdst = (Idst-pwr.bOut)/pwr.mOut; % - approximation ONLY for IGBT when output tf isn't available for target sc current

Rlim = 1e3; % - change only for fine trim - otherwise leave at 1k
nDiode = 2;
Vdiode = 0.7;
nZener = 0;
Vzener =  4.7;

Vdrop = min(pcb.VgH, Vdst + gd.Ichg*Rlim + nDiode*Vdiode + nZener*Vzener);
Vadd = gd.Vdesat - Vdrop;
disp("Need to drop an additional " + round(Vadd,1) + " V in the desat path");

tblk = 1e-6; % - blanking time for desat
cblk = tblk*gd.Ichg/gd.Vdesat;
disp("Need " + round(cblk*1e12,1) + " pF for " + tblk*1e9 + " ns blanking time");

tdelay = tblk + gd.tDesatLEB + gd.tDesatFilt + gd.tDesatOff;
disp("Total delay from desat to gate off is " + round(tdelay*1e6,1) + " us");