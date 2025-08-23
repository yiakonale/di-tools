classdef powerstage
   properties
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
         lg = (obj.RgInt^2)*obj.Ciss/4;
      end
   end
end