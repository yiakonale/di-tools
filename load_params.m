%% Gate Driver

params.UCC21750.RoutH = 2.5;
params.UCC21750.RoutL = 0.3;
params.UCC21750.IoutH = 10;
params.UCC21750.IoutL = 10;
params.UCC21750.Iq = 0.005;
params.UCC21750.Pd = 965e-3;
params.UCC21750.Ichg = 500e-6;
params.UCC21750.Vdesat = 9.15;
params.UCC21750.tDesatLEB = 200e-9;
params.UCC21750.tDesatFilt = 140e-9;
params.UCC21750.tDesatOff = 200e-9;

params.UCC5870.RoutH = 0.33;
params.UCC5870.RoutL = 0.33;
params.UCC5870.IoutH = 15;
params.UCC5870.IoutL = 15;
params.UCC5870.Iq = 0.015;
params.UCC5870.Pd = 450e-3;
params.UCC5870.Ichg = [];        % - variable
params.UCC5870.Vdesat = [];      % - variable
params.UCC5870.tDesatLEB = 158e-9;
params.UCC5870.tDesatFilt = [];  % - variable
params.UCC5870.tDesatOff = 160e-9;

%% Powerstage

params.FS200R12PT4.Type = "IGBT";
params.FS200R12PT4.Qg = 1.65e-6;
params.FS200R12PT4.VgeH = 15;
params.FS200R12PT4.VgeL = -15;
params.FS200R12PT4.Ciss = 14e-9;
params.FS200R12PT4.Crss = 0.5e-9;
params.FS200R12PT4.Coss = []; 
params.FS200R12PT4.RgInt = 3.5;
params.FS200R12PT4.mOut = 266;
params.FS200R12PT4.bOut = -266;

params.FS200R07A5E3_S6.Type = "IGBT";
params.FS200R07A5E3_S6.Qg = 2.15e-6;
params.FS200R07A5E3_S6.VgeH = 15;
params.FS200R07A5E3_S6.VgeL = -15;
params.FS200R07A5E3_S6.Ciss = 13e-9;
params.FS200R07A5E3_S6.Crss = 0.38e-9;
params.FS200R07A5E3_S6.Coss = [];
params.FS200R07A5E3_S6.RgInt = 2;
params.FS200R07A5E3_S6.mOut = 400;
params.FS200R07A5E3_S6.bOut = -368;

params.FS02MR12A8MA2B.Type = "SiC";
params.FS02MR12A8MA2B.Qg = 1.19e-6;
params.FS02MR12A8MA2B.VgeH = 18;
params.FS02MR12A8MA2B.VgeL = -5;
params.FS02MR12A8MA2B.Ciss = 34.5e-9;
params.FS02MR12A8MA2B.Crss = 0.1e-9;
params.FS02MR12A8MA2B.Coss = 1.26e-9;
params.FS02MR12A8MA2B.RgInt = [];
params.FS02MR12A8MA2B.mOut = [];
params.FS02MR12A8MA2B.bOut = [];

params.ADP280120W3.Type = "SiC";
params.ADP280120W3.Qg = 0.629e-6;
params.ADP280120W3.VgeH = 18;
params.ADP280120W3.VgeL = -5;
params.ADP280120W3.Ciss = 18.71e-9;
params.ADP280120W3.Crss = 0.07e-9;
params.ADP280120W3.Coss = 0.72e-9;
params.ADP280120W3.RgInt = [];
params.ADP280120W3.mOut = [];
params.ADP280120W3.bOut = [];

params.ADP360120W3.Type = "SiC";
params.ADP360120W3.Qg = 0.944e-6;
params.ADP360120W3.VgeH = 18;
params.ADP360120W3.VgeL = -5;
params.ADP360120W3.Ciss = 28.07e-9;
params.ADP360120W3.Crss = 0.09e-9;
params.ADP360120W3.Coss = 1.07e-9;
params.ADP360120W3.RgInt = [];
params.ADP360120W3.mOut = [];
params.ADP360120W3.bOut = [];

%% PCBA

params.GDBMK1.Lgs = 40e-9;
params.GDBMK1.VgH = 15;
params.GDBMK1.VgL = -15;