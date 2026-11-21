-- Pass-through test of rawpack.
--
-- No raw stream is ever enabled. The output of link 0 must then be the pass-through bus delayed by
-- one clock, word for word (data, valid and last), and link 1 must stay silent. The pass-through bus
-- carries random frames with random gaps, and the module is reset several times in the middle of
-- them. This shows that the module does not change the data of upack in a design that does not use
-- the raw streams.
--
-- The test ends with the message "RAWPACK PASS-THROUGH TEST PASSED" or a failure.
--
library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use ieee.math_real.ALL;

library work;
use work.chFPGA_Package.ALL;

entity rawpack_pass_testbench is
	generic (
		NUMBER_OF_WORDS: integer := 200000 -- clocks to check
	);
end rawpack_pass_testbench;

architecture behavior of rawpack_pass_testbench is
	constant CLK_PERIOD: time := 2.5 ns;
	signal clk, bsb_clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal in_tdata: std_logic_vector(255 downto 0) := (others => '0');
	signal in_tvalid, in_tlast: std_logic := '0';
	signal out_tdata: slv_array(0 to 1)(255 downto 0);
	signal out_tvalid, out_tlast: std_logic_vector(0 to 1);
	signal done: boolean := FALSE;
begin
	clk <= not clk after CLK_PERIOD / 2 when not done;
	bsb_clk <= not bsb_clk after 4 ns when not done;

	uut: entity work.rawpack
		generic map (
			NUMBER_OF_LINKS => 2
		)
		port map (
			s_axis_raw_tdata  => (0 to 7 => (127 downto 0 => '1')),
			s_axis_raw_tvalid => "11",
			s_axis_raw_tlast  => "00",
			source_sel_in     => (0 to 7 => '0'),
			raw_rst           => rst,

			s_axis_in_tdata  => in_tdata,
			s_axis_in_tvalid => in_tvalid,
			s_axis_in_tlast  => in_tlast,

			m_axis_out_tdata  => out_tdata,
			m_axis_out_tvalid => out_tvalid,
			m_axis_out_tlast  => out_tlast,

			clk => clk,
			rst => rst,

			m_axis_bsb_tready => '1',
			bsb_clk           => bsb_clk,
			bsb_rst           => rst
		);

	test_proc: process
		variable seed1, seed2: positive := 7;
		variable r: real;
		variable valid_words: integer := 0;
		variable prev_tdata: std_logic_vector(255 downto 0);
		variable prev_tvalid, prev_tlast, prev_rst: std_logic := '0';
	begin
		for n in 0 to NUMBER_OF_WORDS - 1 loop
			wait until rising_edge(clk);
			-- The output is the input of the clock before (no valid word out of a reset)
			if n > 0 then
				assert out_tvalid(0) = (prev_tvalid and not prev_rst) report "Wrong tvalid on link 0 at clock " & integer'image(n) severity FAILURE;
				assert out_tvalid(1) = '0' report "Link 1 is not silent" severity FAILURE;
				if out_tvalid(0) then
					assert out_tdata(0) = prev_tdata and out_tlast(0) = prev_tlast report "Wrong word on link 0 at clock " & integer'image(n) severity FAILURE;
					valid_words := valid_words + 1;
				end if;
			end if;
			prev_tdata := in_tdata;
			prev_tvalid := in_tvalid;
			prev_tlast := in_tlast;
			prev_rst := rst;
			-- Next input: random data, a word on 3 clocks out of 4, frames of 20 words on average
			for i in 0 to 7 loop
				uniform(seed1, seed2, r);
				in_tdata(32 * i + 31 downto 32 * i) <= std_logic_vector(to_unsigned(integer(floor(r * 65536.0)), 16)) & std_logic_vector(to_unsigned(n mod 65536, 16));
			end loop;
			uniform(seed1, seed2, r);
			in_tvalid <= to_std_logic(r < 0.75);
			uniform(seed1, seed2, r);
			in_tlast <= to_std_logic(r < 0.05);
			-- Reset: at the start, then 20 clocks every 5000 clocks
			rst <= to_std_logic(n < 20 or n mod 5000 >= 4980);
		end loop;
		assert valid_words > NUMBER_OF_WORDS / 2 report "Not enough words seen" severity FAILURE;
		report "RAWPACK PASS-THROUGH TEST PASSED: " & integer'image(valid_words) & " words checked";
		done <= TRUE;
		wait;
	end process test_proc;
end architecture behavior;
