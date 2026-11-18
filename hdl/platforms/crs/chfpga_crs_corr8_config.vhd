library work;
-- Get all chFPGA_package definitions. Since this USE statement is outside the
-- package, its content is visible only to this package, i.e. "USE
-- chFPGA_config.all" does not import the contents of chFPGA_package.
use work.chFPGA_package.all;

package chfpga_config is

	-- F-Engine/channelizer configuration

	constant CONFIG_CHAN_IMPLEMENT_FFT: boolean               := TRUE;
	constant CONFIG_CHAN_FFT_TYPE: fft_type_enum              := CHORD; -- 14 bit samples, 8 samples/word, 16384 samples/frame, 32+32 bit output
	constant CONFIG_CHAN_CAPTURE_TYPE: chan_capture_type_enum := UCAP;
	constant CONFIG_CHAN_NUMBER_OF_CAPTURE_SOURCES: integer   := 2;
	constant CONFIG_CHAN_SCALER_USE_COMPLEX_GAINS: boolean    := FALSE;
	constant CONFIG_NUMBER_OF_CHANNELIZERS_WITH_FFT: integer  := 8;

    -- Corner-turn engine configuration

	constant CONFIG_CT_TYPE: ct_type_enum                := UCT;
	constant CONFIG_CT_LEVEL: integer                    := 1;
	constant CONFIG_CT_CLK_SOURCE: ct_clk_source_enum    := ADC_CLK; -- Run the corner-turn & correlator on the 400 MHz ADC clock
	constant CONFIG_CT_LANE_TO_LINK_MAP: integer_array   := (0 => -1); -- (ignored  with CT_LEVEL=1, but should have a null list here)

	-- Correlator configuration

	constant CONFIG_CORR_TYPE: corr_type_enum                                             := UCORR44;
	constant CONFIG_CORR_READOUT_BINS: integer_array := (0, 1, 2, 3); -- With CONFIG_FFT_ROTATE_BINS=True, true bins 0, 1, 2 & 3 will be used for readout

    -- 10/100G Ethernet Real-time data offload links configuration

    constant CONFIG_DATA_LINK_TYPE: data_link_type_enum := RAW_CGE; -- 100G QSFP link carrying the raw ADC streamer (rawpack)



end chfpga_config;
