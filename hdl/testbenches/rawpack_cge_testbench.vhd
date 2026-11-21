-- Full-rate testbench for the raw ADC streamer chain: capture bus -> rawpack -> cge -> 100G MAC.
--
-- ``cge`` is the real module; the Xilinx MAC IP inside it is replaced by the behavioural model in
-- ``cmac_usplus_1_sim_model.vhd``, which paces the transmit stream at the 100 Gb/s line rate, fails
-- on a transmit underflow and writes every frame it sends to FRAME_FILE (one line of hex per frame).
--
-- The capture bus carries the same pattern as in ``rawpack_testbench``: sample number t of channel c
-- has the 14-bit value (t * (2c + 3) + 1000c) mod 16384, of which the 12 MSBs are sent. The frame file is checked afterwards by
-- ``check_frames.py`` (headers, packet counter continuity of each stream = no packet lost in the FIFOs, samples).
--
-- This testbench checks that no FIFO overflowed and ends with "RAWPACK CGE SIMULATION DONE".
library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;

library work;
use work.chFPGA_Package.ALL;
use work.tb_package.ALL;

entity rawpack_cge_testbench is
	generic (
		LINKS: integer range 1 to 2 := 2; -- 100G links: one cge and one MAC model for each
		CHAN_A: integer := 2;
		CHAN_B: integer := 5;
		CHAN_C: integer := 7;
		CHAN_D: integer := 0;
		STREAM_ENABLE: integer range 1 to 15 := 15; -- streams to send: bit 0 = A, 1 = B (link 0), 2 = C, 3 = D (link 1)
		BLOCKS_PER_PACKET: integer := 64;
		RUN_TIME_US: integer := 500; -- duration of a run
		RUNS: integer := 1; -- number of runs (start, RUN_TIME_US, stop), each a little longer than the last
		UPSTREAM: integer range 0 to 2 := 1; -- frames on the pass-through bus of link 0, with the timing of upack (194 words every 256 clocks). 0: none, the module has no such bus. 1: all the time. 2: the transmitter is stopped in the middle of a frame during each run.
		CLK_PERIOD_PS: integer := 2500 -- data clock period: 400 MHz
	);
end rawpack_cge_testbench;

architecture behavior of rawpack_cge_testbench is

	constant CLK_PERIOD: time := CLK_PERIOD_PS * 1 ps;
	constant BSB_CLK_PERIOD: time := 8 ns; -- 125 MHz
	constant REFCLK_PERIOD: time := 6.4 ns; -- 156.25 MHz
	constant WORDS_PER_FRAME: integer := 2048;

	signal clk, bsb_clk, refclk: std_logic := '0';
	signal rst, raw_rst, bsb_rst: std_logic := '1';

	signal raw_tdata: slv_array(0 to 7)(127 downto 0) := (others => (others => '0'));
	signal raw_tvalid, raw_tlast: std_logic_vector(0 to 1) := "00";

	signal cge_in_tdata: slv_array(0 to LINKS - 1)(255 downto 0);
	signal cge_in_tvalid, cge_in_tlast: std_logic_vector(0 to LINKS - 1);

	signal bsb_cmd_tdata: std_logic_vector(7 downto 0) := (others => '0');
	signal bsb_cmd_tvalid, bsb_cmd_tlast: std_logic := '0';
	signal bsb_cmd_tready: std_logic;

	signal up_tdata: std_logic_vector(255 downto 0) := (others => '0');
	signal up_tvalid, up_tlast: std_logic := '0';
	signal up_on, up_stopped: boolean := FALSE;
	signal up_index: integer range 0 to 255 := 0; -- clock of the upstream frame period
	signal up_frame: integer := 0;

	signal done: boolean := FALSE;
	signal check_link1: boolean := FALSE;

	function sample_value(chan: integer; frame: integer; word: integer; s: integer) return std_logic_vector is
		variable t: integer;
	begin
		t := (frame * WORDS_PER_FRAME + word) * 8 + s;
		return std_logic_vector(to_unsigned((t * (2 * chan + 3) + chan * 1000) mod 16384, 14));
	end function;

begin

	clk <= not clk after CLK_PERIOD / 2 when not done;
	bsb_clk <= not bsb_clk after BSB_CLK_PERIOD / 2 when not done;
	refclk <= not refclk after REFCLK_PERIOD / 2 when not done;

	rawpack0: entity work.rawpack
		generic map (
			NUMBER_OF_LINKS => LINKS,
			PASS_THROUGH => UPSTREAM /= 0
		)
		port map (
			s_axis_in_tdata  => up_tdata,
			s_axis_in_tvalid => up_tvalid,
			s_axis_in_tlast  => up_tlast,

			s_axis_raw_tdata  => raw_tdata,
			s_axis_raw_tvalid => raw_tvalid,
			s_axis_raw_tlast  => raw_tlast,
			source_sel_in     => (0 to 7 => '0'),
			raw_rst           => raw_rst,

			m_axis_out_tdata  => cge_in_tdata,
			m_axis_out_tvalid => cge_in_tvalid,
			m_axis_out_tlast  => cge_in_tlast,

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

	cge0: entity work.cge
		port map (
			refclk_p => refclk,
			refclk_n => not refclk,

			s_axis_tx_tdata  => cge_in_tdata(0),
			s_axis_tx_tvalid => cge_in_tvalid(0),
			s_axis_tx_tlast  => cge_in_tlast(0),
			clk => clk,
			rst => rst,

			m_axis_bsb_tready => '1',
			bsb_clk => bsb_clk,
			bsb_rst => bsb_rst
		);

	-- Second link: the same block with the second MAC IP (its model writes cmac_frames_1.txt)
	cge1_gen: if LINKS > 1 generate
		cge1: entity work.cge
			generic map (
				CMAC_IP => 2,
				BSB_ADDR_WIDTH => 15
			)
			port map (
				refclk_p => refclk,
				refclk_n => not refclk,

				s_axis_tx_tdata  => cge_in_tdata(1),
				s_axis_tx_tvalid => cge_in_tvalid(1),
				s_axis_tx_tlast  => cge_in_tlast(1),
				clk => clk,
				rst => rst,

				m_axis_bsb_tready => '1',
				bsb_clk => bsb_clk,
				bsb_rst => bsb_rst
			);

		-- At the end of the test, the same checks as for the first link. They are here because the
		-- names of this block exist only with two links.
		check1_proc: process begin
			wait until check_link1;
			assert << signal cge1.fifo_overflow_sticky: std_logic >> = '0' report "cge1 data FIFO overflow" severity FAILURE;
			assert << signal cge1.flag_fifo_overflow_sticky: std_logic >> = '0' report "cge1 flag FIFO overflow" severity FAILURE;
			assert << signal cge1.tx_ovfout_sticky: std_logic >> = '0' and << signal cge1.tx_unfout_sticky: std_logic >> = '0' report "MAC 1 overflow/underflow" severity FAILURE;
			wait;
		end process check1_proc;
	end generate cge1_gen;

	-- Upstream frames: every word has the mark "UPST", the frame number and its position in the
	-- frame, so that check_frames.py can tell that a frame is complete. Like upack, the transmitter
	-- keeps its frame timing while it is stopped.
	up_proc: process begin
		wait until rising_edge(clk);
		if up_on then
			up_tdata <= X"55505354" & std_logic_vector(to_unsigned(up_frame, 32)) & std_logic_vector(to_unsigned(up_index, 16)) & (175 downto 0 => '0');
			up_tvalid <= to_std_logic(up_index < 194 and not up_stopped);
			up_tlast <= to_std_logic(up_index = 193);
			up_index <= (up_index + 1) mod 256;
			if up_index = 255 then
				up_frame <= up_frame + 1;
			end if;
		end if;
	end process up_proc;

	-- Capture bus stimulus: continuous data, as from the ADCs
	stim_proc: process
		variable frame, word: integer := 0;
	begin
		wait until rising_edge(clk);
		if raw_rst then
			frame := 0;
			word := 0;
			raw_tvalid <= "00";
		else
			raw_tvalid <= "11";
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
	end process stim_proc;

	ctrl_proc: process
		alias cge_fifo_overflow is << signal cge0.fifo_overflow_sticky: std_logic >>;
		alias cge_flag_fifo_overflow is << signal cge0.flag_fifo_overflow_sticky: std_logic >>;
		alias cge_tx_ovf is << signal cge0.tx_ovfout_sticky: std_logic >>;
		alias cge_tx_unf is << signal cge0.tx_unfout_sticky: std_logic >>;
		alias raw_fifo_overflow is << signal rawpack0.fifo_overflow_sticky: std_logic >>;
		alias raw_active is << signal rawpack0.raw_active: std_logic >>;
		alias cge_in_frames is << signal cge0.in_frame_ctr: unsigned(7 downto 0) >>;
	begin
		wait for 200 ns;
		wait until rising_edge(clk);
		bsb_rst <= '0';
		rst <= '0';
		raw_rst <= '0';
		wait for 5 us; -- let the MAC model and the cge FIFOs come out of reset
		up_on <= UPSTREAM /= 0;
		wait for 5 us; -- upstream frames only

		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 1, CHAN_B * 16 + CHAN_A);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 28, CHAN_D * 16 + CHAN_C);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 2, BLOCKS_PER_PACKET);
		fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 29, STREAM_ENABLE);
		for r in 0 to RUNS - 1 loop
			if UPSTREAM = 2 then
				wait until rising_edge(clk) and up_index = 50;
				up_stopped <= TRUE;
			end if;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 1); -- enable
			wait for RUN_TIME_US * 1 us + r * 137 * CLK_PERIOD;
			fpga_write_control(bsb_clk, bsb_cmd_tdata, bsb_cmd_tvalid, bsb_cmd_tlast, bsb_cmd_tready, 0, 0);
			wait for 20 us; -- last packet goes out, FIFOs drain
			up_stopped <= FALSE;
			assert raw_active = '0' report "rawpack did not release the link after disable" severity FAILURE;
			wait for 5 us; -- upstream frames only
		end loop;

		assert raw_fifo_overflow = '0' report "rawpack FIFO overflow" severity FAILURE;
		assert cge_fifo_overflow = '0' report "cge data FIFO overflow" severity FAILURE;
		assert cge_flag_fifo_overflow = '0' report "cge flag FIFO overflow" severity FAILURE;
		assert cge_tx_ovf = '0' and cge_tx_unf = '0' report "MAC overflow/underflow" severity FAILURE;
		check_link1 <= TRUE; -- the second link is checked in its generate block
		wait for 1 ns;
		report "RAWPACK CGE SIMULATION DONE (cge input frame counter, 8 bits: " & integer'image(to_integer(cge_in_frames)) & ")";
		done <= TRUE;
		wait for 100 ns;
		std.env.finish;
	end process ctrl_proc;

end architecture behavior;
