function R = measurementRegistry()
%MEASUREMENTREGISTRY Definitions of every supported measurement and method.
%
%   R = measurementRegistry() returns a struct array with one entry per
%   measurement (MEASUREMENT_DESIGN.md section 3). Row numbers refer to
%   MEASUREMENT_SPEC.md. Entries are added group by group (Batch 5c-5h);
%   this version holds the operating point (#1-4), switching energy and
%   power (#5-12), timing (#13-23), slew rates (#24-28) and conduction
%   (#49-54).
%
%   Entry fields
%     id, row, symbol, name, category, unit
%     event        "turnOn" | "turnOff" | "pulse" | "break"
%     optional     true: runs only when enabled (S.measurements.enableOptional)
%     deviceTypes  [] = all, else e.g. "IGBT"
%     methodKey    field of S.measurements.methods holding the preference
%                  order ("" = use the registry order)
%     methods      struct array: id, standard, label, tag, description,
%                  requires (slots), nominal (cfg.nominal field or "")
%     fn           implementation: results = fn(def, method, ctx, sig, S)
%
%   Requirement slots: each slot names the signal role it needs, with
%   alternatives in preference order (e.g. a clamped V_DS channel, else
%   the full-range one). A method is available when every slot finds a
%   signal in the collection; the signals used are recorded in each
%   result. Roles are resolved with resolveRole.
%
%   Tags: IEC methods are tagged with the standard ("IEC 60747-8");
%   others with their class and label ("Conv: bus channel"), because a
%   bare "[Conv]" would not tell two conventional methods apart.

gate = slot("gate", "gateVoltage@active");
Vds  = slot("V", "drainVoltage@active");
IL   = slot("I", "outputCurrent");
Id   = slot("I", "drainCurrent@active");
VdsOnState = slot("V", ["drainVoltageClamped@active", "drainVoltage@active"]);
VdiodeSlot = slot("V", ["drainVoltageClamped@nonActive", "drainVoltage@nonActive"]);
VnonActive = slot("Vref", "drainVoltage@nonActive");

R = struct([]);

%% Operating point (#1-4) -------------------------------------------------
R = add(R, entry("VdcOff", 1, "V_DC,off", "Bus voltage at turn-off", ...
    "Operating point", "V", "turnOff", "VdcOff", @measureBusVoltage, [ ...
    busModel(method("model", "Conv", "V_DC(t)", ...
        ["bus-voltage model V_DC(t) (busVoltageModel: bus channel, KVL, charge droop " ...
         "or constant) averaged over 1 D ending at the turn-off gate instant (V_GS 90 % " ...
         "falling). The tag states the source"], gate))
    method("settledVds", "Conv", "settled V_DS", ...
        ["settled off-state V_DS after the turn-off ringing decays. Includes the " ...
         "freewheel diode's forward voltage (V_DS = V_DC + V_F)"], Vds)
    method("nominal", "Custom", "nominal V_DC", "cfg.nominal.busVoltage", ...
        slot(), "busVoltage")]));

R = add(R, entry("VdcOn", 2, "V_DC,on", "Bus voltage at turn-on", ...
    "Operating point", "V", "turnOn", "VdcOn", @measureBusVoltage, [ ...
    busModel(method("model", "Conv", "V_DC(t)", ...
        ["bus-voltage model V_DC(t) (busVoltageModel: bus channel, KVL, charge droop " ...
         "or constant) averaged over 1 D ending at the turn-on gate instant (V_GS 10 % " ...
         "rising). The tag states the source"], gate))
    method("offStateVds", "Conv", "off-state V_DS", ...
        ["off-state V_DS averaged over 1 D ending at the turn-on gate instant (pulse " ...
         "break). Includes the freewheel diode's forward voltage (V_DS = V_DC + V_F)"], ...
        [Vds, gate])
    method("nominal", "Custom", "nominal V_DC", "cfg.nominal.busVoltage", ...
        slot(), "busVoltage")]));

R = add(R, entry("Ioff", 3, "I_off", "Current at turn-off", ...
    "Operating point", "A", "turnOff", "Ioff", @measureSwitchingCurrent, [ ...
    method("inductorAtInstant", "Conv", "I_L at V_GS 90 %", ...
        ["inductor current at the turn-off gate instant (V_GS 90 % falling), mean over " ...
         "+/- D/2. The inductor current is continuous, so it is the commutated current"], ...
        [IL, gate])
    method("idAtGate90", "Conv", "I_D at V_GS 90 %", ...
        "I_D at the instant V_GS falls to 90 %, mean over +/- D/2", [Id, gate])
    method("filteredIdPre", "Conv", "I_D before gate edge", ...
        "I_D averaged over 1 D ending at the turn-off gate instant", [Id, gate])
    method("nominal", "Custom", "nominal I_test", "cfg.nominal.testCurrent", ...
        slot(), "testCurrent")]));

R = add(R, entry("Ion", 4, "I_on", "Current at turn-on", ...
    "Operating point", "A", "turnOn", "Ion", @measureSwitchingCurrent, [ ...
    method("inductorAtInstant", "Conv", "I_L at V_GS 10 %", ...
        ["inductor current at the turn-on gate instant (V_GS 10 % rising), mean over " ...
         "+/- D/2. The inductor current is continuous, so it is the commutated current"], ...
        [IL, gate])
    method("loadPre", "Conv", "load/diode current before gate edge", ...
        ["load (inductor) current, else the measured diode current, averaged over 1 D " ...
         "ending at the turn-on gate instant"], ...
        [slot("I", ["outputCurrent", "drainCurrent@nonActive"]), gate])
    method("extrapolatedId", "Conv", "extrapolated I_D", ...
        ["settled I_D after the turn-on ringing (within the settling band of its linear " ...
         "trend), fitted over 2 D and extrapolated back to the V_GS 10 % instant"], ...
        [Id, gate])
    method("nominal", "Custom", "nominal I_test", "cfg.nominal.testCurrent", ...
        slot(), "testCurrent")]));

%% Conduction (#49-54, optional) --------------------------------------------
onStateMethods = [
    method("finalPortion", "Conv", "final portion of pulse", ...
        "mean over 1 D ending at the turn-off gate instant (V_GS 90 % falling)", [])
    method("delayToEnd", "Conv", "delay after turn-on to end of pulse", ...
        ["from a delay after V_DS reaches 10 % at turn-on (default: its settling time) " ...
         "to the turn-off gate instant"], [])
    method("custom", "Custom", "user window", ...
        "S.measurements.params.onStateWindow.custom, relative to the turn-off gate instant", [])];

R = add(R, entry("VdsOn", 49, "V_DS(on)", "On-state voltage", "Conduction", "V", ...
    "pulse", "onStateWindow", @measureConduction, withRequires(onStateMethods, [VdsOnState, gate]), true));
R = add(R, entry("IdOn", 50, "I_D(on)", "On-state current", "Conduction", "A", ...
    "pulse", "onStateWindow", @measureConduction, withRequires(onStateMethods, [Id, gate]), true));
R = add(R, entry("RonEff", 51, "R_on,eff", "Effective on-state resistance", "Conduction", ...
    "Ohm", "pulse", "RonEff", @measureConduction, [ ...
    method("averaged", "Conv", "mean V_DS/I_D", ...
        "mean of V_DS / I_D over the on-state window (S.measurements.methods.onStateWindow)", ...
        [VdsOnState, Id, gate])
    method("timeResolved", "Conv", "dynamic V_DS/I_D", ...
        ["mean of V_DS / I_D over +/- D/2 at each delay in " ...
         "S.measurements.params.RonEff.delays after V_DS reaches 10 % at turn-on " ...
         "(dynamic R_DS(on), JEDEC JEP173 for GaN)"], [VdsOnState, Id, gate])], true));
R = add(R, entry("Vf", 52, "V_F", "Freewheel diode forward voltage", "Conduction", "V", ...
    "break", "Vf", @measureConduction, [ ...
    method("breakWindow", "Conv", "pulse break", ...
        ["mean of -V_DS of the non-active device from the settling of the turn-off " ...
         "ringing (+ S.measurements.params.breakWindow.delay) to the next turn-on gate " ...
         "instant"], [VdiodeSlot, VnonActive, gate])
    busModel(method("busModel", "Conv", "V_DS - V_DC(t)", ...
        ["mean of the active device's off-state V_DS minus the bus-voltage model V_DC(t) " ...
         "over the same diode window, for when the non-active V_DS is not captured. " ...
         "Model-based: carries the model's uncertainty"], ...
        [slot("V", "drainVoltage@active"), slot("Vref", "drainVoltage@active"), gate]))], true));
R = add(R, entry("IfDiode", 53, "I_F", "Freewheel diode forward current", "Conduction", "A", ...
    "break", "IfDiode", @measureConduction, [ ...
    method("inductorDuringBreak", "Conv", "I_L during break", ...
        ["inductor current over the diode window of #52. The active device is off, so " ...
         "the whole inductor current flows through the diode"], [IL, VnonActive, gate])
    method("measuredDiode", "Conv", "measured diode current", ...
        "-I_D of the non-active device over the diode window of #52", ...
        [slot("I", "drainCurrent@nonActive"), VnonActive, gate])], true));
R = add(R, entry("PcondDevice", 54, "P_cond", "Conduction power (device)", "Conduction", "W", ...
    "pulse", "onStateWindow", @measureConduction, withRequires(onStateMethods, [VdsOnState, Id, gate]), true));
R = add(R, entry("PcondDiode", 54, "P_cond,F", "Conduction power (diode)", "Conduction", "W", ...
    "break", "", @measureConduction, ...
    method("breakWindow", "Conv", "pulse break", ...
        "mean of V_F * I_F over the diode window of #52 (I_F from I_L, else the measured diode current)", ...
        [VdiodeSlot, slot("I", ["outputCurrent", "drainCurrent@nonActive"]), VnonActive, gate]), true));

%% Timing (#13-23) and slew rates (#24-28) ----------------------------------
R = addTimingAndSlew(R);

%% Switching energy and power (#5-12) ------------------------------------------
R = addEnergy(R);

end

% =====================================================================
function R = addTimingAndSlew(R)
% Declarative methods: each interval is a start and a stop threshold
% (th), resolved by resolveThreshold; each slew rate a pair of levels on
% one signal. Percent levels are on the amplitude scale of the named
% signal's own transition (MEASUREMENT_DESIGN.md 5.4).
G = "gateVoltage@active";
V = "drainVoltage@active";
I = "drainCurrent@active";
on = "turnOn";
off = "turnOff";
both = ["turnOn", "turnOff"];

R = add(R, presets(entry("tdOn", 13, "t_d(on)", "Turn-on delay", "Switching timing", "s", on, ...
    "tdOn", @measureInterval, [ ...
    interval("IEC8", "IEC-8", "V_GS 10 % to V_DS 90 %", "V_GS 10 % rising to V_DS falling to 90 %", th(G, 0.1, "gate"), th(V, 0.9))
    interval("IEC9", "IEC-9", "V_GS 10 % to I_D 10 %", "V_GS 10 % rising to I_D rising to 10 %", th(G, 0.1, "gate"), th(I, 0.1))
    customInterval("tdOn")]), "IEC8", "IEC9"));
R = add(R, presets(entry("tdOff", 14, "t_d(off)", "Turn-off delay", "Switching timing", "s", off, ...
    "tdOff", @measureInterval, [ ...
    interval("IEC8", "IEC-8", "V_GS 90 % to V_DS 10 %", "V_GS 90 % falling to V_DS rising to 10 %", th(G, 0.9, "gate"), th(V, 0.1))
    interval("IEC9", "IEC-9", "V_GS 90 % to I_D 90 %", "V_GS 90 % falling to I_D falling to 90 %", th(G, 0.9, "gate"), th(I, 0.9))
    customInterval("tdOff")]), "IEC8", "IEC9"));
R = add(R, presets(entry("tvf", 15, "t_vf", "Turn-on voltage fall time", "Switching timing", "s", on, ...
    "tvf", @measureInterval, [ ...
    interval("IEC8", "IEC-8", "V_DS 90-10 %", "V_DS 90 % to 10 % at turn-on (IEC 60747-8 t_r)", th(V, 0.9), th(V, 0.1))
    interval("conv8020", "Conv", "V_DS 80-20 %", "V_DS 80 % to 20 % at turn-on", th(V, 0.8), th(V, 0.2))
    interval("conv9010", "Conv", "V_DS 90-10 %", "V_DS 90 % to 10 % at turn-on, outside IEC 60747-8 (e.g. IGBTs)", th(V, 0.9), th(V, 0.1))
    customInterval("tvf")]), "IEC8", "conv9010"));
R = add(R, presets(entry("tvr", 16, "t_vr", "Turn-off voltage rise time", "Switching timing", "s", off, ...
    "tvr", @measureInterval, [ ...
    interval("IEC8", "IEC-8", "V_DS 10-90 %", "V_DS 10 % to 90 % at turn-off (IEC 60747-8 t_f)", th(V, 0.1), th(V, 0.9))
    interval("conv2080", "Conv", "V_DS 20-80 %", "V_DS 20 % to 80 % at turn-off", th(V, 0.2), th(V, 0.8))
    interval("conv1090", "Conv", "V_DS 10-90 %", "V_DS 10 % to 90 % at turn-off, outside IEC 60747-8 (e.g. IGBTs)", th(V, 0.1), th(V, 0.9))
    customInterval("tvr")]), "IEC8", "conv1090"));
R = add(R, presets(entry("tir", 17, "t_ir", "Turn-on current rise time", "Switching timing", "s", on, ...
    "tir", @measureInterval, [ ...
    interval("IEC9", "IEC-9", "I_D 10-90 %", "I_D 10 % to 90 % at turn-on (IEC 60747-9 t_r)", th(I, 0.1), th(I, 0.9))
    interval("conv1090", "Conv", "I_D 10-90 %", "I_D 10 % to 90 % at turn-on, same levels for MOSFETs", th(I, 0.1), th(I, 0.9))
    customInterval("tir")]), "conv1090", "IEC9"));
R = add(R, presets(entry("tif", 18, "t_if", "Turn-off current fall time", "Switching timing", "s", off, ...
    "tif", @measureInterval, [ ...
    interval("IEC9", "IEC-9", "I_D 90-10 %", "I_D 90 % to 10 % at turn-off (IEC 60747-9 t_f)", th(I, 0.9), th(I, 0.1))
    interval("conv9010", "Conv", "I_D 90-10 %", "I_D 90 % to 10 % at turn-off, same levels for MOSFETs", th(I, 0.9), th(I, 0.1))
    customInterval("tif")]), "conv9010", "IEC9"));
tz = presets(entry("tz", 19, "t_z", "Tail time", "Switching timing", "s", off, ...
    "tz", @measureInterval, [ ...
    interval("IEC9", "IEC-9", "I_D 10-2 %", "I_D 10 % to 2 % at turn-off (IGBT tail)", th(I, 0.1), th(I, 0.02))
    customInterval("tz")]), "IEC9", "IEC9");
tz.deviceTypes = "IGBT";
R = add(R, tz);
R = add(R, presets(entry("tOn", 20, "t_on", "Total turn-on time", "Switching timing", "s", on, ...
    "tOn", @measureInterval, [ ...
    interval("IEC8", "IEC-8", "V_GS 10 % to V_DS 10 %", "V_GS 10 % rising to V_DS 10 % (t_d(on) + t_vf)", th(G, 0.1, "gate"), th(V, 0.1))
    interval("IEC9", "IEC-9", "V_GS 10 % to I_D 90 %", "V_GS 10 % rising to I_D 90 % (t_d(on) + t_ir)", th(G, 0.1, "gate"), th(I, 0.9))
    customInterval("tOn")]), "IEC8", "IEC9"));
R = add(R, presets(entry("tOff", 21, "t_off", "Total turn-off time", "Switching timing", "s", off, ...
    "tOff", @measureInterval, [ ...
    interval("IEC8", "IEC-8", "V_GS 90 % to V_DS 90 %", "V_GS 90 % falling to V_DS 90 % (t_d(off) + t_vr)", th(G, 0.9, "gate"), th(V, 0.9))
    interval("IEC9", "IEC-9", "V_GS 90 % to I_D 10 %", "V_GS 90 % falling to I_D 10 % (t_d(off) + t_if)", th(G, 0.9, "gate"), th(I, 0.1))
    customInterval("tOff")]), "IEC8", "IEC9"));
R = add(R, presets(entry("tBreak", 22, "t_break", "Pulse break", "Switching timing", "s", "break", ...
    "tBreak", @measureInterval, [ ...
    interval("conv", "Conv", "V_GS 50 %", "V_GS 50 % falling (end of pulse k) to V_GS 50 % rising (start of pulse k+1)", ...
        th(G, 0.5, "gate", 1), th(G, 0.5, "gate", 2))
    customInterval("tBreak")]), "conv", "conv"));
R = add(R, presets(entry("deadTime", 23, "T_dt", "Half-bridge dead time", "Switching timing", "s", both, ...
    "deadTime", @measureDeadTime, [ ...
    method("conv", "Conv", "V_GS 50 %", ["50 % falling of the outgoing gate to 50 % rising of the " ...
        "incoming gate. Only when the complementary gate is actively driven"], ...
        [slot("gate", G), slot("gateN", "gateVoltage@nonActive")])
    method("custom", "Custom", "user level", "S.measurements.params.custom.deadTime: level and basis", ...
        [slot("gate", G), slot("gateN", "gateVoltage@nonActive")])]), "conv", "conv"));

%% Slew rates
R = add(R, slewEntry("dvdt", 24, "dv/dt", "Average drain-voltage slew rate", "V/s", V, "V_DS"));
R = add(R, slewEntry("didt", 25, "di/dt", "Average drain-current slew rate", "A/s", I, "I_D"));
R = add(R, slewEntry("dvgsdt", 26, "dV_GS/dt", "Gate-voltage slew rate", "V/s", G, "V_GS"));
R = add(R, presets(entry("dvdtMax", 27, "dv/dt,max", "Maximum instantaneous dv/dt", "Slew rate", "V/s", both, ...
    "dvdtMax", @measureSlew, [ ...
    slewMethod("conv", "Conv", "max |dv/dt| in 10-90 %", ["maximum |dV_DS/dt| between the 10 % and 90 % " ...
        "crossings; Savitzky-Golay derivative, window from the steepest band"], V, [0.1 0.9], "maxDerivative")
    slewMethod("custom", "Custom", "max |dv/dt| in user levels", "levels from S.measurements.params.custom.dvdtMax", ...
        V, [], "maxDerivative")]), "conv", "conv"));
R = add(R, presets(entry("didtMax", 28, "di/dt,max", "Maximum instantaneous di/dt", "Slew rate", "A/s", both, ...
    "didtMax", @measureSlew, [ ...
    slewMethod("conv", "Conv", "max |di/dt| in 10-90 %", ["maximum |dI_D/dt| between the 10 % and 90 % " ...
        "crossings; Savitzky-Golay derivative, window from the steepest band"], I, [0.1 0.9], "maxDerivative")
    slewMethod("custom", "Custom", "max |di/dt| in user levels", "levels from S.measurements.params.custom.didtMax", ...
        I, [], "maxDerivative")]), "conv", "conv"));
end

function R = addEnergy(R)
% E_on / E_off: integral of V_DS * I_D between two declared thresholds.
% Each method belongs to a method SET; E_sw (#7) combines E_on and E_off
% of the same set only (MEASUREMENT_SPEC.md row 7).
G = "gateVoltage@active";
V = "drainVoltage@active";
I = "drainCurrent@active";
VI = [slot("V", V), slot("I", I)];
both = ["turnOn", "turnOff"];

R = add(R, presets(entry("Eon", 5, "E_on", "Turn-on energy", "Switching energy", "J", "turnOn", ...
    "Eon", @measureEnergy, [ ...
    energyMethod("IEC8", "IEC-8", "I_D 10 % to V_DS 10 %", th(I, 0.1), th(V, 0.1), "IEC8")
    energyMethod("IEC9", "IEC-9", "V_GS 10 % to V_DS 2 % of V_DC", th(G, 0.1, "gate"), th(V, 0.02, "Vdc"), "IEC9")
    energyMethod("convI10V2", "Conv", "I_D 10 % to V_DS 2 % of V_DC", th(I, 0.1), th(V, 0.02, "Vdc"), "convV2")
    energyMethod("convI10V10", "Conv", "I_D 10 % to V_DS 10 % of V_DC", th(I, 0.1), th(V, 0.1, "Vdc"), "convV10")
    energyMethod("fixed", "Conv", "V_GS 10 % to fixed time", th(G, 0.1, "gate"), [], "fixed")
    energyMethod("custom", "Custom", "user thresholds", [], [], "custom")]), "IEC8", "IEC9"));
R = add(R, presets(entry("Eoff", 6, "E_off", "Turn-off energy", "Switching energy", "J", "turnOff", ...
    "Eoff", @measureEnergy, [ ...
    energyMethod("IEC8", "IEC-8", "V_DS 10 % to I_D 10 %", th(V, 0.1), th(I, 0.1), "IEC8")
    energyMethod("IEC9", "IEC-9", "V_GS 90 % to I_D 2 %", th(G, 0.9, "gate"), th(I, 0.02), "IEC9")
    energyMethod("convV10I2", "Conv", "V_DS 10 % of V_DC to I_D 2 %", th(V, 0.1, "Vdc"), th(I, 0.02), "convV2")
    energyMethod("convV10I10", "Conv", "V_DS 10 % of V_DC to I_D 10 %", th(V, 0.1, "Vdc"), th(I, 0.1), "convV10")
    energyMethod("fixed", "Conv", "V_GS 90 % to fixed time", th(G, 0.9, "gate"), [], "fixed")
    energyMethod("custom", "Custom", "user thresholds", [], [], "custom")]), "IEC8", "IEC9"));

R = add(R, entry("Esw", 7, "E_sw", "Total switching energy", "Switching energy", "J", "pair", ...
    "Esw", @measureEnergy, method("sum", "Conv", "E_on + E_off", ...
    ["E_off of pulse k + E_on of pulse k+1 (same operating point), both from the " ...
     "methods selected for #5 and #6, which must belong to the same method set"], VI)));

ioSlots = [slot("I", I), slot("IL", "outputCurrent"), slot("VN", "drainVoltage@nonActive"), slot("gate", G)];
R = add(R, entry("Eio", 8, "E_io", "Phase-leg switching energy", "Switching energy", "J", both, ...
    "Eio", @measureEnergy, busModel(method("perEvent", "Conv", "energy balance per event", ...
    ["integral of V_DC * I_D,active - I_L * V_DS,non-active (Zhang et al., IEEE TPEL 2017) " ...
     "from the gate instant until the active V_DS has settled (+ S.measurements.params." ...
     "Eio.settleDelay). V_DC from the bus model, held at its value before the edge. " ...
     "Includes both devices' losses and cross-talk; insensitive to V-I deskew"], ioSlots))));
R = add(R, entry("EioPair", 8, "E_io,pair", "Phase-leg switching energy across both events", ...
    "Switching energy", "J", "pair", "EioPair", @measureEnergy, busModel(method("acrossBoth", "Conv", ...
    "energy balance across both events", ["the same integral from the turn-off gate instant of " ...
     "pulse k to the settled turn-on of pulse k+1. Also contains the freewheel diode's " ...
     "conduction energy during the break"], ioSlots))));

R = add(R, entry("EswNonActive", 9, "E_sw,N", "Non-active device switching energy", ...
    "Switching energy", "J", both, "EswNonActive", @measureEnergy, [ ...
    method("direct", "Conv", "direct V_DS,N * I_D,N", ["integral of V_DS * I_D of the " ...
        "non-active device over the active device's E_on / E_off window (needs a second " ...
        "current sensor, which adds loop inductance)"], ...
        [VI, slot("VN", "drainVoltage@nonActive"), slot("IN", "drainCurrent@nonActive")])
    busModel(method("indirect", "Conv", "indirect E_io - E_on/E_off", ...
        "E_io of the event minus the active device's E_on / E_off", [VI, ioSlots]))]));

R = add(R, entry("Pon", 10, "P_on", "Turn-on switching power", "Switching energy", "W", "turnOn", ...
    "Pon", @measureEnergy, [ ...
    method("average", "Conv", "E_on / window", "E_on divided by the length of its window (method of #5)", VI)
    method("peak", "Conv", "peak V_DS*I_D", "maximum of V_DS * I_D inside the E_on window", VI)]));
R = add(R, entry("Poff", 11, "P_off", "Turn-off switching power", "Switching energy", "W", "turnOff", ...
    "Poff", @measureEnergy, [ ...
    method("average", "Conv", "E_off / window", "E_off divided by the length of its window (method of #6)", VI)
    method("peak", "Conv", "peak V_DS*I_D", "maximum of V_DS * I_D inside the E_off window", VI)]));
psw = method("perSwitch", "Conv", "f_s * (E_on + E_off)", ...
    "cfg.switchingFrequency times E_sw (#7) of the pair, per switch", VI);
psw.requiresCfg = "switchingFrequency";
R = add(R, entry("Psw", 12, "P_sw", "Average switching loss", "Switching energy", "W", "pair", ...
    "Psw", @measureEnergy, psw));
end

function m = energyMethod(id, standard, label, start, stop, set)
% Energy window between two thresholds; stop = [] means a fixed duration
% after the start; start = [] means a custom definition.
V = "drainVoltage@active";
I = "drainCurrent@active";
slots = [slot("V", V), slot("I", I)];
specs = [start, stop];
if ~isempty(specs) && any([specs.signal] == "gateVoltage@active")
    slots(end+1) = slot("gate", "gateVoltage@active");
end
if isempty(start)
    description = "start and stop thresholds from S.measurements.params.custom";
elseif isempty(stop)
    description = "from the gate threshold for S.measurements.params.energy.fixedDuration";
else
    description = "integral of V_DS * I_D from " + label;
end
m = method(id, standard, label, description, slots);
m.params = struct('start', start, 'stop', stop, 'set', string(set));
if ~isempty(specs) && any([specs.basis] == "Vdc")
    m = busModel(m);
end
end

function e = slewEntry(id, row, symbol, name, unit, role, label)
e = presets(entry(id, row, symbol, name, "Slew rate", unit, ["turnOn", "turnOff"], id, @measureSlew, [ ...
    slewMethod("avg1090", "Conv", label + " 10-90 % average", "average slope between the 10 % and 90 % crossings", role, [0.1 0.9], "average")
    slewMethod("avg2080", "Conv", label + " 20-80 % average", "average slope between the 20 % and 80 % crossings", role, [0.2 0.8], "average")
    slewMethod("bandMax", "Custom", "max over band", ["steepest average slope over any band of " ...
        "S.measurements.params.slew.band of the swing within 10-90 % (Q10)"], role, [0.1 0.9], "bandMax")
    slewMethod("custom", "Custom", "user levels", "average slope between the levels in S.measurements.params.custom." + id, ...
        role, [], "average")]), "avg1090", "avg1090");
end

function s = th(signal, level, basis, edge)
% Threshold of a declarative method (resolveThreshold).
if nargin < 3
    basis = "transition";
end
if nargin < 4
    edge = 1;
end
s = struct('signal', string(signal), 'level', level, 'basis', string(basis), 'edge', edge);
end

function m = interval(id, standard, label, description, start, stop)
m = method(id, standard, label, description, slotsFor([start, stop]));
m.params = struct('start', start, 'stop', stop);
end

function m = customInterval(id)
m = method("custom", "Custom", "user thresholds", ...
    "start and stop thresholds from S.measurements.params.custom." + id, ...
    slot("gate", "gateVoltage@active"));
m.params = struct('customKey', string(id));
end

function m = slewMethod(id, standard, label, description, role, levels, kind)
m = method(id, standard, label, description, slotsFor(th(role, 0)));
m.params = struct('signal', string(role), 'levels', levels, 'kind', string(kind));
end

function slots = slotsFor(specs)
% One requirement slot per distinct signal role of the thresholds.
roles = unique([specs.signal], 'stable');
slots = slot();
for r = roles
    slots(end+1) = slot(replace(r, "@", "_"), r); %#ok<AGROW>
end
end

function e = presets(e, iec8, iec9)
% Method used by the IEC-8 and IEC-9 presets.
e.presets = struct('IEC8', string(iec8), 'IEC9', string(iec9));
end

% =====================================================================
function R = add(R, e)
if isempty(R)
    R = e;
else
    R(end+1) = e;
end
end

function e = entry(id, row, symbol, name, category, unit, event, methodKey, fn, methods, optional)
if nargin < 11
    optional = false;
end
e.id = string(id);
e.row = row;
e.symbol = string(symbol);
e.name = string(name);
e.category = string(category);
e.unit = string(unit);
e.event = string(event);
e.optional = optional;
e.deviceTypes = strings(1, 0);
e.methodKey = string(methodKey);
e.methods = methods(:)';
e.fn = fn;
e.presets = struct();      % set with presets(): method per IEC preset
end

function m = method(id, standard, label, description, requires, nominal)
if nargin < 6
    nominal = "";
end
if isempty(requires)
    requires = slot();
end
m.id = string(id);
m.standard = string(standard);
m.label = string(label);
m.tag = methodTag(m.standard, m.label);
m.description = strjoin(string(description), "");   % parts may be split for line length
m.requires = requires;
m.nominal = string(nominal);
m.busModel = false;
m.params = struct();       % declarative definition (thresholds, levels)
m.requiresCfg = "";        % top-level cfg field the method needs, e.g. "switchingFrequency"
end

function m = busModel(m)
% The method needs a bus-voltage model (col.busVoltage.source ~= "none").
m.busModel = true;
end

function methods = withRequires(methods, requires)
for k = 1:numel(methods)
    methods(k).requires = requires;
end
end

function s = slot(name, roles)
% With no input, slot() returns an empty 1-by-0 slot array.
if nargin == 0
    s = struct('slot', {}, 'roles', {});
    s = reshape(s, 1, 0);
    return
end
s = struct('slot', string(name), 'roles', string(roles));
end

function t = methodTag(standard, label)
switch standard
    case "IEC-8", t = "IEC 60747-8";
    case "IEC-9", t = "IEC 60747-9";
    case "IEC-2", t = "IEC 60747-2";
    case "JEDEC", t = "JEDEC";
    otherwise,    t = standard + ": " + label;
end
end
