classdef pcba
   properties
      Lgs {mustBeNumeric} % - in henry - gate loop stray inductance
      VgH {mustBeNumeric} % - in volt - Gate positive bias voltage
      VgL {mustBeNumeric} % - in volt - Gate negative bias voltage
   end
   methods
      %function r = roundOff(obj)
       %  r = round([obj.Value],2);
      %end
   end
end