%% Gate Driver

ucc21750 = gdic;
ucc21750.RoutH = 2.5;
ucc21750.RoutL = 0.3;
ucc21750.IoutH = 10;
ucc21750.IoutL = 10;
ucc21750.Pd = 965e-3;
ucc21750.Ichg = 500e-6;
ucc21750.Vdesat = 9.15;
ucc21750.tDesatLEB = 200e-9;
ucc21750.tDesatFilt = 140e-9;
ucc21750.tDesatOff = 200e-9;

%% Powerstage

fs200r12pt4 = powerstage;
fs200r12pt4.Qg = 1.65e-6;
fs200r12pt4.VgeH = 15;
fs200r12pt4.VgeL = -15;
fs200r12pt4.Ciss = 14e-9;
fs200r12pt4.Crss = 0.5e-9;
fs200r12pt4.Coss;
fs200r12pt4.RgInt = 3.5;
fs200r12pt4.mOut = 266;
fs200r12pt4.bOut = -266;

%% PCBA

gdbmk1 = pcba;
gdbmk1.Lgs = 40e-9;
gdbmk1.VgH = 15;
gdbmk1.VgL = -15;