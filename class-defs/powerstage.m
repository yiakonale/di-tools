classdef powerstage
   properties
      Type % - MOSFET (Si/SiC/GaN), IGBT, HEMT
      Qg {mustBeNumeric} % - in coulomb - Gate charge
      VgeH {mustBeNumeric} % - in volt - Gate-emitter/source positive voltage
      VgeL {mustBeNumeric} % - in volt - Gate-emitter/source negative voltage
      Ciss {mustBeNumeric} % - in farad - Input capacitance
      Crss {mustBeNumeric} % - in farad - Reverse transfer capacitance
      Coss {mustBeNumeric} % - in farad - Output capacitance
      RgInt {mustBeNumeric} % - in ohm - Internal gate resistor
      mOut {mustBeNumeric} % - I/VCE - output characteristic slope
      bOut {mustBeNumeric} % - in amps - output characteristic y-intercept
   end
   methods
       function obj = powerstage(params)
         if nargin == 1 && isstruct(params)
             fn = fieldnames(params);
             for k = 1:numel(fn)
                 if isprop(obj, fn{k})
                     obj.(fn{k}) = params.(fn{k});
                 end
             end
         end
      end
      function cgs = Cgs(obj)
          if isempty(obj.Crss)
              cgs = obj.Ciss;
          else
              cgs = obj.Ciss - obj.Crss;
          end
      end
      function cds = Cds(obj)
         cds = obj.Coss - obj.Crss;
      end
      function cgd = Cgd(obj)
         cgd = obj.Crss;
      end
      function lg = Lgs(obj)
          if isempty(obj.RgInt)
              lg = 0;
          else
              lg = (obj.RgInt^2)*obj.Ciss/4;
          end
      end
   end
end