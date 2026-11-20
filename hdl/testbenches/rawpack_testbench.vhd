-- Self-checking testbench for rawpack.
--
-- Feeds a known pattern on all 8 channels of the capture bus, enables the raw stream through the BSB
-- registers, then decodes every packet coming out and checks the headers, the IP checksum, the
-- continuity of the timestamps and every sample. Also checks the pass-through bus before the stream
-- is enabled and after it is disabled.
--
-- The test ends with the message "RAWPACK TEST PASSED" or a failure.
--
library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use std.textio.ALL;

library work;
use work.chFPGA_Package.ALL;
use work.tb_package.ALL;

entity rawpack_testbench is
	generic (
		CHAN_A: integer := 2;
		CHAN_B: integer := 5;
		SOURCE: integer := 0; -- data source of both channels
		SINGLE: integer range 0 to 1 := 0; -- 1: single-channel mode (channel A only)
		PORT_PER_CHANNEL: integer range 0 to 1 := 1; -- 1: stream B uses the UDP destination port + 1
		BLOCKS_PER_PACKET: integer := 64;
		GAP_PERIOD: integer := 0; -- if > 0, tvalid is low one clock out of GAP_PERIOD
		NUMBER_OF_PACKETS: integer := 40; -- packets to check before disabling the stream
		CHANGE_TEST: integer range 0 to 1 := 0; -- 1: write another packet size and mode while the stream runs; they must be ignored until it is stopped
		RESTART_TEST: integer range 0 to 1 := 0; -- 1: first a short run in the other mode (one channel if SINGLE = 0), then the run that is checked: the packet counters of A and B must restart at zero
		RESET_TEST: integer range 0 to 1 := 0; -- 1: reset the packetizer in the middle of the stream (enable stays set) and check that it restarts cleanly
		DUMP_FILE: string := "" -- if not empty, every packet is written to this file as one line of hex bytes (starting at the Ethernet header)
	);
end rawpack_testbench;

architecture behavior of rawpack_testbench is

	constant CLK_PERIOD: time := 2.5 ns; -- 400 MHz
	constant BSB_CLK_PERIOD: time := 8 ns; -- 125 MHz
	constant WORDS_PER_FRAME: integer := 2048;
	constant PASS_WORD: std_logic_vector(255 downto 0) := X"A5A5A5A5_00000000_11111111_22222222_33333333_44444444_55555555_C3C3C3C3";

	signal clk, bsb_clk: std_logic := '0';
	signal rst, raw_rst, bsb_rst: std_logic := '1';

	signal raw_tdata: slv_array(0 to 7)(127 downto 0) := (others => (others => '0'));
	signal raw_tvalid, raw_tlast: std_logic_vector(0 to 1) := "00";
	signal source_sel: std_logic_vector(0 to 7) := (others => '0');

	signal out_tdata: std_logic_vector(255 downto 0);
	signal out_tvalid, out_tlast: std_logic;

	signal bsb_cmd_tdata: std_logic_vector(7 downto 0) := (others => '0');
	signal bsb_cmd_tvalid, bsb_cmd_tlast: std_logic := '0';
	signal bsb_cmd_tready: std_logic;

	signal stream_enabled: boolean := FALSE; -- the testbench has asked for the raw stream
	signal packets_checked: integer := 0;
	signal cur_single: integer range 0 to 1 := SINGLE; -- mode of the run in progress
	signal run_number: integer := 0; -- number of runs that came before the run in progress
	signal pass_words_before, pass_words_after: integer := 0;
	signal done: boolean := FALSE;

	-- Sample value sent for a given channel and absolute sample number
	function sample_value(chan: integer; frame: integer; word: integer; s: integer) return std_logic_vector is
		variable t: integer;
	begin
		t := (frame * WORDS_PER_FRAME + word) * 8 + s;
		return std_logic_vector(to_unsigned((t * (2 * chan + 3) + chan * 1000) mod 16384, 14));
	end function;

begin

	clk <= not clk after CLK_PERIOD / 2 when not done;
	bsb_clk <= not bsb_clk after BSB_CLK_PERIOD / 2 when not done;

	uut: entity work.rawpack
		port map (
			s_axis_raw_tdata  => raw_tdata,
			s_axis_raw_tvalid => raw_tvalid,
			s_axis_raw_tlast  => raw_tlast,
			source_sel_in     => source_sel,
			raw_rst           => raw_rst,

			s_axis_in_tdata  => PASS_WORD,
			s_axis_in_tvalid => '1',
			s_axis_in_tlast  => '0',

			m_axis_out_tdata  => out_tdata,
			m_axis_out_tvalid => out_tvalid,
			m_axis_out_tlast  => out_tlast,

			clk => clk,
			rst => rst,

			s_axis_bsb_tdata  => bsb_cmd_tdata,
			s_axis_bsb_tvalid => bsb_cmd_tvalid,
			s_axis_bsb_tlast  => bsb_cmd_tlast,
			s_axis_bsb_tready => bsb_cmd_tready,
			m_axis_bsb_tready => '1',
			bsb_clk           => bsb_clk,
			bsb_rst           => bsb_rst
		);

	-- Capture bus stimulus: both sources carry the same frame timing; the unused low 2 bits of every
	-- sample are set to check they do not leak in the stream.
	stim_proc: process
		variable frame, word, clk_ctr: integer := 0;
		variable valid: boolean;
	begin
		source_sel <= (others => to_std_logic(SOURCE = 1));
		wait until rising_edge(clk);
		if raw_rst then
			frame := 0;
			word := 0;
			raw_tvalid <= "00";
		else
			clk_ctr := clk_ctr + 1;
			valid := GAP_PERIOD = 0 or (clk_ctr mod GAP_PERIOD) /= 0;
			raw_tvalid <= (others => to_std_logic(valid));
			if valid then
				for c in 0 to 7 loop
					for s in 0 to 7 loop
						raw_tdata(c)(16 * (7 - s) + 15 downto 16 * (7 - s)) <= sample_value(c, frame, word, s) & "11"; -- first sample in the MSBs, as on the UCAP bus
					end loop;
				end loop;
				raw_tlast <= (others => to_std_logic(word = WORDS_PER_FRAME - 1));
				if word = WORDS_PER_FRAME - 1 then
					word := 0;
					frame := frame + 1;
				else
					word := word + 1;
				end if;
			end if;
		end if;
	end process stim_proc;

	-- Control sequence
	ctrl_proc: process
		variable first_packet: integer := 0; -- packets checked before the main run
	begin
		wait for 200 ns;
		wait until rising_edge(clk);
		bsb_rst <= '0';
		rst <= '0';
		raw_rst <= '0';
		wait for 2 us; -- pass-through only

		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 1, CHAN_B * 16 + CHAN_A);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 2, BLOCKS_PER_PACKET);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 16, 16#0A0A0A01#, 4); -- dest IP 10.10.10.1
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 3, 16#03#); -- rotate the source port over 4 values
		wait for 1 us;
		stream_enabled <= TRUE;
		if RESTART_TEST = 1 then
			-- A run in the other mode, stopped completely. In single-channel mode it advances only the
			-- packet counter of stream A. The next run must start with both counters at zero.
			cur_single <= 1 - SINGLE;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 1 + 2 * (1 - SINGLE) + 4 * PORT_PER_CHANNEL);
			wait until packets_checked >= NUMBER_OF_PACKETS / 4;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 2 * (1 - SINGLE) + 4 * PORT_PER_CHANNEL);
			wait for 5 us; -- the last packets go out
			wait until rising_edge(clk);
			first_packet := packets_checked;
			cur_single <= SINGLE;
			run_number <= 1;
		end if;
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 1 + 2 * SINGLE + 4 * PORT_PER_CHANNEL);

		if CHANGE_TEST = 1 then
			wait until packets_checked >= first_packet + NUMBER_OF_PACKETS / 4;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 2, BLOCKS_PER_PACKET + 3);
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 1 + 2 * (1 - SINGLE) + 4 * PORT_PER_CHANNEL);
		end if;

		if RESET_TEST = 1 then
			-- Reset in the middle of a packet. The stream must restart by itself on a frame boundary,
			-- with the packet counter back to zero and no leftover from the interrupted packet.
			wait until packets_checked >= first_packet + NUMBER_OF_PACKETS / 2;
			wait for 123 * CLK_PERIOD;
			wait until rising_edge(clk);
			rst <= '1';
			wait for 20 * CLK_PERIOD;
			wait until rising_edge(clk);
			rst <= '0';
		end if;

		wait until packets_checked >= first_packet + NUMBER_OF_PACKETS;
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 2 * SINGLE * (1 - CHANGE_TEST) + 2 * (1 - SINGLE) * CHANGE_TEST);
		wait for 5 us; -- the packet in progress must complete, then the pass-through bus comes back

		assert pass_words_before > 100 report "Pass-through bus not seen before enable" severity FAILURE;
		assert pass_words_after > 100 report "Pass-through bus not seen after disable" severity FAILURE;
		assert packets_checked >= NUMBER_OF_PACKETS report "Not enough packets" severity FAILURE;
		report "RAWPACK TEST PASSED: " & integer'image(packets_checked) & " packets checked, " &
		       integer'image(pass_words_before) & "/" & integer'image(pass_words_after) & " pass-through words before/after";
		done <= TRUE;
		wait;
	end process ctrl_proc;

	-- Packet checker
	check_proc: process
		constant DATA_WORDS: integer := 3 * BLOCKS_PER_PACKET;
		constant PACKET_BYTES: integer := 32 * (2 + DATA_WORDS);
		type byte_array is array (natural range <>) of integer range 0 to 255;
		variable pkt: byte_array(0 to PACKET_BYTES - 1);
		variable nwords: integer := 0;
		variable in_packet: boolean := FALSE;
		variable seen_raw: boolean := FALSE;
		variable sum, v, expected_ctr, n, stream: integer;
		variable frame, word: integer := 0;
		type int_pair is array (0 to 1) of integer;
		type bool_pair is array (0 to 1) of boolean;
		variable next_frame, next_word: int_pair := (0, 0); -- expected position of the next packet of each stream
		variable have_next: bool_pair := (FALSE, FALSE);
		variable stream_ctr: int_pair := (0, 0); -- packets of each stream since the last reset
		variable expected_stream: integer := 0; -- the streams take turns: A, then B
		variable number_of_resets: integer := 0;
		variable run_seen: integer := 0;
		variable rst_prev: std_logic := '1';
		variable expected: std_logic_vector(11 downto 0);
		variable got: std_logic_vector(11 downto 0);
		variable chan, t_word, t_s, bitpos: integer;
		file dump: text;
		variable dump_open: boolean := FALSE;
		variable l: line;

		impure function be(first, nbytes: integer) return integer is
			variable r: integer := 0;
		begin
			for i in 0 to nbytes - 1 loop
				r := r * 256 + pkt(first + i);
			end loop;
			return r;
		end function;
	begin
		wait until rising_edge(clk);
		if rst = '1' and rst_prev = '0' and stream_enabled then
			number_of_resets := number_of_resets + 1;
		end if;
		rst_prev := rst;
		if run_number /= run_seen then -- a new run after a complete stop: the counters and the stream order start again
			assert not in_packet report "A packet of the previous run is not complete" severity FAILURE;
			run_seen := run_number;
			have_next := (FALSE, FALSE);
			stream_ctr := (0, 0);
			expected_stream := 0;
		end if;
		if rst = '1' and stream_enabled then -- reset during the stream: forget the packet in progress
			assert out_tvalid = '0' or nwords = 0 or in_packet report "Unexpected output in reset" severity FAILURE;
			nwords := 0;
			in_packet := FALSE;
			have_next := (FALSE, FALSE);
			stream_ctr := (0, 0);
			expected_stream := 0;
		end if;
		if rst = '0' and out_tvalid = '1' then
			if not in_packet and out_tdata = PASS_WORD then
				assert out_tlast = '0' report "Unexpected tlast on pass-through word" severity FAILURE;
				if seen_raw then
					pass_words_after <= pass_words_after + 1;
				else
					assert not stream_enabled or pass_words_before > 0 report "No pass-through before enable" severity FAILURE;
					pass_words_before <= pass_words_before + 1;
				end if;
			else
				assert stream_enabled report "Raw data on the output before enable" severity FAILURE;
				in_packet := TRUE;
				seen_raw := TRUE;
				assert nwords < 2 + DATA_WORDS report "Packet too long" severity FAILURE;
				for b in 0 to 31 loop
					pkt(32 * nwords + b) := to_integer(unsigned(out_tdata(255 - 8 * b downto 248 - 8 * b)));
				end loop;
				nwords := nwords + 1;

				if out_tlast then
					assert nwords = 2 + DATA_WORDS report "Wrong packet length: " & integer'image(nwords) & " words" severity FAILURE;

					if DUMP_FILE'length > 0 then
						if not dump_open then
							file_open(dump, DUMP_FILE, write_mode);
							dump_open := TRUE;
						end if;
						for i in 0 to PACKET_BYTES - 1 loop
							hwrite(l, std_logic_vector(to_unsigned(pkt(i), 8)));
						end loop;
						writeline(dump, l);
						flush(dump);
					end if;

					if packets_checked = 0 then -- show the first header in the log
						for w in 0 to 1 loop
							report "Header word " & integer'image(w) & ": " & to_hstring(to_unsigned(be(32 * w, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 3, 3), 24)) &
							       to_hstring(to_unsigned(be(32 * w + 6, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 9, 3), 24)) &
							       to_hstring(to_unsigned(be(32 * w + 12, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 15, 3), 24)) &
							       to_hstring(to_unsigned(be(32 * w + 18, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 21, 3), 24)) &
							       to_hstring(to_unsigned(be(32 * w + 24, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 27, 3), 24)) &
							       to_hstring(to_unsigned(be(32 * w + 30, 2), 16));
						end loop;
					end if;

					-- Ethernet
					for i in 0 to 5 loop
						assert pkt(i) = 255 report "Bad destination MAC" severity FAILURE;
					end loop;
					assert be(6, 3) = 16#005d03# and be(9, 3) = 0 report "Bad source MAC" severity FAILURE;
					assert be(12, 2) = 16#0800# report "Bad ethertype" severity FAILURE;
					-- IPv4
					assert be(14, 2) = 16#4500# report "Bad IP version/header length" severity FAILURE;
					assert be(16, 2) = PACKET_BYTES - 14 report "Bad IP length: " & integer'image(be(16, 2)) severity FAILURE;
					assert be(20, 2) = 16#4000# and be(22, 2) = 16#4011# report "Bad IP flags/TTL/protocol" severity FAILURE;
					sum := 0;
					for i in 0 to 9 loop
						sum := sum + be(14 + 2 * i, 2);
					end loop;
					sum := (sum mod 65536) + (sum / 65536);
					sum := (sum mod 65536) + (sum / 65536);
					assert sum = 16#FFFF# report "Bad IP header checksum" severity FAILURE;
					assert be(26, 2) = 16#0AC0# and be(28, 2) = 16#0002# report "Bad source IP" severity FAILURE;
					assert be(30, 2) = 16#0A0A# and be(32, 2) = 16#0A01# report "Bad destination IP" severity FAILURE;
					-- Each packet holds one channel. The streams take turns: A, then B (A only in single-channel mode).
					stream := pkt(46) / 128;
					assert stream = expected_stream report "Wrong stream order: got stream " & integer'image(stream) severity FAILURE;
					expected_stream := 0 when cur_single = 1 else 1 - stream;
					chan := CHAN_A when stream = 0 else CHAN_B;
					-- UDP
					expected_ctr := stream_ctr(stream);
					stream_ctr(stream) := stream_ctr(stream) + 1;
					assert be(34, 2) = 16#A027# + (expected_ctr mod 4) report "Bad UDP source port: " & integer'image(be(34, 2)) severity FAILURE;
					assert be(36, 2) = 16#A028# + stream * PORT_PER_CHANNEL report "Bad UDP destination port: " & integer'image(be(36, 2)) severity FAILURE;
					assert be(38, 2) = PACKET_BYTES - 34 report "Bad UDP length" severity FAILURE;
					assert be(40, 2) = 0 report "Bad UDP checksum" severity FAILURE;
					-- Raw stream header
					assert be(42, 2) = 16#5241# report "Bad magic" severity FAILURE;
					assert pkt(44) = 3 report "Bad format version" severity FAILURE;
					assert pkt(45) = SOURCE + 4 * cur_single report "Bad flags: " & integer'image(pkt(45)) severity FAILURE;
					assert pkt(46) = 128 * stream + chan report "Bad channel byte: " & integer'image(pkt(46)) severity FAILURE;
					assert pkt(47) = BLOCKS_PER_PACKET report "Bad blocks_per_packet" severity FAILURE;
					assert be(48, 3) = 0 and be(51, 3) = expected_ctr report "Bad packet counter: " & integer'image(be(51, 3)) severity FAILURE;
					assert be(54, 3) = 0 report "Bad frame number (high)" severity FAILURE;
					frame := be(57, 3);
					word := be(60, 2);
					assert pkt(62) = 1 + number_of_resets + run_number report "Bad stream number: " & integer'image(pkt(62)) severity FAILURE;
					assert pkt(63) = 0 report "Reserved field not zero" severity FAILURE;
					if have_next(stream) then
						assert frame = next_frame(stream) and word = next_word(stream)
							report "Timestamp discontinuity: got frame " & integer'image(frame) & " word " & integer'image(word) &
							       ", expected frame " & integer'image(next_frame(stream)) & " word " & integer'image(next_word(stream)) severity FAILURE;
					else
						assert word = 0 report "First packet does not start on a frame boundary" severity FAILURE;
					end if;
					if stream = 1 then -- the packets of A and B with the same counter cover the same time
						assert n = frame * WORDS_PER_FRAME + word report "The packet of stream B does not start where the packet of stream A started" severity FAILURE;
					end if;
					n := frame * WORDS_PER_FRAME + word;
					next_frame(stream) := (n + 8 * BLOCKS_PER_PACKET) / WORDS_PER_FRAME;
					next_word(stream) := (n + 8 * BLOCKS_PER_PACKET) mod WORDS_PER_FRAME;
					have_next(stream) := TRUE;

					-- Samples: little-endian bit stream, 12 bits per sample (the 12 MSBs of the 14-bit input), one channel
					for i in 0 to 64 * BLOCKS_PER_PACKET - 1 loop
						for b in 0 to 11 loop
							bitpos := 12 * i + b;
							v := pkt(64 + bitpos / 8);
							got(b) := to_unsigned(v, 8)(bitpos mod 8);
						end loop;
						t_word := frame * WORDS_PER_FRAME + word + i / 8; -- absolute word number of this sample
						t_s := i mod 8;
						expected := sample_value(chan, t_word / WORDS_PER_FRAME, t_word mod WORDS_PER_FRAME, t_s)(13 downto 2); -- the 2 low bits are not sent
						assert got = expected
							report "Sample mismatch in packet " & integer'image(packets_checked) & " sample " & integer'image(i) &
							       ": got " & integer'image(to_integer(unsigned(got))) & ", expected " & integer'image(to_integer(unsigned(expected))) severity FAILURE;
					end loop;

					n := frame * WORDS_PER_FRAME + word; -- start of this packet, for the check of the next packet of stream B
					packets_checked <= packets_checked + 1;
					nwords := 0;
					in_packet := FALSE;
				end if;
			end if;
		end if;
	end process check_proc;

end architecture behavior;
