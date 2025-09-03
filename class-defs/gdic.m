classdef gdic
   properties
      RoutH {mustBeNumeric} % - in ohm - Output pull-up resistance
      RoutL {mustBeNumeric} % - in ohm - Output pull-down resistance
      IoutH {mustBeNumeric} % - in amps - Peak source current
      IoutL {mustBeNumeric} % - in amps - Peak sink current
      Iq {mustBeNumeric} % - in amps - driver output side quiescent current (worst case)
      Pd {mustBeNumeric} % - in watt - Maximum power dissipation by output side
      Ichg {mustBeNumeric} % - in amps - Blanking capacitor charge current
      Vdesat {mustBeNumeric} % - in volt - Desat Detection Threshold
      tDesatLEB {mustBeNumeric} % - in sec - Leading edge blank time
      tDesatFilt {mustBeNumeric} % - in sec - DESAT deglitch filter
      tDesatOff {mustBeNumeric} % - in sec - DESAT propagation delay to OUT(L) 90%
   end
   methods
       function obj = gdic(params)
         if nargin == 1 && isstruct(params)
             fn = fieldnames(params);
             for k = 1:numel(fn)
                 if isprop(obj, fn{k})
                     obj.(fn{k}) = params.(fn{k});
                 end
             end
         end
       end
      %function r = roundOff(obj)
       %  r = round([obj.Value],2);
      %end
   end
end