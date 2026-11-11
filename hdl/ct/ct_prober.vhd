----------------------------------------------------------------------------------
-- Company: McGill University
-- Engineer: V. Bidula
--
-- Create Date: 2026-08-06
-- Design Name: chFPGA
-- Module Name: ct_prober - impl
-- Project Name: HIRAX
-- Target Devices: Kintex 7 (any platform supported by generic_fifo)
-- Tool versions: Vivado 2022.2+
--
-- Dependencies: generic_fifo, bsb_regs, chFPGA_Package
--
-- Revision:
--  2026-08-06 - File created, modeled on chan/prober.vhd
--
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library xpm;
use xpm.vcomponents.ALL;

use work.chFPGA_Package.ALL; -- Get all component definitions

-- ct_prober: Corner-turn output capture probe
--
-- WHAT
-- ----
-- Periodically captures bursts of 1-4 complete corner-turn output packets from ONE
-- software-selectable lane of the corner-turn engine output bus, and streams them over a
-- 8-bit blocking AXI4-STREAM interface to the slow data capture path (bsb_master -> 1 GbE).
-- Each captured CT packet is prepended with the standard 10-byte capture frame header
-- (FRAME_HEADER_STRUCT) carrying the cookie 0xA2, so the host can distinguish these packets
-- from the channelizer prober (0xA0/0xA1) and correlator (0xCF) capture streams.
--
-- WHY
-- ---
-- The corner-turn output is normally consumed only by the X-engine data links; there is no
-- other way to verify what the corner turn actually emits. This module provides occasional
-- verification snapshots of the exact bytes the X-engine would receive. It is NOT meant for
-- debugging upstream pipeline stages: the in-channelizer probers already capture pre-CT data
-- together with the ADC/FFT/SCALER flags.
--
-- HOW
-- ---
-- The corner-turn output bus is NUMBER_OF_LANES independent, packetized 32-bit lane streams
-- concatenated into one wide word, with LANE 0 AT THE MSBs (the bct_engine output flattening
-- reverses lane order). All lanes share a single TVALID/TLAST. This module registers one
-- 32-bit lane slice (undoing the lane reversal), detects CT packet boundaries with TLAST, and
-- stores whole packets in an asynchronous FIFO. The capture is packet-size-agnostic: it works
-- unchanged for any shuffle mode (shuffle16/256/512), any frames-per-packet grouping and any
-- flags setting, because packets are delimited purely by TLAST. The inner CT packet header
-- (timestamp, stream info) is carried intact in the captured payload.
--
-- Capture is triggered periodically by a primary period counter counting CT packets (TLASTs),
-- with an optional start offset and power-of-2 sub-period, exactly like the channelizer
-- prober. A request/acknowledge toggle handshake between the write (in_clk) and read (out_clk)
-- clock domains ensures a new burst is not captured before the previous one has been fully
-- transmitted; a trigger arriving too early sets the sticky `overrun` status bit and the
-- capture is skipped.
--
-- FIFO CAPACITY / BURST CEILINGS
-- ------------------------------
-- The data FIFO stores 2048 x 33-bit words (32-bit data + TLAST), i.e. 2x FIFO36E1 on
-- Kintex-7 - the same footprint as one channelizer prober. The whole burst must fit in the
-- FIFO because readout only starts after the burst capture completes. Software must therefore
-- limit burst_length according to the CT packet size:
--
--   | CT configuration              | packet size | max packets per burst |
--   |-------------------------------|-------------|-----------------------|
--   | flags off, 1 frame/packet     |   517 words |            3          |
--   | flags off, 2 frames/packet    |  1029 words |            1          |
--   | flags on,  1 frame/packet     |   582 words |            3          |
--   | flags on,  2 frames/packet    |  1159 words |            1          |
--
-- An oversized burst is not fatal: FIFO writes are dropped and the sticky
-- data_fifo_overflow_sticky status bit is raised, but the captured packet is truncated.
--
-- CLOCKING, RESETS AND CDC
-- ------------------------
-- - in_clk is the corner-turn clock (a GTX transmit word clock, 244 MHz on ICE). This clock
--   STOPS while the corner-turn engine is in reset. Software must configure/reset this module
--   only after the corner-turn links are up. in_reset must be asserted during corner-turn
--   resets (it is, when driven from the top-level ct_reset).
-- - out_clk is the capture clock (cap_clk = bsb_clk = 125 MHz on ICE) and always runs. The
--   power-on reset flop is therefore clocked on out_clk so that the FIFO receives a proper
--   power-on reset pulse even if in_clk is not yet running.
-- - The FIFO reset (in_reset or soft_reset or por_rst) is asynchronous; generic_fifo
--   synchronizes it internally and provides wr_rst_busy/rd_rst_busy, which this module uses
--   as its write/read-domain resets. New burst triggers are blocked while wr_rst_busy.
-- - Control bytes cross from bsb_clk to in_clk WITHOUT synchronization, exactly like the
--   channelizer prober: multi-byte fields (primary_period, capture_offset, sub_period) must
--   only be changed followed by a soft_reset, otherwise a torn value can corrupt one period
--   comparison. Exceptions that are safe to change live: capture_en (single bit) and lane_sel
--   (re-latched into current_lane only between bursts, so a mid-burst change cannot tear).
-- - Burst metadata (burst_lane, burst_timestamp) crosses write->read domain unregistered but
--   is protected by the req/ack handshake: it is written when the burst STARTS and consumed
--   by the read logic only after the burst ENDS + CDC latency, i.e. at least one full packet
--   duration (>= 2 us) later. No timing exception is required (all inter-domain paths are
--   already covered by the platform set_clock_groups -asynchronous constraints).
--
-- OUTPUT FORMAT
-- -------------
-- For each captured CT packet, the output stream carries a 10-byte FRAME_HEADER_STRUCT header
-- (see chfpga_package.vhd) followed by the raw packet bytes (32-bit words sent MSB first):
--   - PROBE_ID:  0xA2
--   - STREAM_ID: software-programmed stream_id, with bits 15:12 replaced by the packet index
--     within the burst and bits 3:0 replaced by the captured lane number (per the STREAM_ID
--     convention documented in chfpga_package.vhd: bits 3:0 = hardware-defined lane).
--   - SERIAL_FLAGS/FLAGS: zeros (the corner-turn output carries no TUSER sideband; the CT
--     packet's own flags blocks, if enabled, are part of the captured payload).
--   - TIMESTAMP: the 48-bit CT packet counter value at burst start. This is a local packet
--     count since reset; use the inner CT packet header (in the payload) for system timing.
--
-- Unlike the channelizer prober, this module does NOT emit a trailing orphan header after the
-- last packet of a burst (see the guard in the read state machine below).
--
entity ct_prober is
	generic (
		FPGA_SERIES     : fpga_series_enum;    -- Selects the FIFO primitives in generic_fifo
		NUMBER_OF_LANES : integer := 8;    -- Number of 32-bit lanes in the input bus
		LANE_WIDTH      : integer := 32;   -- Bits per lane
		SIM             : boolean := FALSE -- Shortens the default capture period in simulation
	);
	port (
		-- Input Interface: corner-turn output snoop (non-blocking, in_clk domain)
		-- Lane 0 is at the MSBs of in_tdata (bct_engine output lane reversal).

		in_tdata  : in std_logic_vector(NUMBER_OF_LANES * LANE_WIDTH - 1 downto 0);
		in_tvalid : in std_logic_vector(0 to NUMBER_OF_LANES - 1); -- one per lane (index = lane number); the selected lane's strobe is used
		in_tlast  : in std_logic_vector(0 to NUMBER_OF_LANES - 1); -- one per lane; delimits the CT packets of that lane
		in_clk    : in std_logic; -- corner-turn clock; STOPS during corner-turn resets
		in_reset  : in std_logic;

		-- Output Interface: byte stream to the slow capture path (blocking, out_clk domain)

		out_tdata  : out std_logic_vector(7 downto 0);
		out_tvalid : out std_logic;
		out_tlast  : out std_logic;
		out_tready : in std_logic;
		out_clk    : in std_logic;

		-- Control Interface (command and reply stream buses)

		s_axis_bsb_tdata  : in std_logic_vector(7 downto 0);
		s_axis_bsb_tvalid : in std_logic;
		s_axis_bsb_tlast  : in std_logic;
		s_axis_bsb_tready : out std_logic;
		m_axis_bsb_tdata  : out std_logic_vector(7 downto 0);
		m_axis_bsb_tvalid : out std_logic;
		m_axis_bsb_tlast  : out std_logic;
		m_axis_bsb_tready : in std_logic;
		bsb_clk           : in std_logic;
		bsb_rst           : in std_logic
	);
end entity ct_prober;

---- ARCHITECTURE DECLARATION and DEFINITION --------------------------

architecture impl of ct_prober is

	-----------------------------------------------------------------------
	-- Constants
	-----------------------------------------------------------------------
	-- Default capture period, in CT packets. CT packets are issued every 2.56 us (one per
	-- frame at 1 frame/packet), so 390625 (0x05F5E1) packets is approximately 1 s. This is
	-- the same numeric default as the channelizer prober (which counts 2.56 us frames).
	constant DEFAULT_BURST_PERIOD: std_logic_vector(23 downto 0) := sel(SIM, X"000004", X"05F5E1");

	-----------------------------------------------------------------------
	-- Signals
	-----------------------------------------------------------------------

	-- DATA FIFO signals

	signal data_fifo_rd_en: std_logic := '0';
	signal data_fifo_wr_en: std_logic := '0';
	signal data_fifo_empty: std_logic;
	signal data_fifo_valid: std_logic;
	signal data_fifo_full: std_logic;
	signal data_fifo_overflow: std_logic;
	signal data_fifo_overflow_sticky: std_logic;
	signal data_fifo_wr_rst_busy: std_logic;
	signal data_fifo_rd_rst_busy: std_logic;
	signal data_fifo_din: std_logic_vector(32 downto 0) := (others => '0'); -- bit 32 = TLAST
	signal data_fifo_dout: std_logic_vector(32 downto 0);

	-- Control and status bytes

	signal control_bytes: slv8_array(0 to 14); -- default value set in bsb_regs
	signal status_bytes: slv8_array(0 to 1);

	signal capture_offset: unsigned(23 downto 0);
	signal primary_period: unsigned(23 downto 0);
	signal send_delay_target: unsigned(31 downto 0);
	signal burst_length: unsigned(1 downto 0); -- number of consecutive packets in a burst minus one
	signal stream_id: std_logic_vector(15 downto 0);
	signal new_lane: std_logic_vector(2 downto 0);
	signal soft_reset: std_logic;
	signal capture_en: std_logic;
	signal sub_period: unsigned(4 downto 0);

	signal current_lane: std_logic_vector(2 downto 0);
	signal overrun: std_logic;

	-- Communication between the write and read logic

	signal readout_req: std_logic; -- readout request flag, on the write clock
	signal readout_ack: std_logic; -- readout acknowledge flag, on the read clock
	signal burst_lane: std_logic_vector(2 downto 0); -- lane captured by the current burst
	signal burst_timestamp: std_logic_vector(47 downto 0); -- CT packet counter at burst start

begin

	-----------------------------------------------------------------------------------
	-- CONTROL and STATUS Bytes
	-----------------------------------------------------------------------------------
	-- CT_PROBER Module Memory Map
	--
	-- Byte addresses mirror the channelizer prober (chan/prober.vhd) where the fields
	-- coincide, so the python driver can subclass the prober driver. Fields that differ are
	-- all within CONTROL byte 0.
	--
	-- ------------------------------------------------------------------------------
	-- |  Page   | Addr|Bit(s)|     Name             | Description                   |
	-- |---------|-----|------|----------------------|-------------------------------|
	-- | CONTROL |  0  |  7   | soft_reset           | Resets FIFO, counters and sticky bits |
	-- |         |     |  6   | capture_en           | 0 (default): parked, no new bursts trigger. |
	-- |         |     |      |                      | An in-flight burst completes. Safe to change live. |
	-- |         |     | 5:3  | lane_sel             | CT output lane to capture (0 to NUMBER_OF_LANES-1). |
	-- |         |     |      |                      | Latched between bursts only; safe to change live. |
	-- |         |     |  2   | (reserved)           | (prober_user_flags in the channelizer prober) |
	-- |         |     | 1:0  | burst_length         | Number of consecutive packets in a burst minus one |
	-- |         |     |      |                      | (0: 1 packet ... 3: 4 packets). See burst ceilings above. |
	-- |         | 1-3 | 23:0 | capture_offset(23:0) | Number of packets to skip before starting the capture |
	-- |         | 4-6 | 23:0 | primary_period(23:0) | Number of CT packets between captures minus one. |
	-- |         |     |      |                      | Requires soft_reset after a change (raw CDC). |
	-- |         | 7-8 | 15:0 | stream_id(15:0)      | Bits 15:12 and 3:0 are overwritten by hardware |
	-- |         | 9-10| 15:0 | send_delay           | Time to wait before sending captured data |
	-- |         |11-13|      | (reserved)           | (primary_period(1) in the channelizer prober) |
	-- |         | 14  | 7:5  | (unused)             |                               |
	-- |         |     | 4:0  | sub_period           | Create additional captures every N=2^(sub_period+1) |
	-- |         |     |      |                      | packets after the primary period (prober semantics) |
	-- | STATUS  |  0  | 7:5  | (unused)             |                               |
	-- |         |     |   4  | data_fifo_empty      | For debugging.                |
	-- |         |     |   3  | data_fifo_overflow   | For debugging.                |
	-- |         |     |   2  | data_fifo_overflow_sticky | Cleared by soft_reset/in_reset only |
	-- |         |     |   1  | overrun              | High if we attempted to capture a new burst when the |
	-- |         |     |      |                      | readout of the previous one was not finished |
	-- |         |     |   0  | (unused)             |                               |
	-- |         |  1  | 7:3  | (unused)             |                               |
	-- |         |     | 2:0  | current_lane         | Lane currently latched by the capture mux |
	-- ------------------------------------------------------------------------------

	-- CONTROL Byte 0
	soft_reset   <= control_bytes(0)(7);
	capture_en   <= control_bytes(0)(6);
	new_lane     <= control_bytes(0)(5 downto 3);
	burst_length <= unsigned(control_bytes(0)(1 downto 0));

	-- CONTROL Bytes 1-3
	capture_offset <= to_unsigned(control_bytes(1 to 3));

	-- CONTROL Bytes 4-6
	primary_period <= to_unsigned(control_bytes(4 to 6)); -- 24-bit period, in CT packets

	-- CONTROL Bytes 7-8
	stream_id <= to_slv(control_bytes(7 to 8));

	-- CONTROL Bytes 9-10
	send_delay_target <= to_unsigned(control_bytes(9 to 10)) & X"0000";

	-- CONTROL Bytes 11-13 are reserved (primary_period(1) in the channelizer prober)

	-- CONTROL Byte 14
	sub_period <= unsigned(control_bytes(14)(4 downto 0));

	-- STATUS Byte 0
	status_bytes(0)(7 downto 5) <= (others => '0');
	status_bytes(0)(4)          <= data_fifo_empty;           -- for debugging
	status_bytes(0)(3)          <= data_fifo_overflow;        -- for debugging
	status_bytes(0)(2)          <= data_fifo_overflow_sticky; -- for debugging
	status_bytes(0)(1)          <= overrun;                   -- high if we attempted to capture a new burst when the readout of the previous one was not finished
	status_bytes(0)(0)          <= '0';

	-- STATUS Byte 1
	status_bytes(1)(7 downto 3) <= (others => '0');
	status_bytes(1)(2 downto 0) <= current_lane; -- quasi-static; safe to sample on bsb_clk

	-----------------------------------------------------------------------------------
	-- Memory-Mapped interface instantiation
	-----------------------------------------------------------------------------------
	-- Instantiates a memory-mapped interface to the control and status bytes
	bsb_regs0: entity work.bsb_regs
		generic map (
			NUMBER_OF_CONTROL_BYTES => control_bytes'Length(1), --
			NUMBER_OF_STATUS_BYTES  => status_bytes'Length(1), --
			-- Byte 0 = 0x00: capture disabled (parked), lane 0, burst length = 1 packet.
			-- Bytes 1-3: capture offset = 0. Bytes 4-6: period = ~1 s worth of CT packets.
			-- Bytes 7-10: stream_id = 0, send_delay = 0. Bytes 11-13: reserved = 0.
			-- Byte 14 = 0x17: sub_period = 23 (sub-period captures effectively disabled).
			DEFAULT_CONTROL_BYTES => (X"00_000000" & DEFAULT_BURST_PERIOD & X"0000_0000" & X"000000" & X"17")
		)
		port map (
			-- Control interface (command and reply stream buses)
			s_axis_bsb_tdata  => s_axis_bsb_tdata,
			s_axis_bsb_tvalid => s_axis_bsb_tvalid,
			s_axis_bsb_tlast  => s_axis_bsb_tlast,
			s_axis_bsb_tready => s_axis_bsb_tready,
			m_axis_bsb_tdata  => m_axis_bsb_tdata,
			m_axis_bsb_tvalid => m_axis_bsb_tvalid,
			m_axis_bsb_tlast  => m_axis_bsb_tlast,
			m_axis_bsb_tready => m_axis_bsb_tready,
			bsb_clk           => bsb_clk,
			bsb_rst           => bsb_rst,

			control_bytes => control_bytes,
			status_bytes  => status_bytes
		);

	fifo_blk: block
		signal por_rst: std_logic := '1'; -- Initialize to 1 to ensure power on reset.
		signal fifo_rst: std_logic;
	begin
		-----------------------------------------------------------------------
		-- Data FIFO
		-----------------------------------------------------------------------
		-- 33-bit x 2048-word asynchronous FWFT FIFO holding whole CT packets: bits 31:0 are
		-- the lane data word, bit 32 is TLAST. On Kintex-7 this maps to 2x FIFO36E1 in 18-bit
		-- mode (the same footprint as one channelizer prober FIFO). Unlike the channelizer
		-- prober, the primitives, their parallel composition and the reset sequencing are
		-- handled by the generic_fifo wrapper, which also provides the wr_rst_busy/rd_rst_busy
		-- signals used as the write/read domain resets of this module.

		-- Clear the power-on reset as soon as we have a clock. We use out_clk because it
		-- always runs, whereas in_clk (the corner-turn clock) stops during corner-turn
		-- resets and may not be running at configuration time.
		process(all) begin
			por_rst <= '0' when rising_edge(out_clk);
		end process;

		-- Asynchronous reset assertion is safe: generic_fifo synchronizes internally and
		-- gates its own write/read enables during the reset sequence.
		fifo_rst <= in_reset or soft_reset or por_rst;

		data_fifo0: entity work.generic_fifo
			generic map (
				FPGA_SERIES => FPGA_SERIES,
				MEMORY_TYPE => "embedded",
				IS_ASYNC    => TRUE,
				IS_FWFT     => TRUE,
				DATA_WIDTH  => 33,
				DEPTH       => 2048
			)
			port map (
				wr_clk      => in_clk,
				wr_en       => data_fifo_wr_en,
				din         => data_fifo_din,
				full        => data_fifo_full,
				prog_full   => open,
				overflow    => data_fifo_overflow,
				wr_rst_busy => data_fifo_wr_rst_busy,

				rd_clk      => out_clk,
				rd_en       => data_fifo_rd_en,
				dout        => data_fifo_dout,
				empty       => data_fifo_empty,
				prog_empty  => open,
				valid       => data_fifo_valid,
				rd_rst_busy => data_fifo_rd_rst_busy,

				rst => fifo_rst
			);
	end block fifo_blk;

	write_blk: block
		-- Offset and period counters
		signal primary_period_ctr: unsigned(23 downto 0); -- Counts CT packets within a period.
		signal offset_done: std_logic;

		signal frame_ctr: unsigned(47 downto 0); -- CT packet counter

		signal burst_ctr: unsigned(burst_length'RANGE) := (others => '0'); -- Packet number being captured within a burst
		signal burst_capture: std_logic; -- high while a burst capture is in progress

		-- Delayed copies of the FIFO write-side reset-busy flag. The FIFO36E1 primitives
		-- require WREN to stay low for at least two WRCLK cycles after their reset deasserts;
		-- gating the burst trigger on this delay line guarantees that, since a trigger could
		-- otherwise fire on the very cycle wr_rst_busy clears (e.g. right after a soft_reset
		-- with capture_en already set).
		signal wr_rst_busy_dly: std_logic_vector(3 downto 0) := (others => '1');

		signal readout_acq_resync: std_logic;
	begin

		readout_acq_cdc0: xpm_cdc_single
			generic map (
				SRC_INPUT_REG => 0
			)
			port map (
				src_clk  => '0',
				src_in   => readout_ack,
				dest_clk => in_clk,
				dest_out => readout_acq_resync
			);

		------------------------------------
		-- FIFO Writing process
		------------------------------------
		-- Counts CT packets, selects the target lane, and writes whole packets of the
		-- selected lane into the data FIFO together with the TLAST bit. The FIFO is read one
		-- byte at a time by the reading interface.
		fifo_write_proc: process(all)

			variable lane: integer range 0 to NUMBER_OF_LANES - 1;
			variable rlane: integer range 0 to NUMBER_OF_LANES - 1;
			variable is_first_frame_of_burst: boolean;
			variable sel_tvalid: std_logic; -- strobes of the selected lane
			variable sel_tlast: std_logic;

		begin
			if rising_edge(in_clk) then
				data_fifo_overflow_sticky <= '0' when data_fifo_wr_rst_busy else '1' when data_fifo_overflow;

				-- Track the FIFO reset-busy release (see wr_rst_busy_dly declaration)
				wr_rst_busy_dly <= wr_rst_busy_dly(wr_rst_busy_dly'HIGH - 1 downto 0) & data_fifo_wr_rst_busy;

				-- Select the lane to capture. Lane 0 is at the MSBs of in_tdata (the bct_engine
				-- output flattening reverses lane order), so the data slice uses the reversed lane
				-- number, while the strobe vectors are indexed by lane number directly. Every lane
				-- carries its own TVALID/TLAST (the bin selectors do not start their packets in
				-- step), so all packet framing below uses the selected lane's strobes.
				lane := to_integer(unsigned(current_lane));
				rlane := NUMBER_OF_LANES - 1 - lane;
				sel_tvalid := in_tvalid(lane);
				sel_tlast := in_tlast(lane);

				-- -------------------------------------------
				-- Packet and period counter
				-- -------------------------------------------
				-- Counts incoming CT packets (TLASTs) of the selected lane and the primary period.
				if sel_tvalid and sel_tlast then
					frame_ctr <= frame_ctr + 1; -- always count the 48-bit packet number. We will put this in the header.
					primary_period_ctr <= primary_period_ctr + 1;
					if not offset_done then
						if primary_period_ctr = capture_offset then
							offset_done <= '1';
							primary_period_ctr <= (others => '0');
						end if;
					else
						if primary_period_ctr = primary_period then
							primary_period_ctr <= (others => '0');
						end if; -- if period done
					end if; -- if offset done
				end if; -- last word

				-- Register the FIFO input data bus from the selected lane. This is in phase
				-- with data_fifo_wr_en and burst_capture.
				data_fifo_din(32) <= sel_tlast;
				data_fifo_din(31 downto 0) <= in_tdata(LANE_WIDTH * rlane + LANE_WIDTH - 1 downto LANE_WIDTH * rlane);

				data_fifo_wr_en <= '0'; -- don't write data to FIFO unless overriden below

				if sel_tvalid then
					-- Determine if this is the first packet of a burst to be captured. This is
					-- true when 1) the capture offset is elapsed and 2) all the bits in the
					-- sub-period range are zero, which always includes the first packet of the
					-- period (counter is zero).
					is_first_frame_of_burst := offset_done = '1' and all_zeros(primary_period_ctr, to_integer(sub_period), 0);

					if burst_capture then
						data_fifo_wr_en <= '1'; -- continue writing delayed data
						if sel_tlast then
							burst_ctr <= burst_ctr + 1;
							if burst_ctr = burst_length then -- This was the last word of the last packet of the burst
								burst_capture <= '0'; -- stop burst
								readout_req <= not readout_req; -- toggle bit to signal readout should start now
							end if; -- if last packet
						end if; -- tlast
					elsif is_first_frame_of_burst and capture_en = '1' and data_fifo_wr_rst_busy = '0' and all_zeros(wr_rst_busy_dly) then
						if readout_acq_resync = readout_req then -- if previous readout is completed
							burst_ctr <= (others => '0');
							burst_capture <= '1';
							data_fifo_wr_en <= '1'; -- start writing delayed data
							burst_lane <= current_lane; -- capture burst info
							burst_timestamp <= std_logic_vector(frame_ctr);
						else -- oops, overrun. Flag it, and just skip this capture so we don't interfere with the ongoing readout.
							overrun <= '1';
						end if;
					else
						-- change lane only if we are between bursts
						current_lane <= new_lane;
					end if; -- burst_capture or first_frame_of_burst
				end if; -- tvalid

				if data_fifo_wr_rst_busy then
					burst_ctr <= (others => '0'); -- needed
					burst_capture <= '0';
					data_fifo_wr_en <= '0';
					current_lane <= new_lane;
					frame_ctr <= (others => '0'); -- needed
					primary_period_ctr <= (others => '0'); -- needed.
					offset_done <= '1' when capture_offset = 0 else '0';
					overrun <= '0';
					readout_req <= '0';
				end if; -- reset

			end if; -- clk
		end process;

	end block write_blk;


	read_blk: block
		-- State machine type
		type send_state_type is (
			SEND_STDBY,
			SEND_DELAY,
			SEND_HEADER,
			SEND_DATA
		);

		signal send_state: send_state_type;

		signal dest_ready: std_logic;
		signal send_delay_ctr: unsigned(send_delay_target'RANGE); -- 16 bit delay + 16 bits prescaler
		signal byte_ctr: unsigned(3 downto 0); -- Must be wide enough to count header bytes and data word bytes
		signal burst_ctr: unsigned(burst_length'RANGE);
		signal readout_req_resync, readout_req_dly: std_logic;
	begin

		-- Safely register the readout request flag from the write domain into the read domain
		readout_req_cdc0: xpm_cdc_single
			generic map (
				SRC_INPUT_REG => 0
			)
			port map (
				src_clk  => '0',
				src_in   => readout_req,
				dest_clk => out_clk,
				dest_out => readout_req_resync
			);

		-- Determine when we can write new data on the output bus
		dest_ready <= out_tready or not out_tvalid; -- the output is ready for a new byte if there is currently no valid byte or if the destination is accepting current one.

		-- Fetch the next data word when we are in the SEND_DATA phase, the destination can
		-- receive the data, and we just sent the last byte of the word. Unlike the channelizer
		-- prober (which gated reads at the FIFO primitive port), we must qualify rd_en with
		-- the FIFO valid flag ourselves: generic_fifo only gates reads during reset.
		data_fifo_rd_en <= to_std_logic(send_state = SEND_DATA and dest_ready = '1' and byte_ctr(1 downto 0) = "11") and data_fifo_valid;

		----------------------------------------
		-- FIFO Readout process
		----------------------------------------
		-- Sends the data stored in the FIFO along with packet headers. We send one output
		-- packet per captured CT packet, each with its own 10-byte header.
		--
		-- Transmission is triggered when readout_req is toggled. We acknowledge completion of
		-- the readout by setting readout_ack to the value of readout_req. Since readout_req is
		-- in the write clock domain, we use a CDC block to bring it into the readout domain.
		--
		-- We use the data stored in burst_lane and burst_timestamp to populate the headers of
		-- each packet. These are in the write clock domain, but they are stable when used
		-- here: they are written when the burst capture starts, and this readout only starts
		-- after the burst capture has completed (readout_req toggles at burst end) plus the
		-- CDC latency. The req/ack interlock then keeps them unchanged until the readout is
		-- complete.
		--
		-- We use a large mux to select bytes from the header or data words in order to
		-- minimize resource utilization (see the channelizer prober for the full rationale).
		read_proc: process(all)

			variable byte: integer;
			variable frame_header: frame_header_struct;
			variable frame_header_bytes: slv8_array(0 to FRAME_HEADER_BYTE_LENGTH - 1);

		begin
			if rising_edge(out_clk) then
				-- delay
				readout_req_dly <= readout_req_resync;

				-- synchronous reset is at the bottom of this process

				-- Clear TVALID if the data is read by the destination. This will be overriden below if a new byte is sent at the same time
				out_tvalid <= '0' when out_tready;

				-- Count clocks to implement a programmable delay between a burst being captured and when it is read out
				send_delay_ctr <= send_delay_ctr + 1;

				case send_state is

					when SEND_STDBY => -- wait until burst data is ready
						send_delay_ctr <= (others => '0');
						send_state <= SEND_DELAY when readout_req_resync /= readout_req_dly; -- start reading out data when readout_req toggles

					when SEND_DELAY => -- pre-burst readout delay
						byte_ctr <= (others => '0');
						burst_ctr <= (others => '0');
						send_state <= SEND_HEADER when send_delay_ctr = send_delay_target;

					when SEND_HEADER => -- send packet header bytes
						-- Pack the frame information structure into an array of bytes.
						frame_header.PROBE_ID := X"A2";
						frame_header.STREAM_ID := stream_id;
						frame_header.STREAM_ID(15 downto 12) := std_logic_vector(resize(burst_ctr, 4)); -- packet number within the burst
						frame_header.STREAM_ID(3 downto 0) := '0' & burst_lane; -- captured lane (STREAM_ID bits 3:0 are hardware-defined lane)
						frame_header.SERIAL_FLAGS := "0000"; -- no TUSER sideband at the corner-turn output
						frame_header.FLAGS := "0000";
						frame_header.TIMESTAMP := burst_timestamp; -- CT packet counter at burst start
						frame_header_bytes := struct_to_bytes(frame_header); -- Store the header into an array of bytes

						byte := to_integer(byte_ctr);

						-- End of burst detection. The channelizer prober always returns here
						-- after the last packet and emits an orphan 10-byte header before
						-- noticing the FIFO is empty in SEND_DATA; we skip that orphan so the
						-- output contains exactly the captured packets. The byte_ctr = 0 term
						-- ensures a header transmission is never aborted midway, and the
						-- burst_ctr /= 0 term keeps the first header immune to the FIFO
						-- empty-flag CDC latency at readout start.
						if burst_ctr /= 0 and byte_ctr = 0 and data_fifo_valid = '0' then
							send_state <= SEND_STDBY;
							readout_ack <= readout_req_resync; -- burst fully sent: acknowledge the request
						elsif dest_ready then -- if we can send a new byte
							out_tdata <= frame_header_bytes(byte);
							out_tvalid <= '1';
							out_tlast <= '0';
							byte_ctr <= byte_ctr + 1;
							if byte_ctr = frame_header_bytes'LENGTH - 1 then -- if this is the last header byte
								send_state <= SEND_DATA; -- start sending the data
								byte_ctr <= (others => '0');
							end if;
						end if; -- end of burst / dest_ready

					when SEND_DATA => -- send data
						-- Send data until there is no more data in the buffer, going back to SEND_HEADER after each TLAST
						if data_fifo_valid then -- if there is burst data
							if dest_ready then
								byte := 3 - to_integer(byte_ctr(1 downto 0)); -- Index bytes MSB first
								out_tdata <= data_fifo_dout(8 * byte + 7 downto 8 * byte);
								out_tvalid <= '1';
								out_tlast <= '0';
								byte_ctr <= byte_ctr + 1;
								if byte_ctr(1 downto 0) = "11" then -- last byte of word
									out_tlast <= data_fifo_dout(32);
									byte_ctr <= (others => '0');
									if data_fifo_dout(32) then -- if this is the last data byte, send next packet
										burst_ctr <= burst_ctr + 1;
										send_state <= SEND_HEADER;
									end if;
								end if; -- last byte of word
							end if;
						else
							send_state <= SEND_STDBY;
							readout_ack <= readout_req_resync; -- match readout acknowledge flag with the request flag to indicate the request has been fulfilled
						end if;

				end case;

				if data_fifo_rd_rst_busy then
					out_tvalid <= '0'; -- needed
					send_state <= SEND_STDBY; -- needed to make sure we start with header transmission
					readout_ack <= '0';
				end if; -- reset
			end if; -- clk
		end process;

	end block read_blk;

end architecture impl;
