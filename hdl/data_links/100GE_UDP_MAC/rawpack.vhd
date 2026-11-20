----------------------------------------------------------------------------------
-- Company:  McGill University
--
-- Create Date: 2026-11-18
-- Design Name: chfpga
-- Module Name: rawpack
-- Target Devices: Zynq Ultrascale+ RfSoC
-- Tool Versions: Vivado 2022.2
-- Description: Raw ADC sample packetizer for the 100G Ethernet link (cge)
--
----------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.ALL;
use IEEE.numeric_std.ALL;

library work;
use work.chFPGA_Package.ALL;

-- Streams raw ADC samples of one or two channels as UDP packets for the 100G MAC (``cge``). Each sample is
-- sent as 12 bits: the 12 most significant bits of the 14-bit ADC sample (the 2 low bits are dropped).
--
-- Each packet holds the samples of ONE channel. With two channels, the module sends two packet
-- streams, A and B, one for each channel: a packet of A, then the packet of B that covers the same
-- time. A receiver gets contiguous samples of a channel from each packet, and it can separate the
-- two streams with the UDP destination port or with the stream bit of the header.
--
-- The module taps the capture bus that feeds UCAP (8 samples per clock per channel, each sample
-- MSB-aligned in 16 bits). Two channels (A and B) are selected at run time. The data source of each
-- channel (0 = FUNCGEN output, i.e. ADC or test pattern, 1 = SCALER output) is the one currently
-- selected by UCAP (UCAP control byte 9); ``rawpack`` only reports it in the packet header. Both
-- channels should use the same source. The frame timing is taken from the source of channel A.
--
-- Data rate: 8 samples x 12 bits = 96 bits per clock for each channel (38.4 Gb/s at 400 MHz, 76.8 Gb/s
-- for two channels). For each channel, two consecutive input words make a 192-bit word, and a 3:4
-- gearbox packs four of these (a "block": 8 input words, 64 samples) into 3 words of 256 bits. A
-- packet carries ``blocks_per_packet`` blocks preceded by two 32-byte header words. Each channel has
-- a block RAM FIFO that holds its packets until they are sent: a packet is sent when it is complete
-- in its FIFO, so the two streams never mix inside a packet.
--
-- In single-channel mode only stream A is sent.
--
-- Output bus: 256-bit non-blocking AXI4-Stream in the format expected by ``cge``: the first byte on
-- the wire is the most significant byte of the word.
--
-- When the module is disabled, the ``s_axis_in`` bus (normally from ``upack``) is passed to the
-- output with one clock of latency. The two uses are mutually exclusive: stop the upstream
-- transmitter before enabling ``rawpack``. When ``enable`` is cleared, the packets in progress are
-- completed and sent before the output is handed back.
--
-- Packet format (all multi-byte header fields are big-endian)
--
--   Bytes 0-13   Ethernet header (dest MAC, source MAC, ethertype 0x0800)
--   Bytes 14-33  IPv4 header (no options, DF set, TTL 64, protocol UDP, valid header checksum)
--   Bytes 34-41  UDP header (checksum = 0, i.e. not used). The destination port is ``port_dest`` for
--                stream A and ``port_dest`` + 1 for stream B (same port if ``port_per_channel`` = 0).
--   Bytes 42-63  Raw stream header:
--       42-43  magic 0x5241 ("RA")
--       44     format version (3 = one channel in each packet, 12-bit samples, little-endian bit packing)
--       45     flags: bit 0 = data source of the channel of this packet,
--                     bit 2 = single-channel mode (stream B is not sent),
--                     bit 7 = internal FIFO overflow (sticky)
--       46     bits 2:0 = channel number (0-7) of the samples of this packet,
--              bit 7 = stream: 0 = stream A (first channel), 1 = stream B (second channel)
--       47     blocks_per_packet
--       48-53  packet counter of this stream (48 bits). Each stream has its own counter. The two counters
--              are zero on the first packets of a stream that starts from the stopped state
--              (raw_active = 0), and after a reset.
--       54-59  frame number (48 bits) of the first sample of the packet. Counts frames since the
--              channelizer reset, like the UCAP timestamp.
--       60-61  word number (0-2047) of the first sample of the packet within its frame. The first
--              sample is sample number 8 * word of that frame.
--       62     stream number: incremented every time the streams start (when they are enabled, and when
--              they restart after a packetizer reset). The packet counters restart at zero at the same
--              time, so a change of stream number tells a receiver that the counters have restarted.
--              (If ``enable`` is set again before the last packets of the previous run are out, the
--              counters continue: the mode cannot change in that case, so A and B stay in step.)
--       63     reserved (0)
--   Bytes 64...  96 * blocks_per_packet bytes of samples.
--
-- Sample packing: the payload is a little-endian bit stream, i.e. stream bit n is bit (n mod 8) of
-- payload byte (n / 8). Sample number i of the packet occupies stream bits 12*i to 12*i+11 (LSB
-- first), and the samples are in time order: x(t), x(t+1), x(t+2), ... Every 2 samples fill exactly
-- 3 bytes. A sample value is the 14-bit ADC sample divided by 4 (signed, -2048 to 2047). The first
-- packets after ``enable`` start on the first word of a frame. With the default 64 blocks per
-- packet, a packet holds 4096 samples and a frame of 16384 samples is exactly 4 packets of each
-- stream. The packets of A and B with the same packet counter cover the same time.
--
entity rawpack is
	generic (
		NUMBER_OF_CHANNELS: integer := 8;
		NUMBER_OF_SOURCES: integer  := 2;

		DEFAULT_ENABLE: std_logic                         := '0';
		DEFAULT_SINGLE: std_logic                         := '0'; -- '1': send channel A only
		DEFAULT_PORT_PER_CHANNEL: std_logic               := '1'; -- '1': stream B uses UDP destination port port_dest + 1
		DEFAULT_CHAN_A: integer range 0 to 7              := 0;
		DEFAULT_CHAN_B: integer range 0 to 7              := 1;
		DEFAULT_BLOCKS_PER_PACKET: integer range 4 to 90  := 64; -- 64 blocks = 6144 bytes = 4096 samples, 4 packets of each stream per frame
		DEFAULT_MAC_SRC_ADDR: slv48  := X"005d03000000";
		DEFAULT_MAC_DEST_ADDR: slv48 := X"FFFFFFFFFFFF"; -- Ethernet broadcast
		DEFAULT_IP_SRC_ADDR: slv32   := X"0AC00002";
		DEFAULT_IP_DEST_ADDR: slv32  := X"FFFFFFFF";
		DEFAULT_IP_SRC_PORT: slv16   := X"A027";
		DEFAULT_IP_DEST_PORT: slv16  := X"A028"
	);
	port (
		-- Capture bus (same bus as UCAP), synchronous to clk
		s_axis_raw_tdata  : in slv_array(0 to NUMBER_OF_CHANNELS - 1)(127 downto 0); -- 8 samples x 16 bits per channel; as on the UCAP bus, the first sample in time is in the most significant 16 bits
		s_axis_raw_tvalid : in std_logic_vector(0 to NUMBER_OF_SOURCES - 1); -- one per data source, common to all channels
		s_axis_raw_tlast  : in std_logic_vector(0 to NUMBER_OF_SOURCES - 1); -- last word of a frame, one per data source
		source_sel_in     : in std_logic_vector(0 to NUMBER_OF_CHANNELS - 1) := (others => '0'); -- data source currently on tdata for each channel
		raw_rst           : in std_logic := '0'; -- resets the frame counters. Use the same reset as UCAP to get the same frame numbers.

		-- Pass-through input (used when rawpack is disabled)
		s_axis_in_tdata  : in std_logic_vector(255 downto 0) := (others => '0');
		s_axis_in_tvalid : in std_logic                      := '0';
		s_axis_in_tlast  : in std_logic                      := '0';

		-- Output to cge
		m_axis_out_tdata  : out std_logic_vector(255 downto 0);
		m_axis_out_tvalid : out std_logic := '0';
		m_axis_out_tlast  : out std_logic := '0';

		clk : in std_logic;
		rst : in std_logic; -- synchronous reset of the packetizer

		-- Control and reply streams
		s_axis_bsb_tdata  : in std_logic_vector(7 downto 0) := (others => '0');
		s_axis_bsb_tvalid : in std_logic                    := '0';
		s_axis_bsb_tlast  : in std_logic                    := '0';
		s_axis_bsb_tready : out std_logic;
		m_axis_bsb_tdata  : out std_logic_vector(7 downto 0);
		m_axis_bsb_tvalid : out std_logic;
		m_axis_bsb_tlast  : out std_logic;
		m_axis_bsb_tready : in std_logic                    := '0';
		bsb_clk           : in std_logic                    := '0';
		bsb_rst           : in std_logic                    := '0'
	);
end entity rawpack;

architecture impl of rawpack is

	constant NUMBER_OF_STREAMS: integer := 2; -- stream 0 = A, stream 1 = B
	constant SAMPLES_PER_WORD: integer := 8;
	constant IN_BITS_PER_SAMPLE: integer := 16; -- capture bus sample width (sample is MSB-aligned)
	constant BITS_PER_SAMPLE: integer := 12; -- bits sent per sample: the MSBs of the capture bus sample
	constant CHAN_WIDTH: integer := SAMPLES_PER_WORD * BITS_PER_SAMPLE; -- 96 bits per clock for one channel
	constant PAIR_WIDTH: integer := 2 * CHAN_WIDTH; -- 192 bits: two consecutive input words of one channel
	constant GEARBOX_STEP: integer := 256 - PAIR_WIDTH; -- 64: bits that each output word takes from the next pair, more than the previous one
	constant FORMAT_VERSION: std_logic_vector(7 downto 0) := X"03";

	-- bsb_regs indexes this vector from 0 (byte 0 bit 7 = element 0), so the range must be ascending
	constant DEFAULT_CONTROL_BYTES: std_logic_vector(0 to 28 * 8 - 1) :=
		"00000" & DEFAULT_PORT_PER_CHANNEL & DEFAULT_SINGLE & DEFAULT_ENABLE &          -- byte 0
		'0' & to_slv(DEFAULT_CHAN_B, 3) & '0' & to_slv(DEFAULT_CHAN_A, 3) &             -- byte 1
		to_slv(DEFAULT_BLOCKS_PER_PACKET, 8) &                                          -- byte 2
		X"00" &                                                                         -- byte 3
		DEFAULT_MAC_DEST_ADDR & DEFAULT_MAC_SRC_ADDR &                                  -- bytes 4-15
		DEFAULT_IP_DEST_ADDR & DEFAULT_IP_SRC_ADDR &                                    -- bytes 16-23
		DEFAULT_IP_DEST_PORT & DEFAULT_IP_SRC_PORT;                                     -- bytes 24-27

	signal control_bytes: slv8_array(0 to 27);
	signal status_bytes: slv8_array(0 to 14);

	signal cmd_dat_int_tdata: std_logic_vector(7 downto 0);
	signal cmd_dat_int_tvalid: std_logic;
	signal cmd_dat_int_tlast: std_logic;
	signal cmd_rdy_int_tready: std_logic;
	signal rply_dat_int_tdata: std_logic_vector(7 downto 0);
	signal rply_dat_int_tvalid: std_logic;
	signal rply_dat_int_tlast: std_logic;
	signal rply_rdy_int_tready: std_logic;
	signal ctrl_rst_int: std_logic;

	type u3_stream_array is array (0 to NUMBER_OF_STREAMS - 1) of unsigned(2 downto 0);
	type u48_stream_array is array (0 to NUMBER_OF_STREAMS - 1) of unsigned(47 downto 0);
	type slv256_stream_array is array (0 to NUMBER_OF_STREAMS - 1) of std_logic_vector(255 downto 0);

	-- Registered control values
	signal enable: std_logic := '0';
	signal single: std_logic := '0';
	signal port_per_channel: std_logic := '0';
	signal sel: u3_stream_array := (others => (others => '0')); -- channel of each stream
	signal blocks_per_packet: unsigned(7 downto 0) := (others => '0');
	signal last_block: unsigned(7 downto 0) := (others => '0'); -- blocks_per_packet - 1
	signal last_word: unsigned(10 downto 0) := (others => '0'); -- 3 * blocks_per_packet - 1: last data word of a packet
	signal fifo_words_per_packet: unsigned(10 downto 0) := (others => '1'); -- 3 * blocks_per_packet + 1: the data words and the information word
	signal src_port_mask: std_logic_vector(7 downto 0);
	signal mac_dest, mac_src: slv48;
	signal ip_dest, ip_src: slv32;
	signal port_dest, port_src: slv16;

	-- Frame tracking, one per data source
	signal frame_ctr: u48_array(0 to NUMBER_OF_SOURCES - 1) := (others => (others => '0'));
	type u11_array_t is array (natural range <>) of unsigned(10 downto 0);
	signal word_ctr: u11_array_t(0 to NUMBER_OF_SOURCES - 1) := (others => (others => '0'));

	-- Stage 0: channel selection
	type slv128_stream_array is array (0 to NUMBER_OF_STREAMS - 1) of std_logic_vector(127 downto 0);
	signal ch0: slv128_stream_array;
	signal v0: std_logic := '0';
	signal ts0: unsigned(47 downto 0);
	signal w0: unsigned(10 downto 0);
	signal src: std_logic_vector(0 to NUMBER_OF_STREAMS - 1) := (others => '0'); -- data source of the channel of each stream

	-- Stage 1: 12-bit packing, and two consecutive input words joined
	type pair_stream_array is array (0 to NUMBER_OF_STREAMS - 1) of std_logic_vector(PAIR_WIDTH - 1 downto 0);
	signal d1: pair_stream_array;
	signal v1: std_logic := '0';
	signal ts1: unsigned(47 downto 0);
	signal w1: unsigned(10 downto 0) := (others => '1');

	-- Stage 2: 3:4 gearbox of each stream
	signal running: std_logic := '0';
	signal phase: unsigned(1 downto 0) := (others => '0'); -- pair number in the block
	signal block_ctr: unsigned(7 downto 0) := (others => '0'); -- block number in the packet
	signal hold: pair_stream_array;
	signal stream_number: unsigned(7 downto 0) := (others => '0'); -- not cleared by rst, so a restart after a reset is visible

	-- Packet FIFO of each stream (block RAM). For each packet it holds one information word (frame
	-- and word number of the first sample), then the data words. It holds a complete packet of its
	-- stream while a packet of the other stream is sent: at most about 1.4 packets (380 words with the
	-- largest packets).
	constant FIFO_ADDR_WIDTH: integer := 9; -- 512 words
	type fifo_ptr_array is array (0 to NUMBER_OF_STREAMS - 1) of unsigned(FIFO_ADDR_WIDTH downto 0);
	signal fifo_wr_data: slv256_stream_array;
	signal fifo_wr_en: std_logic_vector(0 to NUMBER_OF_STREAMS - 1) := (others => '0');
	signal fifo_wr_ptr, fifo_rd_ptr: fifo_ptr_array := (others => (others => '0'));
	signal fifo_q: slv256_stream_array; -- word at fifo_rd_ptr, two clocks later
	signal fifo_overflow: std_logic_vector(0 to NUMBER_OF_STREAMS - 1) := (others => '0');
	signal fifo_empty: std_logic_vector(0 to NUMBER_OF_STREAMS - 1) := (others => '1');
	signal packet_ready: std_logic_vector(0 to NUMBER_OF_STREAMS - 1) := (others => '0'); -- a complete packet is in the FIFO
	signal fifo_overflow_sticky: std_logic := '0';

	-- Header
	signal udp_length, ip_length: unsigned(15 downto 0);
	signal csum_a, csum_b, csum_c: unsigned(16 downto 0);
	signal csum_total: unsigned(19 downto 0);
	signal ip_checksum: std_logic_vector(15 downto 0);
	signal header1: std_logic_vector(255 downto 0);
	signal header2: slv256_stream_array; -- second header word of each stream, without the fields that change with each packet

	-- Packet sequencer
	type tx_state_type is (IDLE, START, SEND_HEADER1, SEND_HEADER2, SEND_DATA);
	signal tx_state: tx_state_type := IDLE;
	signal tx_stream: integer range 0 to NUMBER_OF_STREAMS - 1 := 0; -- stream of the packet in progress
	signal last_stream: integer range 0 to NUMBER_OF_STREAMS - 1 := NUMBER_OF_STREAMS - 1; -- stream of the previous packet
	signal rd_word_ctr: unsigned(10 downto 0) := (others => '0'); -- data words read from the FIFO
	signal tx_word_ctr: unsigned(10 downto 0) := (others => '0'); -- data words sent
	signal packet_ctr: u48_stream_array := (others => (others => '0'));
	signal pkt_tdata: std_logic_vector(255 downto 0);
	signal pkt_tvalid: std_logic := '0';
	signal pkt_tlast: std_logic := '0';
	signal raw_active: std_logic := '0';

	attribute ram_style: string;

begin

	-- Bridge the BSB bus to the clk domain so all the registers are synchronous to the data path.
	bsb_fifo0: entity work.bsb_async_fifo
		port map (
			cmd_a_tdata   => s_axis_bsb_tdata,
			cmd_a_tvalid  => s_axis_bsb_tvalid,
			cmd_a_tlast   => s_axis_bsb_tlast,
			cmd_a_tready  => s_axis_bsb_tready,
			rply_a_tdata  => m_axis_bsb_tdata,
			rply_a_tvalid => m_axis_bsb_tvalid,
			rply_a_tlast  => m_axis_bsb_tlast,
			rply_a_tready => m_axis_bsb_tready,
			a_clk         => bsb_clk,

			cmd_b_tdata   => cmd_dat_int_tdata,
			cmd_b_tvalid  => cmd_dat_int_tvalid,
			cmd_b_tlast   => cmd_dat_int_tlast,
			cmd_b_tready  => cmd_rdy_int_tready,
			rply_b_tdata  => rply_dat_int_tdata,
			rply_b_tvalid => rply_dat_int_tvalid,
			rply_b_tlast  => rply_dat_int_tlast,
			rply_b_tready => rply_rdy_int_tready,
			b_clk         => clk,

			rst       => bsb_rst,
			b_rst_out => ctrl_rst_int
		);

	-- Memory Map
	-- ------------------------------------------------------------------------------------------
	-- |  Page   | Addr |Bit(s)|     Name            | Description                               |
	-- |---------|------|------|---------------------|-------------------------------------------|
	-- | CONTROL |  0   |  0   | enable              | '1': stream raw samples. '0': pass the upstream bus through |
	-- |         |      |  1   | single              | '1': send stream A only. Taken into account only while the stream is stopped (raw_active = 0). |
	-- |         |      |  2   | port_per_channel    | '1': the UDP destination port of stream B is port_dest + 1. '0': the two streams use port_dest. Taken into account only while the stream is stopped. |
	-- |         |  1   | 2:0  | chan_a              | Channel of stream A (0-7)                 |
	-- |         |      | 6:4  | chan_b              | Channel of stream B (0-7)                 |
	-- |         |  2   | 7:0  | blocks_per_packet   | Blocks (96 bytes, 64 samples) per packet. 4 to 90. Taken into account only while the stream is stopped (raw_active = 0). |
	-- |         |  3   | 7:0  | src_port_mask       | UDP source port = src_port + (packet counter and mask) |
	-- |         | 4-9  | 47:0 | mac_dest            | Destination MAC address                   |
	-- |         |10-15 | 47:0 | mac_src             | Source MAC address                        |
	-- |         |16-19 | 31:0 | ip_dest             | Destination IP address                    |
	-- |         |20-23 | 31:0 | ip_src              | Source IP address                         |
	-- |         |24-25 | 15:0 | port_dest           | UDP destination port of stream A          |
	-- |         |26-27 | 15:0 | port_src            | UDP source port                           |
	-- | STATUS  |  0   |  0   | running             | Samples are being packed                  |
	-- |         |      |  1   | raw_active          | The output bus carries the raw stream     |
	-- |         |      |  2   | fifo_overflow       | Packet FIFO overflow (sticky until reset). The streams are not valid after an overflow: reset. |
	-- |         |  1   | 7:0  | packet_ctr          | Low 8 bits of the packet counter of stream A |
	-- |         |  2   | 7:0  | source_sel          | Data source of each channel (bit 0 = channel 0) |
	-- |         | 3-8  | 47:0 | packet_ctr_a        | Packet counter of stream A (48 bits): packets sent since the last start. The bytes are read one at a time: read it when the stream is stopped. |
	-- |         | 9-14 | 47:0 | packet_ctr_b        | Packet counter of stream B (48 bits)      |
	-- ------------------------------------------------------------------------------------------
	bsb_regs0: entity work.bsb_regs
		generic map (
			DEFAULT_CONTROL_BYTES   => DEFAULT_CONTROL_BYTES,
			NUMBER_OF_CONTROL_BYTES => control_bytes'Length(1),
			NUMBER_OF_STATUS_BYTES  => status_bytes'Length(1)
		)
		port map (
			s_axis_bsb_tdata  => cmd_dat_int_tdata,
			s_axis_bsb_tvalid => cmd_dat_int_tvalid,
			s_axis_bsb_tlast  => cmd_dat_int_tlast,
			s_axis_bsb_tready => cmd_rdy_int_tready,
			m_axis_bsb_tdata  => rply_dat_int_tdata,
			m_axis_bsb_tvalid => rply_dat_int_tvalid,
			m_axis_bsb_tlast  => rply_dat_int_tlast,
			m_axis_bsb_tready => rply_rdy_int_tready,
			bsb_clk           => clk,
			bsb_rst           => ctrl_rst_int,

			control_bytes => control_bytes,
			status_bytes  => status_bytes
		);

	status_bytes(0) <= (0 => running, 1 => raw_active, 2 => fifo_overflow_sticky, others => '0');
	status_bytes(1) <= std_logic_vector(packet_ctr(0)(7 downto 0));
	status_bytes(2) <= reverse_bits_and_dir(source_sel_in);
	status_bytes(3 to 8) <= to_slv8_array(packet_ctr(0));
	status_bytes(9 to 14) <= to_slv8_array(packet_ctr(1));

	-- Register the control values and pre-compute everything that depends only on them. These
	-- values are static while the stream is running.
	ctrl_proc: process(all)
		variable bpp: unsigned(10 downto 0);
		variable ip_header: std_logic_vector(20 * 8 - 1 downto 0);
		variable udp_header: std_logic_vector(8 * 8 - 1 downto 0);
		variable fold: unsigned(16 downto 0);
		variable port_src_eff, port_dest_eff: unsigned(15 downto 0);
		variable flags: std_logic_vector(7 downto 0);
		variable chan_byte: std_logic_vector(7 downto 0);
	begin
		if rising_edge(clk) then
			enable <= control_bytes(0)(0);
			sel(0) <= unsigned(control_bytes(1)(2 downto 0));
			sel(1) <= unsigned(control_bytes(1)(6 downto 4));
			-- The mode, the port option and the packet size are taken only while the raw stream is
			-- completely stopped, so a change made while it runs (or before the last packet is out)
			-- cannot corrupt a packet.
			if not raw_active then
				single <= control_bytes(0)(1);
				port_per_channel <= control_bytes(0)(2);
				blocks_per_packet <= unsigned(control_bytes(2));
			end if;
			src_port_mask <= control_bytes(3);
			mac_dest <= std_logic_vector(to_unsigned(control_bytes(4 to 9)));
			mac_src <= std_logic_vector(to_unsigned(control_bytes(10 to 15)));
			ip_dest <= std_logic_vector(to_unsigned(control_bytes(16 to 19)));
			ip_src <= std_logic_vector(to_unsigned(control_bytes(20 to 23)));
			port_dest <= std_logic_vector(to_unsigned(control_bytes(24 to 25)));
			port_src <= std_logic_vector(to_unsigned(control_bytes(26 to 27)));

			-- Packet geometry: 3 data words per block
			bpp := resize(blocks_per_packet, 11);
			last_block <= blocks_per_packet - 1;
			last_word <= shift_left(bpp, 1) + bpp - 1;
			fifo_words_per_packet <= shift_left(bpp, 1) + bpp + 1;

			-- Lengths: UDP header (8) + raw stream header (22) + 32 bytes per data word
			udp_length <= 30 + shift_left(resize(last_word + 1, 16), 5);
			ip_length <= 20 + udp_length;

			-- IP header checksum, computed over three clocks. Constant header words:
			-- 0x4500 (version/length/DSCP), 0x0000 (ID), 0x4000 (don't fragment), 0x4011 (TTL 64, UDP).
			csum_a <= resize(ip_length, 17) + X"4500";
			csum_b <= resize(unsigned(ip_src(31 downto 16)), 17) + unsigned(ip_src(15 downto 0));
			csum_c <= resize(unsigned(ip_dest(31 downto 16)), 17) + unsigned(ip_dest(15 downto 0));
			csum_total <= resize(csum_a, 20) + csum_b + csum_c + X"8011";
			fold := resize(csum_total(15 downto 0), 17) + csum_total(19 downto 16);
			fold := resize(fold(15 downto 0), 17) + fold(16 downto 16); -- add the carry back (1's complement sum)
			ip_checksum <= not std_logic_vector(fold(15 downto 0));

			-- Header words. The first byte on the wire is the most significant byte.
			ip_header := X"4500" & std_logic_vector(ip_length) & X"0000" & X"4000" & X"40" & X"11" & ip_checksum & ip_src & ip_dest;
			header1 <= mac_dest & mac_src & X"0800" & ip_header(20 * 8 - 1 downto 2 * 8);
			for s in 0 to NUMBER_OF_STREAMS - 1 loop
				-- Rotating the source port lets the receiving NIC spread the packets over its receive queues
				port_src_eff := unsigned(port_src) + unsigned(packet_ctr(s)(7 downto 0) and unsigned(src_port_mask));
				port_dest_eff := unsigned(port_dest);
				if port_per_channel = '1' and s = 1 then
					port_dest_eff := unsigned(port_dest) + 1;
				end if;
				udp_header := std_logic_vector(port_src_eff) & std_logic_vector(port_dest_eff) & std_logic_vector(udp_length) & X"0000";
				flags := (0 => src(s), 2 => single, 7 => fifo_overflow_sticky, others => '0');
				chan_byte := to_std_logic(s = 1) & "0000" & std_logic_vector(sel(s));
				-- The packet counter, the frame and word numbers and the stream number are set when the packet is sent
				header2(s) <= ip_header(15 downto 0) & udp_header &
				              X"5241" & FORMAT_VERSION & flags & chan_byte &
				              std_logic_vector(blocks_per_packet) &
				              X"000000000000" & X"000000000000" & X"0000" & X"0000";
			end loop;
		end if;
	end process ctrl_proc;

	-- Count the frames and words of every data source, like UCAP does, so the frame numbers are
	-- valid whichever source is selected.
	frame_proc: process(all) begin
		if rising_edge(clk) then
			for src in 0 to NUMBER_OF_SOURCES - 1 loop
				if s_axis_raw_tvalid(src) then
					word_ctr(src) <= word_ctr(src) + 1;
					if s_axis_raw_tlast(src) then
						word_ctr(src) <= (others => '0');
						frame_ctr(src) <= frame_ctr(src) + 1;
					end if;
				end if;
			end loop;
			if raw_rst then
				word_ctr <= (others => (others => '0'));
				frame_ctr <= (others => (others => '0'));
			end if;
		end if;
	end process frame_proc;

	-- Stages 0 and 1: select the channel of each stream, keep the 12 MSBs of each sample, and join
	-- two consecutive input words (an even word of the frame, then the odd word that follows) into
	-- one 192-bit word. Frames have an even number of words, so the word number tells which half a
	-- word is.
	sel_proc: process(all)
		variable s0: integer range 0 to NUMBER_OF_SOURCES - 1;
		variable packed: std_logic_vector(CHAN_WIDTH - 1 downto 0); -- the 8 samples of a channel, 12 bits each, first sample in the low bits
	begin
		if rising_edge(clk) then
			for s in 0 to NUMBER_OF_STREAMS - 1 loop
				src(s) <= source_sel_in(to_integer(sel(s)));
				ch0(s) <= s_axis_raw_tdata(to_integer(sel(s)));
			end loop;
			s0 := to_integer(unsigned'("" & source_sel_in(to_integer(sel(0)))));
			v0 <= s_axis_raw_tvalid(s0);
			ts0 <= frame_ctr(s0);
			w0 <= word_ctr(s0);

			v1 <= '0';
			for s in 0 to NUMBER_OF_STREAMS - 1 loop
				-- Sample n in time order is in input slot 7-n (the first sample is in the MSBs of the capture
				-- word). It goes to position n, so that the output bit stream is in time order.
				for n in 0 to SAMPLES_PER_WORD - 1 loop
					packed((n + 1) * BITS_PER_SAMPLE - 1 downto n * BITS_PER_SAMPLE) :=
						ch0(s)((SAMPLES_PER_WORD - n) * IN_BITS_PER_SAMPLE - 1 downto (SAMPLES_PER_WORD - n) * IN_BITS_PER_SAMPLE - BITS_PER_SAMPLE);
				end loop;
				if v0 then
					if w0(0) = '0' then
						d1(s)(CHAN_WIDTH - 1 downto 0) <= packed;
					else
						d1(s)(PAIR_WIDTH - 1 downto CHAN_WIDTH) <= packed;
					end if;
				end if;
			end loop;
			if v0 then
				if w0(0) = '0' then
					ts1 <= ts0;
					w1 <= w0;
				else
					v1 <= '1';
				end if;
			end if;

			if rst then
				v0 <= '0';
				v1 <= '0';
				w1 <= (others => '1'); -- not a frame start: a pair without its first word cannot start the stream
			end if;
		end if;
	end process sel_proc;

	-- Stage 2: 3:4 gearbox of each stream. Four 192-bit words make three 256-bit words. Output word
	-- j of a block is made of the last 192-64j bits of pair j and the first 64(j+1) bits of pair
	-- j+1, so no output is produced on the first pair of a block. On the first pair of a packet,
	-- that free slot is used to write the information word of the packet in the FIFO.
	gbx_proc: process(all)
		variable accept: boolean;
	begin
		if rising_edge(clk) then
			fifo_wr_en <= (others => '0');
			accept := FALSE;

			if v1 then
				if running then
					if phase = 0 and block_ctr = 0 and enable = '0' then
						running <= '0'; -- stop on a packet boundary so the last packets are complete
					else
						accept := TRUE;
					end if;
				elsif enable = '1' and w1 = 0 then
					running <= '1'; -- start on the first word of a frame
					stream_number <= stream_number + 1;
					accept := TRUE;
				end if;
			end if;

			if accept then
				for s in 0 to NUMBER_OF_STREAMS - 1 loop
					hold(s) <= d1(s);
					if phase = 0 then
						fifo_wr_data(s) <= (others => '0');
						fifo_wr_data(s)(58 downto 0) <= std_logic_vector(ts1) & std_logic_vector(w1); -- information word
					else
						for p in 1 to 3 loop
							if phase = p then
								fifo_wr_data(s) <= d1(s)(GEARBOX_STEP * p - 1 downto 0) & hold(s)(PAIR_WIDTH - 1 downto GEARBOX_STEP * (p - 1));
							end if;
						end loop;
					end if;
					if (phase /= 0 or block_ctr = 0) and (s = 0 or single = '0') then
						fifo_wr_en(s) <= '1';
					end if;
				end loop;

				phase <= phase + 1;
				if phase = 3 then
					if block_ctr = last_block then
						block_ctr <= (others => '0');
					else
						block_ctr <= block_ctr + 1;
					end if;
				end if;
			end if;

			if rst then
				running <= '0';
				phase <= (others => '0');
				block_ctr <= (others => '0');
				fifo_wr_en <= (others => '0');
			end if;
		end if;
	end process gbx_proc;

	-- Packet FIFOs
	fifo_gen: for s in 0 to NUMBER_OF_STREAMS - 1 generate
		type fifo_ram_type is array (0 to 2 ** FIFO_ADDR_WIDTH - 1) of std_logic_vector(255 downto 0);
		signal fifo_ram: fifo_ram_type;
		attribute ram_style of fifo_ram: signal is "block";
		signal ram_q: std_logic_vector(255 downto 0);
		signal level: unsigned(FIFO_ADDR_WIDTH downto 0);
	begin
		level <= fifo_wr_ptr(s) - fifo_rd_ptr(s);

		fifo_proc: process(all) begin
			if rising_edge(clk) then
				fifo_overflow(s) <= '0';
				if fifo_wr_en(s) then
					if level(FIFO_ADDR_WIDTH) then -- full: the word is dropped
						fifo_overflow(s) <= '1';
					else
						fifo_ram(to_integer(fifo_wr_ptr(s)(FIFO_ADDR_WIDTH - 1 downto 0))) <= fifo_wr_data(s);
						fifo_wr_ptr(s) <= fifo_wr_ptr(s) + 1;
					end if;
				end if;
				-- Read: the block RAM register, then its output register
				ram_q <= fifo_ram(to_integer(fifo_rd_ptr(s)(FIFO_ADDR_WIDTH - 1 downto 0)));
				fifo_q(s) <= ram_q;

				packet_ready(s) <= to_std_logic(level >= fifo_words_per_packet);
				fifo_empty(s) <= to_std_logic(level = 0);
				if rst then
					fifo_wr_ptr(s) <= (others => '0');
					packet_ready(s) <= '0';
				end if;
			end if;
		end process fifo_proc;
	end generate fifo_gen;

	-- Packet sequencer. A packet is sent when it is complete in its FIFO, and the streams take
	-- turns: A, then B. For each packet: read the information word, send the two header words, then
	-- the data words. A word read from a FIFO is available two clocks later:
	--
	--   state         FIFO word read    word sent
	--   START         information
	--   SEND_HEADER1  data 0            header 1
	--   SEND_HEADER2  data 1            header 2 (with the information word)
	--   SEND_DATA     data 2, 3, ...    data 0, 1, ...
	tx_proc: process(all)
		variable other: integer range 0 to NUMBER_OF_STREAMS - 1;
	begin
		if rising_edge(clk) then
			pkt_tvalid <= '0';
			pkt_tlast <= '0';

			case tx_state is
				when IDLE =>
					other := NUMBER_OF_STREAMS - 1 - last_stream;
					if packet_ready(other) then
						tx_stream <= other;
						tx_state <= START;
					elsif packet_ready(last_stream) then
						tx_stream <= last_stream;
						tx_state <= START;
					end if;

				when START =>
					fifo_rd_ptr(tx_stream) <= fifo_rd_ptr(tx_stream) + 1;
					rd_word_ctr <= (others => '0');
					tx_state <= SEND_HEADER1;

				when SEND_HEADER1 =>
					fifo_rd_ptr(tx_stream) <= fifo_rd_ptr(tx_stream) + 1;
					rd_word_ctr <= rd_word_ctr + 1;
					pkt_tdata <= header1;
					pkt_tvalid <= '1';
					tx_state <= SEND_HEADER2;

				when SEND_HEADER2 =>
					fifo_rd_ptr(tx_stream) <= fifo_rd_ptr(tx_stream) + 1;
					rd_word_ctr <= rd_word_ctr + 1;
					pkt_tdata(255 downto 128) <= header2(tx_stream)(255 downto 128);
					pkt_tdata(127 downto 80) <= std_logic_vector(packet_ctr(tx_stream));
					pkt_tdata(79 downto 32) <= fifo_q(tx_stream)(58 downto 11); -- frame number of the first sample
					pkt_tdata(31 downto 16) <= "00000" & fifo_q(tx_stream)(10 downto 0); -- word number of the first sample
					pkt_tdata(15 downto 0) <= std_logic_vector(stream_number) & X"00";
					pkt_tvalid <= '1';
					packet_ctr(tx_stream) <= packet_ctr(tx_stream) + 1;
					tx_word_ctr <= (others => '0');
					tx_state <= SEND_DATA;

				when SEND_DATA =>
					if rd_word_ctr <= last_word then
						fifo_rd_ptr(tx_stream) <= fifo_rd_ptr(tx_stream) + 1;
						rd_word_ctr <= rd_word_ctr + 1;
					end if;
					-- The gearbox words are little-endian (stream bit 0 in bit 0); cge sends the most significant byte first.
					pkt_tdata <= reverse_bytes(fifo_q(tx_stream));
					pkt_tvalid <= '1';
					tx_word_ctr <= tx_word_ctr + 1;
					if tx_word_ctr = last_word then
						pkt_tlast <= '1';
						last_stream <= tx_stream;
						tx_state <= IDLE;
					end if;
			end case;

			if or fifo_overflow then
				fifo_overflow_sticky <= '1';
			end if;

			-- A stream that starts from the stopped state starts with the packet counters at zero. The
			-- counters of A and B are then equal for the packets that cover the same time, whatever was
			-- sent before (a run in single-channel mode advances only the counter of A, and leaves the
			-- turn to stream B). The counters
			-- keep their value after the stream stops, so that the host can read them. The transmitter
			-- is idle here: raw_active is still '0' on the first clock cycle of ``enable``.
			if enable = '1' and raw_active = '0' then
				packet_ctr <= (others => (others => '0'));
				last_stream <= NUMBER_OF_STREAMS - 1; -- stream A is sent first, also after a run in single-channel mode
			end if;

			if rst then
				tx_state <= IDLE;
				last_stream <= NUMBER_OF_STREAMS - 1;
				fifo_rd_ptr <= (others => (others => '0'));
				packet_ctr <= (others => (others => '0'));
				fifo_overflow_sticky <= '0';
				pkt_tvalid <= '0';
				pkt_tlast <= '0';
			end if;
		end if;
	end process tx_proc;

	-- Output selection. The raw stream owns the output from ``enable`` until its last packet is out.
	out_proc: process(all) begin
		if rising_edge(clk) then
			raw_active <= enable or running or (or fifo_wr_en) or not (and fifo_empty) or to_std_logic(tx_state /= IDLE);
			if raw_active or pkt_tvalid then
				m_axis_out_tdata <= pkt_tdata;
				m_axis_out_tvalid <= pkt_tvalid;
				m_axis_out_tlast <= pkt_tlast;
			else
				m_axis_out_tdata <= s_axis_in_tdata;
				m_axis_out_tvalid <= s_axis_in_tvalid;
				m_axis_out_tlast <= s_axis_in_tlast;
			end if;
			if rst then
				m_axis_out_tvalid <= '0';
				m_axis_out_tlast <= '0';
			end if;
		end if;
	end process out_proc;

end architecture impl;
