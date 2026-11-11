----------------------------------------------------------------------------------
-- Company: McGill University
-- Engineer: V. Bidula (with AI assistance)
--
-- Create Date: 2026-09-21
-- Design Name: chFPGA
-- Module Name: align32_skew_testbench
-- Project Name: HIRAX / CHIME corner turn
-- Target Devices: simulation only (xsim, VHDL-2008)
--
-- Description: Self-checking testbench for the align32 SOF-window aligner as
-- used by CROSSBAR2 in the ICE shuffle256 corner turn.
--
-- The stimulus reproduces the backplane packet geometry seen by CROSSBAR2:
--   * 647-word packets (4 header + 2 x (256 data + 64 data flags + 1 frame
--     flags) + 1 trailer), one every 1250 ct_clk cycles (2 x 2.56 us at
--     244.14 MHz);
--   * cut-through arrival: the words of a packet are spread over most of the
--     period (~52% duty) in short bursts, optionally with the 64/66 gearbox
--     throttle (2 idle cycles per 66);
--   * lane 0 is the timing reference (internal bypass lane); lanes 1..15
--     start each packet `skew(i)` cycles after lane 0, plus an optional
--     uniform per-packet jitter.
--
-- Each output frame is checked for alignment integrity: every valid lane
-- must carry the same packet number in its header and the running word
-- index in its payload. The per-lane monitoring flags of align32 are
-- counted, and the sticky "bad lane" condition of shuffle_crossbar
-- (global_tvalid and not lane tvalid) is reproduced.
--
-- Scenarios (see the `control` process):
--   S1 baseline           all lanes +40, W=55                -> clean
--   S2 late boundary      lane 5 swept 46..60, W=55          -> measures L
--   S3 window sweep       lanes +40..+54, W in {45..100}     -> boundary rule
--   S4 jitter tail        lane 5 at +49 +/- 6, W=55          -> partial drops
--   S5 early boundary     lane 5 swept -6..0, then -120, W=55 -> early edge; early lanes lost
--   S6 all lanes early    lanes at -10, W=55                 -> all lost
--   S7 global miss        lane 5 valid but with a long tail  -> lane 0 flags too
--   S8 back-to-back       100% duty, 0/1/2 idle cycles       -> H2 gap
--   S9 FIFO headroom      W=250, lanes spread 0..54          -> no overflow
--
-- Run with hdl/testbenches/run_align32_skew.sh. Results are printed to the
-- console and written to RESULTS_FILE in the simulator working directory.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

use STD.TEXTIO.ALL;

use work.chFPGA_Package.ALL;

entity align32_skew_testbench is
	generic (
		NUMBER_OF_LANES: integer := 16;
		RESULTS_FILE: string     := "align32_skew_results.txt"
	);
end entity align32_skew_testbench;

architecture sim of align32_skew_testbench is

	constant CLK_PERIOD: time      := 4.096 ns; -- 244.14 MHz ct_clk
	constant N: integer            := NUMBER_OF_LANES;
	constant PACKET_WORDS: integer := 647; -- CB1 packet, 2 frames per packet, flags on
	constant PERIOD: integer       := 1250; -- 2 channelizer frames at 244.14 MHz
	constant SPAN: integer         := 1200; -- cycles over which the 647 words are spread (cut-through)
	constant START_OFFSET: integer := 400; -- leaves room for negative skews
	constant W_SWEEP: integer_array(0 to 6) := (45, 50, 55, 60, 70, 85, 100); -- S3 window values

	--- Clock, reset, cycle counter --------------------------------------------

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal cyc: integer   := 0;

	--- Packet generator control (driven by the control process) --------------

	signal gen_enable: boolean                    := false;
	signal gen_reset: boolean                     := true;
	signal gen_packets: integer                   := 0;
	signal gen_period: integer                    := PERIOD;
	signal gen_burst: integer                     := 4;
	signal gen_throttle: boolean                  := true;
	signal gen_span: integer_array(0 to N - 1)    := (others => SPAN);
	signal gen_skew: integer_array(0 to N - 1)    := (others => 0);
	signal gen_jitter: integer_array(0 to N - 1)  := (others => 0);
	signal gen_done: std_logic_vector(0 to N - 1) := (others => '0');

	--- UUT ports ----------------------------------------------------------------

	signal s_axis_tvalid: std_logic_vector(0 to N - 1) := (others => '0');
	signal s_axis_tdata: slv32_array(0 to N - 1)       := (others => (others => '0'));
	signal s_axis_tlast: std_logic_vector(0 to N - 1)  := (others => '0');

	signal m_axis_tvalid: std_logic_vector(0 to N - 1);
	signal m_axis_tdata: slv32_array(0 to N - 1);
	signal m_axis_tlast: std_logic_vector(0 to N - 1);
	signal m_axis_tuser: slv4_array(0 to N - 1);
	signal m_axis_global_tvalid: std_logic;
	signal m_axis_global_tlast: std_logic;

	signal sof_window_stop: std_logic_vector(7 downto 0) := std_logic_vector(to_unsigned(55, 8));

	signal fifo_overflow: std_logic_vector(0 to N - 1);
	signal missing_frame: std_logic_vector(0 to N - 1);
	signal bad_frame_length: std_logic_vector(0 to N - 1);
	signal lane0_tfirst_mon: std_logic;
	signal fifo_tfirst_mon: std_logic_vector(0 to N - 1);
	signal fifo_count_mon: slv10_array(0 to N - 1);
	signal lane_monitor: std_logic_vector(0 to N - 1);

	--- Statistics (kept by the monitor process, cleared with clear_stats) -----

	signal clear_stats: boolean                        := false;
	signal st_missing: integer_array(0 to N - 1)       := (others => 0); -- missing_frame pulses
	signal st_badlen: integer_array(0 to N - 1)        := (others => 0); -- bad_frame_length pulses
	signal st_badlane: integer_array(0 to N - 1)       := (others => 0); -- output frames in which the lane was absent
	signal st_frames: integer_array(0 to N - 1)        := (others => 0); -- output frames with the lane valid
	signal st_align_err: integer_array(0 to N - 1)     := (others => 0); -- header packet number differs from lane 0
	signal st_data_err: integer_array(0 to N - 1)      := (others => 0); -- payload word index or lane id wrong
	signal st_fifo_max: integer_array(0 to N - 1)      := (others => 0); -- maximum align FIFO occupancy
	signal st_overflow: std_logic_vector(0 to N - 1)   := (others => '0');
	signal st_global_frames: integer                   := 0;

	-- Word format: lane(4) & packet number(12) & word index(16)
	function make_word(lane, pkt, word: integer) return std_logic_vector is
	begin
		return std_logic_vector(to_unsigned(lane, 4)) & std_logic_vector(to_unsigned(pkt mod 4096, 12)) & std_logic_vector(to_unsigned(word, 16));
	end function make_word;

	function all_zero(a: integer_array) return boolean is
	begin
		for i in a'RANGE loop
			if a(i) /= 0 then
				return false;
			end if;
		end loop;
		return true;
	end function all_zero;

begin

	clk <= not clk after CLK_PERIOD / 2;

	-- Scenario-relative cycle counter: restarts whenever the generators are reset.
	cyc_proc: process(clk) begin
		if rising_edge(clk) then
			if gen_reset then
				cyc <= 0;
			else
				cyc <= cyc + 1;
			end if;
		end if;
	end process cyc_proc;

	-------------------------------------------------------------------------
	-- Packet generators, one per lane
	-------------------------------------------------------------------------
	-- Packet `pkt` of lane i starts at START_OFFSET + pkt * period + skew(i) + jitter.
	-- Words are released with a credit scheduler: every unthrottled cycle adds
	-- PACKET_WORDS credits and a burst of `gen_burst` words is queued whenever
	-- gen_burst * span credits are available, so the packet occupies `span`
	-- cycles on average. With gen_burst = 1 and span = PACKET_WORDS the lane
	-- streams at 100% duty.
	lane_gen: for i in 0 to N - 1 generate

		lane_proc: process(clk)
			variable pkt: integer          := 0;
			variable word: integer         := 0;
			variable sending: boolean      := false;
			variable start_cyc: integer    := 0;
			variable credit: integer       := 0;
			variable burst_left: integer   := 0;
			variable thr: integer          := 0;
			variable seed1: positive       := 1000 + 17 * i;
			variable seed2: positive       := 7 + 3 * i;
			variable rnd: real;
			variable jit: integer;

			procedure schedule_next is
			begin
				jit := 0;
				if gen_jitter(i) > 0 then
					uniform(seed1, seed2, rnd);
					jit := integer(floor(rnd * real(2 * gen_jitter(i) + 1))) - gen_jitter(i);
				end if;
				start_cyc := START_OFFSET + pkt * gen_period + gen_skew(i) + jit;
			end procedure schedule_next;

		begin
			if rising_edge(clk) then
				s_axis_tvalid(i) <= '0';
				s_axis_tlast(i)  <= '0';

				if gen_reset then
					pkt := 0;
					word := 0;
					sending := false;
					credit := 0;
					burst_left := 0;
					thr := (i * 7) mod 66; -- per-lane gearbox phase
					gen_done(i) <= '0';
					schedule_next;

				elsif gen_enable then
					if not sending and pkt < gen_packets and cyc >= start_cyc then
						sending := true;
						word := 0;
						burst_left := 0;
						credit := gen_burst * gen_span(i); -- first burst leaves immediately
					end if;

					if sending then
						thr := (thr + 1) mod 66;
						if not (gen_throttle and thr >= 64) then
							credit := credit + PACKET_WORDS;
							if credit >= gen_burst * gen_span(i) then
								burst_left := burst_left + gen_burst;
								credit := credit - gen_burst * gen_span(i);
							end if;
							if burst_left > 0 then
								s_axis_tvalid(i) <= '1';
								s_axis_tdata(i)  <= make_word(i, pkt, word);
								burst_left := burst_left - 1;
								if word = PACKET_WORDS - 1 then
									s_axis_tlast(i) <= '1';
									sending := false;
									burst_left := 0;
									credit := 0;
									pkt := pkt + 1;
									if pkt >= gen_packets then
										gen_done(i) <= '1';
									end if;
									schedule_next;
								end if;
								word := word + 1;
							end if;
						end if;
					end if;
				end if;
			end if;
		end process lane_proc;

	end generate lane_gen;

	-------------------------------------------------------------------------
	-- Unit under test
	-------------------------------------------------------------------------
	uut: entity work.align32
		generic map (
			NUMBER_OF_LANES         => N,
			ENABLE_MONITORING_LOGIC => FALSE
		)
		port map (
			s_axis_tvalid => s_axis_tvalid,
			s_axis_tdata  => s_axis_tdata,
			s_axis_tlast  => s_axis_tlast,

			m_axis_tvalid        => m_axis_tvalid,
			m_axis_tdata         => m_axis_tdata,
			m_axis_tlast         => m_axis_tlast,
			m_axis_tuser         => m_axis_tuser,
			m_axis_global_tvalid => m_axis_global_tvalid,
			m_axis_global_tlast  => m_axis_global_tlast,

			sof_window_stop => sof_window_stop,
			ignore_lane     => (others => '0'),

			fifo_overflow    => fifo_overflow,
			missing_frame    => missing_frame,
			bad_frame_length => bad_frame_length,
			lane0_tfirst_mon => lane0_tfirst_mon,
			fifo_tfirst_mon  => fifo_tfirst_mon,
			fifo_count_mon   => fifo_count_mon,

			lane_monitor_source => (others => '0'),
			lane_monitor        => lane_monitor,

			clk => clk,
			rst => rst
		);

	-------------------------------------------------------------------------
	-- Monitor: counts flags and checks the aligned output
	-------------------------------------------------------------------------
	monitor: process(clk)
		variable frame_word: integer                           := 0;
		variable ref_pkt: integer                              := -1;
		variable absent: std_logic_vector(0 to N - 1)          := (others => '0');
		variable v: integer;
	begin
		if rising_edge(clk) then
			if clear_stats then
				st_missing      <= (others => 0);
				st_badlen       <= (others => 0);
				st_badlane      <= (others => 0);
				st_frames       <= (others => 0);
				st_align_err    <= (others => 0);
				st_data_err     <= (others => 0);
				st_fifo_max     <= (others => 0);
				st_overflow     <= (others => '0');
				st_global_frames <= 0;
				frame_word := 0;
				ref_pkt := -1;
				absent := (others => '0');
			else
				for i in 0 to N - 1 loop
					if missing_frame(i) then
						st_missing(i) <= st_missing(i) + 1;
					end if;
					if bad_frame_length(i) then
						st_badlen(i) <= st_badlen(i) + 1;
					end if;
					if fifo_overflow(i) then
						st_overflow(i) <= '1';
					end if;
					v := to_integer(unsigned(fifo_count_mon(i)));
					if v > st_fifo_max(i) then
						st_fifo_max(i) <= v;
					end if;
					if m_axis_tvalid(i) and m_axis_tlast(i) then
						st_frames(i) <= st_frames(i) + 1;
					end if;
				end loop;

				if m_axis_global_tvalid then
					if frame_word = 0 then
						ref_pkt := to_integer(unsigned(m_axis_tdata(0)(27 downto 16)));
					end if;
					for i in 0 to N - 1 loop
						if m_axis_tvalid(i) then
							if to_integer(unsigned(m_axis_tdata(i)(15 downto 0))) /= frame_word or to_integer(unsigned(m_axis_tdata(i)(31 downto 28))) /= i then
								st_data_err(i) <= st_data_err(i) + 1;
							end if;
							if frame_word = 0 and to_integer(unsigned(m_axis_tdata(i)(27 downto 16))) /= ref_pkt then
								st_align_err(i) <= st_align_err(i) + 1;
							end if;
						else
							absent(i) := '1'; -- shuffle_crossbar's bad_lane_sticky condition
						end if;
					end loop;
					if m_axis_global_tlast then
						st_global_frames <= st_global_frames + 1;
						for i in 0 to N - 1 loop
							if absent(i) then
								st_badlane(i) <= st_badlane(i) + 1;
							end if;
						end loop;
						absent := (others => '0');
						frame_word := 0;
					else
						frame_word := frame_word + 1;
					end if;
				end if;
			end if;
		end if;
	end process monitor;

	-------------------------------------------------------------------------
	-- Scenario control and checking
	-------------------------------------------------------------------------
	control: process
		file f: text;
		variable l: line;
		variable fails: integer      := 0;
		variable measured_l: integer := -1; -- FIFO write-to-valid latency inferred from S2
		variable s_star: integer     := -1; -- first failing skew in S2
		variable skews: integer_array(0 to N - 1);
		variable jitters: integer_array(0 to N - 1);
		variable spans: integer_array(0 to N - 1);
		variable predicted_fail: boolean;
		variable observed_fail: boolean;
		variable gap1_ok: boolean    := false;
		variable e_star: integer     := 1; -- first passing (least negative) early skew in S5; 1 = not found

		procedure wait_cycles (
			n: integer
		) is
		begin
			for k in 1 to n loop
				wait until rising_edge(clk);
			end loop;
		end procedure wait_cycles;

		procedure out_line (
			s: string
		) is
			variable ll: line;
		begin
			write(ll, s);
			writeline(f, ll);
			report s
				severity note;
		end procedure out_line;

		procedure check (
			cond: boolean;
			msg: string
		) is
		begin
			if not cond then
				fails := fails + 1;
				out_line("  CHECK FAILED: " & msg);
			end if;
		end procedure check;

		-- Runs one scenario and prints the per-lane statistics.
		procedure run_scenario (
			name: string;
			w: integer;
			sk: integer_array;
			jt: integer_array;
			sp: integer_array;
			packets: integer;
			period: integer;
			burst: integer;
			throttle: boolean
		) is
			variable timeout: integer;
		begin
			sof_window_stop <= std_logic_vector(to_unsigned(w, 8));
			gen_skew <= sk;
			gen_jitter <= jt;
			gen_span <= sp;
			gen_packets <= packets;
			gen_period <= period;
			gen_burst <= burst;
			gen_throttle <= throttle;
			gen_enable <= false;
			gen_reset <= true;
			rst <= '1';
			clear_stats <= true;
			wait_cycles(20);
			rst <= '0';
			wait_cycles(40); -- FIFO reset recovery
			clear_stats <= false;
			gen_reset <= false;
			wait_cycles(2);
			gen_enable <= true;

			timeout := START_OFFSET + (packets + 4) * period + 5000;
			for k in 1 to timeout loop
				wait until rising_edge(clk);
				exit when gen_done = (gen_done'RANGE => '1');
			end loop;
			wait_cycles(2 * period + 2000); -- drain
			gen_enable <= false;
			wait_cycles(2);

			out_line("== " & name & "  W=" & integer'image(w) & "  packets=" & integer'image(packets) & "  period=" & integer'image(period) & "  burst=" & integer'image(burst) & "  throttle=" & boolean'image(throttle) & "  global_frames=" & integer'image(st_global_frames));
			out_line("   lane  skew jitter  span  missing badlen badlane frames alignerr dataerr fifomax ovf");
			for i in 0 to N - 1 loop
				write(l, i, right, 7);
				write(l, sk(i), right, 6);
				write(l, jt(i), right, 7);
				write(l, sp(i), right, 6);
				write(l, st_missing(i), right, 9);
				write(l, st_badlen(i), right, 7);
				write(l, st_badlane(i), right, 8);
				write(l, st_frames(i), right, 7);
				write(l, st_align_err(i), right, 9);
				write(l, st_data_err(i), right, 8);
				write(l, st_fifo_max(i), right, 8);
				write(l, string'("   "));
				write(l, std_logic'image(st_overflow(i))(2));
				writeline(f, l);
			end loop;
			-- also echo a compact per-lane summary to the console
			write(l, string'("   missing per lane:"));
			for i in 0 to N - 1 loop
				write(l, st_missing(i), right, 6);
			end loop;
			report l.all
				severity note;
			deallocate(l);
		end procedure run_scenario;

	begin
		file_open(f, RESULTS_FILE, write_mode);
		out_line("align32 skew/window testbench, " & integer'image(N) & " lanes, packet=" & integer'image(PACKET_WORDS) & " words, period=" & integer'image(PERIOD) & ", span=" & integer'image(SPAN));

		-------------------------------------------------------------------
		-- S1: baseline, realistic: every GTX lane 40 cycles behind lane 0
		-------------------------------------------------------------------
		skews := (0 => 0, others => 40);
		jitters := (others => 0);
		spans := (others => SPAN);
		run_scenario("S1 baseline", 55, skews, jitters, spans, 30, PERIOD, 4, true);
		check(all_zero(st_missing) and all_zero(st_badlen) and all_zero(st_badlane), "S1: no lane may drop");
		check(all_zero(st_align_err) and all_zero(st_data_err), "S1: aligned output must be intact");
		check(st_global_frames = 30, "S1: all 30 packets must come out");
		check(st_overflow = (st_overflow'RANGE => '0'), "S1: no FIFO overflow");

		-------------------------------------------------------------------
		-- S2: late-lane boundary. Lane 5 skew swept, no throttle, no jitter.
		-------------------------------------------------------------------
		for s in 46 to 60 loop
			skews := (0 => 0, others => 40);
			skews(5) := s;
			run_scenario("S2 late boundary lane5=" & integer'image(s), 55, skews, jitters, spans, 20, PERIOD, 4, false);
			for i in 0 to N - 1 loop
				if i /= 5 then
					check(st_missing(i) = 0 and st_badlane(i) = 0, "S2 s=" & integer'image(s) & ": lane " & integer'image(i) & " must be clean");
				end if;
			end loop;
			check(all_zero(st_align_err) and all_zero(st_data_err), "S2 s=" & integer'image(s) & ": aligned output must be intact");
			check(st_missing(5) = 0 or st_missing(5) = 20, "S2 s=" & integer'image(s) & ": lane 5 must be deterministic (0 or all packets), got " & integer'image(st_missing(5)));
			if st_missing(5) > 0 then
				check(st_badlen(5) > 0 and st_badlane(5) > 0, "S2 s=" & integer'image(s) & ": dropped lane must show the MISSING+BAD_FRAME_LENGTH+BAD_TVALID triplet");
				check(st_global_frames = 20, "S2 s=" & integer'image(s) & ": frames still come out without lane 5");
				if s_star < 0 then
					s_star := s;
				end if;
			else
				check(s_star < 0, "S2 s=" & integer'image(s) & ": lane passes after having failed at a smaller skew");
			end if;
		end loop;
		check(s_star > 0, "S2: a failing skew must be found in 46..60");
		if s_star > 0 then
			measured_l := 55 + 3 - s_star;
			out_line("S2 RESULT: first failing skew s* = " & integer'image(s_star) & " for W=55  ->  late tolerance = W+2-L = " & integer'image(s_star - 1) & " cycles, FIFO latency L = " & integer'image(measured_l));
		end if;

		-------------------------------------------------------------------
		-- S3: window sweep with lanes spread 40..54
		-------------------------------------------------------------------
		for i in 1 to N - 1 loop
			skews(i) := 39 + i;
		end loop;
		skews(0) := 0;
		for wi in W_SWEEP'RANGE loop
			run_scenario("S3 window sweep", W_SWEEP(wi), skews, jitters, spans, 20, PERIOD, 4, false);
			for i in 1 to N - 1 loop
				predicted_fail := skews(i) > W_SWEEP(wi) + 2 - measured_l;
				observed_fail := st_missing(i) > 0;
				check(predicted_fail = observed_fail, "S3 W=" & integer'image(W_SWEEP(wi)) & ": lane " & integer'image(i) & " skew " & integer'image(skews(i)) & " predicted_fail=" & boolean'image(predicted_fail) & " observed_fail=" & boolean'image(observed_fail));
			end loop;
			check(st_missing(0) = 0, "S3: lane 0 never flags when only other lanes are late");
			check(all_zero(st_align_err) and all_zero(st_data_err), "S3: aligned output must be intact");
		end loop;

		-------------------------------------------------------------------
		-- S4: jitter tail on one lane near the edge, with gearbox throttle
		-------------------------------------------------------------------
		skews := (0 => 0, others => 40);
		skews(5) := 49;
		jitters := (others => 0);
		jitters(5) := 6;
		run_scenario("S4 jitter tail", 55, skews, jitters, spans, 1000, PERIOD, 4, true);
		check(st_missing(5) > 0 and st_missing(5) < 1000, "S4: lane 5 must drop a fraction of packets, got " & integer'image(st_missing(5)));
		for i in 0 to N - 1 loop
			if i /= 5 then
				check(st_missing(i) = 0, "S4: lane " & integer'image(i) & " must be clean");
			end if;
		end loop;
		check(all_zero(st_align_err) and all_zero(st_data_err), "S4: aligned output must be intact");
		out_line("S4 RESULT: lane 5 at 49 +/- 6 with throttle dropped " & integer'image(st_missing(5)) & " of 1000 packets");

		-------------------------------------------------------------------
		-- S5: early-lane boundary. A SOF that reaches its FIFO output before
		-- lane 0 has reopened the window is flushed, and a flushed lane has no
		-- queued trailer ahead of its next SOF, so it cannot recover: lanes
		-- earlier than the reference by more than L-1 cycles are lost on
		-- every packet, not occasionally.
		-------------------------------------------------------------------
		jitters := (others => 0);
		for e in -6 to 0 loop
			skews := (0 => 0, others => 40);
			skews(5) := e;
			run_scenario("S5 early boundary lane5=" & integer'image(e), 55, skews, jitters, spans, 20, PERIOD, 4, false);
			check(st_missing(5) = 0 or st_missing(5) = 20, "S5 e=" & integer'image(e) & ": lane 5 must be deterministic (0 or all packets), got " & integer'image(st_missing(5)));
			for i in 0 to N - 1 loop
				if i /= 5 then
					check(st_missing(i) = 0 and st_badlane(i) = 0, "S5 e=" & integer'image(e) & ": lane " & integer'image(i) & " must be clean");
				end if;
			end loop;
			check(all_zero(st_align_err) and all_zero(st_data_err), "S5 e=" & integer'image(e) & ": aligned output must be intact");
			if st_missing(5) = 0 then
				if e_star = 1 then
					e_star := e;
				end if;
			else
				check(e_star = 1, "S5 e=" & integer'image(e) & ": lane fails after having passed at an earlier skew");
			end if;
		end loop;
		check(e_star <= 0, "S5: a passing skew must be found in -6..0");
		out_line("S5 RESULT: first passing early skew e* = " & integer'image(e_star) & "  ->  early tolerance = " & integer'image(-e_star) & " cycles (predicted L-1 = " & integer'image(measured_l - 1) & ")");
		check(e_star = 1 - measured_l, "S5: early tolerance must equal L-1");
		skews := (0 => 0, others => 40);
		skews(5) := -120;
		run_scenario("S5b far-early lane5=-120", 55, skews, jitters, spans, 20, PERIOD, 4, false);
		check(st_missing(5) = 20 and st_badlane(5) = 20 and st_frames(5) = 0, "S5b: a lane 120 cycles early must be lost on every packet");
		check(st_overflow = (st_overflow'RANGE => '0') and st_fifo_max(5) < 16, "S5b: the flushed lane's FIFO stays near-empty");
		out_line("S5b RESULT: lane 5 at -120 dropped " & integer'image(st_missing(5)) & " of 20 packets, FIFO occupancy " & integer'image(st_fifo_max(5)) & " of 512");

		-------------------------------------------------------------------
		-- S6: every GTX lane earlier than the reference -> all of them are lost
		-------------------------------------------------------------------
		skews := (0 => 0, others => -10);
		run_scenario("S6 all lanes early", 55, skews, jitters, spans, 20, PERIOD, 4, false);
		out_line("S6 RESULT (informative): with no lane later than lane 0, lanes at -10 dropped " & integer'image(st_missing(1)) & " of 20 packets");

		-------------------------------------------------------------------
		-- S7: a valid lane whose tail arrives too late -> global miss signature
		-------------------------------------------------------------------
		skews := (0 => 0, others => 40);
		spans := (others => SPAN);
		spans(5) := SPAN + 100; -- lane 5 header on time, trailer 100 cycles later than the rest
		run_scenario("S7 global miss (lane5 long tail)", 55, skews, jitters, spans, 20, PERIOD, 4, false);
		check(st_missing(0) > 0, "S7: lane 0 must flag MISSING when the lockstep readout overruns the next window");
		check(st_badlane(0) = 0, "S7: lane 0 never shows BAD_TVALID");
		out_line("S7 RESULT: lane 0 missing=" & integer'image(st_missing(0)) & ", global frames=" & integer'image(st_global_frames) & " of 20");
		spans := (others => SPAN);

		-------------------------------------------------------------------
		-- S8: back-to-back packets at 100% duty with 0, 1, 2 idle cycles
		-------------------------------------------------------------------
		skews := (others => 0);
		spans := (others => PACKET_WORDS);
		for gap in 0 to 2 loop
			run_scenario("S8 back-to-back gap=" & integer'image(gap), 55, skews, jitters, spans, 20, PACKET_WORDS + gap, 1, false);
			if gap = 0 then
				check(st_missing(0) > 0, "S8 gap=0: zero idle cycles must lose SOFs (global miss)");
			elsif gap = 2 then
				check(all_zero(st_missing), "S8 gap=2: two idle cycles must be enough");
				check(all_zero(st_align_err) and all_zero(st_data_err), "S8 gap=2: aligned output must be intact");
			else
				gap1_ok := all_zero(st_missing) and all_zero(st_align_err) and all_zero(st_data_err);
			end if;
			out_line("S8 RESULT gap=" & integer'image(gap) & ": lane 0 missing=" & integer'image(st_missing(0)) & ", global frames=" & integer'image(st_global_frames) & " of 20, fifo max lane0=" & integer'image(st_fifo_max(0)));
		end loop;
		out_line("S8 RESULT: minimum inter-packet gap at 100% duty = " & integer'image(2 - boolean'pos(gap1_ok)) & " idle cycle(s)");

		-------------------------------------------------------------------
		-- S9: FIFO headroom at the maximum practical window
		-------------------------------------------------------------------
		for i in 1 to N - 1 loop
			skews(i) := (i * 54) / (N - 1);
		end loop;
		skews(0) := 0;
		spans := (others => SPAN);
		run_scenario("S9 FIFO headroom", 250, skews, jitters, spans, 20, PERIOD, 4, true);
		check(all_zero(st_missing) and all_zero(st_badlane), "S9: no drops at W=250");
		check(st_overflow = (st_overflow'RANGE => '0'), "S9: no FIFO overflow at W=250");
		check(all_zero(st_align_err) and all_zero(st_data_err), "S9: aligned output must be intact");
		out_line("S9 RESULT: W=250, max FIFO occupancy over all lanes = " & integer'image(st_fifo_max(0)) & " (lane 0)");

		-------------------------------------------------------------------
		if fails = 0 then
			out_line("RESULT: PASS");
		else
			out_line("RESULT: FAIL (" & integer'image(fails) & " checks failed)");
		end if;
		file_close(f);
		std.env.finish;
		wait;
	end process control;

end architecture sim;
