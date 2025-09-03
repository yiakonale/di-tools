classdef pcba
   properties
      Lgs {mustBeNumeric} % - in henry - gate loop stray inductance
      VgH {mustBeNumeric} % - in volt - Gate positive bias voltage
      VgL {mustBeNumeric} % - in volt - Gate negative bias voltage
   end
   methods
       function obj = pcba(params)
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