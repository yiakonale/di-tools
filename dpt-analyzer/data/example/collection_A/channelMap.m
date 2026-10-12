function map = channelMap()
%CHANNELMAP Channel assignments for data/example/collection_A.
%   Tektronix MSO58B multi-pulse record, LS device active.
%   CH5 and CH8 are the drain currents of the two parallel LS devices and
%   are deliberately not mapped; MATH1 (CH5 + CH8) is the total Id-LS.

map.description = "Example record: LS active, parallel LS devices (Id-LS = MATH1 = CH5 + CH8)";

map.channels.CH1.signal   = "Vgs-HS";
map.channels.CH1.file     = "Tek000_ch1.mat";

map.channels.CH2.signal   = "Vgs-LS";
map.channels.CH2.file     = "Tek000_ch2.mat";

map.channels.CH3.signal   = "Vds-LS";
map.channels.CH3.file     = "Tek000_ch3.mat";

map.channels.CH4.signal   = "Vds-HS";
map.channels.CH4.file     = "Tek000_ch4.mat";

map.channels.CH7.signal   = "Iout";
map.channels.CH7.file     = "Tek000_ch7.mat";

map.channels.MATH1.signal = "Id-LS";
map.channels.MATH1.file   = "Tek000_math1.mat";

end
