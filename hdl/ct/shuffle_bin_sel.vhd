----------------------------------------------------------------------------------
-- Company: McGill University
-- Engineer: J.-F. Cliche
--
-- Create Date:    16:32:32 05/02/2011
-- Design Name: chFPGA PoC
-- Module Name:    shuffle_bin_sel - Behavioral
-- Project Name: CHIME
-- Target Devices: Virtex 6 or 7 series
--
-- Revision:
-- Revision 0.01 - File Created
--    2011-07-18 JFC: Modified output interface to 32 bits, with header inserted in the stream
--                    Major cleanup of the FIFO writer code to make it more readable (?). Removed all (?) combinatorial signals.
--    2012-05-31 JFC: Modified for AXI4 Streaming interface. Removed the VALID handling. All frames are processed, but the TUSER flags are passed on to the header and output.
--    2012-10-20 JFC: Made the RESET synchronous to allow more flexibility to the Synthesizer and help meet timing constraints.
--                    Resized the word counter to LOG2_MAX_NUMBER_OF_WORDS to reduce the load on the RAM output (the mask bit a) determines when to
--                    increment the counter and b)is used to mux whether we store length or length+1 in header)
--    2013-12-05 JFC: Added 4-bit mode and multi-frame packing support. Output reset is now same as input reset to avoid saturating the FIFOs unless the right sequence of reset is used.
--    2014-01-14 JFC: Modified into CHAN_SEL with new architecture: Now has a front-end FIFO for alignment/half-word selection/buffer consecutively selected channels. There is no more output fifos.
--                    Also added handling of headers and flagging info.
--    ...
--    See GIT repository for more history
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use ieee.std_logic_misc.ALL; -- for and_reduce
use ieee.math_real.ALL; -- for ceil()

library unisim;
use unisim.vcomponents.ALL;
use work.chfpga_package.ALL; -- Get all component definitions

------- shuffle_bin_sel ENTITY DECLARATION ----------------------

-- Aggregates data for selected frequency bins from multiple incoming
-- packetized input data streams into a single output data stream.
--
-- The bin selector aggregates data from some or all of its input streams. In order to maintain a
-- manageable data rate on the resulting aggregated output lanes, some data must be dropped. For this reason,
-- only a fraction of the frequency bins are kept.
--
-- For example, if we have  200 MWord/s of data coming from 16 lanes and to select 1/16 of the frequency bins,
-- the output stream will still clock at 200 MWords/s.
--
-- The frequency channels are selected by writing a bit pattern into a RAM block, where each bit identifies
-- whether a frequency bin  is to passed on to the output.
--
-- The bin selector can have one or multiple outputs. All the outputs are filtered using the same bin
-- selection map. Each output of a  N-inputs, M-outputs bin selector gathers data from N/M input
-- lanes. A bin selector with multiple outputs allows partial combining of the channels of incoming streams, which can then be
-- combined in a downstream crossbar. This feature provides the flexibility required to support multiple software-configurable corner turn modes.
--
-- The input data is provided by an array of N 32-bit-wide non-blocking AXI4-Streaming buses. Each
-- incoming stream have headers, followed by a block of data, a block of data flags, frame flags, and
-- a final packet flag word. The frames must already be aligned.
--
-- The output consist of M 32-bit-wide non-blocking AXI4-Streaming buses, with a same overall structure, but with ddta from more channels and less bins.
-- The output is non-blocking, meaning it will not wait for a TREADY signal from the destination before sending data. The destination must have buffering to cope with uneven data flow.
--
-- The packets for both input and output streams have the following structure:
--
--   - Packet header (4 words)
--   - Data block, consisting of:
--
--        - For each frame
--
--           - For each bin
--
--              - data words, from lower channel to higher channel number, 1 byte ((4+4) bit complex value)  per channel, little endian ordering (lower channel in Leasy significant Byte).
--
--    - Data flag block, consisting of:
--
--        - For each frame
--
--         - For each bin
--
--            - data flag words, 1 bit per channel, same order as data block channels, bit 0 of word correspond to the lower channel number.
--
--  - Frame flags, consisting of
--
--       - For each frame
--
--           - Frame flag words, 2 bits per channel : ADC saturation flags in bits 0-15, FFT saturation flags in bits 16-31.
--
--  - Packet flags (1 word)
--
-- The data from multiple lanes is combined and buffers in a way that this structure is preserved
-- at the output. The data words, data flags and frame flags are sent out in the order of the input
-- lanes: data from  lane 0 first, then data from lane 1 etc.
--
-- The bin selector operates on a single clock to simplify the logic and resource usage. All inputs and outputs buses operate on that clock. is clocked on a separate clock than the channelizer processor outputs.
-- This means that the correlator can be clocked faster than the channelizer processor clock to allow more time for transmission of the the header overhead or simply to allow the correlator to process more channels.
-- It is important that in all cases the output data rate of the FIFO is higher than the rate required to transmit the selected data plus the header bytes.
--
-- Each bit in the RAM block identifies whether a bin received in the incoming stream is to be
-- included in the output. Bit 0 in dicates if the incoming bin 0 is kept, bit 1 indicates for bin 1
-- etc. The memory map is software configurable over the control interface.
--
-- The control interface offers a number of registers that must be programmed with the expected
-- input packet geometry and the desired output packet contents.
--
-- The hardwired generics parameter, `COMBINE_DATA_FLAGS`, indicates if the bin selector shall
-- combine data flags from two adjacent lanes to fill a 32-bit word. Indeed, data from the first
-- crossbar contain data from 16 channels, and only the lower half or the data flag words are
-- occupied. Combining the flags on the 2nd crossbar saves bandwidth, but is not needed on the
-- subsequent crossbars since all 32-bits are packed with flags.
--

entity shuffle_bin_sel is
	generic (
		PLATFORM_TYPE        : platform_type_enum;       -- necessary to select the proper FIFOs
		BIN_SEL_NUMBER     : integer;       -- Bin selector index number. Output lanes will be numbered in the packet header as lane_number=  BIN_SEL_NUMBER*NUMBER_OF_OUTPUTS + bin_sel_output_lane_index
		NUMBER_OF_INPUTS   : integer;       -- Number of input streams. Must be a multiple of NUMBER_OF_OUTPUTS.
		NUMBER_OF_OUTPUTS  : integer := 1;  -- Number of output streams. Must be a multiple of 2 if COMBINE_DATA_FLAGS=TRUE
		COMBINE_DATA_FLAGS : boolean := TRUE;
		WORDS_PER_BIN_MAX  : integer := 4;  -- Maximum number of words that can be present in a bin on one input lane. The 2nd crossbar receives up to 4 words. The 3rd crossbar will can have up to 4*16=64 words.
		BINS_PER_FRAME_MAX : integer := 64; -- Maximum number of bins per frame
		FIFO_TYPE_MAP      : integer_array  -- Specifies the type of data FIFO to use for each input lane in order to balance resource type and acheive the highest logic density. 0= use pairs of BRAM/Embedded FIFOs, 1=Use shift-register (LUT-based) FIFO.
	);
	port (
		-- Input interface (non-blocking, i.e. always accept data)

		s_axis_tdata  : in slv32_array(0 to NUMBER_OF_INPUTS - 1);
		s_axis_tvalid : in std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
		s_axis_tlast  : in std_logic_vector(0 to NUMBER_OF_INPUTS - 1);

		s_axis_global_tvalid : in std_logic; -- active while the longest packet is active
		s_axis_global_tlast  : in std_logic; -- active when the longest packet is at its last word

		-- Output interface (blocking, i.e. will send data only when the sink is ready)

		m_axis_tdata  : out slv32_array(0 to NUMBER_OF_OUTPUTS - 1);
		m_axis_tvalid : out std_logic_vector(0 to NUMBER_OF_OUTPUTS - 1);
		m_axis_tlast  : out std_logic_vector(0 to NUMBER_OF_OUTPUTS - 1);
		m_axis_terror : out std_logic_vector(0 to NUMBER_OF_OUTPUTS - 1);

		-- lane_map: in slv4_array(0 to NUMBER_OF_INPUTS-1);
		clk : in std_logic; -- Input clock, common to all channelizers
		rst : in std_logic; -- reset, synchronous to clk

		shuffle_flags_mask : in slv32; -- Specify the mask to apply on the packet flags word to trigger the terror line.

		-- Control interface (command and reply stream buses)
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
end entity shuffle_bin_sel;

--- ARCHITECTURE DECLARATION and DEFINITION ---------------------
-- Describes the logic that implement the entity's functionnalities. See this architecture for the implementation details.
--
-- The writing process waits for all channelizers to have valid data, and if the filter bit is '1', the data from each channelizer is written in their respective FIFO.
-- Then the filter RAM 'bit' pointer is incremented.
-- When the last word of a frame is detected, the pointer is reset, the header is constructed and is written in the HEADER FIFO.
-- This assumes that all the input data streams are aligned.
--
-- When the readout process detects

architecture behavioral of shuffle_bin_sel is

	attribute KEEP: string;
	attribute EQUIVALENT_REGISTER_REMOVAL: string;

	constant FPGA_SERIES: fpga_series_enum := PLATFORM_INFO(PLATFORM_TYPE).FPGA_SERIES;
	constant NUMBER_OF_INPUT_LANES_PER_OUTPUT: integer := NUMBER_OF_INPUTS / NUMBER_OF_OUTPUTS;

	--- Signal definitions ------------------------------------

	signal m_axis_tdata_int: slv32_array(0 to NUMBER_OF_OUTPUTS - 1);
	signal m_axis_tvalid_int: std_logic_vector(0 to NUMBER_OF_OUTPUTS - 1);
	signal m_axis_tlast_int: std_logic_vector(0 to NUMBER_OF_OUTPUTS - 1);

	-- MASK RAM signals
	--  Port A: Control port ( data width: 8 bits)
	signal mask_ram_ctrl_addr: std_logic_vector(6 downto 0);
	-- signal mask_ram_ctrl_rd_en: std_logic;
	signal mask_ram_ctrl_wr_en: std_logic;
	signal mask_ram_ctrl_wr_en_vect: std_logic_vector(0 downto 0);
	signal mask_ram_ctrl_din: std_logic_vector(7 downto 0);
	signal mask_ram_ctrl_dout: std_logic_vector(7 downto 0);

	--  Port B: Data processing port ( data width: 1 bit)
	signal mask_ram_dout: std_logic; -- Up to 2 selection flags per word (both flags are used only in dual-channel mode, otherwise only the LSB is used)
	-- signal mask_ram_addr: UNSIGNED(8 downto 0):=(others=>'0'); -- up to 512 flag groups. Initialization needed to prevent 'U' from getting into the RAM before the clock starts and resets this register.

	constant WORD_CTR_WIDTH: integer := width(WORDS_PER_BIN_MAX);

	-- DATA FIFO signals

	signal data_fifo_rd_en: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal data_fifo_rd_en_int: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal data_fifo_wr_en: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal data_fifo_wr_en_packet_flags: std_logic := '0';
	signal data_fifo_wr_en_packet_flags_dly: std_logic := '0';
	signal data_fifo_wr_en_always: std_logic := '0';
	signal data_fifo_wr_en_always_dly: std_logic := '0';
	signal data_fifo_wr_en_if_selected: std_logic := '0';
	signal data_fifo_wr_en_if_selected_dly: std_logic := '0';
	signal data_fifo_first_word: std_logic := '0';
	signal data_fifo_first_word_dly: std_logic := '0';
	signal data_fifo_last_word_of_group: std_logic := '0';
	signal data_fifo_last_word_of_group_dly: std_logic := '0';
	signal data_fifo_combine_flag: std_logic := '0';
	signal data_fifo_combine_flag_dly: std_logic := '0';
	signal data_fifo_number_of_words: unsigned(WORD_CTR_WIDTH - 1 downto 0); -- Counts the word in the current bin
	signal data_fifo_number_of_words_dly: unsigned(WORD_CTR_WIDTH - 1 downto 0); -- Counts the word in the current bin
	signal data_fifo_empty: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal data_fifo_valid: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal data_fifo_overflow: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal data_fifo_full: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal data_fifo_din: slv35_array(0 to NUMBER_OF_INPUTS - 1) := (others => (others => '0')); -- (Only 32 bits are used) init not necessary
	signal data_fifo_dout: slv35_array(0 to NUMBER_OF_INPUTS - 1); -- (Only 32 bits are used)


	signal flags_fifo_din: std_logic_vector(WORD_CTR_WIDTH - 1 + 2 downto 0);
	signal flags_fifo_wr_en: std_logic;
	signal flags_fifo_rd_en: std_logic;
	signal flags_fifo_dout: std_logic_vector(WORD_CTR_WIDTH - 1 + 2 downto 0);
	signal flags_fifo_overflow: std_logic;
	signal flags_fifo_valid: std_logic;

	signal frame_number_capture_trig: std_logic := '0';
	signal stream_id_capture_trig: std_logic := '0';
	signal frame_number_capture_trig_dly: std_logic := '0';
	signal stream_id_capture_trig_dly: std_logic := '0';

	signal data_fifo_overflow_sticky: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);
	signal flags_fifo_overflow_sticky: std_logic;

	signal timestamp_ctr: unsigned(47 downto 0) := (others => '0');
	signal in_dat_frame_ctr: unsigned(7 downto 0) := (others => '0');
	signal recv_header_word_ctr: unsigned(width(SHUFFLE_FRAME_HEADER_WORD_LENGTH) downto 0);
	signal send_header_word_ctr: unsigned(width(SHUFFLE_FRAME_HEADER_WORD_LENGTH) downto 0);

	signal odd_bin_dly1: std_logic;
	signal odd_bin_dly2: std_logic;
	signal select_word: std_logic;

	signal reset_all: std_logic;
	signal reset_all_reg: std_logic;

	--- Define Control word and its signals
	signal control_bytes: slv8_array(0 to 7); -- default value set in the CMD_SLAVE
	signal status_bytes: slv8_array(0 to 2);

	signal stream_id: std_logic_vector(11 downto 0);
	signal user_reset: std_logic;

	signal four_bits: std_logic;
	signal use_offset_binary: std_logic;
	signal send_flags: std_logic;
	signal lane0_bypass: std_logic;
	signal lane0_bypass_reg: std_logic;
	signal overflow_reset: std_logic;
	signal number_of_output_bins_per_frame: std_logic_vector(11 downto 0);
	signal number_of_output_words_per_bin: std_logic_vector(7 downto 0);
	signal first_lane: unsigned(3 downto 0); --
	signal last_lane: unsigned(3 downto 0); --
	signal number_of_input_bins_per_frame: unsigned(7 downto 0); -- number of words that are selected by the word selection map
	signal number_of_input_words_per_bin: unsigned(6 downto 0); -- number of words in a bin (full chime max, 4 bits mode, 3rd shuffle = 256 pol/ (4 pol/word) = 64 words
	signal number_of_input_frame_flags_words_per_frame: unsigned(2 downto 0); -- number of frame flags words in each frame. 2nd crossbar gets 1, 3rd crossbar gets 2 in shuffle256 and 4 in shuffle512
	signal number_of_input_data_flags_words_per_bin: unsigned(1 downto 0); -- number of data flags words for each bin. 2nd crossbar gets 1 (half filled, use COMBINE_DATA_FLAGS=TRUE), 3rd crossbar gets 1 in shuffle256 and 2 in shuffle512
	signal frames_per_packet: unsigned(2 downto 0); -- number of input frames to put in one output frame
	signal zero_packet_flags: std_logic;

	signal word_ctr: unsigned(WORD_CTR_WIDTH - 1 downto 0); -- Counts the word in the current bin
	signal bin_ctr: unsigned(width(BINS_PER_FRAME_MAX) - 1 downto 0); -- Counts the bin in the current frame
	signal lane_en: std_logic_vector(0 to NUMBER_OF_INPUTS - 1);

	signal last_frame_number: unsigned(1 downto 0); -- Counts the current frame number in the output packet
	signal last_word_number: unsigned(word_ctr'RANGE); -- Counts the word in the current bin
	signal last_frame_flags_word_number: unsigned(word_ctr'RANGE); -- Last frame flags words in the current frame
	signal last_data_flags_word_number: unsigned(word_ctr'RANGE); -- Last  data flags words in the current bin

	signal   last_bin_number: unsigned(bin_ctr'RANGE); -- Counts the bin in the current frame
	signal   block_ctr: unsigned(1 downto 0);
	constant DATA_BLOCK: integer       := 0;
	constant DATA_FLAGS_BLOCK: integer := 1;
	constant FRAME_FLAGS_BLOCK: integer := 2;
	constant FLUSH_BLOCK: integer      := 3;


	-- constant NEXT_INPUT_BIT: integer := 32; -- (NOT USED) Indicates that the next word should come from the next input
	constant COMBINE_WORDS_BIT: integer := WORD_CTR_WIDTH; -- Indicates that the current word should be combined with the next one (enabled sending data flags block from the 1st crossbar, which occupy only 16 of the 32 bits).
	constant END_OF_PACKET_BIT: integer := WORD_CTR_WIDTH + 1; -- Indicates this is the last word of a packet, and is therefore a packet status word. Overrides any other control bits.

	signal recv_header: std_logic;
	signal packet_flags: slv32;

	-- FIFO readout signals

	signal lane: unsigned(3 downto 0); -- Current indexes the lane map
	signal first_lane_reg: unsigned(3 downto 0);
	signal last_lane_reg: unsigned(3 downto 0);
	signal sublane_active: std_logic_vector(0 to NUMBER_OF_INPUTS - 1); -- '1' for the sublanes within [first_lane, last_lane] of each output. Only those data FIFOs are written and OR-ed into the packet flags (trailer) word.
	signal frame_ctr: unsigned(1 downto 0); -- Counts the current frame number in the output packet
	signal send_header: std_logic;
	signal combine_words: std_logic;
	signal end_of_packet: std_logic;
	signal is_last_word: std_logic;
	signal is_last_lane: std_logic;
	signal send_word_ctr: unsigned(width(WORDS_PER_BIN_MAX) - 1 downto 0); -- Counts the word in the current bin

begin

	-----------------------------------------------------------------------------------
	-- CONTROL and STATUS Bytes
	-----------------------------------------------------------------------------------
	-- shuffle_bin_sel Memory Map
	-- ------------------------------------------------------------------------------
	-- |  Page   | Addr|Bit(s)|     Name             | Description                   |
	-- |---------|-----|------|----------------------|-------------------------------|
	-- | CONTROL |  0  |   7  | user_reset           | Reset the module and clears the FIFOs.|
	-- |         |     |   6  | lane0_bypass         | Bypass lane 0 |
	-- |         |     | 5:4  | number_of_input_data_flags_words_per_bin | Number of input data flags words per bin |
	-- |         |     | 3:0  | first_lane           | First input lane number |
	-- |         |  1  | 7:0  | STREAM_ID(11:4)      | Upper 8 bits of Stream ID to be used for tagging the output frames |
	-- |         |  2  | 7:4  | STREAM_ID(3:0)       | Lower 4 bits of Stream ID |
	-- |         |     |   3  | zero_packet_flags    | Zero packet flags |
	-- |         |     | 2:0  | number_of_input_frame_flags_words_per_frame | Number of input frame flags words per frame |
	-- |         |  3  | 7:0  | number_of_input_bins_per_frame | Number of input bins per frame |
	-- |         |  4  |   7  | overflow_reset        | Reset overflow counters |
	-- |         |     | 6:0  | number_of_input_words_per_bin | Number of input words per bin |
	-- |         |  5  | 7:5  | frames_per_packet    | Number of frames per packet |
	-- |         |     | 3:0  | last_lane            | Last input lane number |
	-- |         |  6  | 7:0  | number_of_output_words_per_bin | Number of output words per bin (for header) |
	-- |         |  7  |   7  | four_bits            | Four bits mode (for header) |
	-- |         |     |   6  | use_offset_binary    | Use offset binary encoding (for header) |
	-- |         |     |   5  | send_flags           | Send flags in packets |
	-- |         |     | 4:0  | number_of_output_bins_per_frame | Number of output bins per frame |
	-- | STATUS  |  0  |   7  | data_fifo_empty      | EMPTY status flag of the DATA FIFO for lane 0. Active HIGH. |
	-- |         |     |   6  | flags_fifo_overflow_sticky | Sticky flag indicating that flags FIFO has overflown. |
	-- |         |     |   5  | reset_all_reg        | Reset all register status |
	-- |         |     |   4  | COMBINE_DATA_FLAGS   | Combine data flags status |
	-- |         |     | 3:0  | NUMBER_OF_OUTPUTS    | Number of outputs |
	-- |         | 1:2 |15:0  | data_fifo_overflow_sticky | Data FIFO overflow sticky flags (one per output) |
	-- | RAM     | 0-63 | -   | MASK_RAM                 | Word selection map. Each of the 512 bit indicates whether the corresponding word (frequency bin pair) is retained by this correlator. |
	-- ------------------------------------------------------------------------------
	--

	-- CONTROL Byte 0
	user_reset                               <= control_bytes(0)(7); -- Used in both IN_CLK and OUT_CLK domain
	lane0_bypass                             <= control_bytes(0)(6);
	number_of_input_data_flags_words_per_bin <= unsigned(control_bytes(0)(5 downto 4));
	first_lane                               <= unsigned(control_bytes(0)(3 downto 0));

	-- CONTROL Byte 1-2
	stream_id                                   <= (control_bytes(1) & control_bytes(2)(7 downto 4)); --
	zero_packet_flags                           <= control_bytes(2)(3);
	number_of_input_frame_flags_words_per_frame <= unsigned(control_bytes(2)(2 downto 0));
	-- CONTROL Byte 2-3
	number_of_input_bins_per_frame <= unsigned(control_bytes(3)); -- used in IN_CLK domain

	-- CONTROL Byte 4
	overflow_reset                <= control_bytes(4)(7);
	number_of_input_words_per_bin <= unsigned(control_bytes(4)(6 downto 0)); --

	-- CONTROL Byte 5
	frames_per_packet <= unsigned(control_bytes(5)(7 downto 5)); --
	last_lane         <= unsigned(control_bytes(5)(3 downto 0)); --

	-- CONTROL Byte 6
	number_of_output_words_per_bin <= control_bytes(6); -- for the header only

	-- CONTROL Byte 7
	four_bits                       <= control_bytes(7)(7); -- for the header only
	use_offset_binary               <= control_bytes(7)(6); -- for the header only
	send_flags                      <= control_bytes(7)(5);
	number_of_output_bins_per_frame <= resize(control_bytes(7)(4 downto 0), number_of_output_bins_per_frame'LENGTH);

	-- STATUS Byte 0
	status_bytes(0)(7) <= data_fifo_empty(0);
	status_bytes(0)(6) <= flags_fifo_overflow_sticky;
	status_bytes(0)(5) <= reset_all_reg;
	status_bytes(0)(4) <= to_std_logic(COMBINE_DATA_FLAGS);
	-- status_bytes(0)(2)<= to_std_logic(IMPLEMENT_HEADER_CAPTURE);
	status_bytes(0)(3 downto 0) <= to_slv(NUMBER_OF_OUTPUTS, 4);

	-- STATUS Byte 1-2
	-- status_bytes(2)<=to_slv8_array(timestamp_capture(to_integer(unsigned(header_capture_lane_sel))));
	-- status_bytes(3)<=to_slv(DOUT_FRAME_CTR);
	status_bytes(1 to 2) <= to_slv8_array(resize(reverse_bits_and_dir(data_fifo_overflow_sticky), 16));

	-- debug ports
	-- status_bytes(4)(3 downto 0)<=to_slv(lane);
	-- status_bytes(4)(4)<= scaler_flags_fifo_overflow;
	-- status_bytes(4)(5)<= frame_flags_fifo_overflow;
	-- status_bytes(4)(6)<= data_fifo_rd_en;
	-- status_bytes(4)(7)<=data_fifo_rd_en;

	-- status_bytes(5)(3 downto 0)<= reverse_bits_and_dir(data_fifo_valid(0 to 3));
	-- status_bytes(5)(7 downto 4)<= reverse_bits_and_dir(data_fifo_overflow(0 to 3));

	-----------------------------------------------------------------------------------
	-- Memory-Mapped interface instantiation
	-----------------------------------------------------------------------------------
	-- Instantiates a memory-mapped interface to the control and status bytes

	bsb_regs0: entity work.bsb_regs
		generic map (
			NUMBER_OF_CONTROL_BYTES => control_bytes'Length(1), --
			NUMBER_OF_STATUS_BYTES  => status_bytes'Length(1), --
			DEFAULT_CONTROL_BYTES   => X"01_123_008_01_2F_00_00",
			RAM_ADDR_WIDTH          => 7,
			RAM_LATENCY             => 2,  -- Control port of RAM has an output register that creates a 2-clock latency total
			USE_RAM_DOUT_RDY        => FALSE
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
			status_bytes  => status_bytes,

			ram_din   => mask_ram_ctrl_din,
			ram_dout  => mask_ram_ctrl_dout,
			ram_addr  => mask_ram_ctrl_addr,
			ram_wr_en => mask_ram_ctrl_wr_en,
			ram_rd_en => open -- the ram is always reading
		);

	------------------------------------------------
	-- Bin selection map RAM
	------------------------------------------------

	-- Dual port RAM used to store the channel selection mask pattern
	-- The control side has 2 clock latency, as we use the embedded output registers to relax timing.
	-- The system-side port uses 1 clock output latency (no output registers) to avoid pipeling the wide data bus unnecessarily to align the ram content with the corresponding word.
	-- We will increase to 2 clock latency if the combinatorial delays are too large.
	-- Port A is an 8-bit wide interface allowing the control system to program the RAM
	-- Port B is a 2-bit interface that the processing process reads to identify if a word is to be kept.
	-- We need to use a Block RAM (as opposed to distributed RAM) so we can have assymetric aspect ratio
	mask_ram0: entity work.shuffle_bin_sel_mask_ram
		port map (
			clka   => bsb_clk,
			wea(0) => mask_ram_ctrl_wr_en,
			addra  => mask_ram_ctrl_addr,
			dina   => mask_ram_ctrl_din,
			douta  => mask_ram_ctrl_dout,

			clkb     => clk,
			web      => (others => '0'), -- we never write from this side
			dinb     => (others => '0'), -- we never write from this side
			addrb    => std_logic_vector(resize(bin_ctr,10)), -- we strip one bit because we read flags in pairs
			doutb(0) => mask_ram_dout -- two flags for each bin number
		);

	-- The flags FIFO describe provide instructions to the readout logic on how to read each block of data from the data FIFO.
	-- It indicate the size of each block of data, whether words should be combined, and when this is the last block of he packet.
	-- Implement the  4-bit wide FIFO (CB2, nominally 4x128, two per FPGA) or the 6-bit wide (CB3, 6x32, 8 per FPGA) depending on the need to save space.

	flags_fifo4_gen: if WORD_CTR_WIDTH = 2 generate -- WORDS_PER_BIN = 4

		flags_fifo0: entity work.SHUFFLE_BIN_SEL_FLAGS_FIFO4 -- 2 bit counter + 2 extra flags
			port map (
				clk  => clk,
				srst => reset_all_reg,

				din   => flags_fifo_din,
				wr_en => flags_fifo_wr_en,

				rd_en      => flags_fifo_rd_en,
				dout       => flags_fifo_dout,
				valid      => flags_fifo_valid,
				data_count => open,
				overflow   => flags_fifo_overflow
			);

	end generate flags_fifo4_gen;

	flags_fifo6_gen: if WORD_CTR_WIDTH /= 2 generate -- WORDS_PER_BIN = 16 or other. make sure we always instantiate a FIFO, so there will be an error if  flags_fifo_din/dout with don't match with the FIFO

		flags_fifo0: entity work.SHUFFLE_BIN_SEL_FLAGS_FIFO6 -- 4 bit counter + 2 extra flags
			port map (
				clk  => clk,
				srst => reset_all_reg,

				din   => flags_fifo_din,
				wr_en => flags_fifo_wr_en,

				rd_en      => flags_fifo_rd_en,
				dout       => flags_fifo_dout,
				valid      => flags_fifo_valid,
				data_count => open,
				overflow   => flags_fifo_overflow
			);

	end generate flags_fifo6_gen;

	-- DOUT_FLAGS<=(others=>'0'); -- clear flags until we decide what we will send to the correlator
	-- Generates a DATA FIFO for each of the channelizer outputs

	data_fifo_gen: for i in 0 to NUMBER_OF_INPUTS - 1 generate
		---------------------------------------------------
		-- Data FIFOs
		---------------------------------------------------
		-- The DATA FIFO stores the selected words.
		-- This is a *NOT* a First Word Fall-through FIFO (to save a set of 32 output registers)
		-- We have a FIFO for each input.
		-- This FIFO needs to be deep enough to accomodate:
		--   - D = (1-Fout/Fin/N)*W*B*F words, where
		--         N=Number of input lanes,
		--      W= words per bin,
		--      B= number of contiguous bins,
		--      F=Frames per packet,
		--      Fout/Fin: input/output word clock frequencies (after and before the CROSSBAR FIFO).
		-- For the CHIME Pathfinder second cross bar, N=16 input lanes, W=4 (16 channels, 4-bit mode), B=1024/16/8=8 bins, F=4, Fout/Fin=322/244 MHz: D= (1-322/244/16)*4*8*4 = 118 words deep
		-- In practice there are always dead cycles in the incoming data (due to 200/244 MHz crossing, backplane link data framing, gearbox etc). This gives more time for the read side to  catch up, so the effectively used depth is less than this.
		-- A single RAMB18 provides a 514 deep FWFT FIFO.
		-- We elimine this FIFO by requiring every selected bin to be followed by at least N non-selected bins. To be considered if BRAM resource availability is an issue.

		bram_fifo_gen: if FIFO_TYPE_MAP(i) = 0 and i MOD 2 = 0 generate

			data_fifo0: entity work.shuffle_bin_sel_data_fifo_bram
				port map (
					srst => reset_all_reg,
					clk  => clk,

					din   => data_fifo_din(i),
					wr_en => data_fifo_wr_en(i),
					full  => data_fifo_full(i),

					rd_en => data_fifo_rd_en(i),
					dout  => data_fifo_dout(i),
					valid => data_fifo_valid(i),
					empty => data_fifo_empty(i),

					overflow => data_fifo_overflow(i)
				);

		end generate bram_fifo_gen;

		-- Every other FIFO is implemented as an embedded FIFO to eliminate the use of external logic.
		-- WARNING: The FIFO must have the same latency as the other FIFOs! Disable Embedded register to get a latency of zero.

		embed_fifo_gen: if FIFO_TYPE_MAP(i) = 0 and i MOD 2 = 1 generate

			data_fifo_k7: if FPGA_SERIES = KINTEX7 generate

				data_fifo0: entity work.shuffle_bin_sel_data_fifo_embed
					port map (
						rst => reset_all_reg, -- async reset on K7 embed FIFOs
						clk => clk,

						din   => data_fifo_din(i),
						wr_en => data_fifo_wr_en(i),
						full  => data_fifo_full(i),

						rd_en => data_fifo_rd_en(i),
						dout  => data_fifo_dout(i),
						valid => data_fifo_valid(i),
						empty => data_fifo_empty(i),

						overflow => data_fifo_overflow(i)
					);

			end generate data_fifo_k7;

			data_fifo_up: if FPGA_SERIES = ULTRASCALEPLUS generate

				data_fifo0: entity work.shuffle_bin_sel_data_fifo_embed_up
					port map (
						srst => reset_all_reg, -- sync reset on U+ embed FIFOs
						clk  => clk,

						din   => data_fifo_din(i),
						wr_en => data_fifo_wr_en(i),
						full  => data_fifo_full(i),

						rd_en => data_fifo_rd_en(i),
						dout  => data_fifo_dout(i),
						valid => data_fifo_valid(i),
						empty => data_fifo_empty(i),

						overflow => data_fifo_overflow(i)
					);

			end generate data_fifo_up;

		end generate embed_fifo_gen;

		-- If desired, use a Shift register FIFO (35 bits x 64 words). Those use only 1 LUT per 2 bits of width.
		-- Since those are not FWFT, we use a standard FIFO and turn it into a FWFT with some extra logic.
		-- The Distributed FIFO has a latenct of 1: data is placed on the bus on the next rising edge when RD_EN is high.
		-- With the surrounding logic, this FIFO has a latency of 0: if VALID is High, the data is immediately available on the bus.
		-- When RD_EN is High and the clock rises, the current value is captured by the user, and a new value is placed on the bus

		dram_fifo_gen: if FIFO_TYPE_MAP(i) = 1 generate
			data_fifo_rd_en_int(i) <= data_fifo_rd_en(i) or not data_fifo_valid(i);

			data_fifo0: entity work.shuffle_bin_sel_data_fifo_dram
				port map (
					srst => reset_all_reg,
					clk  => clk,

					din   => data_fifo_din(i),
					wr_en => data_fifo_wr_en(i),
					full  => data_fifo_full(i),

					rd_en => data_fifo_rd_en_int(i), -- emulate a FWFT FIFO by forcing a read if there is no valid data
					dout  => data_fifo_dout(i),
					empty => data_fifo_empty(i),

					overflow => data_fifo_overflow(i)
				);

			process(all) begin
				if rising_edge(clk) then
					if reset_all_reg = '1' then
						data_fifo_valid(i) <= '0';
					elsif data_fifo_rd_en_int(i) = '1' then
						data_fifo_valid(i) <= not data_fifo_empty(i);
					end if;
				end if;
			end process;

		end generate dram_fifo_gen; -- if DRAM

	end generate data_fifo_gen; -- for i in NUMBER_OF_INPUTS

	-- Write data to the data and data flags FIFOs according to the bin selection map
	fifo_wr_proc: process(all)

		variable ix: integer range 0 to SHUFFLE_FRAME_HEADER_WORD_LENGTH - 1;
		-- variable header_word_array: slv32_array(0 to SHUFFLE_FRAME_HEADER_WORD_LENGTH-1);
		-- variable header:SHUFFLE_FRAME_HEADER_STRUCT;
		-- variable new_packet_flags: slv32;
		variable data_fifo_wr_en_var: std_logic;

	begin
		if rising_edge(clk) then
			reset_all <= rst or user_reset;
			reset_all_reg <= reset_all;

			-- Make sticky FIFO overflow flags
			if overflow_reset = '1' or reset_all_reg = '1' then
				data_fifo_overflow_sticky <= (others => '0');
				flags_fifo_overflow_sticky <= '0';
			else
				data_fifo_overflow_sticky <= data_fifo_overflow_sticky or data_fifo_overflow;
				flags_fifo_overflow_sticky <= flags_fifo_overflow_sticky or flags_fifo_overflow;
			end if;


			-- data_fifo_din_dly <= data_fifo_din;
			data_fifo_wr_en_always_dly       <= data_fifo_wr_en_always;
			data_fifo_wr_en_if_selected_dly  <= data_fifo_wr_en_if_selected;
			data_fifo_wr_en_packet_flags_dly <= data_fifo_wr_en_packet_flags;
			data_fifo_first_word_dly         <= data_fifo_first_word;
			data_fifo_last_word_of_group_dly <= data_fifo_last_word_of_group;
			data_fifo_combine_flag_dly       <= data_fifo_combine_flag;
			data_fifo_number_of_words_dly    <= data_fifo_number_of_words;

			-- Determine if words in the ongoing data group shall be written to the FIFO. This happens when:
			-- 1) they are bin-related (data, data flags) and the bin is selected;
			-- 2) they are not bin-related (frame_flags, packet_flags) and should unconditionally be written

      data_fifo_wr_en_var := data_fifo_wr_en_packet_flags_dly or data_fifo_wr_en_always_dly  or (data_fifo_wr_en_if_selected_dly and mask_ram_dout);

			flags_fifo_din(data_fifo_number_of_words_dly'length - 1 downto 0) <= to_slv(data_fifo_number_of_words_dly);
			flags_fifo_din(COMBINE_WORDS_BIT) <= data_fifo_combine_flag_dly;
			flags_fifo_din(END_OF_PACKET_BIT) <= data_fifo_wr_en_packet_flags_dly;
			-- We write to the flags FIFO when
			--  1) we are writing data and this is the last word of the bin to be written
			--  2) we are writing the packets flags, and must write the entry whether or we have
			--     reached the end of the data group (in case of malformed packets)
			-- We write only when the last word is there, so it is guaranteed that we will have
			-- WORDS_PER_BIN words in the data FIFO. This way we don't have to check the valid flags
			-- (very stretched out 16:1 mux, very bad for timing).
			flags_fifo_wr_en <= data_fifo_wr_en_packet_flags_dly or (data_fifo_last_word_of_group_dly and data_fifo_wr_en_var);

			for i in 0 to NUMBER_OF_INPUTS - 1 loop
				-- data_fifo_din(i)(NEXT_INPUT_BIT) <= data_fifo_last_word_of_group_dly; -- (not used) Tell the FIFO reader to increment the lane counteer because this is the last word of the bin
				if data_fifo_wr_en_packet_flags_dly = '1' then
					-- Compose a new packet flag word
					-- The new status consists of incoming status flags left-shifted by N+4 bits.
					--
					--   NOTE: The CHAN_BIT_SEL sets the packet flags to all zeros.
					--
					--   NOTE: If errors occur on this stage (CRC erors,
					--   missing packet or wrong packet length), the incoming
					--   packet flags will NOT be forwarded (the bits are all set
					--   to zero). Do not rely on the previous stage flags if
					--   there are aerors in the current stage.
					--
					-- The lower bits n=0 to N-1 are set as follows:
					--     bit n : indicated if ANY of the following errors occured on the input lane 'n'. Bit 'n' is set to '1' if:
					--        - the lane has no data or is too short relative to the reference frame (tvalid=0)
					--            - the lane has valid data but is too long relative to the reference frame (tvalid=1 and tlast=0)
					--            - there was a GTX receive error (data bit 31 of the last word forced to 1. That bit just was shifted out)
					--     bit N+0 : CRC Error on incoming frame (might not be set if frame is missing or not the right length, which will be indicated by other flags)
					--     bit N+1 : Missing frame or frame too short (tvalid = 0)
					--     bit N+2 : Frame too long (tvalid=1 and tlast = 0)
					--     bit N+3 : The data of frame fifo has overflowed in the past and data is no longer reliable

					if s_axis_tvalid(i) = '1' and s_axis_tlast(i) = '1' and s_axis_tdata(i)(31) = '0' then
						data_fifo_din(i)(31 downto 0) <= shift_left(s_axis_tdata(i), NUMBER_OF_INPUTS + 4);
					else
						data_fifo_din(i) <= (others => '0');
					end if;
					-- data_fifo_din(i)(31 downto 16) <= s_axis_tdata(i)(15 downto 0); -- shift left incoming packet flags by 16 bits
					data_fifo_din(i)(NUMBER_OF_INPUTS + 3) <= data_fifo_overflow_sticky(i) or flags_fifo_overflow_sticky; -- FIFO overflow
					data_fifo_din(i)(NUMBER_OF_INPUTS + 2) <= to_std_logic(s_axis_tvalid(i) = '1' and s_axis_tlast(i) = '1' and s_axis_tdata(i)(31) = '1'); -- CRC Error
					data_fifo_din(i)(NUMBER_OF_INPUTS + 1) <= to_std_logic(s_axis_tvalid(i) = '1' and s_axis_tlast(i) = '0'); -- frame too long
					data_fifo_din(i)(NUMBER_OF_INPUTS + 0) <= to_std_logic(s_axis_tvalid(i) = '0'); -- Missing frame or frame too short
					data_fifo_din(i)(i) <= to_std_logic(
	                                    (s_axis_tvalid(i) = '1' and s_axis_tlast(i) = '1' and s_axis_tdata(i)(31) = '1') or -- CRC error
	                                    (s_axis_tvalid(i) = '0') or -- Missing frame or frame too short
	                                    (s_axis_tvalid(i) = '1' and s_axis_tlast(i) = '0') -- frame too long
	                                   );
				else
					data_fifo_din(i)(31 downto 0) <= s_axis_tdata(i);
				end if;
				-- Only the sublanes this bin selector actually reads (first_lane..last_lane of each
				-- output) are written. Sublanes outside that range belong to another bin
				-- selector's outputs: if they were written they would never be drained, and their
				-- stale FIFO heads used to be OR-ed into the packet flags word at end_of_packet.
				data_fifo_wr_en(i) <= data_fifo_wr_en_var and sublane_active(i);

			end loop;


			data_fifo_wr_en_always <= '0';
			data_fifo_wr_en_if_selected <= '0';
			data_fifo_wr_en_packet_flags <= '0';
			data_fifo_last_word_of_group <= '0';

			if reset_all_reg = '1' then -- make sure there won't be spurious data and flag FIFO write in case of a single-clock reset pulse.
				data_fifo_wr_en_always_dly <= '0';
				data_fifo_wr_en_if_selected_dly <= '0';
				data_fifo_last_word_of_group_dly <= '0';
			end if;

			-- Precompute static values so we don't expose combinatorial logic to the state machine
			last_frame_flags_word_number <= resize(number_of_input_frame_flags_words_per_frame - 1, last_word_number'LENGTH); -- precompute static value
			last_data_flags_word_number <= resize(number_of_input_data_flags_words_per_bin - 1, last_word_number'LENGTH); -- precompute static value
			last_frame_number <= resize(frames_per_packet - 1, last_frame_number'LENGTH); -- Pre-compute the number of the last frame to reduce combinatorial depth

			--------------
			-- SEQUENCER
			--------------
			-- Initialize the word/bin/block/frame counters when we are processing the packet
			-- header. Located out of the "if s_axis_global_tvalid='1'" block to remove unnecessary
			-- conditional logic and to remove load and routing on s_axis_global_tvalid='1'.
			if recv_header = '1' then
				last_word_number <= resize(number_of_input_words_per_bin - 1, last_word_number'LENGTH); -- initial value for DATA blocks. Is changed to appropriate values after each block
				last_bin_number <= resize(number_of_input_bins_per_frame - 1, last_bin_number'LENGTH); -- is set to 0 after the DATA FLAGS block
				block_ctr <= (others => '0');
				frame_ctr <= (others => '0');
				bin_ctr <= (others => '0');
				word_ctr <= (others => '0');
				data_fifo_combine_flag <= '0';
			end if;

			-- Single shot flags. Are always zero unless overriden below.
			frame_number_capture_trig <= '0';
			stream_id_capture_trig <= '0';

			if s_axis_global_tvalid = '1' then
				-- Header processing phase. We just skip the header.
				if recv_header = '1' then
					recv_header_word_ctr <= recv_header_word_ctr + 1;
						ix := to_integer(recv_header_word_ctr);

					case ix is

						when 0 =>
							null;

						when 1 =>
							null;

						when 2 =>
							null;

						when 3 =>
							-- check timestamp
							-- If all ok proceed to read the data, otherwise flush
							recv_header <= '0';
							packet_flags <= (others => '0'); -- by the time we clear this register we have already sent the packet flags

					end case;

				-- data processing phase
				else -- if recv_header='0'
					data_fifo_wr_en_if_selected <= to_std_logic(block_ctr = DATA_BLOCK or block_ctr = DATA_FLAGS_BLOCK);
					data_fifo_wr_en_always <= to_std_logic(block_ctr = FRAME_FLAGS_BLOCK); -- don't write if we get packet flags that ar enot the last word of the frame
					data_fifo_combine_flag <= to_std_logic(COMBINE_DATA_FLAGS and (block_ctr = DATA_FLAGS_BLOCK));
					data_fifo_first_word <= to_std_logic(word_ctr = 0);
					data_fifo_number_of_words <= last_word_number;

					-- Count words, bins and frames
					word_ctr <= word_ctr + 1;
					if word_ctr = last_word_number then -- if last word in bin
						data_fifo_last_word_of_group <= '1';
						word_ctr <= (others => '0');
						bin_ctr <= bin_ctr + 1;
						if bin_ctr = last_bin_number then -- if last bin in frame
							bin_ctr <= (others => '0');
							frame_ctr <= frame_ctr + 1;
							if frame_ctr = last_frame_number then -- if last frame in block
								frame_ctr <= (others => '0');
								if block_ctr /= FLUSH_BLOCK then
									block_ctr <= block_ctr + 1;
								end if;
								if block_ctr = DATA_BLOCK then -- this is the end of the data block. Next we will count one scaler flag word for each bin.
									last_word_number <= last_data_flags_word_number; -- depending on the crossbar and shuffle mode, there might be 1 or 2 data flag words per bins
								elsif block_ctr = DATA_FLAGS_BLOCK then -- Scaler flags are finished. Now we count the frame flags for each frame
									last_word_number <= last_frame_flags_word_number; -- Depending ont he crossbar, there could be 1 or 2 frame flags.
									last_bin_number <= (others => '0'); -- Frame flags do not repeat for every bin
								elsif block_ctr = FRAME_FLAGS_BLOCK then -- Frame flags are finished. Now we count a single packet flag per frame
									last_word_number <= (others => '0'); -- There is only one packet flag per frame
								end if;
							end if;
						end if;
					end if;
				end if; -- if recv_header


				-- override the FIFO write if an unexpected EOF occurs
				-- We presume the last word is always a packet flag word in which error bits will be set as needed
				-- If this is not a packet flag word due to corruption, additional bits might be randomly set
				if s_axis_global_tlast = '1' then
					data_fifo_wr_en_packet_flags <= '1'; -- will force data and flags FIFO writing. combine_flag will be ignored by the read process.
					recv_header_word_ctr <= (others => '0');
					recv_header <= '1';
				end if; -- s_axis_global_tlast='1'
			end if; -- if s_axis_global_tvalid='1'

			if reset_all_reg = '1' then
				recv_header_word_ctr <= (others => '0');
				recv_header <= '1';
			end if;

		end if; -- clk
	end process;


	-------------------------------
	-- FIFO Read Process
	-------------------------------
	-- Reads the data FIFOs block-by-block based on the info found in the FLAGS FIFO the and put the data on the output lane(s).
	--

	-- FIFO Read enable

	-- The data FIFO read enables are derived combinatiorally to make sure we fetch a new word from the data FIFO as soon as we have consumed the current word.
	--
	-- The ``data_fifo_rd_en`` is derived only from the flags FIFO and the state
	-- machine to make sure all signals are local and to minimize the number of
	-- combinatorial inputs (The logic can be implemented in a single 6-input LUT). This helps meet timing, especially ar 322 MHz.
	--
	-- We read the FIFO when
	--    - we are in the data sending phase ( send_header='0')
	--    - There is data to be read, as proxied by flags_fifo_valid='1' (the flag word is written when the last data word is written, so we assume there is data if there is a flag)
	--    - we are processing this specific FIFO lane ((i=lane or (combine_words='1' and  i=(lane or "0001")) or we are processing the packet flag from all lanes (end_of_packet='1').
	--
	-- The range of input sublanes that are read is set by ``first_lane``/``last_lane``.
	-- Sublanes outside that range are neither written nor read (see ``sublane_active``),
	-- so their FIFOs stay empty and cannot overflow or contaminate the packet flags word.
	-- (Earlier versions wrote all sublanes; the unread ones overflowed and their stale
	-- heads were OR-ed into the trailer at end_of_packet, which made the trailer data-dependent.)

	fifo_rd_en_gen0: for j in 0 to NUMBER_OF_OUTPUTS - 1 generate

		fifo_rd_en_gen: for i in 0 to NUMBER_OF_INPUT_LANES_PER_OUTPUT - 1 generate
			data_fifo_rd_en(j * NUMBER_OF_INPUT_LANES_PER_OUTPUT + i) <= '1' when send_header = '0' and flags_fifo_valid = '1' and (i = lane or (combine_words = '1' and  i = (lane or "0001")) or end_of_packet = '1') else '0'; -- 8-input LUT
		end generate fifo_rd_en_gen;

	end generate fifo_rd_en_gen0;


	combine_words    <= flags_fifo_dout(COMBINE_WORDS_BIT) and to_std_logic(COMBINE_DATA_FLAGS);                                              -- And with COMBINE_DATA_FLAGS to reduce logic utilization if combining is never needed
	end_of_packet    <= flags_fifo_dout(END_OF_PACKET_BIT);
	is_last_word     <= to_std_logic(send_word_ctr = unsigned(flags_fifo_dout(send_word_ctr'LENGTH - 1 downto 0)));                           -- 4-input LUT
	is_last_lane     <= to_std_logic((lane(3 downto 1) = last_lane_reg(3 downto 1)) and (combine_words = '1' or lane(0) = last_lane_reg(0))); -- 9 signals
	flags_fifo_rd_en <= '1' when send_header = '0' and ((is_last_word = '1' and is_last_lane = '1') or end_of_packet = '1') else '0';         -- 15-input LUT, all local!

	fifo_rd_proc: process(all)

		variable header_word_array: slv32_array(0 to SHUFFLE_FRAME_HEADER_WORD_LENGTH - 1);
		variable frame_header: shuffle_frame_header_struct;
		variable ix0, ix1: integer range 0 to NUMBER_OF_INPUT_LANES_PER_OUTPUT - 1;
		variable tdata: slv35_array(0 to NUMBER_OF_INPUT_LANES_PER_OUTPUT - 1);
		variable tdata_active: slv35_array(0 to NUMBER_OF_INPUT_LANES_PER_OUTPUT - 1); -- tdata with the sublanes outside first_lane..last_lane zeroed (trailer OR only)

		function or_reduce(a : slv35_array) return slv35 is

			variable ret: slv35 := (others => '0');

		begin

			for i in a'RANGE loop
			        ret := ret or a(i);
			end loop;

			return ret;

		end function or_reduce;

	begin
		if rising_edge(clk) then
			lane0_bypass_reg <= lane0_bypass; -- register to prevent the synthesizer form integrating the bsb_regs login om the path. This crosses clock domains, but it is semi-static so it's ok.
			for j in 0 to NUMBER_OF_OUTPUTS - 1 loop
				if lane0_bypass_reg then
					m_axis_tdata(j) <= s_axis_tdata(BIN_SEL_NUMBER * NUMBER_OF_OUTPUTS + j);
					m_axis_tvalid(j) <= s_axis_tvalid(BIN_SEL_NUMBER * NUMBER_OF_OUTPUTS + j);
					m_axis_tlast(j) <= s_axis_tlast(BIN_SEL_NUMBER * NUMBER_OF_OUTPUTS + j);
					m_axis_terror(j) <= or_reduce(s_axis_tdata(BIN_SEL_NUMBER * NUMBER_OF_OUTPUTS + j) and shuffle_flags_mask);
				else
					m_axis_tdata(j) <= m_axis_tdata_int(j);
					m_axis_tvalid(j) <= m_axis_tvalid_int(j);
					m_axis_tlast(j) <= m_axis_tlast_int(j);
					m_axis_terror(j) <= or_reduce(m_axis_tdata_int(j) and shuffle_flags_mask);
				end if;
			end loop;

			first_lane_reg <= first_lane;
			last_lane_reg <= to_unsigned(max(0, min(to_integer(last_lane), NUMBER_OF_INPUT_LANES_PER_OUTPUT - 1)), 4);

			-- Static per-sublane enable derived from the programmed lane range (semi-static
			-- configuration; software programs it before releasing the module from reset).
			for i in 0 to NUMBER_OF_INPUTS - 1 loop
				sublane_active(i) <= to_std_logic((i mod NUMBER_OF_INPUT_LANES_PER_OUTPUT) >= to_integer(first_lane_reg) and (i mod NUMBER_OF_INPUT_LANES_PER_OUTPUT) <= to_integer(last_lane_reg));
			end loop;

			------------------------------------
			-- SYNCHRONOUS RESET : See the end of the block
			-------------------------------------

			-----------
			-- SEND HEADER
			-----------
			if send_header = '1' then
				-- Initialize state variables that will be used for data transmission. We keep those outside if blocks to minimize logic depth.
				-- combine_words <= '0';
				lane <= first_lane_reg; -- Lane being read
				send_word_ctr <= (others => '0');

				for j in 0 to NUMBER_OF_OUTPUTS - 1 loop
					-- Build the packet header to be sent for this lane
					frame_header :=
					(

					 COOKIE                 => SHUFFLE_FRAME_HEADER_COOKIE,
					 PROTOCOL_VERSION       => SHUFFLE_FRAME_HEADER_PROTOCOL_VERSION,
					 HEADER_LENGTH_IN_WORDS => to_slv(SHUFFLE_FRAME_HEADER_WORD_LENGTH, frame_header.HEADER_LENGTH_IN_WORDS'LENGTH),
					 stream_id              => stream_id & to_slv(BIN_SEL_NUMBER * NUMBER_OF_OUTPUTS + j, 4),


					 ENCODING               => (0=> four_bits, 1=> use_offset_binary, 2=> send_flags, others => '0'),
					 NUMBER_OF_FRAMES       => to_slv(frames_per_packet, frame_header.NUMBER_OF_FRAMES'LENGTH),
					 NUMBER_OF_BINS         => number_of_output_bins_per_frame, -- ** to be fixed : will change for 2nd, 3rd etc  shuffle
					 NUMBER_OF_CHANNELS     => std_logic_vector(resize(number_of_output_words_per_bin, frame_header.NUMBER_OF_CHANNELS'LENGTH)),


					 ANCILLARY_DATA         => (X"0000" & std_logic_vector(timestamp_ctr(47 downto 32))),


					 TIMESTAMP              => std_logic_vector(timestamp_ctr(31 downto 0))
					);

					header_word_array := struct_to_word(frame_header);
					m_axis_tdata_int(j) <= header_word_array(to_integer(send_header_word_ctr)); -- We re-use send_word ctr because it is already used in the logic path
					m_axis_tvalid_int(j) <= '0'; -- overriden below
					m_axis_tlast_int(j) <= '0'; -- overriden below
				end loop;

				if flags_fifo_valid = '1' then
					m_axis_tvalid_int <= (others => '1');
					send_header_word_ctr <= send_header_word_ctr + 1;
					if send_header_word_ctr = SHUFFLE_FRAME_HEADER_WORD_LENGTH - 1 then
						send_header <= '0';
						send_header_word_ctr <= (others => '0');
						timestamp_ctr <= timestamp_ctr + frames_per_packet;
					end if;
				end if;
			end if;
			-----------
			-- SEND DATA
			-----------
			-- Data and frame flags: Send word from each lane
			if send_header = '0' then
				-- Put data on the currently selected lane bus, whether or not it is valid.
				-- We'll set the tvalid flag only if it is valid.
				-- This is to avoid generating an enable line on the whole bus that is based on a 16:1 mux on the fifo valid signals.
				for j in 0 to NUMBER_OF_OUTPUTS - 1 loop
					tdata := data_fifo_dout(j * NUMBER_OF_INPUT_LANES_PER_OUTPUT to (j + 1) * NUMBER_OF_INPUT_LANES_PER_OUTPUT - 1);
					for k in 0 to NUMBER_OF_INPUT_LANES_PER_OUTPUT - 1 loop
						if sublane_active(j * NUMBER_OF_INPUT_LANES_PER_OUTPUT + k) = '1' then
							tdata_active(k) := tdata(k);
						else
							tdata_active(k) := (others => '0');
						end if;
					end loop;

					ix0 := to_integer(lane);
					ix1 := to_integer(lane or "0001");
					if end_of_packet = '1' then
						if zero_packet_flags = '1' then
							m_axis_tdata_int(j) <= (others => '0');
						else
							-- Packet flags word: OR of the flags words of the sublanes this output reads.
							m_axis_tdata_int(j) <= or_reduce(tdata_active)(31 downto 0);
						end if;
					elsif combine_words = '1' and COMBINE_DATA_FLAGS = TRUE then
						m_axis_tdata_int(j)(15 downto 0) <= tdata(ix0)(15 downto 0);
						m_axis_tdata_int(j)(31 downto 16) <= tdata(ix1)(15 downto 0);
					else
						m_axis_tdata_int(j) <= tdata(ix0)(31 downto 0);
					end if;
				end loop;

				m_axis_tvalid_int <= (others => '0'); -- overriden below
				m_axis_tlast_int <= (others => '0'); -- overriden below

				if flags_fifo_valid = '1' then
					m_axis_tvalid_int <= (others => '1');
					send_word_ctr <= send_word_ctr + 1;

					-- When we reach the end of packet, we send the packet flags from the first lane and we ignore the rest, as we go back immediately in header mode.
					if end_of_packet = '1' then
						m_axis_tlast_int <= (others => '1');
						send_header_word_ctr <= (others => '0');
						send_header <= '1';
						lane <= first_lane_reg;
					-- input_sel <= not data_fifo_rd_en;

					elsif is_last_word = '1' then -- If we are told to switch to the next lane
						send_word_ctr <= (others => '0');

						if is_last_lane = '1' then -- if this is the last lane being read
							lane <= first_lane_reg; --
						else -- not last lane. Proceed to next lane
							if combine_words = '1' and COMBINE_DATA_FLAGS = TRUE then
								lane <= lane + 2;
							else
								lane <= lane + 1;
							end if;
						end if;

					end if; -- if next input flag
				end if; -- if fifo data valid on selected lane

			end if; -- if header or data

			-- end if; -- if data=1 and data_fifo_valid
			-- end if; -- if destination ready


			-- Reset - overrides the variables that may have been set above
			-- We do not implement this as a "if reset (..reset code..) else (...main code...) end if". because all signals not processed in the reset code would end up with a clock enable depending on the reset line in the main code. That is quite a heavy load.
			if reset_all_reg = '1' then
				m_axis_tvalid_int <= (others => '0'); -- needed
				send_header_word_ctr <= (others => '0');
				send_word_ctr <= (others => '0'); -- needed?
				timestamp_ctr <= (others => '0');
				send_header <= '1';
			end if; -- reset

		end if; -- clk
	end process;

end architecture behavioral;

