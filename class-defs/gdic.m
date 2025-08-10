classdef gdic
   properties
      RoutH {mustBeNumeric} % - in ohm - Output pull-up resistance
      RoutL {mustBeNumeric} % - in ohm - Output pull-down resistance
      IoutH {mustBeNumeric} % - in amps - Peak source current
      IoutL {mustBeNumeric} % - in amps - Peak sink current
      Pd {mustBeNumeric} % - in watt - Maximum power dissipation by output side
      Ichg {mustBeNumeric} % - in amps - Blanking capacitor charge current
      Vdesat {mustBeNumeric} % - in volt - Desat Detection Threshold
      tDesatLEB {mustBeNumeric} % - in sec - Leading edge blank time
      tDesatFilt {mustBeNumeric} % - in sec - DESAT deglitch filter
      tDesatOff {mustBeNumeric} % - in sec - DESAT propagation delay to OUT(L) 90%
   end
   methods
      %function r = roundOff(obj)
       %  r = round([obj.Value],2);
      %end
   end
end