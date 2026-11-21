-- Self-checking testbench for rawpack.
--
-- Feeds a known pattern on all 8 channels of the capture bus, enables the raw streams through the
-- BSB registers, then decodes every packet coming out of each link and checks the headers, the IP
-- checksum, the continuity of the timestamps and every sample. Also checks the pass-through bus of
-- link 0: before the streams are enabled and after they are disabled, or all the time if no stream
-- uses link 0. The pass-through bus carries frames of the length of the upack frames, back to back.
-- Every one of them that comes out must be complete: the link changes hands only between two
-- frames (SWEEP starts and stops the streams at every position of a frame). If the upstream
-- transmitter is stopped in the middle of a frame (PASS_MUTE), the module must close that frame
-- before its first packet.
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
		LINKS: integer range 1 to 2 := 2; -- 100G links of the module under test
		CHAN_A: integer := 2;
		CHAN_B: integer := 5;
		CHAN_C: integer := 7;
		CHAN_D: integer := 0;
		SOURCE: integer := 0; -- data source of all channels
		STREAM_ENABLE: integer range 1 to 15 := 15; -- streams to send: bit 0 = A, 1 = B (link 0), 2 = C, 3 = D (link 1)
		BLOCKS_PER_PACKET: integer := 64;
		GAP_PERIOD: integer := 0; -- if > 0, tvalid is low one clock out of GAP_PERIOD
		NUMBER_OF_PACKETS: integer := 40; -- packets to check before disabling the streams
		CHANGE_TEST: integer range 0 to 1 := 0; -- 1: write another packet size and other streams while the streams run; they must be ignored until the module is stopped
		RESTART_TEST: integer range 0 to 1 := 0; -- 1: first a short run with the streams RESTART_ENABLE, then the run that is checked: the packet counters must restart at zero
		RESTART_ENABLE: integer range 1 to 15 := 1; -- streams of the first run of RESTART_TEST
		PASS_MUTE: integer range 0 to 1 := 0; -- 0: the upstream transmitter (pass-through bus) sends frames back to back all the time. 1: it is stopped in the middle of a frame before a run that uses link 0, until the end of the run: the module must close the frame.
		SWEEP: integer := 0; -- maximum number of short runs before the run that is checked. Each one starts and stops at another position of the upstream frame. With 485 or more, the runs go on until every position is done, and the test fails if some are not.
		RESET_TEST: integer range 0 to 1 := 0; -- 1: reset the packetizer in the middle of the stream (enable stays set) and check that it restarts cleanly
		DUMP_FILE: string := "" -- if not empty, every packet of link 0 is written to this file as one line of hex bytes (starting at the Ethernet header). The packets of link 1 go to the file with ".1" added.
	);
end rawpack_testbench;

architecture behavior of rawpack_testbench is

	constant CLK_PERIOD: time := 2.5 ns; -- 400 MHz
	constant BSB_CLK_PERIOD: time := 8 ns; -- 125 MHz
	constant WORDS_PER_FRAME: integer := 2048;
	constant PASS_WORD: std_logic_vector(255 downto 0) := X"A5A5A5A5_00000000_11111111_22222222_33333333_44444444_55555555_C3C3C3C3";
	constant PASS_FRAME_WORDS: integer := 194; -- length of the frames on the pass-through bus (the length of the upack frames)
	constant STREAMS: integer := 2 * LINKS;
	constant MASK_LIMIT: integer := 2 ** STREAMS; -- streams that do not exist are ignored by the module
	type int_array4 is array (0 to 3) of integer;
	constant CHAN_OF: int_array4 := (CHAN_A, CHAN_B, CHAN_C, CHAN_D); -- channel of each stream

	-- Another set of streams, not empty
	function other_streams(mask: integer) return integer is
	begin
		if mask = 15 then
			return 1;
		end if;
		return 15 - mask;
	end function;
	constant OTHER_MASK: integer := other_streams(STREAM_ENABLE);

	signal clk, bsb_clk: std_logic := '0';
	signal rst, raw_rst, bsb_rst: std_logic := '1';

	signal raw_tdata: slv_array(0 to 7)(127 downto 0) := (others => (others => '0'));
	signal raw_tvalid, raw_tlast: std_logic_vector(0 to 1) := "00";
	signal source_sel: std_logic_vector(0 to 7) := (others => '0');

	signal out_tdata: slv_array(0 to LINKS - 1)(255 downto 0);
	signal out_tvalid, out_tlast: std_logic_vector(0 to LINKS - 1);

	signal bsb_cmd_tdata: std_logic_vector(7 downto 0) := (others => '0');
	signal bsb_cmd_tvalid, bsb_cmd_tlast: std_logic := '0';
	signal bsb_cmd_tready: std_logic;

	type int_link_array is array (0 to LINKS - 1) of integer;
	signal stream_enabled: boolean := FALSE; -- the testbench has asked for the raw streams
	signal link_packets: int_link_array := (others => 0); -- packets checked on each link
	signal packets_checked: integer := 0;
	signal cur_mask: integer range 0 to 15 := STREAM_ENABLE mod MASK_LIMIT; -- streams of the run in progress
	signal run_number: integer := 0; -- number of runs that came before the run in progress
	signal run_start: int_link_array := (others => -1); -- word number of the first sample of the run in progress, as each link gives it
	signal pass_before, pass_after: int_link_array := (others => 0); -- pass-through words seen on each link (only link 0 has them)
	type bool_link_array is array (0 to LINKS - 1) of boolean;
	signal raw_seen: bool_link_array := (others => FALSE);
	alias pass_words_before: integer is pass_before(0);
	alias pass_words_after: integer is pass_after(0);
	signal done: boolean := FALSE;
	signal pass_tvalid, pass_tlast: std_logic := '0';
	signal upstream_stopped: std_logic := '0'; -- the upstream transmitter is stopped
	signal pass_index: integer := 0; -- word of the upstream frame
	signal start_phases, stop_phases: std_logic_vector(0 to PASS_FRAME_WORDS - 1) := (others => '0'); -- positions in the upstream frame at which the streams were enabled and disabled
	-- The upstream frame (194 clocks of 2.5 ns) and the control clock (8 ns) come back to the same
	-- alignment every 485 control clocks. The sweep makes its writes at each of these alignments.
	constant SWEEP_PERIOD: integer := 485;
	signal bsb_count: integer := 0; -- control clocks
	signal closed: int_link_array := (others => 0); -- open pass-through frames that the module closed, on each link (only link 0 has them)
	alias terminators: integer is closed(0);

	-- Sample value sent for a given channel and absolute sample number
	function sample_value(chan: integer; frame: integer; word: integer; s: integer) return std_logic_vector is
		variable t: integer;
	begin
		t := (frame * WORDS_PER_FRAME + word) * 8 + s;
		return std_logic_vector(to_unsigned((t * (2 * chan + 3) + chan * 1000) mod 16384, 14));
	end function;

	-- The 12-bit value that the module must send for a 14-bit sample
	function reduced(x: std_logic_vector(13 downto 0)) return std_logic_vector is
		variable v: integer;
	begin
		v := to_integer(signed(x));
		v := v + 2; -- rounded: a half goes up
		v := v - (v mod 4);
		v := v / 4;
		if v > 2047 then
			v := 2047;
		end if;
		return std_logic_vector(to_signed(v, 12));
	end function;

	function mask_bit(mask: integer; s: integer) return integer is
	begin
		return (mask / 2 ** s) mod 2;
	end function;

begin

	clk <= not clk after CLK_PERIOD / 2 when not done;
	bsb_clk <= not bsb_clk after BSB_CLK_PERIOD / 2 when not done;

	uut: entity work.rawpack
		generic map (
			NUMBER_OF_LINKS => LINKS
		)
		port map (
			s_axis_raw_tdata  => raw_tdata,
			s_axis_raw_tvalid => raw_tvalid,
			s_axis_raw_tlast  => raw_tlast,
			source_sel_in     => source_sel,
			raw_rst           => raw_rst,

			s_axis_in_tdata  => PASS_WORD,
			s_axis_in_tvalid => pass_tvalid,
			s_axis_in_tlast  => pass_tlast,

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

	-- Pass-through bus: frames of PASS_FRAME_WORDS words with no gap, the worst case for the module.
	-- Like upack, the transmitter keeps its frame timing while it is stopped: only tvalid is removed,
	-- so it stops and starts in the middle of frames.
	pass_proc: process begin
		wait until rising_edge(clk);
		pass_tvalid <= not upstream_stopped;
		pass_tlast <= to_std_logic(pass_index = PASS_FRAME_WORDS - 1);
		pass_index <= (pass_index + 1) mod PASS_FRAME_WORDS;
	end process pass_proc;

	-- Positions in the upstream frame at which ``enable`` changed in the module
	phase_proc: process
		alias uut_enable is <<signal uut.enable: std_logic>>;
		variable prev: std_logic := '0';
	begin
		wait until rising_edge(clk);
		if uut_enable = '1' and prev = '0' then
			start_phases(pass_index) <= '1';
		elsif uut_enable = '0' and prev = '1' then
			stop_phases(pass_index) <= '1';
		end if;
		prev := uut_enable;
	end process phase_proc;

	bsb_count <= bsb_count + 1 when rising_edge(bsb_clk);

	sum_proc: process(all)
		variable n: integer;
	begin
		n := 0;
		for l in 0 to LINKS - 1 loop
			n := n + link_packets(l);
		end loop;
		packets_checked <= n;
	end process sum_proc;

	-- Control sequence
	ctrl_proc: process
		variable first_packet: integer := 0; -- packets checked before the main run

		-- PASS_MUTE: the upstream transmitter stops in the middle of a frame before a run that uses link 0
		procedure stop_upstream(mask: integer) is
		begin
			if PASS_MUTE = 1 and mask mod 4 /= 0 then
				wait until rising_edge(clk) and pass_index = 5;
				upstream_stopped <= '1';
			end if;
		end procedure;
	begin
		wait for 200 ns;
		wait until rising_edge(clk);
		bsb_rst <= '0';
		rst <= '0';
		raw_rst <= '0';
		wait for 2 us; -- pass-through only

		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 1, CHAN_B * 16 + CHAN_A);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 28, CHAN_D * 16 + CHAN_C);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 2, BLOCKS_PER_PACKET);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 16, 16#0A0A0A01#, 4); -- link 0: dest IP 10.10.10.1
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 42, 16#0A0A0B01#, 4); -- link 1: dest IP 10.10.11.1
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 3, 16#03#); -- rotate the source port over 4 values
		wait for 1 us;
		stream_enabled <= TRUE;
		-- Short runs that start and stop at every position of the upstream frame. The checker fails on
		-- an upstream frame that is not complete.
		for k in 0 to SWEEP - 1 loop
			exit when (and start_phases) = '1' and (and stop_phases) = '1'; -- all the positions are done
			cur_mask <= STREAM_ENABLE mod MASK_LIMIT;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 29, STREAM_ENABLE);
			wait until rising_edge(bsb_clk) and bsb_count mod SWEEP_PERIOD = (3 * k) mod SWEEP_PERIOD;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 1);
			wait until packets_checked >= first_packet + 2;
			wait until rising_edge(bsb_clk) and bsb_count mod SWEEP_PERIOD = (7 * k + 1) mod SWEEP_PERIOD;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 0);
			wait for 5 us; -- the last packets go out
			wait until rising_edge(clk);
			first_packet := packets_checked;
			run_number <= run_number + 1;
		end loop;
		if SWEEP >= SWEEP_PERIOD then
			assert (and start_phases) = '1' and (and stop_phases) = '1' report "The sweep did not start and stop at every position of the upstream frame: " & to_string(start_phases) & " " & to_string(stop_phases) severity FAILURE;
		end if;
		if RESTART_TEST = 1 then
			-- A run with other streams, stopped completely. It advances only the packet counters of its
			-- streams. The next run must start with all the counters at zero.
			cur_mask <= RESTART_ENABLE mod MASK_LIMIT;
			stop_upstream(RESTART_ENABLE);
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 29, RESTART_ENABLE);
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 1);
			wait until packets_checked >= NUMBER_OF_PACKETS / 4;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 0);
			upstream_stopped <= '0'; -- the host starts the upstream transmitter again
			wait for 5 us; -- the last packets go out
			wait until rising_edge(clk);
			first_packet := packets_checked;
			cur_mask <= STREAM_ENABLE mod MASK_LIMIT;
			run_number <= run_number + 1;
		end if;
		stop_upstream(STREAM_ENABLE);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 29, STREAM_ENABLE);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 1);

		if CHANGE_TEST = 1 then
			wait until packets_checked >= first_packet + NUMBER_OF_PACKETS / 4;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 2, BLOCKS_PER_PACKET + 3);
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 29, OTHER_MASK);
		end if;

		if RESET_TEST = 1 then
			-- Reset in the middle of a packet. The streams must restart by themselves on a frame boundary,
			-- with the packet counters back to zero and no leftover from the interrupted packets.
			wait until packets_checked >= first_packet + NUMBER_OF_PACKETS / 2;
			wait for 123 * CLK_PERIOD;
			wait until rising_edge(clk);
			rst <= '1';
			wait for 20 * CLK_PERIOD;
			wait until rising_edge(clk);
			rst <= '0';
		end if;

		wait until packets_checked >= first_packet + NUMBER_OF_PACKETS;
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 0);
		upstream_stopped <= '0';
		wait for 5 us; -- the packets in progress must complete, then the pass-through bus comes back

		assert pass_words_before > 100 report "Pass-through bus not seen before enable" severity FAILURE;
		if raw_seen(0) then
			assert pass_words_after > 100 report "Pass-through bus not seen after disable" severity FAILURE;
		else
			-- No stream used link 0: the pass-through bus had the link all the time
			assert pass_words_before > NUMBER_OF_PACKETS * 3 * BLOCKS_PER_PACKET / 4 report "The pass-through bus did not keep link 0" severity FAILURE;
		end if;
		if raw_seen(0) and PASS_MUTE = 1 then
			-- Each run on link 0 started with the upstream transmitter stopped in the middle of a frame: the module closed it
			assert terminators >= 1 + RESTART_TEST * to_integer(unsigned'("" & to_std_logic(RESTART_ENABLE mod 4 /= 0 and STREAM_ENABLE mod 4 /= 0))) or RESET_TEST = 1
				report "The open pass-through frames were not closed: " & integer'image(terminators) severity FAILURE;
		else
			assert terminators = 0 report "The module closed an upstream frame, but the upstream transmitter never stopped" severity FAILURE;
		end if;
		assert packets_checked >= NUMBER_OF_PACKETS report "Not enough packets" severity FAILURE;
		for l in 0 to LINKS - 1 loop
			assert link_packets(l) > 0 or (cur_mask / 4 ** l) mod 4 = 0 or RESTART_TEST = 1 report "No packet on link " & integer'image(l) severity FAILURE;
		end loop;
		report "RAWPACK TEST PASSED: " & integer'image(packets_checked) & " packets checked, " &
		       integer'image(pass_words_before) & "/" & integer'image(pass_words_after) & " pass-through words before/after";
		done <= TRUE;
		wait;
	end process ctrl_proc;

	-- All the links must give the same first sample for a run: the streams start together
	start_proc: process(all) begin
		for l in 1 to LINKS - 1 loop
			assert run_start(l) = -1 or run_start(0) = -1 or run_start(l) = run_start(0)
				report "Link " & integer'image(l) & " did not start on the same sample as link 0" severity FAILURE;
		end loop;
	end process start_proc;

	-- Packet checker of each link
	check_gen: for LINK in 0 to LINKS - 1 generate
		check_proc: process
			constant DATA_WORDS: integer := 3 * BLOCKS_PER_PACKET;
			constant PACKET_BYTES: integer := 32 * (2 + DATA_WORDS);
			type byte_array is array (natural range <>) of integer range 0 to 255;
			variable pkt: byte_array(0 to PACKET_BYTES - 1);
			variable nwords: integer := 0;
			variable in_packet: boolean := FALSE;
			variable seen_raw: boolean := FALSE;
			variable sum, v, expected_ctr, n, stream, index, link_mask: integer;
			variable frame, word: integer := 0;
			type int_pair is array (0 to 1) of integer;
			variable stream_ctr: int_pair := (0, 0); -- packets of each stream of the link since the last start
			variable start: integer := -1; -- word number of the first sample of the run
			variable expected_index: integer := 0; -- the streams of the link take turns
			variable number_of_resets: integer := 0;
			variable run_seen: integer := 0;
			variable mask_seen: integer := -1;
			variable pass_open: boolean := FALSE; -- a pass-through frame is on the output without its last word
			variable pass_len: integer := 0; -- words of the pass-through frame in progress
			variable pass_resync: boolean := TRUE; -- the next pass-through frame can be short: the test starts in the middle of a frame, or a reset came
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

			-- First enabled stream of the link, counted in the link, starting the search at ``from``
			impure function next_index(from: integer) return integer is
			begin
				if mask_bit(link_mask, from mod 2) = 1 then
					return from mod 2;
				end if;
				return (from + 1) mod 2;
			end function;
		begin
			wait until rising_edge(clk);
			link_mask := (cur_mask / 4 ** LINK) mod 4;
			if rst = '1' and rst_prev = '0' and stream_enabled then
				number_of_resets := number_of_resets + 1;
			end if;
			rst_prev := rst;
			if run_number /= run_seen then -- a new run after a complete stop: the counters and the stream order start again
				assert not in_packet report "A packet of the previous run is not complete" severity FAILURE;
				run_seen := run_number;
				stream_ctr := (0, 0);
				start := -1;
				run_start(LINK) <= -1;
				expected_index := next_index(0);
			end if;
			if rst = '1' and stream_enabled then -- reset during the stream: forget the packet in progress
				assert out_tvalid(LINK) = '0' or nwords = 0 or in_packet report "Unexpected output in reset" severity FAILURE;
				nwords := 0;
				in_packet := FALSE;
				stream_ctr := (0, 0);
				start := -1;
				run_start(LINK) <= -1;
				expected_index := next_index(0);
				pass_open := FALSE;
				pass_len := 0;
				pass_resync := TRUE;
			end if;
			if cur_mask /= mask_seen then -- the streams change only while the module is stopped: the order starts again
				mask_seen := cur_mask;
				expected_index := next_index(0);
			end if;
			if rst = '0' and out_tvalid(LINK) = '1' then
				if LINK = 0 and not in_packet and out_tdata(LINK) = (255 downto 0 => '0') and out_tlast(LINK) = '1' then
					-- The word that closes a pass-through frame when the raw streams take the link
					assert stream_enabled and link_mask /= 0 report "A closing word on link 0 while it has no raw stream" severity FAILURE;
					assert pass_open report "A closing word with no open pass-through frame" severity FAILURE;
					pass_open := FALSE;
					pass_len := 0;
					closed(LINK) <= closed(LINK) + 1;
				elsif LINK = 0 and not in_packet and out_tdata(LINK) = PASS_WORD then
					-- Pass-through frames arrive complete: the link changes hands only between two of them
					pass_len := pass_len + 1;
					pass_open := out_tlast(LINK) = '0';
					if out_tlast(LINK) = '1' then
						assert pass_resync or pass_len = PASS_FRAME_WORDS report "Pass-through frame of " & integer'image(pass_len) & " words" severity FAILURE;
						pass_len := 0;
						pass_resync := FALSE;
					end if;
					if seen_raw then
						pass_after(LINK) <= pass_after(LINK) + 1;
					else
						assert not stream_enabled or pass_before(LINK) > 0 report "No pass-through before enable" severity FAILURE;
						pass_before(LINK) <= pass_before(LINK) + 1;
					end if;
				else
					assert stream_enabled report "Raw data on the output before enable" severity FAILURE;
					assert link_mask /= 0 report "Raw data on link " & integer'image(LINK) & ", which has no stream" severity FAILURE;
					assert in_packet or not pass_open report "A raw packet starts inside an open pass-through frame" severity FAILURE;
					in_packet := TRUE;
					seen_raw := TRUE;
					raw_seen(LINK) <= TRUE;
					assert nwords < 2 + DATA_WORDS report "Packet too long" severity FAILURE;
					for b in 0 to 31 loop
						pkt(32 * nwords + b) := to_integer(unsigned(out_tdata(LINK)(255 - 8 * b downto 248 - 8 * b)));
					end loop;
					nwords := nwords + 1;

					if out_tlast(LINK) then
						assert nwords = 2 + DATA_WORDS report "Wrong packet length: " & integer'image(nwords) & " words" severity FAILURE;

						if DUMP_FILE'length > 0 then
							if not dump_open then
								if LINK = 0 then
									file_open(dump, DUMP_FILE, write_mode);
								else
									file_open(dump, DUMP_FILE & "." & integer'image(LINK), write_mode);
								end if;
								dump_open := TRUE;
							end if;
							for i in 0 to PACKET_BYTES - 1 loop
								hwrite(l, std_logic_vector(to_unsigned(pkt(i), 8)));
							end loop;
							writeline(dump, l);
							flush(dump);
						end if;

						if link_packets(LINK) < 1 then
							for w in 0 to 1 loop
								report "Link " & integer'image(LINK) & " header word " & integer'image(w) & ": " & to_hstring(to_unsigned(be(32 * w, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 3, 3), 24)) &
								       to_hstring(to_unsigned(be(32 * w + 6, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 9, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 12, 3), 24)) &
								       to_hstring(to_unsigned(be(32 * w + 15, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 18, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 21, 3), 24)) &
								       to_hstring(to_unsigned(be(32 * w + 24, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 27, 3), 24)) & to_hstring(to_unsigned(be(32 * w + 30, 2), 16));
							end loop;
						end if;

						-- Ethernet header
						for i in 0 to 5 loop
							assert pkt(i) = 255 report "Bad destination MAC" severity FAILURE;
						end loop;
						assert be(6, 3) = 16#005d03# and be(9, 3) = LINK report "Bad source MAC" severity FAILURE;
						assert be(12, 2) = 16#0800# report "Bad ethertype" severity FAILURE;
						-- IPv4 header
						assert be(14, 2) = 16#4500# report "Bad IP version/header length" severity FAILURE;
						assert be(16, 2) = PACKET_BYTES - 14 report "Bad IP length: " & integer'image(be(16, 2)) severity FAILURE;
						assert be(20, 2) = 16#4000# and be(22, 2) = 16#4011# report "Bad IP flags/TTL/protocol" severity FAILURE;
						sum := 0;
						for i in 0 to 9 loop
							sum := sum + be(14 + 2 * i, 2);
						end loop;
						sum := (sum mod 65536) + sum / 65536;
						sum := (sum mod 65536) + sum / 65536;
						assert sum = 16#FFFF# report "Bad IP header checksum" severity FAILURE;
						assert be(26, 2) = 16#0AC0# + LINK and be(28, 2) = 16#0002# report "Bad source IP" severity FAILURE;
						assert be(30, 2) = 16#0A0A# and be(32, 2) = 16#0A01# + 256 * LINK report "Bad destination IP" severity FAILURE;
						-- Each packet holds one channel. The enabled streams of the link take turns.
						stream := (pkt(46) / 16) mod 8;
						index := stream - 2 * LINK;
						assert index = expected_index report "Wrong stream order: got stream " & integer'image(stream) severity FAILURE;
						expected_index := next_index(index + 1);
						chan := CHAN_OF(stream);
						-- UDP
						expected_ctr := stream_ctr(index);
						stream_ctr(index) := stream_ctr(index) + 1;
						assert be(34, 2) = 16#A027# + (expected_ctr mod 4) report "Bad UDP source port: " & integer'image(be(34, 2)) severity FAILURE;
						assert be(36, 2) = 16#A410# + 2 * LINK + index report "Bad UDP destination port: " & integer'image(be(36, 2)) severity FAILURE;
						assert be(38, 2) = PACKET_BYTES - 34 report "Bad UDP length" severity FAILURE;
						assert be(40, 2) = 0 report "Bad UDP checksum" severity FAILURE;
						-- Raw stream header
						assert be(42, 2) = 16#5241# report "Bad magic" severity FAILURE;
						assert pkt(44) = 4 report "Bad format version" severity FAILURE;
						assert pkt(45) = SOURCE + 2 + 4 * cur_mask report "Bad flags: " & integer'image(pkt(45)) severity FAILURE;
						assert pkt(46) = 16 * stream + chan report "Bad channel byte: " & integer'image(pkt(46)) severity FAILURE;
						assert pkt(47) = BLOCKS_PER_PACKET report "Bad blocks_per_packet" severity FAILURE;
						assert be(48, 3) = 0 and be(51, 3) = expected_ctr report "Bad packet counter: " & integer'image(be(51, 3)) severity FAILURE;
						assert be(54, 3) = 0 report "Bad frame number (high)" severity FAILURE;
						frame := be(57, 3);
						word := be(60, 2);
						assert pkt(62) = (1 + number_of_resets + run_number) mod 256 report "Bad run number: " & integer'image(pkt(62)) severity FAILURE;
						assert pkt(63) = 12 report "Bad sample width" severity FAILURE;
						-- The packets of all streams with the same counter cover the same time
						n := frame * WORDS_PER_FRAME + word;
						if start < 0 then
							assert word = 0 report "First packet does not start on a frame boundary" severity FAILURE;
							start := n - expected_ctr * 8 * BLOCKS_PER_PACKET;
							run_start(LINK) <= start;
						end if;
						assert n = start + expected_ctr * 8 * BLOCKS_PER_PACKET
							report "Timestamp error: stream " & integer'image(stream) & " packet " & integer'image(expected_ctr) & " starts at word " & integer'image(n) &
							       ", expected " & integer'image(start + expected_ctr * 8 * BLOCKS_PER_PACKET) severity FAILURE;

						-- Samples: little-endian bit stream, 12 bits per sample, one channel
						for i in 0 to 64 * BLOCKS_PER_PACKET - 1 loop
							for b in 0 to 11 loop
								bitpos := 12 * i + b;
								v := pkt(64 + bitpos / 8);
								got(b) := to_unsigned(v, 8)(bitpos mod 8);
							end loop;
							t_word := frame * WORDS_PER_FRAME + word + i / 8; -- absolute word number of this sample
							t_s := i mod 8;
							expected := reduced(sample_value(chan, t_word / WORDS_PER_FRAME, t_word mod WORDS_PER_FRAME, t_s));
							assert got = expected
								report "Sample mismatch in packet " & integer'image(link_packets(LINK)) & " of link " & integer'image(LINK) & " sample " & integer'image(i) &
								       ": got " & integer'image(to_integer(unsigned(got))) & ", expected " & integer'image(to_integer(unsigned(expected))) severity FAILURE;
						end loop;

						link_packets(LINK) <= link_packets(LINK) + 1;
						nwords := 0;
						in_packet := FALSE;
					end if;
				end if;
			end if;
		end process check_proc;
	end generate check_gen;

end architecture behavior;
