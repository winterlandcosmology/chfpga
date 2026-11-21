----------------------------------------------------------------------------------
-- Company:  McGill University
-- Engineer: JF CLiche
--
-- Create Date: 09/16/2013 04: 48: 29 PM
-- Design Name:
-- Module Name: cge
-- Project Name: CHORD
-- Target Devices: Zynq Ultrascale+ RfSoC
-- Tool Versions: Vivado 2022.1 +
-- Description: Implements a 100G Ethernet interface.
--
--
----------------------------------------------------------------------------------


library IEEE;
use IEEE.std_logic_1164.ALL;
use IEEE.numeric_std.ALL;
use IEEE.std_logic_misc.ALL; -- for reduce functions

library UNISIM;
use UNISIM.VComponents.all;

Library xpm;
use xpm.vcomponents.all;

library work;
use work.chFPGA_Package.all;

--
-- Implements a 100G Ethernet interfaces that transmit the incoming data as UDP packets.
--
entity cge is
	generic (
		DEFAULT_MAC_SRC_ADDR: slv48  := X"005d03000000"; -- Source MAC Address to use for each link (Xilinx OUI)
		DEFAULT_MAC_DEST_ADDR: slv48 := X"FFFFFFFFFFFF"; -- Destination MAC address to use by each link. 0xFFFFFFFFFFFF means Ethernet broadcast.
		DEFAULT_IP_SRC_ADDR: slv32   := X"0AC00002"; -- Source IP address used by each link
		DEFAULT_IP_DEST_ADDR: slv32  := X"FFFFFFFF"; -- Default destination addres used by each link. If DEST_ADDR_MODE=1, the destination adress is determined by a combination of register values and lane number.
		DEFAULT_IP_DEST_PORT: slv16  := X"A028"; -- Destination port used by each lane

		BSB_ADDR_WIDTH: integer := 19; -- address bits of the commands that this module uses. The bits above (used by the command routers) are cleared.
		CMAC_IP: integer range 1 to 2 := 1; -- 100G MAC IP core to use: 1 = cmac_usplus_1, 2 = cmac_usplus_2 (the second hard MAC of the device, for a second link)
		IMPLEMENT_PACKET_GENERATOR: boolean := TRUE; -- if TRUE, the embedded packet generator will be implemented.
		SIM: boolean := FALSE
		);
	port (
		-- 100G Serial interface
		
		tx_p: out std_logic_vector(0 to 3);
		tx_n: out std_logic_vector(0 to 3);
		refclk_p: in std_logic; -- 156.250 reference clock input
		refclk_n: in std_logic;

		refclk_out: out std_logic; -- 156.25 MHz Reference clock output (buffered?)

		s_axis_tx_tdata: in std_logic_vector(255 downto 0) := (others => '0'); -- First byte to transmit is in in LSB (i.e first bit transmitted is bit 0)
		s_axis_tx_tvalid: in std_logic := '0';
		s_axis_tx_tlast: in std_logic := '0';
		clk: in std_logic; -- axis bus clock

		clk322_out: out std_logic; -- 322 MHz clock derived from 100G core. Clocks all user signals
		rst: in std_logic; -- synchrounous reset
		-- init_clk: in std_logic; -- continuous clock

		-- Control and reply streams
		s_axis_bsb_tdata: in std_logic_vector(7 downto 0) := (others => '0');
		s_axis_bsb_tvalid: in std_logic := '0';
		s_axis_bsb_tlast: in std_logic := '0';
		s_axis_bsb_tready: out std_logic;
		m_axis_bsb_tdata: out std_logic_vector(7 downto 0);
		m_axis_bsb_tvalid: out std_logic;
		m_axis_bsb_tlast: out std_logic;
		m_axis_bsb_tready: in std_logic := '0';
		bsb_clk: in std_logic := '0'; -- control clock
		bsb_rst: in std_logic := '0'

		-- areset: in std_logic -- asynchronous reset
	 );
end entity cge;

architecture impl of cge is

	-- Attribute definitions

	attribute ASYNC_REG: string;
	--- Constants

-- Signals


	signal control_bytes: slv8_array(0 to 20);
	signal status_bytes: slv8_array(0 to 6);

	signal tx_axis_tdata: std_logic_vector(511 downto 0);
	signal tx_axis_tvalid: std_logic;
	signal tx_axis_tlast: std_logic;
	signal tx_axis_tready: std_logic;
	signal tx_axis_tkeep: std_logic_vector(63 downto 0);

	signal gt_txp_out, gt_txn_out: std_logic_vector(3 downto 0);

	-- CMAC config port (bsb_regs 16-bit RAM): target selected by control byte 6
	constant CMAC_RAM_ADDR_WIDTH   : positive := 16;
	constant DRP_ADDR_WIDTH         : positive := 10; -- core and GT channel DRP
	constant CMN_DRP_ADDR_WIDTH     : positive := 16; -- GT common DRP
	constant NUM_GT_LANES          : positive := 4;

	-- control_bytes(6)(2:0) config_port_sel; (5:4) gt_lane_sel
	constant CMAC_PORT_CORE_DRP    : unsigned(2 downto 0) := "001";
	constant CMAC_PORT_GT_CMN_DRP  : unsigned(2 downto 0) := "010";
	constant CMAC_PORT_GT_CH_DRP   : unsigned(2 downto 0) := "011";

	signal ram_din      : std_logic_vector(15 downto 0);
	signal ram_dout     : std_logic_vector(15 downto 0);
	signal ram_addr     : std_logic_vector(CMAC_RAM_ADDR_WIDTH - 1 downto 0);
	signal ram_wr_en    : std_logic;
	signal ram_rd_en    : std_logic;
	signal ram_en       : std_logic;
	signal ram_dout_rdy : std_logic;

	signal cmac_config_port_sel : unsigned(2 downto 0);
	signal gt_lane_sel          : unsigned(1 downto 0);

	-- Shared DRP-style RAM beat to all CMAC config ports (16-bit data)
	signal drp_addr     : std_logic_vector(DRP_ADDR_WIDTH - 1 downto 0);
	signal cmn_drp_addr : std_logic_vector(CMN_DRP_ADDR_WIDTH - 1 downto 0);
	signal drp_din      : std_logic_vector(15 downto 0);
	signal drp_dout     : std_logic_vector(15 downto 0);
	signal drp_en       : std_logic;
	signal drp_we       : std_logic;
	signal drp_rdy      : std_logic;

	signal core_drp_dout : std_logic_vector(15 downto 0);
	signal core_drp_rdy  : std_logic;
	signal cmn_drp_dout  : std_logic_vector(15 downto 0);
	signal cmn_drp_rdy   : std_logic;
	signal gt_ch_drp_dout : slv_array(NUM_GT_LANES - 1 downto 0)(15 downto 0);
	signal gt_ch_drp_rdy  : std_logic_vector(NUM_GT_LANES - 1 downto 0);

	signal core_drp_en  : std_logic;
	signal cmn_drp_en   : std_logic;
	signal gt_ch_drp_en : std_logic_vector(NUM_GT_LANES - 1 downto 0);

	-- Per-lane GT PRBS / DFE fabric (latched from control bytes 7-8; channel DRP via BSB RAM)
	signal gt_rxdfelpmreset  : std_logic_vector(NUM_GT_LANES - 1 downto 0) := (others => '0');
	signal gt_rxprbscntreset : std_logic_vector(NUM_GT_LANES - 1 downto 0) := (others => '0');
	signal gt_rxprbssel      : std_logic_vector(4 * NUM_GT_LANES - 1 downto 0) := (others => '0');
	signal gt_txprbssel      : std_logic_vector(4 * NUM_GT_LANES - 1 downto 0) := (others => '0');
	signal gt_txdiffctrl     : std_logic_vector(5 * NUM_GT_LANES - 1 downto 0);
	signal gt_txprecursor    : std_logic_vector(5 * NUM_GT_LANES - 1 downto 0);
	signal gt_txpostcursor   : std_logic_vector(5 * NUM_GT_LANES - 1 downto 0);
	signal gt_rxlpmen        : std_logic_vector(NUM_GT_LANES - 1 downto 0);

	signal cmac_reset_tx_datapath: std_logic := '0';
	signal cmac_reset_rx_datapath: std_logic := '0';
	signal cmac_sys_reset: std_logic := '0';
	signal cmac_core_tx_reset: std_logic := '0';

	signal ctl_tx_enable: std_logic;
	signal ctl_tx_rsfec_enable: std_logic;
	signal ctl_tx_send_idle: std_logic;
	signal ctl_tx_send_rfi: std_logic;
	signal ctl_tx_send_lfi: std_logic;
	signal ctl_tx_test_pattern: std_logic;
	signal clk_out_int: std_logic;
	signal gt_ref_clk_out: std_logic;

	signal clk_out_div2_int: std_logic;
	signal refclk_div2_int: std_logic;

	signal refclk_out_int: std_logic;
	signal usr_tx_reset: std_logic; -- registered CMAC reset output
	signal usr_tx_reset_pre: std_logic;  -- non-registered version of the CMAC usr_tx_rst

	signal tx_gt_locked_led: std_logic;

	signal tx_preamblein: std_logic_vector(55 downto 0) := (others => '0');

	signal tx_ovfout: std_logic;
	signal tx_unfout: std_logic;
	signal tx_ovfout_sticky: std_logic;
	signal tx_unfout_sticky: std_logic;

	-- Data FIFO signals
	signal fifo_srst: std_logic := '1'; -- init for sims
	signal fifo_din: std_logic_vector(256 + 2 - 1 downto 0);
	signal fifo_wr_en: std_logic := '0'; -- init for sims
	signal fifo_rd_en: std_logic;
	signal fifo_dout: std_logic_vector(512 + 4 - 1 downto 0);
	signal fifo_full: std_logic;
	signal fifo_overflow: std_logic;
	signal fifo_overflow_sticky: std_logic;
	signal fifo_empty: STD_LOGIC;
	signal fifo_valid: std_logic;
	signal fifo_almost_full: std_logic;
	signal fifo_almost_full_reg: std_logic;
	signal fifo_wr_rst_busy: std_logic;
	signal fifo_rd_rst_busy: std_logic;


	-- Flag FIFO signals
	signal flag_fifo_wr_en: std_logic;
	signal flag_fifo_overflow: std_logic;
	signal flag_fifo_overflow_sticky: std_logic;
	signal flag_fifo_full: std_logic;
	signal flag_fifo_rd_en: std_logic;
	signal flag_fifo_valid: std_logic;

	signal tx_reset_done: std_logic;

	-- temporary signals
	signal axis_tx_tdata: std_logic_vector(255 downto 0); -- First byte to transmit is in in LSB (i.e first bit transmitted is bit 0)
	signal axis_tx_tvalid: std_logic := '0';
	signal axis_tx_tlast: std_logic := '0';

	signal axis_pktgen_tdata: std_logic_vector(255 downto 0);
	signal axis_pktgen_tvalid: std_logic := '0';
	signal axis_pktgen_tlast: std_logic := '0';

	signal number_of_udp_words: unsigned(7 downto 0); -- 32-byte words, not including the padding
	signal packet_spacing_in_words: unsigned(15 downto 0);
	signal enable_packet_generator: std_logic;
	signal enable_packet_generator_reg: std_logic;
	signal in_frame_ctr: unsigned(7 downto 0);
	signal out_frame_ctr: unsigned(7 downto 0);
	signal packet_length: unsigned(15 downto 0);
	signal capture_byte_number: unsigned(15 downto 0);
	signal capture_byte: std_logic_vector(7 downto 0);
	signal capture_tlast: std_logic;

begin
	clk322_out <= clk_out_int;
	refclk_out <= refclk_out_int;
	tx_p <= reverse_bits_and_dir(gt_txp_out);
	tx_n <= reverse_bits_and_dir(gt_txn_out);

	-- CONTROL Byte 0

	cmac_reset_tx_datapath <= control_bytes(0)(0);
	cmac_reset_rx_datapath <= control_bytes(0)(1);
	cmac_sys_reset <= control_bytes(0)(2);
	cmac_core_tx_reset <= control_bytes(0)(3);
	ctl_tx_rsfec_enable <= control_bytes(0)(4);

	enable_packet_generator <= control_bytes(0)(7);
	-- CONTROL Byte 1
	number_of_udp_words <= unsigned(control_bytes(1));

	-- CONTROL Byte 2-3
	packet_spacing_in_words <= to_unsigned(control_bytes(2 to 3));

	-- CONTROL Byte 4-5
	capture_byte_number <= to_unsigned(control_bytes(4 to 5));


	-- CONTROL Byte 6: GT lane select and BSB RAM/DRP port target
	gt_lane_sel            <= unsigned(control_bytes(6)(5 downto 4));
	cmac_config_port_sel   <= unsigned(control_bytes(6)(2 downto 0));

	-- CONTROL Byte 6: PRBS / DFE controls
	gt_ctl_store_proc: process(bsb_clk) is
		variable lane : integer range 0 to NUM_GT_LANES - 1;
	begin
		if rising_edge(bsb_clk) then
			lane := to_integer(gt_lane_sel);
			gt_rxdfelpmreset(lane)  <= control_bytes(7)(7);
			gt_rxprbscntreset(lane) <= control_bytes(7)(6);
			gt_txprbssel(4 * lane + 3 downto 4 * lane) <= '0' & control_bytes(7)(5 downto 3);
			gt_rxprbssel(4 * lane + 3 downto 4 * lane) <= '0' & control_bytes(7)(2 downto 0);
		end if;
	end process gt_ctl_store_proc;

	-- CONTROL Bytes 8-19: per-lane TX driver settings (GTY async ports, UG578 Table 3-35). Dedicated bytes per lane,
	-- not muxed by gt_lane_sel. Reset value: swing code 24 = 950 mV, pre-cursor code 8 = 1.87 dB, post-cursor code 15 = 3.99 dB (site tests).
	gt_tx_drive_gen: for i in 0 to NUM_GT_LANES - 1 generate
		gt_txdiffctrl(5 * i + 4 downto 5 * i)   <= control_bytes(8 + 3 * i)(4 downto 0);
		gt_txprecursor(5 * i + 4 downto 5 * i)  <= control_bytes(9 + 3 * i)(4 downto 0);
		gt_txpostcursor(5 * i + 4 downto 5 * i) <= control_bytes(10 + 3 * i)(4 downto 0);
	end generate gt_tx_drive_gen;

	-- CONTROL Byte 20 bits 3:0: RX equalizer mode per lane (GTY RXLPMEN, UG578). 0 = DFE (reset value, previous tie-off),
	-- 1 = LPM. After a change, pulse the RX equalizer reset of that lane (byte 7 bit 7, RXDFELPMRESET).
	gt_rxlpmen <= control_bytes(20)(NUM_GT_LANES - 1 downto 0);

	---- STATUS Byte 0

	status_bytes(0) <= (
		0 => tx_gt_locked_led,
		1 => tx_ovfout_sticky,
		2 => tx_unfout_sticky,
		3 => fifo_overflow_sticky,
		4 => flag_fifo_overflow_sticky,
		5 => capture_tlast, -- will always read 0
		6 => rst,
		7 => usr_tx_reset -- reset signal from CMAC
		);

	---- STATUS Byte 1-2
	status_bytes(1) <= std_logic_vector(in_frame_ctr);
	status_bytes(2) <= std_logic_vector(out_frame_ctr);

	---- STATUS Byte 3-4
	status_bytes(3 to 4) <= to_slv8_array(packet_length);

	status_bytes(5) <= capture_byte;

	-- STATUS Byte 6: active config port and GT lane (shadow of control byte 6)
	status_bytes(6)(2 downto 0) <= std_logic_vector(cmac_config_port_sel);
	status_bytes(6)(5 downto 4) <= std_logic_vector(gt_lane_sel);
	status_bytes(6)(7 downto 6) <= (others => '0');

	-- Memory Map
	-- ------------------------------------------------------------------------------
	-- |  Page   | Addr|Bit(s)|     Name             | Description                   |
	-- |---------|-----|------|----------------------|-------------------------------|
	-- | CONTROL |  0  |  0   | cmac_reset_tx_datapath | Reset CMAC TX datapath |
	-- |         |     |  1   | cmac_reset_rx_datapath | Reset CMAC RX datapath |
	-- |         |     |  2   | cmac_sys_reset         | CMAC system reset |
	-- |         |     |  3   | cmac_core_tx_reset     | CMAC core TX reset |
	-- |         |     |  4   | ctl_tx_rsfec_enable     | RS-FEC enable (fabric) |
	-- |         |     |  5   | (unused)                |                               |
	-- |         |     |  6   | (unused)                |                               |
	-- |         |     |  7   | enable_packet_generator | Enable packet generator |
	-- |         |  1  | 7:0  | number_of_udp_words     | Number of UDP words |
	-- |         | 2-3 |15:0  | packet_spacing_in_words | Packet spacing in words (16 bits) |
	-- |         | 4-5 |15:0  | capture_byte_number     | Capture byte number (16 bits) |
	-- |         |  6  | 5:4  | gt_lane_sel             | GT lane for byte 7 and GT channel DRP |
	-- |         |     | 2:0  | config_port_sel         | BSB RAM target (1=core DRP,2=GT cmn,3=GT ch DRP+lane) |
	-- |         | 7    | 7  | gt_prbs_fabric_reset    | PRBS / DFE reset (per lane) |
	-- |         |      | 6    | gt_rxprbscntreset       | PRBS counter reset (active lane) |
	-- |         |      | 5:3  | gt_txprbssel            | PRBS TX select (active lane) |
	-- |         |      | 2:0  | gt_rxprbssel            | PRBS RX select (active lane) |
	-- |         | 8+3i | 4:0 | gt_txdiffctrl (lane i)  | TX swing, lane i=0-3 (0 = 390 mV ... 31 = 1040 mV; reset 24 = 950 mV) |
	-- |         | 9+3i | 4:0 | gt_txprecursor (lane i) | TX pre-cursor emphasis, lane i=0-3 (0 = none; reset 8 = 1.87 dB) |
	-- |         |10+3i | 4:0 | gt_txpostcursor (lane i)| TX post-cursor emphasis, lane i=0-3 (0 = none; reset 15 = 3.99 dB) |
	-- |         | 20   | 3:0 | gt_rxlpmen (bit i = lane i) | RX equalizer mode: 0 = DFE, 1 = LPM |
	-- | STATUS  |  0  |  0   | tx_gt_locked_led        | TX GT locked LED |
	-- |         |     |  1   | tx_ovfout_sticky        | TX overflow output sticky |
	-- |         |     |  2   | tx_unfout_sticky        | TX underflow output sticky |
	-- |         |     |  3   | fifo_overflow_sticky    | FIFO overflow sticky |
	-- |         |     |  4   | flag_fifo_overflow_sticky | Flag FIFO overflow sticky |
	-- |         |     |  5   | capture_tlast           | Capture TLAST (always reads 0) |
	-- |         |     |  6   | rst                     | Reset status |
	-- |         |     |  7   | usr_tx_reset            | User TX reset (from CMAC) |
	-- |         |  1  | 7:0  | in_frame_ctr            | Input frame counter |
	-- |         |  2  | 7:0  | out_frame_ctr           | Output frame counter |
	-- |         | 3-4 |15:0  | packet_length            | Packet length (16 bits) |
	-- |         |  5  | 7:0  | capture_byte            | Capture byte |
	-- |         |  6  | 5:4  | gt_lane_sel             | Active GT lane (readback) |
	-- |         |     | 2:0  | config_port_sel         | Active RAM target (readback) |
	-- | RAM     |  *   | -    | ram_offset              | Offset within selected port (16-bit RAM beats). Port: 1=core DRP, 2=GT common DRP, 3=GT channel DRP (lane from byte 6) |
	-- ------------------------------------------------------------------------------

	bsb_regs0: entity work.bsb_regs
		generic map (
			DEFAULT_CONTROL_BYTES => X"00_11_0020_0000_00_00" & X"18080F_18080F_18080F_18080F" & X"00", -- bytes 8-19 (TX drive, swing/pre/post per lane): 950 mV, pre 1.87 dB, post 3.99 dB; byte 20 = 0: DFE
			ADDR_WIDTH => BSB_ADDR_WIDTH,
			USE_RAM_DOUT_RDY => TRUE,
			USE_PIPELINED_RAM_WRITE => FALSE,
			RAM_DATA_WIDTH => 16,
			RAM_ADDR_WIDTH => CMAC_RAM_ADDR_WIDTH,
			NUMBER_OF_CONTROL_BYTES => control_bytes'Length(1),
			NUMBER_OF_STATUS_BYTES => status_bytes'Length(1)
		)
		port map (
			s_axis_bsb_tdata => s_axis_bsb_tdata,
			s_axis_bsb_tvalid => s_axis_bsb_tvalid,
			s_axis_bsb_tlast => s_axis_bsb_tlast,
			s_axis_bsb_tready => s_axis_bsb_tready,
			m_axis_bsb_tdata => m_axis_bsb_tdata,
			m_axis_bsb_tvalid => m_axis_bsb_tvalid,
			m_axis_bsb_tlast => m_axis_bsb_tlast,
			m_axis_bsb_tready => m_axis_bsb_tready,
			bsb_clk          => bsb_clk,
			bsb_rst          => bsb_rst,
			control_bytes => control_bytes,
			status_bytes  => status_bytes,
			RAM_DIN      => ram_din,
			RAM_DOUT     => ram_dout,
			RAM_DOUT_RDY => ram_dout_rdy,
			RAM_WR_EN    => ram_wr_en,
			RAM_RD_EN    => ram_rd_en,
			RAM_EN       => ram_en,
			RAM_ADDR     => ram_addr
		);

	-- Route bsb_regs RAM port per control_bytes(6)(2:0) (config_port_sel)
	drp_en       <= ram_en;
	drp_we       <= ram_wr_en;
	drp_din      <= ram_din;
	drp_addr     <= ram_addr(DRP_ADDR_WIDTH - 1 downto 0);
	cmn_drp_addr <= ram_addr(CMN_DRP_ADDR_WIDTH - 1 downto 0);

	core_drp_en  <= drp_en when cmac_config_port_sel = CMAC_PORT_CORE_DRP else '0';
	cmn_drp_en   <= drp_en when cmac_config_port_sel = CMAC_PORT_GT_CMN_DRP else '0';
	gt_ch_drp_en_gen: for i in 0 to NUM_GT_LANES - 1 generate
		gt_ch_drp_en(i) <= drp_en when cmac_config_port_sel = CMAC_PORT_GT_CH_DRP and gt_lane_sel = to_unsigned(i, gt_lane_sel'length) else '0';
	end generate gt_ch_drp_en_gen;

	ram_dout_rdy <= drp_rdy;
	ram_dout     <= drp_dout;

	config_port_mux: process(all) begin
		case cmac_config_port_sel is
			when CMAC_PORT_CORE_DRP =>
				drp_dout <= core_drp_dout;
				drp_rdy  <= core_drp_rdy;
			when CMAC_PORT_GT_CMN_DRP =>
				drp_dout <= cmn_drp_dout;
				drp_rdy  <= cmn_drp_rdy;
			when CMAC_PORT_GT_CH_DRP =>
				drp_dout <= gt_ch_drp_dout(to_integer(gt_lane_sel));
				drp_rdy  <= gt_ch_drp_rdy(to_integer(gt_lane_sel));
			when others =>
				drp_dout <= (others => '0');
				drp_rdy  <= drp_en and not drp_we;
		end case;
	end process config_port_mux;

-- The ``flag_fifo`` is a 1-bit x 16  asynchronous distributed-RAM FIFO. A '0' is pushed in the FIFO
-- to indicate that a packet is complete in the data FIFO.
flag_fifo0: xpm_fifo_async
    generic map (
		FIFO_MEMORY_TYPE    => "dist", -- String
		READ_MODE           => "fwft",         -- String
		FIFO_READ_LATENCY   => 0,     -- must be 0 for READ_MODE=fwft
		WRITE_DATA_WIDTH    => 1,     -- DECIMAL
		FIFO_WRITE_DEPTH    => 16,   --
		READ_DATA_WIDTH     => 1,      -- DECIMAL
		FULL_RESET_VALUE    => 0,      -- DECIMAL
		SIM_ASSERT_CHK      => 1,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
		USE_ADV_FEATURES    => "1001", -- bit [0: overflow], [1: prog_full], 2: wr_count, 3: almost_full, 8: underflow, 9: prog_empty, 10: rd_count, 11: almost_empty, [12: valid]
		WR_DATA_COUNT_WIDTH => 11    -- Not needed
    )
    port map (

       rst => fifo_srst,               -- Reset, synchronous to wr_clk.

       -- Write domain
       wr_clk => clk,                  -- Write clock
       din => "0",                -- Write Data:
       wr_en => flag_fifo_wr_en,            -- Write Enable: Must be held active-low when rst or wr_rst_busy is active high.
       full => flag_fifo_full,              -- Full Flag:  Write requests are ignored when the FIFO is full.
       overflow => flag_fifo_overflow,      -- Overflow: This signal indicates that a write request was rejected because fifo was FULL

        -- Read domain
       rd_clk => clk_out_int,          -- Read clock
       rd_en => flag_fifo_rd_en,            -- 1-bit input: Read Enable: Must be held low when rd_rst_busy is active high.
       dout => open,              -- Read Data
       data_valid => flag_fifo_valid,       -- Read Data Valid: High when data is available on dout.
       empty => open,            -- Empty Flag: High when FIFO is empty. Read requests are ignored.

       injectdbiterr => '0', -- Double Bit Error Injection: Injects a double bit error
       injectsbiterr => '0', -- Single Bit Error Injection: Injects a single bit error
       sleep => '0'         -- Dynamic power saving: If sleep is High, the memory/fifo block is in power saving mode.
    );

-- Independent clock Builtin FWFT FIFO, 288-bit input data width, 576-bit output data width, with output register, latency=0 on USP
-- Prog full must be < MAX_DEPTH-2 to compensate for the delayed prog_full signal.
-- We need 8 RAMB36 minimum because the output width of each BRAM is 72 bits max. Each BRAM is 36-bit x 1k.
-- Total memory is 8*4kbytes = 32 kBytes minimum.
-- We to store 1 full frame (8k), plus a little additional space to store the next incoming frame while the first one is sent out.
-- So we have too much memory, but we can't make it smaller due to the wide output width.
--
-- The speed of the FIFO seems to be limited by the fact that  it combinatorially combines the FULL signals of every cell to gate WR_EN, and the PROG_FULL is a "or" combination of PROG_FULL from every cell, as is the EMPTY signal (which generates VALID).
-- This is probably because this is an async FIFO, and not all cells might capture the data on the same clock, so we use the worst of all cell.
--
-- FIFO is (256+2)x1024 in, (512+4)x512 out, implemented as 8xRAMB36. We need to use at least 8xRAMB36 to acheive the output bus width (512 bits + 2 TVALID + 2 TLAST). 72bits*8 = 576 bits.
data_fifo0: xpm_fifo_async
    generic map (
       READ_MODE => "fwft",         -- String
       FIFO_READ_LATENCY => 0,     -- must be 0 for READ_MODE=fwft
       WRITE_DATA_WIDTH => 256 + 2,     -- DECIMAL
       FIFO_WRITE_DEPTH => 1024,   -- Write: 256+2 x 1024, Read: 512+2 x 512  (8x RAMB36)
       READ_DATA_WIDTH => 512 + 4,      -- DECIMAL
       FULL_RESET_VALUE => 0,      -- DECIMAL
       PROG_FULL_THRESH => 1017,     -- Value must be between 9 and 1017
       SIM_ASSERT_CHK => 1,        -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
       USE_ADV_FEATURES => "1003", -- bit [0: overflow], [1: prog_full], 2: wr_count, 3: almost_full, 8: underflow, 9: prog_empty, 10: rd_count, 11: almost_empty, [12: valid]
       WR_DATA_COUNT_WIDTH => 11    -- Not needed
    )
    port map (

       rst => fifo_srst,               -- Reset, synchronous to wr_clk.

       -- Write domain
       wr_clk => clk,                   -- Write clock
       din => fifo_din,                 -- Write Data:
       wr_en => fifo_wr_en,             -- Write Enable: Must be held active-low when rst or wr_rst_busy is active high.
       full => fifo_full,               -- Full Flag:  Write requests are ignored when the FIFO is full.
       prog_full => fifo_almost_full,   -- Programmable Full: asserted when the number of words in the FIFO is greater than or equal to the programmable full threshold
       overflow => fifo_overflow,       -- Overflow: This signal indicates that a write request was rejected because fifo was FULL
       wr_rst_busy => fifo_wr_rst_busy, -- Write Reset Busy: Active-High indicator that the FIFO write domain is currently in a reset state.
    --   almost_full => fifo_almost_full, -- Asserted when the FIFO is one write from FULL

        -- Read domain
       rd_clk => clk_out_int,           -- Read clock
       rd_en => fifo_rd_en,             -- 1-bit input: Read Enable: Must be held low when rd_rst_busy is active high.
       dout => fifo_dout,               -- Read Data
       data_valid => fifo_valid,        -- Read Data Valid: High when data is available on dout.
       empty => fifo_empty,             -- Empty Flag: High when FIFO is empty. Read requests are ignored.
    --   almost_empty => almost_empty,  -- Almost Empty: Asserted when there is only one more read before EMPTY.
    --   prog_empty => prog_empty,      -- Programmable Empty: High when number of words in the FIFO is less than or equal to the empty threshold value.
       rd_rst_busy => fifo_rd_rst_busy, -- Read Reset Busy: Active-High indicator that the FIFO read domain is currently in a reset state.

       injectdbiterr => '0', -- Double Bit Error Injection: Injects a double bit error
       injectsbiterr => '0', -- Single Bit Error Injection: Injects a single bit error
       sleep => '0'         -- Dynamic power saving: If sleep is High, the memory/fifo block is in power saving mode.
    );
-- fifo_din(287 downto 258) <= (others => '0'); -- don't leave the unused FIFO data inputs floating: critical warnings

fifo_wr_block: block
	signal is_high_word: std_logic;
	signal was_tlast: std_logic;
	signal usr_tx_reset_resync: std_logic;
	signal word_ctr: unsigned(15 downto 0);
begin
	-- Place incoming bytes on the fifo data bus
	fifo_din(255 downto 0) <= axis_tx_tdata;
	-- save the tlast and tvalid flags
	fifo_din(256 + 0) <= axis_tx_tlast;
	fifo_din(256 + 1) <= axis_tx_tvalid; -- we store tvalid because we might have dummy writes
	-- generate the fifo write signal.
	--  We force a dummy write if the low word is tlast to make sure to complete the 64-byte output word.
	-- Otherwise a packet with an odd number of 32-bytes words would not start transmitting until the beginning of the next packet.
	-- As a (maybe unnecessary) protection, we stop writing in the data FIFO if it is almost full, except for the tlast word so we don't desynchronize with the flag fifo
	fifo_wr_en <= (axis_tx_tvalid or (is_high_word and was_tlast)) and (not fifo_almost_full_reg or axis_tx_tlast) and tx_reset_done;
	-- We indicate we have a complete packet as soon as we get a valid tlast.
	-- If the last word is on the low word, the last word will be delayed until the dummy word is sent on the next clock,
	-- so don't assume that valid on the flags fifo means valid data on the data fifo.
	flag_fifo_wr_en <= axis_tx_tvalid and axis_tx_tlast and tx_reset_done;


	-- Synchronize the manual trigger signal to the 10 MHz clock
	man_trig_cdc0: xpm_cdc_single
		generic map (
			SRC_INPUT_REG => 0
		)
		port map (
			src_in => usr_tx_reset,
			src_clk => '0',
			dest_clk => clk,
			dest_out => usr_tx_reset_resync
		);

	fifo_wr_proc: process(all)
		variable byte: integer;
	begin
		if rising_edge(clk) then

			-- register the almost_full flag to cut down the combinatorial path between the FIFO output (almost_full) all the way back into the FIFO input (fifo_wr_en).
			-- The generated FIFO core combinatorially "or" the prog_full from all BRAMs internally
			-- In addition to this, the wr_en is combinatorially contitional to all 8 "full" flags.
			-- Thise causes long tracks (from top to bottom) and 4-deep combinatorial logic, which makes it hard to meet timing at 375 MHz.
			--
			-- Since the almost_full signal arrives late, we configure the RAM to trigger it at DEPTH-2 or before so we will always have room to write the TLAST word.
			fifo_almost_full_reg <= fifo_almost_full;

			fifo_srst <= '0';
			if usr_tx_reset_resync or rst then -- need to resync to clk
				fifo_srst <= '1';
				tx_reset_done <= '0'; -- this stops writing to both FIFOs
			end if;

			-- Implement a tx_reset_done signal that is '1' when we are ready to write to the FIFO.
			-- We wait for BOTH the data FIFO to be ready. The data FIFO has ot sone rst_done signal.
			-- The only way to tell when the flag fifo is ready is to look at the full signal going low after a reset.
			if not tx_reset_done and not flag_fifo_full and not fifo_wr_rst_busy then
				tx_reset_done <= '1';
			end if;

			-- Generate sticky overflow signals
			fifo_overflow_sticky <= '1' when fifo_almost_full_reg;
			flag_fifo_overflow_sticky <= '1' when flag_fifo_overflow;



			enable_packet_generator_reg <= enable_packet_generator; -- pipeline
			-- Source selection
			if IMPLEMENT_PACKET_GENERATOR and enable_packet_generator_reg = '1' then -- use packet generator data
				axis_tx_tdata <= axis_pktgen_tdata;
				axis_tx_tvalid <= axis_pktgen_tvalid;
				axis_tx_tlast <= axis_pktgen_tlast;
			else -- use external bus
				axis_tx_tdata <= s_axis_tx_tdata;
				axis_tx_tvalid <= s_axis_tx_tvalid;
				axis_tx_tlast <= s_axis_tx_tlast;
			end if; -- source select

			if axis_tx_tvalid then
				was_tlast <= axis_tx_tlast;
				word_ctr <= word_ctr + 1;
				if word_ctr = capture_byte_number(15 downto 5) then
					byte := to_integer(not capture_byte_number(4 downto 0));
					capture_byte <= axis_tx_tdata(8 * byte + 7 downto 8 * byte);
					capture_tlast <= axis_tx_tlast;
				end if;
				if axis_tx_tlast then
					in_frame_ctr <= in_frame_ctr + 1;
					packet_length <= word_ctr;
					word_ctr <= (others => '0');
				end if;
			end if;

			if fifo_wr_en and not fifo_full then -- don't toggle is_high_word if the write did not take place
				is_high_word <= not is_high_word;
			end if;

			-- Reset
			if not tx_reset_done then -- if reset in in progress
				is_high_word <= '0';
				in_frame_ctr <= (others => '0');
				fifo_overflow_sticky <= '0';
				word_ctr <= (others => '0');
				flag_fifo_overflow_sticky <= '0';
			end if;


		end if; -- clk
	end process fifo_wr_proc;
end block fifo_wr_block;


-------------------------------------------
-- Packet Generator
-------------------------------------------
pkt_gen_gen: if IMPLEMENT_PACKET_GENERATOR generate
	-- TX state machine states
	TYPE TX_STATE_TYPE IS (
		INIT,
		SEND_HEADER1,
		SEND_HEADER2,
		SEND_DATA,
		SEND_NOTHING
	);

	signal tx_state: TX_STATE_TYPE;
	signal word_ctr: unsigned(15 downto 0);
	signal tdata: std_logic_vector(255 downto 0);
	signal frame_ctr: unsigned(63 downto 0);
	signal udp_payload_length: unsigned(15 downto 0);
	signal ip_packet_length: unsigned(15 downto 0);


	-- Compute the IP header checksum, which is the 1's complement of the 1's complement sum of all 16-bit words in the IP header, assuming the checsum field itself is zero.
	-- 1's complement sum means we add the carry back to the sum (e.g 0 + 1:  0xFFFF+0x0001 = 0x10000 = 0x0001 or 0x0000+0x0001=0x00001=0x0001)
	function compute_ip_checksum(ip_header: std_logic_vector(20 * 8 - 1 downto 0)) return std_logic_vector is
	    variable sum: unsigned(19 downto 0) := (others => '0'); -- we add 16  16-bit words, so we can have up to 4-bits of overflow
	begin
	    for i in 0 to 9 loop -- just cover the IP header words
	        sum := sum + unsigned(ip_header(i * 16 + 15 downto i * 16));
	    end loop;
	    sum := sum + sum(19 downto 16); -- add all carries from previous sums to generate a 1's complement sum
	    return not std_logic_vector(sum(15 downto 0)); -- return the 1's complement of the sum
	end function compute_ip_checksum;

begin
	pkt_gen_proc: process(all)
		variable mac_header: std_logic_vector(14 * 8 - 1 downto 0); -- 14-bytes Ethernet header (excluding preamble)
		variable ip_header: std_logic_vector(20 * 8 - 1 downto 0); -- 20-bytes IP header
		variable udp_header: std_logic_vector(8 * 8 - 1 downto 0); -- 8-bytes UDP header
		variable ip_checksum: std_logic_vector(15 downto 0); -- 16-bit checksum of the IP header
	begin
		if rising_edge(clk) then

			-- pre-compute the UDP and IP packet lengths
			udp_payload_length  <= 8 + 22 + shift_left(resize(number_of_udp_words, 16), 5); -- 22 bytes padding to complete the second 32-byte header word
			ip_packet_length <= 20 + udp_payload_length;

			mac_header := DEFAULT_MAC_DEST_ADDR & DEFAULT_MAC_SRC_ADDR & X"0800"; -- dest MAC addr, src MAC addr, ethertype (0x0800=IPv4)
			ip_header := X"4500" & (X"0000") & X"1234" & X"0000" & X"7F" & X"11" & (X"0000") & DEFAULT_IP_SRC_ADDR & DEFAULT_IP_DEST_ADDR; -- Version/HdrLen/DSCP/ECP flags, IP Len, ID, Flags/Frag offset, TTL, Protocol, IP header checksum, src IP addr, Dest IP Addr
			udp_header := X"A027" & DEFAULT_IP_DEST_PORT & (X"0000") & X"0000"; -- Src port, dest port, UDP len,  UDP checksum (0=disable)
			ip_header(18 * 8 - 1 downto 16 * 8) := std_logic_vector(ip_packet_length); -- insert IP length prior to computing checksum
			ip_checksum := compute_ip_checksum(ip_header);
			ip_header(10 * 8 - 1 downto 8 * 8) := ip_checksum; -- insert IP checksum
			udp_header(4 * 8 - 1 downto 2 * 8) := std_logic_vector(udp_payload_length); -- insert UDP payload length

			case tx_state is
				when INIT =>
					axis_pktgen_tdata <= (others => '0');
					axis_pktgen_tvalid <= '0';
					axis_pktgen_tlast <= '0';
					frame_ctr <= (others => '0');
					tx_state <= SEND_HEADER1;

				when SEND_HEADER1 =>
					axis_pktgen_tdata <= mac_header & ip_header(20 * 8 - 1 downto 2 * 8);
					axis_pktgen_tvalid <= '1';
					axis_pktgen_tlast <= '0';
					word_ctr <= (others => '0');
					tx_state <= SEND_HEADER2;
				when SEND_HEADER2 =>
					axis_pktgen_tdata <= ip_header(15 downto 0) & udp_header &
					         X"BEEF_FACE_ABBA_0000" & -- UDP checksum, Start of Udp payload
					         reverse_bytes(std_logic_vector(frame_ctr)) & -- UDP payload (contd) - filler bytes
					         X"00_11_22_33_44_55"; -- UDP payload (contd) - filler bytes
					axis_pktgen_tvalid <= '1';
					axis_pktgen_tlast <= '0';
					frame_ctr <= frame_ctr + 16;
					word_ctr <= word_ctr + 1;
					tx_state <= SEND_DATA;

				when SEND_DATA =>
					for b in 0 to 31 loop
						axis_pktgen_tdata((31 - b) * 8 + 7 downto (31 - b) * 8) <= to_slv(b, 8);
					end loop;
					axis_pktgen_tvalid <= '1';
					axis_pktgen_tlast <= '0';
					word_ctr <= word_ctr + 1;
					if word_ctr = number_of_udp_words then
						axis_pktgen_tlast <= '1';
						if word_ctr = packet_spacing_in_words then
							tx_state <= SEND_HEADER1;
						else
							tx_state <= SEND_NOTHING;
						end if;
					end if;

				when SEND_NOTHING =>
					axis_pktgen_tdata <= (others => '0');
					axis_pktgen_tvalid <= '0';
					axis_pktgen_tlast <= '0';
					word_ctr <= word_ctr + 1;
					if word_ctr = packet_spacing_in_words then
						tx_state <= SEND_HEADER1;
					end if;
				end case;

			-- Stay in reset and don't send anything until we the transmitter is fully out of reset.
			if not tx_reset_done then
				tx_state <= INIT;
			end if;

		end if; -- clk


	end process pkt_gen_proc;
end generate pkt_gen_gen;



-- Reads the FIFO 64-bytes at a time at the CMAC's pace. Readout does not start until there is a
-- full packet in the data FIFO (as indicated by the flags FIFO), to ensure there is no underflow.
-- We handle cases where a frame ends after the first 32 bytes by sending the low and high words in
-- two separate transactions.
fifo_rd_block: block
	signal tvalid0, tvalid1: std_logic;  -- tvalid on the low and high words
	signal tlast0, tlast1: std_logic;  -- tlast on the low and high words
	signal is_high_word: std_logic;
	signal send_half_words: std_logic;

	-- TX state machine states
	TYPE TX_STATE_TYPE IS (
		INIT_CMAC,
		CMAC_LOCKED,
		CMAC_ALIGNED,
		FIFO_READY
	);

	signal tx_state: TX_STATE_TYPE := INIT_CMAC; -- Initialization needed

begin
	tx_axis_tdata(255 downto 0) <= reverse_bytes(fifo_dout(255 downto 0)); -- reverse byte order so that the first byte transmitted is byte 0
	tx_axis_tdata(511 downto 256) <= reverse_bytes(fifo_dout(513 downto 258));
	-- tx_axis_tdata <= reverse_bytes(std_logic_vector'(fifo_dout(288+255 downto 288) & fifo_dout(255 downto 0))); -- reverse byte order so that the first byte transmitted is byte 0
	tlast0 <= fifo_dout(256);
	tvalid0 <= fifo_dout(257);
	tlast1 <= fifo_dout(514);
	tvalid1 <= fifo_dout(515);

	-- send_last_words is '1' when we have to perform two separate transactions, one for on each half word.
	-- This happens if 1) we have *two* valid half words, and the first half word is is the last word of a packet.
	send_half_words <= tvalid0 and tlast0 and tvalid1;

	-- We fetch a new word from the FIFO when
	--  1) We have a valid word on the FIFO output
	--  2) The CMAC is consuming the current word (tready=1)
	--  3) We are NOT sending half words, or if we are, we are sending the high word
	fifo_rd_en <= to_std_logic(fifo_valid = '1' and tx_axis_tready = '1' and flag_fifo_valid = '1' and (send_half_words = '0' or is_high_word = '1')); -- '1' when a transaction will occur on the next clock
	flag_fifo_rd_en <= tx_axis_tvalid and tx_axis_tready and tx_axis_tlast and flag_fifo_valid;
	-- We have a CMAC tvalid flag whenever there is valid data out of the FIFO, since we are either sending the low word, the high word, or the full word.
	tx_axis_tvalid <= fifo_valid and flag_fifo_valid and (tvalid0 or tvalid1);
	-- We send the last word if
	-- 1) we are sending half words and the current half word is the last
	-- 2) we are not sending half word and the high (second) half word is the last.
	tx_axis_tlast <= tlast0 when send_half_words = '1' and is_high_word = '0' else -- note: tlast0=1 by definition when send_half_words=1. The synthesizer will simplify that.
	                 tlast1 when send_half_words = '1' and is_high_word = '1' else -- tvalid=1 by definition since send_half_words=1
	                 (tlast0 and tvalid0) or (tlast1 and tvalid1) when send_half_words = '0' else -- if any of the valid half word is the last. Can't be both since send_half_word=0.
	                 '0'; -- should not happen

	-- Here we decide which of the bytes we are sending.
	-- We set the byte-enables of each half word when its respective tvalid=1, and in the case we are sending only half words, only if the current half word is active.
	tx_axis_tkeep(31 downto 0) <= (others => '1') when tvalid0 = '1' and (send_half_words = '0' or is_high_word = '0') else
	                              (others => '0');
	tx_axis_tkeep(63 downto 32) <= (others => '1') when tvalid1 = '1' and (send_half_words = '0' or is_high_word = '1') else
	                               (others => '0');

	fifo_rd_proc: process(all) begin
		if rising_edge(clk_out_int) then
			usr_tx_reset <= usr_tx_reset_pre; -- register the reset signal to help deal with the large fanout
			-- ``is_high_word`` is used to tell if we are to send the low or high 32 bytes coming out of the FIFO.
			-- This is used in case there is a TLAST on the low word and the  low and high words needs to be sent separately.
			-- The variable is set to '0' whenever we read the FIFO, and is increased to 1 whenever a transfer to the CMAC occur.
			if fifo_rd_en or usr_tx_reset then
				is_high_word <= '0';
			elsif tx_axis_tready and tx_axis_tvalid then
				is_high_word <= '1';
			end if;


			-- Initialization state machine
			case tx_state is

				when INIT_CMAC =>
					ctl_tx_enable        <= '0';
					ctl_tx_send_idle     <= '0';
					ctl_tx_send_lfi      <= '0';
					ctl_tx_send_rfi      <= '0';
					ctl_tx_test_pattern  <= '0';
					tx_gt_locked_led <= '0';
					-- tx_core_busy_led <= '0';

					-- if reset_done  then
						tx_state <= CMAC_LOCKED;
					-- end if;

				when CMAC_LOCKED =>
					ctl_tx_send_rfi <= '1';
					tx_gt_locked_led <= '1';
					tx_state <= CMAC_ALIGNED;

				when CMAC_ALIGNED => -- wait for reset to complete
					ctl_tx_send_rfi      <= '0';
					if not fifo_rd_rst_busy then
						tx_state <= FIFO_READY;
					end if;

				when FIFO_READY => -- send data
					ctl_tx_enable        <= '1';
					-- send_data <= '1';
			end case;

			if tx_ovfout then
				tx_ovfout_sticky <= '1';
			end if;
			if tx_unfout then
				tx_unfout_sticky <= '1';
			end if;
			if tx_axis_tvalid and tx_axis_tvalid then
				out_frame_ctr <= out_frame_ctr + 1;
			end if;
			if usr_tx_reset then
				tx_state <= INIT_CMAC;
				tx_ovfout_sticky <= '0';
				tx_unfout_sticky <= '0';
				out_frame_ctr <= (others => '0');
			end if;

		end if; -- clk

	end process fifo_rd_proc;

end block fifo_rd_block;



-- The two IP cores have the same ports. They differ by the hard MAC and the transceivers that they use.
cmac1_gen: if CMAC_IP = 1 generate
	CMAC_INST: entity work.cmac_usplus_1
	  port map (
			gt_txp_out => gt_txp_out,
			gt_txn_out => gt_txn_out,
			gt_ref_clk_p => refclk_p,
			gt_ref_clk_n => refclk_n,
			init_clk => bsb_clk,
			gt_txusrclk2 => clk_out_int,
			gt_ref_clk_out => refclk_out_int,
			ctl_tx_enable => ctl_tx_enable,
			ctl_tx_test_pattern => ctl_tx_test_pattern,
			ctl_tx_send_rfi => ctl_tx_send_rfi,
			ctl_tx_send_lfi => ctl_tx_send_lfi,
			ctl_tx_send_idle => ctl_tx_send_idle,
			tx_axis_tready => tx_axis_tready,
			tx_axis_tvalid => tx_axis_tvalid,
			tx_axis_tdata => tx_axis_tdata,
			tx_axis_tlast => tx_axis_tlast,
			tx_axis_tkeep => tx_axis_tkeep,
			tx_axis_tuser => '0',
			tx_ovfout => tx_ovfout,
			tx_unfout => tx_unfout,
			tx_preamblein => tx_preamblein,
			gt_loopback_in => (others => '0'),
			gt_drpclk      => bsb_clk,

			-- GT transceiver debug / attribute ports (inactive; required when ADD_GT_CNTRL_STS_PORTS=1)
			gt_eyescanreset    => (others => '0'),
			gt_eyescantrigger  => (others => '0'),
			gt_rxcdrhold       => (others => '0'),
			gt_rxpolarity      => (others => '0'),
			gt_rxrate          => (others => '0'),
			gt_txdiffctrl      => gt_txdiffctrl,
			gt_txpolarity      => (others => '0'),
			gt_txinhibit       => (others => '0'),
			gt_txpippmen       => (others => '0'),
			gt_txpippmsel      => (others => '0'),
			gt_txpostcursor    => gt_txpostcursor,
			gt_txprbsforceerr  => (others => '0'),
			gt_txprecursor     => gt_txprecursor,
			gt_rxdfelpmreset   => gt_rxdfelpmreset,
			gt_rxlpmen         => gt_rxlpmen,
			gt_rxprbscntreset  => gt_rxprbscntreset,
			gt_rxprbssel       => gt_rxprbssel,
			gt_txprbssel       => gt_txprbssel,
			ctl_tx_rsfec_enable => ctl_tx_rsfec_enable,

			gt_eyescandataerror => open,
			gt_rxrecclkout      => open,
			gt_powergoodout     => open,
			gt_txbufstatus      => open,
			gt_rxprbserr        => open,
			gt_rxresetdone      => open,
			gt_txresetdone      => open,
			gt_rxbufstatus      => open,

			stat_tx_bad_fcs => open,
			stat_tx_broadcast => open,
			stat_tx_frame_error => open,
			stat_tx_local_fault => open,
			stat_tx_multicast => open,
			stat_tx_packet_1024_1518_bytes => open,
			stat_tx_packet_128_255_bytes => open,
			stat_tx_packet_1519_1522_bytes => open,
			stat_tx_packet_1523_1548_bytes => open,
			stat_tx_packet_1549_2047_bytes => open,
			stat_tx_packet_2048_4095_bytes => open,
			stat_tx_packet_256_511_bytes => open,
			stat_tx_packet_4096_8191_bytes => open,
			stat_tx_packet_512_1023_bytes => open,
			stat_tx_packet_64_bytes => open,
			stat_tx_packet_65_127_bytes => open,
			stat_tx_packet_8192_9215_bytes => open,
			stat_tx_packet_large => open,
			stat_tx_packet_small => open,
			stat_tx_total_bytes => open,
			stat_tx_total_good_bytes => open,
			stat_tx_total_good_packets => open,
			stat_tx_total_packets => open,
			stat_tx_unicast => open,
			stat_tx_vlan => open,

			gtwiz_reset_tx_datapath => cmac_reset_tx_datapath,
			gtwiz_reset_rx_datapath => cmac_reset_rx_datapath,
			sys_reset => cmac_sys_reset,
			core_tx_reset => cmac_core_tx_reset,
			usr_tx_reset => usr_tx_reset_pre,

			-- Core DRP
			core_drp_reset => bsb_rst,
			drp_clk        => bsb_clk,
			drp_addr       => drp_addr,
			drp_di         => drp_din,
			drp_en         => core_drp_en,
			drp_do         => core_drp_dout,
			drp_rdy        => core_drp_rdy,
			drp_we         => drp_we,

			-- GT common DRP (gt_cmn_drp_0)
			common0_drpaddr => cmn_drp_addr,
			common0_drpdi   => drp_din,
			common0_drpen   => cmn_drp_en,
			common0_drpdo   => cmn_drp_dout,
			common0_drprdy  => cmn_drp_rdy,
			common0_drpwe   => drp_we,

			-- GT channel DRP (gt_ch_drp_0 .. 3)
			gt0_drpaddr => drp_addr,
			gt0_drpdi   => drp_din,
			gt0_drpen   => gt_ch_drp_en(0),
			gt0_drpdo   => gt_ch_drp_dout(0),
			gt0_drprdy  => gt_ch_drp_rdy(0),
			gt0_drpwe   => drp_we,

			gt1_drpaddr => drp_addr,
			gt1_drpdi   => drp_din,
			gt1_drpen   => gt_ch_drp_en(1),
			gt1_drpdo   => gt_ch_drp_dout(1),
			gt1_drprdy  => gt_ch_drp_rdy(1),
			gt1_drpwe   => drp_we,

			gt2_drpaddr => drp_addr,
			gt2_drpdi   => drp_din,
			gt2_drpen   => gt_ch_drp_en(2),
			gt2_drpdo   => gt_ch_drp_dout(2),
			gt2_drprdy  => gt_ch_drp_rdy(2),
			gt2_drpwe   => drp_we,

			gt3_drpaddr => drp_addr,
			gt3_drpdi   => drp_din,
			gt3_drpen   => gt_ch_drp_en(3),
			gt3_drpdo   => gt_ch_drp_dout(3),
			gt3_drprdy  => gt_ch_drp_rdy(3),
			gt3_drpwe   => drp_we
	  );
end generate cmac1_gen;

cmac2_gen: if CMAC_IP = 2 generate
	CMAC_INST: entity work.cmac_usplus_2
	  port map (
			gt_txp_out => gt_txp_out,
			gt_txn_out => gt_txn_out,
			gt_ref_clk_p => refclk_p,
			gt_ref_clk_n => refclk_n,
			init_clk => bsb_clk,
			gt_txusrclk2 => clk_out_int,
			gt_ref_clk_out => refclk_out_int,
			ctl_tx_enable => ctl_tx_enable,
			ctl_tx_test_pattern => ctl_tx_test_pattern,
			ctl_tx_send_rfi => ctl_tx_send_rfi,
			ctl_tx_send_lfi => ctl_tx_send_lfi,
			ctl_tx_send_idle => ctl_tx_send_idle,
			tx_axis_tready => tx_axis_tready,
			tx_axis_tvalid => tx_axis_tvalid,
			tx_axis_tdata => tx_axis_tdata,
			tx_axis_tlast => tx_axis_tlast,
			tx_axis_tkeep => tx_axis_tkeep,
			tx_axis_tuser => '0',
			tx_ovfout => tx_ovfout,
			tx_unfout => tx_unfout,
			tx_preamblein => tx_preamblein,
			gt_loopback_in => (others => '0'),
			gt_drpclk      => bsb_clk,

			-- GT transceiver debug / attribute ports (inactive; required when ADD_GT_CNTRL_STS_PORTS=1)
			gt_eyescanreset    => (others => '0'),
			gt_eyescantrigger  => (others => '0'),
			gt_rxcdrhold       => (others => '0'),
			gt_rxpolarity      => (others => '0'),
			gt_rxrate          => (others => '0'),
			gt_txdiffctrl      => gt_txdiffctrl,
			gt_txpolarity      => (others => '0'),
			gt_txinhibit       => (others => '0'),
			gt_txpippmen       => (others => '0'),
			gt_txpippmsel      => (others => '0'),
			gt_txpostcursor    => gt_txpostcursor,
			gt_txprbsforceerr  => (others => '0'),
			gt_txprecursor     => gt_txprecursor,
			gt_rxdfelpmreset   => gt_rxdfelpmreset,
			gt_rxlpmen         => gt_rxlpmen,
			gt_rxprbscntreset  => gt_rxprbscntreset,
			gt_rxprbssel       => gt_rxprbssel,
			gt_txprbssel       => gt_txprbssel,
			ctl_tx_rsfec_enable => ctl_tx_rsfec_enable,

			gt_eyescandataerror => open,
			gt_rxrecclkout      => open,
			gt_powergoodout     => open,
			gt_txbufstatus      => open,
			gt_rxprbserr        => open,
			gt_rxresetdone      => open,
			gt_txresetdone      => open,
			gt_rxbufstatus      => open,

			stat_tx_bad_fcs => open,
			stat_tx_broadcast => open,
			stat_tx_frame_error => open,
			stat_tx_local_fault => open,
			stat_tx_multicast => open,
			stat_tx_packet_1024_1518_bytes => open,
			stat_tx_packet_128_255_bytes => open,
			stat_tx_packet_1519_1522_bytes => open,
			stat_tx_packet_1523_1548_bytes => open,
			stat_tx_packet_1549_2047_bytes => open,
			stat_tx_packet_2048_4095_bytes => open,
			stat_tx_packet_256_511_bytes => open,
			stat_tx_packet_4096_8191_bytes => open,
			stat_tx_packet_512_1023_bytes => open,
			stat_tx_packet_64_bytes => open,
			stat_tx_packet_65_127_bytes => open,
			stat_tx_packet_8192_9215_bytes => open,
			stat_tx_packet_large => open,
			stat_tx_packet_small => open,
			stat_tx_total_bytes => open,
			stat_tx_total_good_bytes => open,
			stat_tx_total_good_packets => open,
			stat_tx_total_packets => open,
			stat_tx_unicast => open,
			stat_tx_vlan => open,

			gtwiz_reset_tx_datapath => cmac_reset_tx_datapath,
			gtwiz_reset_rx_datapath => cmac_reset_rx_datapath,
			sys_reset => cmac_sys_reset,
			core_tx_reset => cmac_core_tx_reset,
			usr_tx_reset => usr_tx_reset_pre,

			-- Core DRP
			core_drp_reset => bsb_rst,
			drp_clk        => bsb_clk,
			drp_addr       => drp_addr,
			drp_di         => drp_din,
			drp_en         => core_drp_en,
			drp_do         => core_drp_dout,
			drp_rdy        => core_drp_rdy,
			drp_we         => drp_we,

			-- GT common DRP (gt_cmn_drp_0)
			common0_drpaddr => cmn_drp_addr,
			common0_drpdi   => drp_din,
			common0_drpen   => cmn_drp_en,
			common0_drpdo   => cmn_drp_dout,
			common0_drprdy  => cmn_drp_rdy,
			common0_drpwe   => drp_we,

			-- GT channel DRP (gt_ch_drp_0 .. 3)
			gt0_drpaddr => drp_addr,
			gt0_drpdi   => drp_din,
			gt0_drpen   => gt_ch_drp_en(0),
			gt0_drpdo   => gt_ch_drp_dout(0),
			gt0_drprdy  => gt_ch_drp_rdy(0),
			gt0_drpwe   => drp_we,

			gt1_drpaddr => drp_addr,
			gt1_drpdi   => drp_din,
			gt1_drpen   => gt_ch_drp_en(1),
			gt1_drpdo   => gt_ch_drp_dout(1),
			gt1_drprdy  => gt_ch_drp_rdy(1),
			gt1_drpwe   => drp_we,

			gt2_drpaddr => drp_addr,
			gt2_drpdi   => drp_din,
			gt2_drpen   => gt_ch_drp_en(2),
			gt2_drpdo   => gt_ch_drp_dout(2),
			gt2_drprdy  => gt_ch_drp_rdy(2),
			gt2_drpwe   => drp_we,

			gt3_drpaddr => drp_addr,
			gt3_drpdi   => drp_din,
			gt3_drpen   => gt_ch_drp_en(3),
			gt3_drpdo   => gt_ch_drp_dout(3),
			gt3_drprdy  => gt_ch_drp_rdy(3),
			gt3_drpwe   => drp_we
	  );
end generate cmac2_gen;

end architecture impl;





