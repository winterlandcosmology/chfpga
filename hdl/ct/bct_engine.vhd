----------------------------------------------------------------------------------
-- Company: McGill University
-- Engineer: J.-F. Cliche
--
-- Create Date:    2025-01-31
-- Design Name:    chFPGA
-- Module Name:    bct
-- Project Name: CHIME, HIRAX, FRB Outriggers
-- Target Devices: Kintex 7
-- Tool versions: Vivado 2022.2

-- Description: Corner-turn engine typically used with IceBoards and backplanes.
-- Performs internal 16x16 corner-turn, and optional 16x16 intra-crate (16 boards) and intercrate (2 crates) corner turns.
--
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.std_logic_misc.ALL; -- for and_reduce, etc...
use IEEE.math_real.ALL; -- for ceil()

library UNISIM;
use UNISIM.VComponents.ALL;

use work.chFPGA_Package.ALL;

-- Implement the corner turn operation
---    a) between channels in the same board
--     b) between boards in the same crate (optional)
--     c) between boards in two crates (optional)
--
-- The corner-turn engine is implemented using the following blocks
--
--    - CROSSBAR: channelizer crosbar a.k.a 1st crossbar
--    - CROSSBAR2: shuffle_crossbar
--    - bp_shuffle
--    - CROSSBAR3 shuffle_crossbar
entity bct_engine is
	generic (
		PLATFORM_TYPE: platform_type_enum; -- necessary to select the proper FIFOs
		NUMBER_OF_INPUT_LANES: integer := 16; -- Number of channelizer inputs
		BINS_PER_INPUT_WORD: integer   := 2;
		BITS_PER_INPUT_BIN: integer    := 8 + 8; -- BCT has double the resolution, but 8+8 bits are used for bypass mode only. Non-bypass uses 4+4 bits. 

		INPUT_LANE_WIDTH: integer := BINS_PER_INPUT_WORD * BITS_PER_INPUT_BIN; -- width of the scaler output word

		-- Corner-turning level:
		-- - 1: single-board (local) only (no backplane),
		-- - 2: Option 1 plus 4x4 subbackplane corner-turn (4 boards, using GTY),
		-- - 3: Option 2 + additional 4x4 corner-turn between 2 or 4 sub-backplanes (8 or 16 boards)
		CT_LEVEL: integer := 3;

		-- List indicating the GTY link number associated to each lane. -1 means a bypass  lane (no GTY, stays internal to the board).
		LANE_TO_LINK_MAP: integer_array := ( -- Backplane PCB Lanes
											  0 => -1, -- Bypass lane
											  1 => 0, 2=> 1, 3 => 2, 4 => 3,  5 => 4,  6 => 5,  7 => 6, 8=> 7, 9=> 8, 10=> 9, 11=> 10, 12=> 11, 13=> 12, 14=> 13, 15=> 14,
		-- Backplane QUAD Lanes
											  16 to 19 => -1, -- Bypass lane
											  20 => 15, 21 => 16, 22 => 17, 23=> 18);
		LINK_TO_QUAD_MAP: integer_array   := (0 to 3 => 0, 4 to 7 => 1, 8 to 11=> 2, 12 to 14 => 3, 15 to 18=> 4); -- Indicates which quad is associated to each GTY link.
		QUAD_TO_REFCLK_MAP: integer_array := (0 => 1, 1 => 0, 2 => 0, 3=> 1, 4 => 1); -- Indicates which refclk is associated with each QUAD
		LANE_TO_GROUP_MAP: integer_array  := (0 to 15 => 0, 16 to 23 => 1); -- Indicates to which lane group each lane is associated with


		-- Derived parameters
		INPUT_WORD_WIDTH: integer    := NUMBER_OF_INPUT_LANES * INPUT_LANE_WIDTH;
		BITS_PER_OUTPUT_BIN: integer := BITS_PER_INPUT_BIN / 2; -- BCT outputs 4+4 bits data
		OUTPUT_WORD_WIDTH: integer           := INPUT_WORD_WIDTH * BITS_PER_OUTPUT_BIN / BITS_PER_INPUT_BIN;  -- The CT preserves the data rate unless bits/bin is modified
		NUMBER_OF_OUTPUT_LANES: integer      := OUTPUT_WORD_WIDTH / 32; -- Number of 32-bit output streams (8) - Do not override
		NUMBER_OF_LINKS: integer             := LINK_TO_QUAD_MAP'LENGTH; --  Number of physical data links (GTYs) - Do not override
		NUMBER_OF_REFCLK: integer            := sel(QUAD_TO_REFCLK_MAP'LENGTH > 0, max(QUAD_TO_REFCLK_MAP) + 1, 0); -- Number of reference clocks - Do not override
		BP_LINK_SPEED: integer               := 0 -- 0: 7.5 Gb/s (txclk_out=244 MHz), 1: 10 Gb/s (txclk_out=322 MHz)
	);
	port (
		-- Non-blocking input stream from the channelizer, synchronous to `clk`
		-- All inputs are assumed to be aligned, hence the single TVALID/TLAST.
		s_axis_tdata: in slv_array(0 to NUMBER_OF_INPUT_LANES - 1)(INPUT_LANE_WIDTH - 1 downto 0); -- data from each channelizer, each of which contains 4x (4+4)-bit bin values
		s_axis_tuser: in slv_array(0 to NUMBER_OF_INPUT_LANES - 1)(3 downto 0); -- data from each channelizer, each of which contains 4x (4+4)-bit bin values
		s_axis_tvalid: in std_logic;
		s_axis_tlast: in std_logic;

		-- Non-blocking output stream, synchronous to `clk`.
		-- NUMBER_OF_OUTPUT_LANES 32-bit lanes packed in `m_axis_tdata` with lane 0 at the MSBs.
		-- Every lane carries its own TVALID/TLAST (vector index = lane number): with CT_LEVEL >= 2
		-- the lanes come from independent bin selectors that start their packets at different
		-- times, so a single strobe shared by all lanes would misframe lanes 1..N-1 downstream.
		m_axis_tvalid: out slv(0 to NUMBER_OF_OUTPUT_LANES - 1);
		m_axis_tdata: out slv(OUTPUT_WORD_WIDTH - 1 downto 0);
		m_axis_tlast: out slv(0 to NUMBER_OF_OUTPUT_LANES - 1);


		-- Backplane data shuffle

		tx_p: out std_logic_vector(0 to NUMBER_OF_LINKS - 1);
		tx_n: out std_logic_vector(0 to NUMBER_OF_LINKS - 1);
		rx_p: in std_logic_vector(0 to NUMBER_OF_LINKS - 1);
		rx_n: in std_logic_vector(0 to NUMBER_OF_LINKS - 1);
		refclk_p: in std_logic_vector(0 to NUMBER_OF_REFCLK - 1); -- 156.250 clock
		refclk_n: in std_logic_vector(0 to NUMBER_OF_REFCLK - 1);

		refclk_div2: out std_logic_vector(0 to NUMBER_OF_REFCLK - 1);
		txclk_div2: out std_logic; -- divided-by-two version of the TX word clock, which is also clk_out

		txclk_out: out std_logic; -- Word clock from the GTY TX link
		-- frame_clk_in: in std_logic;
		clk: in  std_logic; -- AXI-S bus clocks. Tie to clk_out if the backplane links are enabled
		rst: in std_logic;

		align_pulse: out std_logic;

		-- Control interface (command and reply stream buses)
		s_axis_bsb_tdata: in std_logic_vector(7 downto 0);
		s_axis_bsb_tvalid: in std_logic;
		s_axis_bsb_tlast: in std_logic;
		s_axis_bsb_tready: out std_logic;
		m_axis_bsb_tdata: out std_logic_vector(7 downto 0);
		m_axis_bsb_tvalid: out std_logic;
		m_axis_bsb_tlast: out std_logic;
		m_axis_bsb_tready: in std_logic;
		bsb_clk: in std_logic;
		bsb_rst: in std_logic
	);
end entity bct_engine;

architecture impl of bct_engine is

	function indices_of(vin: integer_array; target: integer) return integer_array is

		variable vout: integer_array(0 to vin'LENGTH);
		variable n: integer; -- number of matches

	begin

            n := 0;
		for j in vin'RANGE loop
			if vin(j) = target then
                    vout(n) := j;
                    n       := n + 1;
			end if;
		end loop;

		return vout(0 to n - 1);

	end function indices_of;


	-- Attribute definitions

	attribute KEEP: string;
	attribute EQUIVALENT_REGISTER_REMOVAL: string;
	attribute ASYNC_REG: string;
	attribute SHREG_EXTRACT: string;
	attribute DONT_TOUCH: string;


	constant BSB_CROSSBAR1_PORT: integer := 0; -- Top-level address of the CT-Engine 1st crossbar.
	constant BSB_CROSSBAR2_PORT: integer := 1; -- Top-level address of the CT-Engine 2nd crossbar
	constant BSB_CROSSBAR3_PORT: integer := 2; -- Top level address of the CT-Engine 3rd crossbar
	constant BSB_BP_SHUFFLE_PORT: integer := 3; -- Top level address of the CT-Engine backplane shuffle subsystem.
	constant BSB_ROUTER_PORTS: integer := 4; -- Total number of router output ports.


	constant NUMBER_OF_BP_PCB_SHUFFLE_LANES: integer := count(LANE_TO_GROUP_MAP, 0);
	constant NUMBER_OF_BP_QSFP_SHUFFLE_LANES: integer := count(LANE_TO_GROUP_MAP, 1);
	constant NUMBER_OF_SHUFFLE_LANES: integer := LANE_TO_LINK_MAP'LENGTH;

	constant NUMBER_OF_GPU_LINKS: integer := NUMBER_OF_BP_QSFP_SHUFFLE_LANES;
	constant NUMBER_OF_OUT_LANES: integer := NUMBER_OF_GPU_LINKS;

	constant NUMBER_OF_CT1_INPUT_LANES: integer := NUMBER_OF_INPUT_LANES;
	constant NUMBER_OF_CT1_OUTPUT_LANES: integer := NUMBER_OF_BP_PCB_SHUFFLE_LANES;


	-- constant NUMBER_OF_BIN_SEL: integer := NUMBER_OF_OUTPUT_LANES/NUMBER_OF_OUTPUT_LANES_PER_BIN_SEL;

	signal bsb_rst_reg: std_logic;
	signal rst_reg: std_logic;

	-- Routed BSB buses for each device
	signal bct_router_bsb_cmd_tdata: slv8_array(0 to BSB_ROUTER_PORTS - 1);
	signal bct_router_bsb_cmd_tvalid: std_logic_vector(0 to BSB_ROUTER_PORTS - 1);
	signal bct_router_bsb_cmd_tlast: std_logic_vector(0 to BSB_ROUTER_PORTS - 1);
	signal bct_router_bsb_cmd_tready: std_logic_vector(0 to BSB_ROUTER_PORTS - 1);
	signal bct_router_bsb_rply_tdata: slv8_array(0 to BSB_ROUTER_PORTS - 1);
	signal bct_router_bsb_rply_tvalid: std_logic_vector(0 to BSB_ROUTER_PORTS - 1);
	signal bct_router_bsb_rply_tlast: std_logic_vector(0 to BSB_ROUTER_PORTS - 1);
	signal bct_router_bsb_rply_tready: std_logic_vector(0 to BSB_ROUTER_PORTS - 1);


	--    signal bp_shuffle_out_tdata64: slv64_array(0 to NUMBER_OF_LANES-1);
	-- signal bp_shuffle_out_tuser: slv4_array(0 to NUMBER_OF_LANES-1);
	-- signal bp_shuffle_out_tready: slv(0 to NUMBER_OF_LANES-1);
	-- signal axis_bp_shuffle_out_clk: slv(0 to NUMBER_OF_LANES-1);


	-- unused ?
	--  signal s_axis_tfirst: slv(0 to NUMBER_OF_INPUT_LANES - 1);

	--  signal m_axis_tvalid_int: slv(0 to NUMBER_OF_OUTPUT_LANES - 1);
	--  signal m_axis_tdata_int: slv32_array(0 to NUMBER_OF_OUTPUT_LANES - 1);
	--  signal m_axis_tlast_int: slv(0 to NUMBER_OF_OUTPUT_LANES - 1);
	--  signal m_axis_terror_int: slv(0 to NUMBER_OF_OUTPUT_LANES - 1);

	-- Internal AXI-Streaming buses

	--  signal m_axis_fifo_tvalid: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_fifo_tdata: slv32_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_fifo_tlast: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_fifo_tuser: slv4_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_fifo_tready: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	-- signal frame_clk:slv (0 to NUMBER_OF_INPUT_LANES-1);

	--  signal m_axis_align_tvalid: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_align_tdata: slv32_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_align_tlast: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_align_tuser: slv4_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_align_global_tvalid: std_logic;
	--  signal m_axis_align_global_tlast: std_logic;

	--  signal m_axis_remap_tvalid: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_remap_tdata: slv32_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_remap_tlast: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	--  -- signal m_axis_remap_tuser: slv4_array(0 to NUMBER_OF_INPUT_LANES-1);
	--  signal m_axis_remap_global_tvalid: std_logic;
	--  signal m_axis_remap_global_tlast: std_logic;

	--  signal m_axis_remap_tvalid_reg: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_remap_tdata_reg: slv32_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal m_axis_remap_tlast_reg: slv(0 to NUMBER_OF_INPUT_LANES - 1);
	-- signal m_axis_remap_tuser_reg: slv4_array(0 to NUMBER_OF_INPUT_LANES-1);

	--  attribute shreg_extract of m_axis_remap_tvalid_reg: signal is "no";
	--  attribute shreg_extract of m_axis_remap_tdata_reg: signal is "no";
	--  attribute shreg_extract of m_axis_remap_tlast_reg: signal is "no";


	--  signal input_frame_ctr: u8_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal align_frame_ctr: u8_array(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal output_frame_ctr: u8_array(0 to NUMBER_OF_OUTPUT_LANES - 1);
	--  signal packet_error_ctr: u16_array(0 to NUMBER_OF_OUTPUT_LANES - 1);
	-- signal enable_fifo_frame_detection: std_logic;
	-- signal enable_align_frame_detection: std_logic;
	-- signal enable_remap_frame_detection: std_logic;
	-- signal enable_output_frame_detection: std_logic;

	--  signal lane_monitor: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal lane_monitor_sel: unsigned(3 downto 0);
	--  signal lane_monitor_reset: std_logic;
	--  signal input_frame_detection: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  -- signal fifo_frame_detection:  std_logic_vector(0 to NUMBER_OF_INPUT_LANES-1);
	--  signal align_frame_detection: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal remap_frame_detection: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	----  signal output_frame_detection: std_logic_vector(0 to NUMBER_OF_OUTPUT_LANES - 1);
	--  signal align_fifo_overflow: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal align_fifo_overflow_sticky: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal missing_frame: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal missing_frame_sticky: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal discarded_data: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal discarded_data_sticky: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal bad_lane_sticky: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);
	--  signal bad_eof_sticky: std_logic_vector(0 to NUMBER_OF_INPUT_LANES - 1);

	--  signal frame_clk_sel: std_logic;
	--  signal align_reset: std_logic;
	--  signal remap_reset: std_logic;
	--  signal clk_ctr: unsigned(7 downto 0);
	--  -- signal frame_clk_ctr: unsigned(7 downto 0);
	--  -- signal frame_clk_dly: std_logic;
	--  signal align_reset_all: std_logic;

	--- Define Control word and its signals
	-- signal CONTROL_BYTES: slv8_array(0 to (2 + (NUMBER_OF_INPUT_LANES+1)/2 + 2)); -- default value set in the CMD_SLAVE
	-- signal STATUS_BYTES: slv8_array(0 to 14);

	-- signal capture_word_ctr: unsigned(7 downto 0);
	-- signal capture_word_number: unsigned(7 downto 0);
	-- signal capture_word_ctr_en: std_logic;
	-- signal capture_done: std_logic;
	-- signal capture_tdata: slv32;
	-- signal capture_tvalid:std_logic;
	-- signal capture_tlast:std_logic;


	-- signal delay_capture_word_ctr: u16_array(0 to 1);
	-- signal delay_capture_word_ctr_en: std_logic_vector(0 to 1);
	--  signal delay_capture_word_ctr: unsigned(15 downto 0);
	--  signal delay_capture_word_ctr_en: std_logic;
	--  signal delay_capture_word_ctr_arm: std_logic;

	--  signal delay_capture_ref_word_ctr: unsigned(15 downto 0);
	--  signal delay_capture_ref_word_ctr_en: std_logic;


	signal control_bytes: slv8_array(0 to 0); -- default value set in the CMD_SLAVE
	signal status_bytes: slv8_array(0 to 2);

begin

	ctrl_rst_proc: process(all) begin
		bsb_rst_reg <= bsb_rst when rising_edge(bsb_clk);
	end process;

	-- Pipeline corner-turn reset
	process(all) begin
		rst_reg <= rst when rising_edge(clk);
	end process;

	---------------------------------------------------------------------
	-- ROUTER
	---------------------------------------------------------------------
	-- Routes the commands and replies to/from the crossbar subsystems

	bsb_router0: entity work.bsb_router
		generic map (
			NUMBER_OF_PORTS => BSB_ROUTER_PORTS,
			ADDRESS_MASK    => "---11--------------" -- 4 ports max, 14-bit internal address range per port
		)
		port map (
			-- Upstream BSB interface
			s_axis_bsb_tdata => s_axis_bsb_tdata,
			s_axis_bsb_tvalid => s_axis_bsb_tvalid,
			s_axis_bsb_tlast => s_axis_bsb_tlast,
			s_axis_bsb_tready => s_axis_bsb_tready,
			m_axis_bsb_tdata => m_axis_bsb_tdata,
			m_axis_bsb_tvalid => m_axis_bsb_tvalid,
			m_axis_bsb_tlast => m_axis_bsb_tlast,
			m_axis_bsb_tready => m_axis_bsb_tready,

			-- Downstream BSB interface
			m_axis_routed_bsb_tdata => bct_router_bsb_cmd_tdata,
			m_axis_routed_bsb_tvalid => bct_router_bsb_cmd_tvalid,
			m_axis_routed_bsb_tlast => bct_router_bsb_cmd_tlast,
			m_axis_routed_bsb_tready => bct_router_bsb_cmd_tready,
			s_axis_routed_bsb_tdata => bct_router_bsb_rply_tdata,
			s_axis_routed_bsb_tvalid => bct_router_bsb_rply_tvalid,
			s_axis_routed_bsb_tlast => bct_router_bsb_rply_tlast,
			s_axis_routed_bsb_tready => bct_router_bsb_rply_tready,

			cmd_overflow => open,

			clk => bsb_clk,
			rst => bsb_rst_reg
		);


	---------------------------------------------------------------------
	-- CT1 CROSSBAR
	---------------------------------------------------------------------

	crossbar0_gen: if CT_LEVEL = 1 generate -- use hardwired crossbar
		--    constant IN_BITS_PER_BIN: integer  := INPUT_LANE_WIDTH / BINS_PER_INPUT_WORD; -- 32/2 = 16
		--    constant OUT_BITS_PER_BIN: integer := 4 + 4;
		--    constant CT1_OUTPUT_LANES: integer := BINS_PER_INPUT_WORD;
		constant NUMBER_OF_CB1_INPUT_LANES: integer := NUMBER_OF_INPUT_LANES;
		constant CB1_INPUT_LANE_WIDTH: integer := INPUT_LANE_WIDTH;

		constant CT1_OUTPUT_LANE_WIDTH: integer   := BITS_PER_OUTPUT_BIN * NUMBER_OF_INPUT_LANES; -- 8*16 = 128 bits/bin

		signal in_frame_ctr, out_frame_ctr: unsigned(7 downto 0);

		signal cb1_in_tdata: slv_array(0 to NUMBER_OF_CB1_INPUT_LANES - 1)(CB1_INPUT_LANE_WIDTH - 1 downto 0);
		signal cb1_in_tvalid: std_logic;
		signal cb1_in_tlast: std_logic;
		signal cb1_in_rst: std_logic;
		attribute shreg_extract of cb1_in_tdata, cb1_in_tvalid, cb1_in_tlast: signal is "no";
		attribute shreg_extract of cb1_in_rst: signal is "no";

		signal resetdone: std_logic;

	begin
		-- If we have CT_LEVEL=1, we perform a fixed wired internal corner-turn
		process(all)

			variable rchan, rbin: integer; -- reverse lane and bin numbers
			variable in_lsb, out_lsb: integer;

		begin
			if rising_edge(clk) then
				-- count CT1 input and output words
				in_frame_ctr  <= in_frame_ctr + 1 when s_axis_tvalid and s_axis_tlast;
				out_frame_ctr <= out_frame_ctr + 1 when m_axis_tvalid(0) and m_axis_tlast(0); -- all lanes carry identical strobes in the hardwired crossbar

				-- pipeline channelizer data
				-- This CT engine assumes that the channelizer data is aligned, i.e. all lanes share a common tvalid and tlast
				cb1_in_tdata  <= s_axis_tdata;
				cb1_in_tvalid <= s_axis_tvalid when not rst_reg else '0';
				cb1_in_tlast  <= s_axis_tlast;
				cb1_in_rst    <= rst_reg;

				-- Implement a hardwired CROSSBAR1.
				-- We take  the dana from NUMBER_OF_INPUT_LANES lanes, each word containing values from BINS_PER_INPUT_WORD different bins,
				-- and pack them in a single vector where data is grouped by bins (low bin on SB), each bin containing lanes (low lane on MSB),
				-- then each lane containing 4+4 bit real/Imag components (Re in MSB)
				for bin in 0 to BINS_PER_INPUT_WORD - 1 loop -- 0 to 3
					rbin := BINS_PER_INPUT_WORD - 1 - bin;

					for chan in 0 to NUMBER_OF_CB1_INPUT_LANES - 1 loop -- 0 to 7
					   rchan := NUMBER_OF_CB1_INPUT_LANES - 1 - chan; -- reverse input channel,  7 to 0
						for i in 0 to 1 loop -- real, im
    					   in_lsb := BITS_PER_INPUT_BIN * rbin + BITS_PER_INPUT_BIN / 2 * i;
    					   out_lsb := CT1_OUTPUT_LANE_WIDTH * rbin + BITS_PER_OUTPUT_BIN * rchan + BITS_PER_OUTPUT_BIN / 2 * i;
							m_axis_tdata(out_lsb + BITS_PER_OUTPUT_BIN / 2 - 1 downto out_lsb) <= cb1_in_tdata(chan)(in_lsb + BITS_PER_INPUT_BIN / 2 - 1 downto in_lsb + BITS_PER_INPUT_BIN / 2 - BITS_PER_OUTPUT_BIN / 2); -- take MSBs
						end loop;

					end loop;

				end loop;

				-- The hardwired crossbar produces all lanes in the same cycle: identical strobes on every lane.
				m_axis_tvalid <= (others => cb1_in_tvalid and not cb1_in_rst);
				m_axis_tlast <= (others => cb1_in_tlast);
			--        resetdone <= not cb1_in_rst;
			end if; -- clk
		end process;

	else generate -- if CT_LEVEL >=2, we implement the three crossbars and BP_SHUFFLE


		--     signal axis_bp_shuffle_bypass: std_logic;
		constant NUMBER_OF_CB1_INPUT_LANES: integer := NUMBER_OF_INPUT_LANES;
		constant CB1_INPUT_LANE_WIDTH: integer := INPUT_LANE_WIDTH; -- hardcoded to slv32
		constant NUMBER_OF_CB1_OUTPUT_LANES: integer := NUMBER_OF_BP_PCB_SHUFFLE_LANES;
		constant CB1_OUTPUT_LANE_WIDTH: integer := CB1_INPUT_LANE_WIDTH; -- hardcoded to be equal to support bypass mode

		constant PCB_INDICES: integer_array := indices_of(LANE_TO_GROUP_MAP, 0); -- return a list of indices matching the target value
		constant PCB_LOW: integer := min(PCB_INDICES);
		constant PCB_HIGH: integer := max(PCB_INDICES);

		constant NUMBER_OF_CB2_INPUT_LANES: integer := NUMBER_OF_CB1_OUTPUT_LANES;
		constant CB2_INPUT_LANE_WIDTH: integer := CB1_OUTPUT_LANE_WIDTH;
		constant NUMBER_OF_CB2_OUTPUT_LANES: integer := NUMBER_OF_BP_QSFP_SHUFFLE_LANES;
		constant CB2_OUTPUT_LANE_WIDTH: integer := CB2_INPUT_LANE_WIDTH; -- hardcoded to be equal to support bypass mode

		constant QSFP_INDICES: integer_array := indices_of(LANE_TO_GROUP_MAP, 1); -- return a list of indices matching the target value
		constant QSFP_LOW: integer := min(QSFP_INDICES);
		constant QSFP_HIGH: integer := max(QSFP_INDICES);

		constant NUMBER_OF_CB3_INPUT_LANES: integer := NUMBER_OF_CB2_OUTPUT_LANES;
		constant CB3_INPUT_LANE_WIDTH: integer := CB2_OUTPUT_LANE_WIDTH;
		constant NUMBER_OF_CB3_OUTPUT_LANES: integer := NUMBER_OF_GPU_LINKS;
		constant CB3_OUTPUT_LANE_WIDTH: integer := CB3_INPUT_LANE_WIDTH; -- hardcoded to be equal to support bypass mode


		--------------------
		-- CB1 signals
		--------------------

		signal cb1_bsb_rst: std_logic;

		signal cb1_in_rst: std_logic;
		signal cb1_out_rst: std_logic;

		signal cb1_in_tdata_reg1: slv_array(0 to NUMBER_OF_CB1_INPUT_LANES - 1)(INPUT_LANE_WIDTH - 1 downto 0);
		signal cb1_in_tuser_reg1: slv_array(0 to NUMBER_OF_CB1_INPUT_LANES - 1)(3 downto 0);
		signal cb1_in_tvalid_reg1: std_logic;
		signal cb1_in_tlast_reg1: std_logic;
		attribute shreg_extract of cb1_in_tdata_reg1, cb1_in_tuser_reg1, cb1_in_tvalid_reg1, cb1_in_tlast_reg1: signal is "no";

		signal cb1_in_tdata_reg2: slv_array(0 to NUMBER_OF_CB1_INPUT_LANES - 1)(INPUT_LANE_WIDTH - 1 downto 0);
		signal cb1_in_tuser_reg2: slv_array(0 to NUMBER_OF_CB1_INPUT_LANES - 1)(3 downto 0);
		signal cb1_in_tvalid_reg2: std_logic;
		signal cb1_in_tlast_reg2: std_logic;
		attribute shreg_extract of cb1_in_tdata_reg2, cb1_in_tuser_reg2, cb1_in_tvalid_reg2, cb1_in_tlast_reg2: signal is "no";

		signal cb1_in_tdata_reg3: slv32_array(0 to NUMBER_OF_CB1_INPUT_LANES - 1);
		signal cb1_in_tuser_reg3: slv4_array(0 to NUMBER_OF_CB1_INPUT_LANES - 1);
		signal cb1_in_tvalid_reg3: std_logic;
		signal cb1_in_tlast_reg3: std_logic;
		attribute shreg_extract of cb1_in_tdata_reg3, cb1_in_tuser_reg3, cb1_in_tvalid_reg3, cb1_in_tlast_reg3: signal is "no";

		signal cb1_out_tdata: slv32_array(0 to NUMBER_OF_CB1_OUTPUT_LANES - 1);
		signal cb1_out_tvalid: std_logic_vector(0 to NUMBER_OF_CB1_OUTPUT_LANES - 1);
		signal cb1_out_tlast: std_logic_vector(0 to NUMBER_OF_CB1_OUTPUT_LANES - 1);

		-- PCB and QSFP lanes are concatenated into a single vector to be handled by a single xlink_array module.

		--------------------
		-- BP SHUFFLE signals
		--------------------

		signal bp_shuffle_bsb_rst: std_logic;

		signal bp_shuffle_in_tdata: slv32_array(0 to NUMBER_OF_SHUFFLE_LANES - 1);
		--    signal bp_shuffle_in_tdata64: slv64_array(0 to NUMBER_OF_SHUFFLE_LANES - 1);
		signal bp_shuffle_in_tvalid: std_logic_vector(0 to NUMBER_OF_SHUFFLE_LANES - 1);
		signal bp_shuffle_in_tlast: std_logic_vector(0 to NUMBER_OF_SHUFFLE_LANES - 1);
		signal bp_shuffle_in_rst: std_logic_vector(0 to NUMBER_OF_BP_PCB_SHUFFLE_LANES + NUMBER_OF_BP_QSFP_SHUFFLE_LANES - 1);
		signal bp_shuffle_in_rst_reg: std_logic;
		attribute shreg_extract of bp_shuffle_in_rst_reg: signal is "no";

		signal bp_shuffle_out_tdata: slv32_array(0 to NUMBER_OF_SHUFFLE_LANES - 1);
		signal bp_shuffle_out_tvalid: std_logic_vector(0 to NUMBER_OF_SHUFFLE_LANES - 1);
		signal bp_shuffle_out_tlast: std_logic_vector(0 to NUMBER_OF_SHUFFLE_LANES - 1);
		signal bp_shuffle_out_rst: std_logic;

		--------------------
		-- CB2 signals
		--------------------

		signal cb2_bsb_rst: std_logic;
		attribute shreg_extract of cb2_bsb_rst: signal is "no";

		signal cb2_out_rst: std_logic;

		signal cb1_in_rst_reg1, cb1_in_rst_reg2, cb1_in_rst_reg3: std_logic;

		signal cb2_in_reset: std_logic;
		signal cb2_in_reset_reg: std_logic;
		attribute shreg_extract of cb2_in_reset, cb2_in_reset_reg: signal is "no";

		signal cb2_in_tdata_reg: slv32_array(0 to NUMBER_OF_BP_PCB_SHUFFLE_LANES - 1);
		signal cb2_in_tvalid_reg: std_logic_vector(0 to NUMBER_OF_BP_PCB_SHUFFLE_LANES - 1);
		signal cb2_in_tlast_reg: std_logic_vector(0 to NUMBER_OF_BP_PCB_SHUFFLE_LANES - 1);
		attribute shreg_extract of cb2_in_tdata_reg, cb2_in_tvalid_reg, cb2_in_tlast_reg: signal is "no";

		signal cb2_in_tdata: slv32_array(0 to NUMBER_OF_BP_PCB_SHUFFLE_LANES - 1);
		signal cb2_in_tvalid: std_logic_vector(0 to NUMBER_OF_BP_PCB_SHUFFLE_LANES - 1);
		signal cb2_in_tlast: std_logic_vector(0 to NUMBER_OF_BP_PCB_SHUFFLE_LANES - 1);
		attribute shreg_extract of cb2_in_tdata, cb2_in_tvalid, cb2_in_tlast: signal is "no";

		signal cb2_out_tdata: slv32_array(0 to NUMBER_OF_BP_QSFP_SHUFFLE_LANES - 1);
		signal cb2_out_tvalid: std_logic_vector(0 to NUMBER_OF_BP_QSFP_SHUFFLE_LANES - 1);
		signal cb2_out_tlast: std_logic_vector(0 to NUMBER_OF_BP_QSFP_SHUFFLE_LANES - 1);
		attribute shreg_extract of cb2_out_tdata, cb2_out_tvalid, cb2_out_tlast: signal is "no";

		--------------------
		-- CB3 signals
		--------------------

		signal cb3_bsb_rst: std_logic;
		attribute shreg_extract of cb3_bsb_rst: signal is "no";

		signal cb3_in_rst: std_logic;
		signal cb3_out_rst: std_logic;
		attribute shreg_extract of cb3_in_rst, cb3_out_rst: signal is "no";

		signal cb3_in_tdata: slv32_array(0 to NUMBER_OF_BP_QSFP_SHUFFLE_LANES - 1);
		signal cb3_in_tvalid: std_logic_vector(0 to NUMBER_OF_BP_QSFP_SHUFFLE_LANES - 1);
		signal cb3_in_tlast: std_logic_vector(0 to NUMBER_OF_BP_QSFP_SHUFFLE_LANES - 1);
		attribute shreg_extract of cb3_in_tdata, cb3_in_tvalid, cb3_in_tlast: signal is "no";


		signal cb3_out_tdata: slv32_array(0 to NUMBER_OF_GPU_LINKS - 1);
		signal cb3_out_tvalid: std_logic_vector(0 to NUMBER_OF_GPU_LINKS - 1);
		signal cb3_out_tlast: std_logic_vector(0 to NUMBER_OF_GPU_LINKS - 1);
		attribute shreg_extract of cb3_out_tdata, cb3_out_tvalid, cb3_out_tlast: signal is "no";

	--        signal resetdone: std_logic;


	begin

		assert CB1_INPUT_LANE_WIDTH = 32 report "Crossbar1 supports only 32-bit inputs" severity failure;
		assert NUMBER_OF_CB3_OUTPUT_LANES = NUMBER_OF_OUTPUT_LANES report "The number of CB3 output lanes must match the number of 32-bit lanes in the output word" severity failure;

		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				cb1_bsb_rst  <= bsb_rst;
			end if;
		end process;

		-- Pipeline and connect the channelizer output to the 1st crossbar inputs.
		-- The pipelining is there to help meeting timing closure, as we need to route long distance from the channelizer to the first crossbar
		cb1_pipe_proc: process(all) begin
			if rising_edge(clk) then
				-- Pipeline 1
				-- pipeline channelizer data
				-- This CT engine assumes that the channelizer data is aligned, i.e. all lanes share a common tvalid and tlast
				cb1_in_tdata_reg1 <= s_axis_tdata;
				cb1_in_tuser_reg1 <= s_axis_tuser;
				cb1_in_tvalid_reg1 <= s_axis_tvalid when not rst_reg else '0';
				cb1_in_tlast_reg1 <= s_axis_tlast;
				cb1_in_rst_reg1 <= rst_reg;

				-- Pipeline 2
				cb1_in_tdata_reg2 <= cb1_in_tdata_reg1;
				cb1_in_tuser_reg2 <= cb1_in_tuser_reg1;
				cb1_in_tvalid_reg2 <= cb1_in_tvalid_reg1 when not cb1_in_rst_reg1 else '0';
				cb1_in_tlast_reg2 <= cb1_in_tlast_reg1;
				cb1_in_rst_reg2 <= cb1_in_rst_reg1;

				-- Pipeline 3
				-- for now convert from slv_array to slv32_array until we fix this
				for i in 0 to NUMBER_OF_CB1_INPUT_LANES - 1 loop
					cb1_in_tdata_reg3(i) <= cb1_in_tdata_reg2(i);
					cb1_in_tuser_reg3(i) <= cb1_in_tuser_reg2(i);
				end loop;

				cb1_in_tvalid_reg3 <= cb1_in_tvalid_reg2 when not cb1_in_rst_reg2 else '0';
				cb1_in_tlast_reg3 <= cb1_in_tlast_reg2;
				cb1_in_rst_reg3 <= cb1_in_rst_reg2;

				cb1_out_rst <= cb1_in_rst_reg3;
			end if; -- clk
		end process cb1_pipe_proc;

		-- Instantiate the CHAN crossbar, which includes:

		chan_crossbar0: entity work.chan_crossbar
			generic map (
				PLATFORM_TYPE            => PLATFORM_TYPE,  -- needed to select family-dependent FIFOs
				NUMBER_OF_INPUT_LANES  => NUMBER_OF_CB1_INPUT_LANES,
				NUMBER_OF_OUTPUT_LANES => NUMBER_OF_CB1_OUTPUT_LANES,
				BINSEL_PBLOCK_MAP      => (0 to 4 => 0, 5 to 8 => 1, 9 to 12 => 1, 13 to 15 => 0)
			)
			port map (
				-- Input stream from the channelizer (AXI4-streaming, non-blocking, on clk)
				s_axis_tuser  => cb1_in_tuser_reg3,
				s_axis_tvalid => cb1_in_tvalid_reg3,
				s_axis_tdata  => cb1_in_tdata_reg3,
				s_axis_tlast  => cb1_in_tlast_reg3,

				-- Output stream to the shuffle module (AXI4-streaming, non-blocking, on clk)
				m_axis_tdata  => cb1_out_tdata,
				m_axis_tvalid => cb1_out_tvalid,
				m_axis_tlast  => cb1_out_tlast,

				clk => clk,
				rst => cb1_in_rst_reg3,

				--            lane_monitor => debug2,

				-- Control interface (command and reply stream buses)
				s_axis_bsb_tdata => bct_router_bsb_cmd_tdata(BSB_CROSSBAR1_PORT),
				s_axis_bsb_tvalid => bct_router_bsb_cmd_tvalid(BSB_CROSSBAR1_PORT),
				s_axis_bsb_tlast => bct_router_bsb_cmd_tlast(BSB_CROSSBAR1_PORT),
				s_axis_bsb_tready => bct_router_bsb_cmd_tready(BSB_CROSSBAR1_PORT),
				m_axis_bsb_tdata => bct_router_bsb_rply_tdata(BSB_CROSSBAR1_PORT),
				m_axis_bsb_tvalid => bct_router_bsb_rply_tvalid(BSB_CROSSBAR1_PORT),
				m_axis_bsb_tlast => bct_router_bsb_rply_tlast(BSB_CROSSBAR1_PORT),
				m_axis_bsb_tready => bct_router_bsb_rply_tready(BSB_CROSSBAR1_PORT),
				bsb_clk      => bsb_clk,
				bsb_rst      => cb1_bsb_rst
			);


		---------------------------------------------------------------------
		-- BACKPLANE PCB and QSFP DATA LINKS
		---------------------------------------------------------------------
		-- Implements the GTX links to exchange the packetized data over to other boards on the backplane (over the backplane PCB links) or to boards on another crate (using the backplane QSFP links).

		process(all) begin
			if rising_edge(bsb_clk) then
				bp_shuffle_bsb_rst  <= bsb_rst;
			end if;
		end process;

		-- Pipeline the channelizer crossbar output to the backplane PCB shuffle input
		bp_proc: process(all) begin
			if rising_edge(clk) then
				bp_shuffle_in_rst <= (others => cb1_out_rst);
				bp_shuffle_in_rst_reg <= bp_shuffle_in_rst(0);
				bp_shuffle_out_rst <= bp_shuffle_in_rst_reg;

				-- Assign the CB1 output to the SHUFFLE input lanes corresponding to group 0 (PCB links)
				bp_shuffle_in_tdata(PCB_LOW to PCB_HIGH) <= cb1_out_tdata;
				bp_shuffle_in_tvalid(PCB_LOW to PCB_HIGH) <= cb1_out_tvalid and not bp_shuffle_in_rst(PCB_LOW to PCB_HIGH); -- we have a vector of resets to facilitate routing
				bp_shuffle_in_tlast(PCB_LOW to PCB_HIGH) <= cb1_out_tlast;

				bp_shuffle_in_tdata(QSFP_LOW to QSFP_HIGH) <= cb2_out_tdata;
				bp_shuffle_in_tvalid(QSFP_LOW to QSFP_HIGH) <= cb2_out_tvalid when not bp_shuffle_out_rst else (others => '0');
				bp_shuffle_in_tlast(QSFP_LOW to QSFP_HIGH) <= cb2_out_tlast;


				cb2_in_tdata  <= bp_shuffle_out_tdata(PCB_LOW to PCB_HIGH);
				cb2_in_tvalid <= bp_shuffle_out_tvalid(PCB_LOW to PCB_HIGH) when not bp_shuffle_out_rst else (others => '0');
				cb2_in_tlast  <= bp_shuffle_out_tlast(PCB_LOW to PCB_HIGH);

				cb3_in_tdata  <= bp_shuffle_out_tdata(QSFP_LOW to QSFP_HIGH); -- QSFP shuffle lanes are concatenated after PCB shuffle lanes
				cb3_in_tvalid <= bp_shuffle_out_tvalid(QSFP_LOW to QSFP_HIGH) when not bp_shuffle_out_rst else (others => '0');
				cb3_in_tlast  <= bp_shuffle_out_tlast(QSFP_LOW to QSFP_HIGH);

			end if;
		end process;

		bp_shuffle0: entity work.xglink_array -- use component instantiation to delay binding in this if-generate block and prevent errors
			generic map (
				LANE_TO_LINK_MAP   => LANE_TO_LINK_MAP,
				LANE_GROUP_MAP     => LANE_TO_GROUP_MAP, -- We cast to make sure the synthesizer can unambiguously determine the final type and infer the entity in case the entity file is not needed (if-generate is False) and not included in the project
				LANE_TO_QUAD_MAP   => LINK_TO_QUAD_MAP, -- Indicates which quad is associated each channel. The QUAD number is an integer between 0 and N-1, where N is the total number of quads used.
				QUAD_TO_REFCLK_MAP => QUAD_TO_REFCLK_MAP, -- Indicates which refclk is associated with each QUAD (N integers from 0 to NUMBER_OF_REFCLK-1).
				LINK_SPEED         => BP_LINK_SPEED, -- 0: 7.5 Gb/s (244 MHz word clock), 1: 10 Gb/s (322 MHz word clock)
				IMPLEMENT_RX       => TRUE,
				SIM                => FALSE
			)
			port map (
				tx_p     => tx_p,
				tx_n     => tx_n,
				rx_p     => rx_p,
				rx_n     => rx_n,
				refclk_p => refclk_p,
				refclk_n => refclk_n,

				-- TX user interface (AXI-Streaming, non-blocking, on clk_out)
				s_axis_tx_tdata  => bp_shuffle_in_tdata,
				s_axis_tx_tvalid => bp_shuffle_in_tvalid,
				s_axis_tx_tlast  => bp_shuffle_in_tlast,

				-- RX user interface (AXI-Streaming, non-blocking, on clk_out)
				m_axis_rx_tdata  => bp_shuffle_out_tdata,
				m_axis_rx_tvalid => bp_shuffle_out_tvalid,
				m_axis_rx_tlast  => bp_shuffle_out_tlast,

				clk_out => txclk_out, -- 244 or 322 MHz clock generated by the backplane shuffle transmitter from the reference clock. Must be used to clock all the Tx (slave) interface data.  There is one single clock per array.
				areset  => bp_shuffle_in_rst_reg,

				-- Clock monitoring ports
				refclk_div2 => refclk_div2, -- divided-by-two version of the 156.25 MHz reference clock fed to the QUAD PLL
				txclk_div2  => txclk_div2, -- divided-by-two version of the TX word clock, which is also clk_out

				-- Debug signals
				lane_monitor => open,

				-- User bypass control line
				-- bypass      => axis_bp_shuffle_bypass,

				-- Control and reply streams
				s_axis_bsb_tdata => bct_router_bsb_cmd_tdata(BSB_BP_SHUFFLE_PORT),
				s_axis_bsb_tvalid => bct_router_bsb_cmd_tvalid(BSB_BP_SHUFFLE_PORT),
				s_axis_bsb_tlast => bct_router_bsb_cmd_tlast(BSB_BP_SHUFFLE_PORT),
				s_axis_bsb_tready => bct_router_bsb_cmd_tready(BSB_BP_SHUFFLE_PORT),
				m_axis_bsb_tdata => bct_router_bsb_rply_tdata(BSB_BP_SHUFFLE_PORT),
				m_axis_bsb_tvalid => bct_router_bsb_rply_tvalid(BSB_BP_SHUFFLE_PORT),
				m_axis_bsb_tlast => bct_router_bsb_rply_tlast(BSB_BP_SHUFFLE_PORT),
				m_axis_bsb_tready => bct_router_bsb_rply_tready(BSB_BP_SHUFFLE_PORT),
				bsb_clk => bsb_clk,
				bsb_rst => bp_shuffle_bsb_rst
			);


		---------------------------------------------------------------------
		-- CROSSBAR 2
		---------------------------------------------------------------------

		-- pipeline the bsb resets
		process(all) begin
			if rising_edge(bsb_clk) then
				cb2_bsb_rst  <= bsb_rst;
			end if;
		end process;

		-- Pipeline the backplane PCB shuffle output to the shuffle crossbar input
		crossbar2_in_pipe_proc: process(all) begin
			if rising_edge(clk) then
				-- Pipeline resets
				cb2_in_reset <= bp_shuffle_out_rst;
				cb2_in_reset_reg <= cb2_in_reset;
				cb2_out_rst <= cb2_in_reset_reg;

				-- Pipeline data bus
				cb2_in_tdata_reg  <= cb2_in_tdata;
				cb2_in_tvalid_reg <= cb2_in_tvalid when not cb2_in_reset_reg else (others => '0');
				cb2_in_tlast_reg  <= cb2_in_tlast;
			end if;
		end process;

		crossbar2: entity work.shuffle_crossbar -- use component instantiation to delay binding in if-generate block and prevent errors during elaboration
			generic map (
				PLATFORM_TYPE                        => PLATFORM_TYPE,  -- needed to select family-dependent FIFOs
				NUMBER_OF_INPUT_LANES              => NUMBER_OF_BP_PCB_SHUFFLE_LANES, -- Number of input streams
				NUMBER_OF_OUTPUT_LANES             => NUMBER_OF_BP_QSFP_SHUFFLE_LANES, -- Number of output streams
				NUMBER_OF_OUTPUT_LANES_PER_BIN_SEL => 4,
				WORDS_PER_BIN_MAX                  => 4,  -- 1st crossbar outputs data for 16 channels max = 4 words
				BINS_PER_FRAME_MAX                 => 128, -- need 128 bins in case i'm in 16
				COMBINE_DATA_FLAGS                 => TRUE,
				SHUFFLE_FLAGS_MASK                 => slv32'(X"00070000") -- count errors from crossbar 2 only
			)
			port map (
				-- Non-blocking AXI-Streaming input
				s_axis_tdata  => cb2_in_tdata_reg,
				s_axis_tvalid => cb2_in_tvalid_reg,
				s_axis_tlast  => cb2_in_tlast_reg,
				-- s_axis_tready => axis_bp_crossbar2_in_tready,

				-- Non-blocking AXI-Streaming output
				m_axis_tdata  => cb2_out_tdata,
				m_axis_tvalid => cb2_out_tvalid,
				m_axis_tlast  => cb2_out_tlast,
				-- m_axis_tready => cb2_out_tready,

				clk => clk,
				rst => cb2_in_reset,

				--       align_pulse => debug1,
				-- Control interface (command and reply stream buses)
				s_axis_bsb_tdata => bct_router_bsb_cmd_tdata(BSB_CROSSBAR2_PORT),
				s_axis_bsb_tvalid => bct_router_bsb_cmd_tvalid(BSB_CROSSBAR2_PORT),
				s_axis_bsb_tlast => bct_router_bsb_cmd_tlast(BSB_CROSSBAR2_PORT),
				s_axis_bsb_tready => bct_router_bsb_cmd_tready(BSB_CROSSBAR2_PORT),
				m_axis_bsb_tdata => bct_router_bsb_rply_tdata(BSB_CROSSBAR2_PORT),
				m_axis_bsb_tvalid => bct_router_bsb_rply_tvalid(BSB_CROSSBAR2_PORT),
				m_axis_bsb_tlast => bct_router_bsb_rply_tlast(BSB_CROSSBAR2_PORT),
				m_axis_bsb_tready => bct_router_bsb_rply_tready(BSB_CROSSBAR2_PORT),
				bsb_clk      => bsb_clk,
				bsb_rst      => cb2_bsb_rst
			);


		---------------------------------------------------------------------
		-- CROSSBAR 3
		---------------------------------------------------------------------

		-- Pipeline the BSB reset
		process(all) begin
			if rising_edge(bsb_clk) then
				cb3_bsb_rst  <= cb2_bsb_rst;
			end if;
		end process;

		-- Pipeline the backplane PCB shuffle output to the shuffle crossbar input
		process(all)

			variable rlane, src_lsb, lsb: integer;

		begin
			if rising_edge(clk) then
				-- pipeline reset
				cb3_in_rst <= bp_shuffle_out_rst;
				cb3_out_rst <= cb3_in_rst;

				-- Assign outputs: pack the lanes (lane 0 at the MSBs) and pass each lane's own
				-- strobes. The CB3 bin selectors start their packets at different times (bin
				-- selector k waits for its first selected bin), so lane 0's strobes must not be
				-- used for the other lanes.
				for lane in 0 to NUMBER_OF_CB3_OUTPUT_LANES - 1 loop -- 0 to 7
                    rlane := NUMBER_OF_CB3_OUTPUT_LANES - 1 - lane;
                    lsb := CB3_OUTPUT_LANE_WIDTH * rlane;
					m_axis_tdata(lsb + CB3_OUTPUT_LANE_WIDTH - 1 downto lsb) <= cb3_out_tdata(lane);
					m_axis_tvalid(lane) <= cb3_out_tvalid(lane) and not cb3_out_rst;
					m_axis_tlast(lane) <= cb3_out_tlast(lane);
				end loop;
			end if; -- clk
		end process;


		crossbar3: entity work.shuffle_crossbar -- use component instantiation to delay binding in if-generate block and prevent errors during elaboration
			generic map (
				PLATFORM_TYPE                        => PLATFORM_TYPE,  -- needed to select family-dependent FIFOs
				NUMBER_OF_INPUT_LANES              => NUMBER_OF_CB3_INPUT_LANES, -- Number of input streams
				NUMBER_OF_OUTPUT_LANES             => NUMBER_OF_CB3_OUTPUT_LANES, -- Number of output streams
				NUMBER_OF_OUTPUT_LANES_PER_BIN_SEL => 1,
				COMBINE_DATA_FLAGS                 => FALSE,
				WORDS_PER_BIN_MAX                  => 16,
				BINS_PER_FRAME_MAX                 => 64,
				SHUFFLE_FLAGS_MASK                 => slv32'(X"70000700") -- Count errors from both crossbars. Use a qualified axpression to ensure type is known.

			)
			port map (
				-- Non-blocking AXI-Streaming input
				s_axis_tdata  => cb3_in_tdata,
				s_axis_tvalid => cb3_in_tvalid,
				s_axis_tlast  => cb3_in_tlast,
				-- s_axis_tready => axis_bp_crossbar2_in_tready,

				-- Non-blocking AXI-Streaming output
				m_axis_tdata  => cb3_out_tdata,
				m_axis_tvalid => cb3_out_tvalid,
				m_axis_tlast  => cb3_out_tlast,
				-- m_axis_tready => cb2_out_tready,

				clk => clk,
				rst => cb3_in_rst,

				-- Control interface (command and reply stream buses)
				s_axis_bsb_tdata => bct_router_bsb_cmd_tdata(BSB_CROSSBAR3_PORT),
				s_axis_bsb_tvalid => bct_router_bsb_cmd_tvalid(BSB_CROSSBAR3_PORT),
				s_axis_bsb_tlast => bct_router_bsb_cmd_tlast(BSB_CROSSBAR3_PORT),
				s_axis_bsb_tready => bct_router_bsb_cmd_tready(BSB_CROSSBAR3_PORT),
				m_axis_bsb_tdata => bct_router_bsb_rply_tdata(BSB_CROSSBAR3_PORT),
				m_axis_bsb_tvalid => bct_router_bsb_rply_tvalid(BSB_CROSSBAR3_PORT),
				m_axis_bsb_tlast => bct_router_bsb_rply_tlast(BSB_CROSSBAR3_PORT),
				m_axis_bsb_tready => bct_router_bsb_rply_tready(BSB_CROSSBAR3_PORT),
				bsb_clk      => bsb_clk,
				bsb_rst      => cb3_bsb_rst
			);

	end generate crossbar0_gen;

end architecture impl;

