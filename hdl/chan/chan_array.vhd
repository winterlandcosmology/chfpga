----------------------------------------------------------------------------------
-- Company: McGill University
-- Engineer: JF Cliche
--
-- Create Date: 2024
-- Design Name: chan_array
-- Module Name: chan_array - impl
-- Project Name: chfpga
-- Target Devices: Zynq Ultrascale+ RfSoC
-- Tool Versions: Vivado 2022.1 +
-- Description: Array of ADC data acquisition blocks and channelizers
--
-- This module contains the ADC generation logic and channelizer array
-- extracted from chfpga.vhd for improved modularity.
--
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.std_logic_misc.ALL; -- for and_reduce

library UNISIM;
use UNISIM.vcomponents.ALL;

library xpm;
use xpm.vcomponents.ALL;

library work;
use work.chFPGA_Package.ALL; -- Get all component definitions
use work.chFPGA_config.ALL; -- Get implementation-specific definitions

entity chan_array is
	generic (
		PLATFORM_TYPE                     : platform_type_enum;
		ADC_TYPE                        : adc_type_enum;
		NUMBER_OF_ADCS                  : integer;
		NUMBER_OF_CHANNELIZERS          : integer                                           := NUMBER_OF_ADCS;
		NUMBER_OF_CHANNELIZERS_WITH_FFT : integer                                           := NUMBER_OF_CHANNELIZERS;
		FFT_TYPE                        : fft_type_enum;
		CAPTURE_TYPE                    : chan_capture_type_enum;
		NUMBER_OF_CAPTURE_SOURCES       : integer                                           := CHAN_CAPTURE_INFO(CAPTURE_TYPE).NUMBER_OF_SOURCES;
		CAPTURE_BITS_PER_WORD           : integer                                           := CHAN_CAPTURE_INFO(CAPTURE_TYPE).INPUT_WIDTH;
		ADC_SAMPLES_PER_FRAME           : integer := FFT_INFO(FFT_TYPE).SAMPLES_PER_FRAME;
		ADC_IS_DIFFERENTIAL             : bool_array_array(0 to NUMBER_OF_ADCS - 1)(0 to 8) := (others => (others => TRUE));
		ADC_PROVIDE_BUFFERED_DIVCLK     : bool_array(0 to NUMBER_OF_ADCS - 1)            := (1 => TRUE, others => FALSE);
		ADC_INSTANTIATE_PLL             : bool_array(0 to NUMBER_OF_ADCS - 1)            := (others => FALSE);
		ADC_USE_EXT_DATA_CLK            : bool_array(0 to NUMBER_OF_ADCS - 1)            := (0 to 3 => TRUE, others => FALSE);
		ADC_CLOCKING_REGION_MAP         : integer_array_array(0 to NUMBER_OF_ADCS - 1)(0 to 8) := (others => (others => 0));
		CHAN_CLK_SOURCE_LANE                  : integer                                           := 1;
		ADC_TO_ADC_BOARD_MAP            : integer_array(0 to NUMBER_OF_ADCS - 1)         := (others => -1);
		NUMBER_OF_ADC_BOARDS            : integer                                           := 2;
		CT_CLK_SOURCE                   : ct_clk_source_enum                                := CORR_CLK;
		CHAN_CLK_SOURCE                 : chan_clk_source_enum                              := ADC;
		CORR_TYPE                       : corr_type_enum                                    := NONE;
		CT_TYPE                         : ct_type_enum                                      := BCT;
		NUMBER_OF_PROBER_PORTS: integer := sel(CAPTURE_TYPE=PROBER, NUMBER_OF_CHANNELIZERS, 1);
		SIM                             : boolean                                           := FALSE
	);
	port (
		-- FMC ADC Interface (EV8AQ160)

		adc_data_p : in slv8_array(0 to NUMBER_OF_ADCS - 1)       := (others => (others => '0'));
		adc_data_n : in slv8_array(0 to NUMBER_OF_ADCS - 1)       := (others => (others => '1'));
		adc_clk_p  : in std_logic_vector(0 to NUMBER_OF_ADCS - 1) := (others => '0');
		adc_clk_n  : in std_logic_vector(0 to NUMBER_OF_ADCS - 1) := (others => '1');

		-- AXIS ADC Interface

		adc_axis_tdata  : in slv128_array(0 to NUMBER_OF_ADCS - 1)     := (others => (others => '0'));
		adc_axis_tvalid : in std_logic_vector(0 to NUMBER_OF_ADCS - 1) := (others => '0');
		adc_axis_clk    : in std_logic_vector(0 to NUMBER_OF_ADCS - 1) := (others => '0');
		adc_or                : in std_logic_vector(0 to NUMBER_OF_ADCS - 1)  := (others => '0'); -- ADC overrange
		adc_ov                : in std_logic_vector(0 to NUMBER_OF_ADCS - 1)  := (others => '0'); -- ADC overvoltage

		-- AXIS ADC clocks

		adc_clkout : in std_logic_vector(0 to NUMBER_OF_ADCS - 1) := (others => '0'); -- Divided ADC sampling clock from tile, used for monitoring only (create divide-by-two signal)
		adc_sysref : in std_logic                                 := '0'; -- PL_SYSREF, reclocked through adc_axis_clk (plclk)

		-- ADCDAQ signals

		adcdaq_reset : in std_logic; -- Resets the ADCDAQ. Async. Typically from user-controlled GPIO or REFCLK reset sequencer.
		adc_clk      : out std_logic; -- Word clock from one of the ADC
		adc_clk_div2 : out std_logic_vector(0 to NUMBER_OF_ADCS - 1);

		-- FMC Interface
		fmc_refclk : in std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1); -- Used to sample the ADC clock for delay calibration in ADCDAQ
		clk200     : in std_logic; -- Stable 200 MHz clock used only to clock the ADCDAQ's IODELAYs

		-- ADC Clock Output (for clocks module)

		-- ADC Data Outputs (for system module event counting)
		adc_tvalid : out std_logic_vector(0 to NUMBER_OF_ADCS - 1);
		adc_tlast  : out std_logic_vector(0 to NUMBER_OF_ADCS - 1);


		-- Channelizer internal signal processing clocks and resets
		chan_clk   : in std_logic_vector(0 to max(8, max(NUMBER_OF_CHANNELIZERS, NUMBER_OF_ADCS)) - 1);
		chan_reset : in std_logic_vector(0 to max(8, max(NUMBER_OF_CHANNELIZERS, NUMBER_OF_ADCS)) - 1);



		-- Channelizer Outputs (on ct_clk)

		chan_out_tdata        : out slv_array(0 to NUMBER_OF_CHANNELIZERS - 1)(31 downto 0);
		chan_out_tuser        : out slv_array(0 to NUMBER_OF_CHANNELIZERS - 1)(3 downto 0);
		chan_out_tvalid       : out std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
		chan_out_tlast        : out std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
		ct_clk                : in std_logic;
		ct_reset              : in std_logic;

		-- 8-bit data capture stream from PROBER or UCAP

		m_axis_prober_tdata  : out slv_array(0 to NUMBER_OF_PROBER_PORTS - 1)(7 downto 0);
		m_axis_prober_tvalid : out std_logic_vector(0 to NUMBER_OF_PROBER_PORTS - 1);
		m_axis_prober_tlast  : out std_logic_vector(0 to NUMBER_OF_PROBER_PORTS - 1);
		m_axis_prober_tready : in std_logic_vector(0 to NUMBER_OF_PROBER_PORTS - 1);
		axis_cap_clk      : in std_logic                     := '0';

		-- Channelizer BSB Control Interface (on bsb_clk)

		s_axis_bsb_tdata  : in std_logic_vector(7 downto 0)  := (others => '0');
		s_axis_bsb_tvalid : in std_logic                     := '0';
		s_axis_bsb_tlast  : in std_logic                     := '0';
		s_axis_bsb_tready : out std_logic                    := '0';
		m_axis_bsb_tdata  : out std_logic_vector(7 downto 0) := (others => '0');
		m_axis_bsb_tvalid : out std_logic                    := '0';
		m_axis_bsb_tlast  : out std_logic                    := '0';
		m_axis_bsb_tready : in std_logic                     := '0';
		bsb_clk           : in std_logic;
		bsb_rst           : in std_logic;

		-- UCAP BSB Control interface

		s_axis_ucap_bsb_tdata  : in std_logic_vector(7 downto 0)  := (others => '0');
		s_axis_ucap_bsb_tvalid : in std_logic                     := '0';
		s_axis_ucap_bsb_tlast  : in std_logic                     := '0';
		s_axis_ucap_bsb_tready : out std_logic                    := '0';
		m_axis_ucap_bsb_tdata  : out std_logic_vector(7 downto 0) := (others => '0');
		m_axis_ucap_bsb_tvalid : out std_logic                    := '0';
		m_axis_ucap_bsb_tlast  : out std_logic                    := '0';
		m_axis_ucap_bsb_tready : in std_logic                     := '0';

		-- Copy of the capture bus that feeds UCAP, for the raw ADC streamer (on chan_clk(0)). Driven only when CAPTURE_TYPE=UCAP.

		m_axis_raw_tdata  : out slv_array(0 to max(NUMBER_OF_ADCS, NUMBER_OF_CHANNELIZERS) - 1)(CAPTURE_BITS_PER_WORD - 1 downto 0) := (others => (others => '0'));
		m_axis_raw_tvalid : out std_logic_vector(0 to NUMBER_OF_CAPTURE_SOURCES - 1)                                             := (others => '0'); -- one per data source
		m_axis_raw_tlast  : out std_logic_vector(0 to NUMBER_OF_CAPTURE_SOURCES - 1)                                             := (others => '0');
		m_axis_raw_source : out std_logic_vector(0 to max(NUMBER_OF_ADCS, NUMBER_OF_CHANNELIZERS) - 1)                           := (others => '0'); -- data source currently on tdata for each channel
		m_axis_raw_rst    : out std_logic                                                                                        := '0' -- reset used by UCAP for its frame counters
	);
end entity chan_array;

architecture impl of chan_array is

	-- Attribute definitions
	attribute KEEP: string;
	attribute DONT_TOUCH: string;
	attribute EQUIVALENT_REGISTER_REMOVAL: string;
	attribute SHREG_EXTRACT: string;

	-- Constants
	constant FPGA_SERIES: fpga_series_enum := PLATFORM_INFO(PLATFORM_TYPE).FPGA_SERIES;
	constant ADC_SAMPLES_PER_WORD            : integer := FFT_INFO(FFT_TYPE).SAMPLES_PER_WORD;
	constant ADC_BITS_PER_SAMPLE             : integer := FFT_INFO(FFT_TYPE).BITS_PER_SAMPLE;

	constant NUMBER_OF_ADCS_OR_CHANNELIZERS: integer := max(NUMBER_OF_ADCS, NUMBER_OF_CHANNELIZERS);
	constant ADC_BITS_PER_WORD: integer := ADC_SAMPLES_PER_WORD * ADC_BITS_PER_SAMPLE;
	constant ADC_INSTANTIATE_IDELAYCTRL: bool_array(0 to NUMBER_OF_ADCS - 1) := (0 => TRUE, others => FALSE);
	constant CORR_PROBE_BASE_PORT: integer := NUMBER_OF_CHANNELIZERS; -- Top level address for the first correlator block

	-- Signals

	-- Channel router signals
	signal chan_router_bsb_cmd_tdata: slv8_array(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_router_bsb_cmd_tvalid: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_router_bsb_cmd_tlast: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_router_bsb_cmd_tready: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_router_bsb_rply_tdata: slv8_array(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_router_bsb_rply_tvalid: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_router_bsb_rply_tlast: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_router_bsb_rply_tready: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);

	-- ADCDAQ BSB signals
	signal adcdaq_bsb_cmd_tdata: slv8_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adcdaq_bsb_cmd_tvalid: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adcdaq_bsb_cmd_tlast: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adcdaq_bsb_cmd_tready: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adcdaq_bsb_rply_tdata: slv8_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adcdaq_bsb_rply_tvalid: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adcdaq_bsb_rply_tlast: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adcdaq_bsb_rply_tready: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);

	-- ADC data bus (internal)
	signal adc_tdata: slv_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1)(ADC_BITS_PER_WORD - 1 downto 0);
	signal adc_tuser: slv_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1)(ADC_SAMPLES_PER_WORD - 1 downto 0);
	signal adc_tvalid_int: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal adc_tlast_int: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);

	-- Data capture/monitoring outputs from chan_array
	signal chan_mon_tdata: slv_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1)(CAPTURE_BITS_PER_WORD - 1 downto 0);
	signal chan_mon_tvalid: slv_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1)(0 to NUMBER_OF_CAPTURE_SOURCES - 1);
	signal chan_mon_tlast: slv_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1)(0 to NUMBER_OF_CAPTURE_SOURCES - 1);
	signal chan_mon_source_req: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
	signal chan_mon_source_ack: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);

	-- Data capture/monitoring outputs from Channelizers' PROBERs
	signal chan_prober_tdata: slv_array(0 to NUMBER_OF_CHANNELIZERS - 1)(7 downto 0);
	signal chan_prober_tvalid: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_prober_tlast: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_prober_tready: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);

	-- Channelizer output alignment (chan_align_blk)
	signal chan_out_almost_empty: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
	signal chan_out_send: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1) := (others => '1');
begin

	-- ADCDAQ_RESET <= adcdaq_reset_async or refclk_adcdaq_reset;

	--------------------------------------------------------------------
	-- ADCs
	--------------------------------------------------------------------
	adc_gen: case ADC_TYPE generate
		---------------
		-- EV8AQ160 ADC
		---------------
		when EV8AQ160_case: EV8AQ160 =>
			signal adc_ioclk: std_logic;
			signal adc_divclk: std_logic;
			signal adc_tdata8: slv32_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
			signal adc_data_ready_all: std_logic_vector(0 to NUMBER_OF_ADCS - 1);
			signal adc_send_data_async: std_logic;
			-- Internal ADC clock signals (for EV8AQ160)
			signal adc_divclk_out_bufg: std_logic_vector(0 to NUMBER_OF_ADCS - 1);
			signal adc_ioclk_out_pll: std_logic_vector(0 to NUMBER_OF_ADCS - 1);
			signal adc_divclk_out_pll: std_logic_vector(0 to NUMBER_OF_ADCS - 1);
		begin

			-- Check that we have a valid board map
			check_map_gen: for i in 0 to NUMBER_OF_ADC_BOARDS - 1 generate
				assert is_in(i, ADC_TO_ADC_BOARD_MAP) report "ADC_TO_ADC_BOARD_MAP must be defined and must cover all ADC boards" severity failure;
			end generate;

			-- Selects which ADCDAQ will provides the master clock for the clock generator module to provide channelizer clocks.
			adc_clk <= adc_divclk_out_bufg(CHAN_CLK_SOURCE_LANE); -- Must use output with ADC_INSTANTIATE_PLL=TRUE , preferably an output without PLL

			-- Generate a global ``send_data`` signal that is '1' when all ADCs have data to send.
			-- The inputs are all from different clocks
			--   1) Since we do a AND operation and all signals are zero after reset, the outputs should be stable at zero until all inputs are '1'
			--   2) Even if a channelizer started reading one or two clocks after the others, the packets are realigned at the end of the channelizers
			--   3) The adc_send_data should be resynchronized to its clock domain
			--      before being fed to ADCDAQ. The pipelining will take care of that.
			--      Physical separation of the pipeling registers makes this a less
			--      than optimal CDC, but as stated above timing is not critical.
			adc_send_data_async <= and(adc_data_ready_all); --

			-- Select which ADCDAQ provides an external clock to other ADCDAQs (used only if USE_EXT_DATA_CLK=TRUE)
			adc_ioclk  <= adc_ioclk_out_pll(CHAN_CLK_SOURCE_LANE); -- Must use output with ADC_INSTANTIATE_PLL=TRUE , preferably an output without PLL
			adc_divclk <= adc_divclk_out_pll(CHAN_CLK_SOURCE_LANE); -- Must use output with ADC_INSTANTIATE_PLL=TRUE , preferably an output without PLL

			adcgen: for i in 0 to NUMBER_OF_ADCS - 1 generate
				signal adc_data_ready: std_logic;
				signal adc_data_ready_reg1: std_logic;
				signal adc_send_data: std_logic;
				signal adc_send_data_reg: std_logic;

				attribute keep of adc_data_ready_reg1: signal is "true"; -- prevent equivalent register merging
				attribute keep of adc_send_data_reg: signal is "true"; -- prevent equivalent register merging

				signal adcdaq_bsb_rst: std_logic_vector(0 to NUMBER_OF_ADCS - 1);
				signal adcdaq_bsb_rst_reg: std_logic_vector(0 to NUMBER_OF_ADCS - 1);
				attribute dont_touch of adcdaq_bsb_rst, adcdaq_bsb_rst_reg: signal is "true";

			begin

				-- pipeline the bsb reset signals
				rst_proc: process(all) begin
					if rising_edge(bsb_clk) then
						adcdaq_bsb_rst <= (others => bsb_rst);
						adcdaq_bsb_rst_reg  <= adcdaq_bsb_rst;
					end if;
				end process;

				-- Resync adc_send_data_async to the local clock.
				adc_ready_cdc0: xpm_cdc_single
					generic map (
						SRC_INPUT_REG => 0
					)
					port map (
						src_clk  => '0',
						src_in   => adc_send_data_async,
						dest_clk => chan_clk(i),
						dest_out => adc_send_data
					);

				-- Generate the adc_send_data which will tells all the ADCs to start
				-- sending data once all of them have their FIFO half-full
				adc_send_proc: process(all) begin
					if rising_edge(chan_clk(i)) then
						adc_data_ready_reg1 <= adc_data_ready; -- pipeline all adc_data_ready signals so they can be combined (and_reduce) at a central point
						adc_data_ready_all(i) <= adc_data_ready_reg1; -- pipeline
						adc_send_data_reg <= adc_send_data; -- pipeline AND resync adc_send_data
					end if;
				end process;

				adc_tdata(i) <= adc_tdata8(i);

				adcdaq0: entity work.adcdaq
					generic map (
						FPGA_SERIES             => FPGA_SERIES,
						IMPLEMENT_ADCDAQ        => TRUE, --
						PROVIDE_BUFFERED_DIVCLK => ADC_PROVIDE_BUFFERED_DIVCLK(i),
						USE_EXT_DATA_CLK        => ADC_USE_EXT_DATA_CLK(i), -- Use array to select whether a PLL should be used for this instance.
						IS_DIFFERENTIAL         => ADC_IS_DIFFERENTIAL(i),
						INSTANTIATE_PLL         => ADC_INSTANTIATE_PLL(i), --
						CLOCKING_REGION_MAP     => ADC_CLOCKING_REGION_MAP(i),
						INSTANTIATE_IDELAYCTRL  => ADC_INSTANTIATE_IDELAYCTRL(i),
						SIM                     => SIM
					)
					port map (
						-- ADC interface
						adc_data_h_p => adc_data_p(i),
						adc_data_h_n => adc_data_n(i),
						adc_clk_h_p  => adc_clk_p(i),
						adc_clk_h_n  => adc_clk_n(i),

						-- Readout interface
						-- ADC_OUT_DAT => ADC_DAT(i),
						m_axis_adc_tdata  => adc_tdata8(i),
						m_axis_adc_tvalid => adc_tvalid_int(i),
						m_axis_adc_tlast  => adc_tlast_int(i),
						m_axis_adc_tuser  => adc_tuser(i),
						adc_clk           => chan_clk(i),

						-- Readout controls
						data_ready => adc_data_ready, -- '1' when there is enough data in the FIFO to start reading
						send_data  => adc_send_data_reg, -- '1' starts data transmission from the FIFOs

						-- Clock outputs (before PLL)
						divclk_out_bufg => adc_divclk_out_bufg(i), -- BUFG-buffered word clock derived from the ADC clock (provided if ADC_PROVIDE_BUFFERED_DIVCLK=TRUE)

						-- Clock outputs to deserializer logic (generated by PLL if ADC_INSTANTIATE_PLL=TRUE)
						ioclk_out_pll  => adc_ioclk_out_pll(i), -- PLL-generated IOCLK clock (if corresponding ADC_INSTANTIATE_PLL=TRUE)
						divclk_out_pll => adc_divclk_out_pll(i), -- PLL-generated DIVCLK (word) clock (if corresponding ADC_INSTANTIATE_PLL=TRUE)

						-- Clock monitor
						adc_clk_out_div2 => adc_clk_div2(i), -- Word clock divided by 2 in logic for frequency counter


						-- External data clocks
						ioclk_in  => adc_ioclk, -- External IOCLK, used if USE_EXT_DATA_CLK=TRUE
						divclk_in => adc_divclk, -- External DIVCLK, used if USE_EXT_DATA_CLK=TRUE

						-- Global synchronization
						adcdaq_reset => adcdaq_reset,

						-- Control lines
						s_axis_bsb_tdata  => adcdaq_bsb_cmd_tdata(i),
						s_axis_bsb_tvalid => adcdaq_bsb_cmd_tvalid(i),
						s_axis_bsb_tlast  => adcdaq_bsb_cmd_tlast(i),
						s_axis_bsb_tready => adcdaq_bsb_cmd_tready(i),
						m_axis_bsb_tdata  => adcdaq_bsb_rply_tdata(i),
						m_axis_bsb_tvalid => adcdaq_bsb_rply_tvalid(i),
						m_axis_bsb_tlast  => adcdaq_bsb_rply_tlast(i),
						m_axis_bsb_tready => adcdaq_bsb_rply_tready(i),
						bsb_clk           => bsb_clk,
						bsb_rst           => adcdaq_bsb_rst_reg(i),

						ref_clk => fmc_refclk(ADC_TO_ADC_BOARD_MAP(i)), -- Used to sample the ADC clock waveform
						clk200  => clk200 -- Used to clock the IODELAYCTRL
					);

			end generate adcgen;

		end EV8AQ160_case;

		when axis_case: AXIS =>
			-----------------------
			-- AXIS ADC DATA SOURCE
			-----------------------
			-- The ``adcdaq_reset`` signal, which is genererated by REFCLK on CLK10  is resynchronized to adc_clk. It is assumed that the system and constraints are set
			-- so we can register this signal without timing issues (i.e. set_multicycle_path might have to be set to ensure sane timing).
			--
			-- When ``adcdaq_reset`` is set, the module stops sending ADC data (TVALID=0). Once ``adcdaq_reset`` is released, data won't flow for a full frame
			-- to allow time for the CHAN and CT/CORR engines to come out of reset, then data will start flowing again

			constant WORDS_PER_FRAME: integer := ADC_SAMPLES_PER_FRAME / ADC_SAMPLES_PER_WORD;
			constant LOG2_WORDS_PER_FRAME: integer := integer_log2(WORDS_PER_FRAME);

			signal adc_send_data2: std_logic_vector(0 to NUMBER_OF_ADCS - 1); -- indicates when TVALID can be passed on
			signal adc_tdata_reg: slv128_array(0 to NUMBER_OF_ADCS - 1);
			signal adc_tvalid_reg: std_logic_vector(0 to NUMBER_OF_ADCS - 1);

			signal adcdaq_reset_pre: std_logic; -- ADCDAQ reset, resynchronized to adc_clk
			signal adcdaq_reset_reg: std_logic; -- ADCDAQ reset, pipelined

		begin
			-- Select clock to be used as a source to generate channelizer clocks
			-- We don't use the clocks directly, but we use the reset sequencer which use these clocks.
			-- We should separate the reset sequencer from the clock generator.
			adc_clk <= adc_axis_clk(CHAN_CLK_SOURCE_LANE);

			-- resynchronize ADCDAQ_RESET (clk10) to ADC_CLK
			adcdaq_proc: process(all) begin
				if rising_edge(adc_clk) then
					adcdaq_reset_pre <= adcdaq_reset;
					adcdaq_reset_reg <= adcdaq_reset_pre; -- add extra pipelining to facilitate routing
				end if; -- clk
			end process;

			-- Pipeline and frame the ADC with a TLAST signal and generate the divide-by-two adc clock monitoring signals for the frequency counter
			-- The first frame is skipped to provide time for the channelizer pipeline modules to complete their reset cycles.
			gen_adc: for i in 0 to NUMBER_OF_ADCS - 1 generate
				signal adc_word_ctr: unsigned(LOG2_WORDS_PER_FRAME - 1 downto 0) := (others => '0'); -- Counts words in frame
				signal chan_reset_reg: std_logic;
				attribute dont_touch of chan_reset_reg: signal is "true";
			begin

				adc_clk_div2_proc: process(all) begin
					-- Generate a divide-by-2 version of the downscaled ADC sampling clock
					if rising_edge(adc_clkout(i)) then
						adc_clk_div2(i) <= not adc_clk_div2(i);
					end if; -- adc_axis_clk
				end process;

				adc_proc: process(all) begin
					if rising_edge(chan_clk(i)) then
						chan_reset_reg <= chan_reset(i);
						-- pipeline the ADC data. The ADCs are on the right side of the RfSoC, and some logic may end up on the left.
						adc_tdata_reg(i) <= adc_axis_tdata(i);
						adc_tvalid_reg(i) <= adc_axis_tvalid(i);

						if adc_tvalid_reg(i) then
							adc_word_ctr <= adc_word_ctr + 1;
						end if;

						-- AXIS ADC data comes in 128-bit bus that contains 8x 16-bit sample words.
						-- Actual ADC data is 12 or 14 bits, MSB-aligned in each word. First sample is in the lower word.
						-- Here we repack the ADC samples in a Nsamples x Nbits_per_samples word and also
						-- invert the order of the words to put the first sample in the MSB of the word
						for j in 0 to ADC_SAMPLES_PER_WORD - 1 loop
							adc_tdata(i)(ADC_BITS_PER_SAMPLE * (j + 1) - 1 downto ADC_BITS_PER_SAMPLE * j) <= adc_tdata_reg(i)(16 * (ADC_SAMPLES_PER_WORD - j) - 1 downto 16 * (ADC_SAMPLES_PER_WORD - j) - ADC_BITS_PER_SAMPLE);
						end loop;

						-- Pass the data bus and clear overflow flags
						adc_tuser(i) <= adc_or; -- overrange flag. *** TODO ***  this signal is asynchronous. May need to resynchronize on the AXIS clock
						adc_tvalid_int(i) <= adc_tvalid_reg(i) and adc_send_data2(i);
						adc_tlast_int(i) <= '0';
						-- generate TLAST
						if all_ones(adc_word_ctr) then
							adc_tlast_int(i) <= '1';
							adc_send_data2(i) <= '1'; -- start setting tvalid to 1
						end if; -- last word
						-- Synchronous reset
						if chan_reset_reg or adcdaq_reset_reg then
							adc_tvalid_int(i) <= '0';
							adc_tvalid_reg(i) <= '0';
							adc_word_ctr <= (others => '0');
							adc_send_data2(i) <= '0';
						end if;
					end if; -- if clk
				end process;

			end generate gen_adc;

		end axis_case;
	end generate adc_gen; -- case ADC_TYPE

	--------------------------------------------------
	-- CHANNELIZER COMMAND ROUTER
	--------------------------------------------------
	chan_router_blk: block
		signal chan_router_bsb_rst: std_logic;
		attribute dont_touch of chan_router_bsb_rst: signal is "true";
	begin
		-- Pipeline the BSB reset
		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				chan_router_bsb_rst <= bsb_rst;
			end if;
		end process;

		-- Memory Map
		--
		-- |Port #   | Base Addr       | Sub-module |  |
		-- |----|-----------------|------------- |-------------|
		-- | 0  | Base + 0x00000  | CHAN[0] & ADCDAQ[0]       |             |
		-- | 1  | Base + 0x02000  | CHAN[1] & ADCDAQ[1]       |             |
		-- | 2  | Base + 0x04000  | CHAN[2] & ADCDAQ[2]       |             |
		-- | 3  | Base + 0x06000  | CHAN[3] & ADCDAQ[3]       |             |
		-- | 4  | Base + 0x08000  | CHAN[4] & ADCDAQ[4]       |             |
		-- | 5  | Base + 0x0A000  | CHAN[5] & ADCDAQ[5]       |             |
		-- | 6  | Base + 0x0C000  | CHAN[6] & ADCDAQ[6]       |             |
		-- | 7  | Base + 0x0E000  | CHAN[7] & ADCDAQ[7]       |             |
		-- | 8  | Base + 0x10000  | CHAN[8] & ADCDAQ[8]       |             |
		-- | 9  | Base + 0x12000  | CHAN[9] & ADCDAQ[9]       |             |
		-- | 10 | Base + 0x14000  | CHAN[10] & ADCDAQ[10]       |             |
		-- | 11 | Base + 0x16000  | CHAN[11] & ADCDAQ[11]       |             |
		-- | 12 | Base + 0x18000  | CHAN[12] & ADCDAQ[12]       |             |
		-- | 13 | Base + 0x1A000  | CHAN[13] & ADCDAQ[13]       |             |
		-- | 14 | Base + 0x1C000  | CHAN[14] & ADCDAQ[14]       |             |
		-- | 15 | Base + 0x1E000  | CHAN[15] & ADCDAQ[15]       |             |

		chan_router0: entity work.bsb_router
			generic map (
				NUMBER_OF_PORTS => NUMBER_OF_CHANNELIZERS,
				ADDRESS_MASK    => "---1111------------" -- '1': used to generate port index, '-' = don't care,
			)
			port map (
				-- Master control interface
				s_axis_bsb_tdata  => s_axis_bsb_tdata,
				s_axis_bsb_tvalid => s_axis_bsb_tvalid,
				s_axis_bsb_tlast  => s_axis_bsb_tlast,
				s_axis_bsb_tready => s_axis_bsb_tready,
				m_axis_bsb_tdata  => m_axis_bsb_tdata,
				m_axis_bsb_tvalid => m_axis_bsb_tvalid,
				m_axis_bsb_tlast  => m_axis_bsb_tlast,
				m_axis_bsb_tready => m_axis_bsb_tready,

				m_axis_routed_bsb_tdata  => chan_router_bsb_cmd_tdata,
				m_axis_routed_bsb_tvalid => chan_router_bsb_cmd_tvalid,
				m_axis_routed_bsb_tlast  => chan_router_bsb_cmd_tlast,
				m_axis_routed_bsb_tready => chan_router_bsb_cmd_tready,
				s_axis_routed_bsb_tdata  => chan_router_bsb_rply_tdata,
				s_axis_routed_bsb_tvalid => chan_router_bsb_rply_tvalid,
				s_axis_routed_bsb_tlast  => chan_router_bsb_rply_tlast,
				s_axis_routed_bsb_tready => chan_router_bsb_rply_tready,

				clk => bsb_clk,
				rst => bsb_rst
			);

	end block chan_router_blk;

	---------------------------------------------------------------------
	--  CHANNELIZERS
	---------------------------------------------------------------------
	chan_gen: for i in 0 to NUMBER_OF_CHANNELIZERS - 1 generate

		signal chan_reset_reg: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1); -- Reset for each channelizer input synchronous to their respective clock
		attribute equivalent_register_removal of chan_reset_reg: signal is "no";
		attribute keep of chan_reset_reg: signal is "true";
		attribute shreg_extract of chan_reset_reg: signal is "no";
		attribute dont_touch of chan_reset_reg: signal is "true";

		signal chan_bsb_rst: std_logic;
		signal chan_bsb_rst_reg: std_logic;
		attribute dont_touch of chan_bsb_rst, chan_bsb_rst_reg: signal is "true";

		signal adc_tdata_reg: slv_array(0 to NUMBER_OF_CHANNELIZERS - 1)(ADC_BITS_PER_WORD - 1 downto 0);
		signal adc_tvalid_reg: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
		signal adc_tlast_reg: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
		signal adc_tuser_reg: slv_array(0 to NUMBER_OF_CHANNELIZERS - 1)(ADC_SAMPLES_PER_WORD - 1 downto 0);

		attribute shreg_extract of adc_tdata_reg, adc_tvalid_reg, adc_tlast_reg, adc_tuser_reg: signal is "no";

		attribute dont_touch of chan0: label is "true"; -- don't optimize through cell boundaries


	begin

		-- Pipeline the BSB reset
		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				chan_bsb_rst <= bsb_rst;
				chan_bsb_rst_reg <= chan_bsb_rst;
			end if;
		end process;

		-- Pipeline the channel synchronous resets
		pipe_proc: process(all) begin
			if rising_edge(chan_clk(i)) then
				chan_reset_reg(i) <= chan_reset(i);

				adc_tdata_reg(i) <= adc_tdata(i);
				adc_tvalid_reg(i) <= adc_tvalid_int(i);
				adc_tlast_reg(i) <= adc_tlast_int(i);
				adc_tuser_reg(i) <= adc_tuser(i);
				if chan_reset(i) then
					adc_tvalid_reg(i) <= '0';
				end if;
			end if; -- clk
		end process;

		chan0: entity work.chan
		    generic map(
				PLATFORM_TYPE => PLATFORM_TYPE,
				IMPLEMENT_FFT => i < NUMBER_OF_CHANNELIZERS_WITH_FFT,
				FFT_TYPE => FFT_TYPE,
				SCALER_USE_COMPLEX_GAINS => CONFIG_CHAN_SCALER_USE_COMPLEX_GAINS, -- don't use config param here
				CAPTURE_TYPE => CAPTURE_TYPE,
				CT_TYPE => CT_TYPE
					)
			port map (
				-- Channelizer input (synchronous to in_clk)
				
				in_dat_tdata  => adc_tdata_reg(i),
				in_dat_tvalid => adc_tvalid_reg(i),
				in_dat_tlast  => adc_tlast_reg(i),
				in_dat_tuser  => adc_tuser_reg(i),
				in_reset      => chan_reset_reg(i),
				in_clk        => chan_clk(i), -- input and signal processing clock

				-- Channelizer output, resynchronized to out_clk
				out_dat_tdata        => chan_out_tdata(i),
				out_dat_tvalid       => chan_out_tvalid(i),
				out_dat_tlast        => chan_out_tlast(i),
				out_dat_tuser        => chan_out_tuser(i),
				out_dat_send         => chan_out_send(i),
				out_dat_almost_empty => chan_out_almost_empty(i),
				out_reset            => ct_reset,
				out_clk              => ct_clk, -- output clock

				-- Control interface
				s_axis_bsb_tdata  => chan_router_bsb_cmd_tdata(i),
				s_axis_bsb_tvalid => chan_router_bsb_cmd_tvalid(i),
				s_axis_bsb_tlast  => chan_router_bsb_cmd_tlast(i),
				s_axis_bsb_tready => chan_router_bsb_cmd_tready(i),

				m_axis_bsb_tdata  => chan_router_bsb_rply_tdata(i),
				m_axis_bsb_tvalid => chan_router_bsb_rply_tvalid(i),
				m_axis_bsb_tlast  => chan_router_bsb_rply_tlast(i),
				m_axis_bsb_tready => chan_router_bsb_rply_tready(i),

				bsb_clk => bsb_clk,
				bsb_rst => chan_bsb_rst_reg,

				-- ADCDAQ Control interface
				m_axis_adcdaq_bsb_tdata  => adcdaq_bsb_cmd_tdata(i),
				m_axis_adcdaq_bsb_tvalid => adcdaq_bsb_cmd_tvalid(i),
				m_axis_adcdaq_bsb_tlast  => adcdaq_bsb_cmd_tlast(i),
				m_axis_adcdaq_bsb_tready => adcdaq_bsb_cmd_tready(i),

				s_axis_adcdaq_bsb_tdata  => adcdaq_bsb_rply_tdata(i),
				s_axis_adcdaq_bsb_tvalid => adcdaq_bsb_rply_tvalid(i),
				s_axis_adcdaq_bsb_tlast  => adcdaq_bsb_rply_tlast(i),
				s_axis_adcdaq_bsb_tready => adcdaq_bsb_rply_tready(i),

				-- Full width data monitoring port
				m_axis_cap_tdata  => chan_mon_tdata(i),
				m_axis_cap_tvalid => chan_mon_tvalid(i),
				m_axis_cap_tlast  => chan_mon_tlast(i),
				cap_source_req    => chan_mon_source_req(i),
				cap_source_ack    => chan_mon_source_ack(i),

				-- 8-bit data capture streaming interface
				m_axis_prober_tdata  => chan_prober_tdata(i),
				m_axis_prober_tvalid => chan_prober_tvalid(i),
				m_axis_prober_tlast  => chan_prober_tlast(i),
				m_axis_prober_tready => chan_prober_tready(i),
				axis_prober_clk      => axis_cap_clk
			);
	end generate chan_gen;


	-- Connect ADC data outputs (for system module - only first NUMBER_OF_ADCS elements)
	adc_tvalid <= adc_tvalid_int(0 to NUMBER_OF_ADCS - 1);
	adc_tlast  <= adc_tlast_int(0 to NUMBER_OF_ADCS - 1);

	-----------------------------
	--  Raw data capture
	-----------------------------
	cap_gen: case CAPTURE_TYPE generate
		when PROBER =>
			-- Nothing to do: capture logic in self-contained in CHAN
			chan_mon_source_req <= (others => '0'); -- make sure the net is driven

			m_axis_prober_tdata <= chan_prober_tdata;
			m_axis_prober_tvalid <= chan_prober_tvalid;
			m_axis_prober_tlast <= chan_prober_tlast;
			chan_prober_tready <= m_axis_prober_tready;

		when uram_case: UCAP =>

			signal chan_mon_reg1_tdata: slv_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1)(CAPTURE_BITS_PER_WORD - 1 downto 0);
			signal chan_mon_reg1_tvalid: std_logic_vector(0 to NUMBER_OF_CAPTURE_SOURCES - 1);
			signal chan_mon_reg1_tlast: std_logic_vector(0 to NUMBER_OF_CAPTURE_SOURCES - 1);
			attribute shreg_extract of chan_mon_reg1_tdata, chan_mon_reg1_tvalid, chan_mon_reg1_tlast: signal is "no"; -- needed to prevent pipeline registers to be combined into shoft registers

			signal chan_mon_reg2_tdata: slv_array(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1)(CAPTURE_BITS_PER_WORD - 1 downto 0);
			signal chan_mon_reg2_tvalid: std_logic_vector(0 to NUMBER_OF_CAPTURE_SOURCES - 1);
			signal chan_mon_reg2_tlast: std_logic_vector(0 to NUMBER_OF_CAPTURE_SOURCES - 1);
			attribute shreg_extract of chan_mon_reg2_tdata, chan_mon_reg2_tvalid, chan_mon_reg2_tlast: signal is "no"; -- needed to prevent pipeline registers to be combined into shoft registers

			signal chan_mon_source_req_pre: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1); -- data source request for each channel
			signal ucap_source_ack1: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1); -- curent data source on tdata for each channel
			signal ucap_source_ack2: std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1); -- curent data source on tdata for each channel
			attribute shreg_extract of ucap_source_ack1, ucap_source_ack2: signal is "no";

			signal ucap_bsb_rst, ucap_bsb_rst_reg: std_logic;
			signal ucap_clk: std_logic;
			signal ucap_rst, ucap_rst_reg: std_logic;
		begin

			ucap_clk <= chan_clk(0);
			-- Pipeline the reset signal. ADC logic and UCAP (which uses Ultraram) are at opposite sides of the FPGA on the Ultrascale+.
			process(all) begin
				if rising_edge(ucap_clk) then
					ucap_rst <= chan_reset(0);
					ucap_rst_reg <= ucap_rst;
				end if;
			end process;


			-- Pipeline the BSB reset
			bsb_rst_proc: process(all) begin
				if rising_edge(bsb_clk) then
					ucap_bsb_rst            <= bsb_rst;
					ucap_bsb_rst_reg        <= ucap_bsb_rst;
				end if; -- RST/CLK
			end process;

			-- Pipeline the Muxed Capture data bus
			pipe_proc: process(all) begin
				if rising_edge(ucap_clk) then
					chan_mon_reg1_tdata <= chan_mon_tdata;
					chan_mon_reg1_tvalid <= chan_mon_tvalid(0); -- all channels are assumed to be synchronous
					chan_mon_reg1_tlast <= chan_mon_tlast(0);
					chan_mon_source_req <= chan_mon_source_req_pre;
					ucap_source_ack1 <= chan_mon_source_ack;

					chan_mon_reg2_tdata <= chan_mon_reg1_tdata;
					chan_mon_reg2_tvalid <= chan_mon_reg1_tvalid;
					chan_mon_reg2_tlast <= chan_mon_reg1_tlast;
					ucap_source_ack2 <= ucap_source_ack1;

				end if;
			end process;

			-- Export the same bus for the raw ADC streamer
			m_axis_raw_tdata <= chan_mon_reg2_tdata;
			m_axis_raw_tvalid <= chan_mon_reg2_tvalid;
			m_axis_raw_tlast <= chan_mon_reg2_tlast;
			m_axis_raw_source <= ucap_source_ack2;
			m_axis_raw_rst <= ucap_rst_reg;

			ucap0: entity work.ucap
				generic map (
					FPGA_SERIES => FPGA_SERIES,
					CAPTURE_BITS_PER_WORD => CAPTURE_BITS_PER_WORD
				)
				port map (
					-- Data monitoring port, synchronous to s_axis_clk
					s_axis_tdata   => chan_mon_reg2_tdata,
					s_axis_tvalid  => chan_mon_reg2_tvalid,
					s_axis_tlast   => chan_mon_reg2_tlast,
					source_sel_out => chan_mon_source_req_pre,
					source_sel_in  => ucap_source_ack2,

					s_axis_clk => ucap_clk,
					rst        => ucap_rst_reg,

					-- Output stream, synchronous to m_axis_clk
					m_axis_tdata  => m_axis_prober_tdata(0),
					m_axis_tvalid => m_axis_prober_tvalid(0),
					m_axis_tlast  => m_axis_prober_tlast(0),
					m_axis_tready => m_axis_prober_tready(0),

					m_axis_clk => axis_cap_clk,

					-- BSB interface
					s_axis_bsb_tdata  => s_axis_ucap_bsb_tdata,
					s_axis_bsb_tvalid => s_axis_ucap_bsb_tvalid,
					s_axis_bsb_tlast  => s_axis_ucap_bsb_tlast,
					s_axis_bsb_tready => s_axis_ucap_bsb_tready,
					m_axis_bsb_tdata  => m_axis_ucap_bsb_tdata,
					m_axis_bsb_tvalid => m_axis_ucap_bsb_tvalid,
					m_axis_bsb_tlast  => m_axis_ucap_bsb_tlast,
					m_axis_bsb_tready => m_axis_ucap_bsb_tready,
					bsb_clk           => bsb_clk,
					bsb_rst           => ucap_bsb_rst_reg
				);
		end uram_case;

		when others =>
			assert FALSE report "Unsupported CAPTURE_TYPE" severity FAILURE;

	end generate cap_gen;

	---------------------------------------------------------------------
	-- Channelizer output alignment
	---------------------------------------------------------------------
	-- Assert chan_out_send to all channelizers except when any output FIFO is almost empty,
	-- ensuring all channelizers always produce words simultaneously.
	-- The almost_empty flags are pipelined two stages to a central point, OR-reduced to derive
	-- send, then pipelined two stages back. The channelizer FIFO almost-empty threshold must
	-- absorb this four-cycle round-trip latency.
	chan_align_blk: block
		signal almost_empty_reg1, almost_empty_reg2: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
		signal send_reg1, send_reg2: std_logic_vector(0 to NUMBER_OF_CHANNELIZERS - 1);
		signal send: std_logic;
		attribute keep of send_reg1, send_reg2, send, almost_empty_reg1, almost_empty_reg2: signal is "true"; -- prevent the tool from inferring a shift register
	begin
		chan_align_proc: process(all) begin
			if rising_edge(ct_clk) then
				almost_empty_reg1 <= chan_out_almost_empty;
				almost_empty_reg2 <= almost_empty_reg1;
				send <= '0' when ct_reset else not(or almost_empty_reg2);
				send_reg1 <= (others => send);
				send_reg2 <= send_reg1;
				chan_out_send <= send_reg2;
			end if;
		end process;
	end block chan_align_blk;

end architecture impl;

