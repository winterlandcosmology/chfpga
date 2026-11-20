-- Behavioural stand-in for the Xilinx 100G MAC IP (cmac_usplus_1), for simulation only.
--
-- It replaces the IP (and its transceivers) so that the logic in front of the MAC can be simulated
-- quickly at the real data rate. It models only what matters for that logic:
--
--  - the 322.265625 MHz user clock and the reset sequence,
--  - the transmit AXI4-Stream port with a ``tready`` that paces the stream at the 100 Gb/s line rate,
--    counting the per-frame overhead that the MAC adds on the wire (preamble, FCS, inter-frame gap),
--  - the rule that a frame must not be interrupted once started: a missing ``tvalid`` in the
--    middle of a frame is reported as an underflow (failure), as the real MAC would corrupt the frame.
--
-- Every transmitted frame is written to FRAME_FILE as one line of hex bytes, starting at the
-- Ethernet destination address (no preamble, no FCS).
--
-- Do not add this file to a synthesis project.
library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use std.textio.ALL;

entity cmac_usplus_1 is
	generic (
		FRAME_FILE: string := "cmac_frames.txt";
		LINE_RATE: real := 100.0e9; -- bits per second on the wire. A real link can be 100 ppm slower.
		WIRE_OVERHEAD_BYTES: integer := 24 -- preamble + SFD (8), FCS (4), minimum inter-frame gap (12)
	);
	port (
		gt_txp_out: out std_logic_vector(3 downto 0);
		gt_txn_out: out std_logic_vector(3 downto 0);
		gt_ref_clk_p: in std_logic;
		gt_ref_clk_n: in std_logic;
		init_clk: in std_logic;
		gt_txusrclk2: out std_logic;
		gt_ref_clk_out: out std_logic;
		ctl_tx_enable: in std_logic;
		ctl_tx_test_pattern: in std_logic;
		ctl_tx_send_rfi: in std_logic;
		ctl_tx_send_lfi: in std_logic;
		ctl_tx_send_idle: in std_logic;
		tx_axis_tready: out std_logic;
		tx_axis_tvalid: in std_logic;
		tx_axis_tdata: in std_logic_vector(511 downto 0);
		tx_axis_tlast: in std_logic;
		tx_axis_tkeep: in std_logic_vector(63 downto 0);
		tx_axis_tuser: in std_logic;
		tx_ovfout: out std_logic;
		tx_unfout: out std_logic;
		tx_preamblein: in std_logic_vector(55 downto 0);
		gt_loopback_in: in std_logic_vector(11 downto 0);
		gt_drpclk: in std_logic;

		gt_eyescanreset: in std_logic_vector(3 downto 0);
		gt_eyescantrigger: in std_logic_vector(3 downto 0);
		gt_rxcdrhold: in std_logic_vector(3 downto 0);
		gt_rxpolarity: in std_logic_vector(3 downto 0);
		gt_rxrate: in std_logic_vector(11 downto 0);
		gt_txdiffctrl: in std_logic_vector(19 downto 0);
		gt_txpolarity: in std_logic_vector(3 downto 0);
		gt_txinhibit: in std_logic_vector(3 downto 0);
		gt_txpippmen: in std_logic_vector(3 downto 0);
		gt_txpippmsel: in std_logic_vector(3 downto 0);
		gt_txpostcursor: in std_logic_vector(19 downto 0);
		gt_txprbsforceerr: in std_logic_vector(3 downto 0);
		gt_txprecursor: in std_logic_vector(19 downto 0);
		gt_rxdfelpmreset: in std_logic_vector(3 downto 0);
		gt_rxlpmen: in std_logic_vector(3 downto 0);
		gt_rxprbscntreset: in std_logic_vector(3 downto 0);
		gt_rxprbssel: in std_logic_vector(15 downto 0);
		gt_txprbssel: in std_logic_vector(15 downto 0);
		ctl_tx_rsfec_enable: in std_logic;

		gt_eyescandataerror: out std_logic_vector(3 downto 0);
		gt_rxrecclkout: out std_logic_vector(3 downto 0);
		gt_powergoodout: out std_logic_vector(3 downto 0);
		gt_txbufstatus: out std_logic_vector(7 downto 0);
		gt_rxprbserr: out std_logic_vector(3 downto 0);
		gt_rxresetdone: out std_logic_vector(3 downto 0);
		gt_txresetdone: out std_logic_vector(3 downto 0);
		gt_rxbufstatus: out std_logic_vector(11 downto 0);

		stat_tx_bad_fcs: out std_logic;
		stat_tx_broadcast: out std_logic;
		stat_tx_frame_error: out std_logic;
		stat_tx_local_fault: out std_logic;
		stat_tx_multicast: out std_logic;
		stat_tx_packet_1024_1518_bytes: out std_logic;
		stat_tx_packet_128_255_bytes: out std_logic;
		stat_tx_packet_1519_1522_bytes: out std_logic;
		stat_tx_packet_1523_1548_bytes: out std_logic;
		stat_tx_packet_1549_2047_bytes: out std_logic;
		stat_tx_packet_2048_4095_bytes: out std_logic;
		stat_tx_packet_256_511_bytes: out std_logic;
		stat_tx_packet_4096_8191_bytes: out std_logic;
		stat_tx_packet_512_1023_bytes: out std_logic;
		stat_tx_packet_64_bytes: out std_logic;
		stat_tx_packet_65_127_bytes: out std_logic;
		stat_tx_packet_8192_9215_bytes: out std_logic;
		stat_tx_packet_large: out std_logic;
		stat_tx_packet_small: out std_logic;
		stat_tx_total_bytes: out std_logic_vector(5 downto 0);
		stat_tx_total_good_bytes: out std_logic_vector(13 downto 0);
		stat_tx_total_good_packets: out std_logic;
		stat_tx_total_packets: out std_logic;
		stat_tx_unicast: out std_logic;
		stat_tx_vlan: out std_logic;

		gtwiz_reset_tx_datapath: in std_logic;
		gtwiz_reset_rx_datapath: in std_logic;
		sys_reset: in std_logic;
		core_tx_reset: in std_logic;
		usr_tx_reset: out std_logic;

		core_drp_reset: in std_logic;
		drp_clk: in std_logic;
		drp_addr: in std_logic_vector(9 downto 0);
		drp_di: in std_logic_vector(15 downto 0);
		drp_en: in std_logic;
		drp_do: out std_logic_vector(15 downto 0);
		drp_rdy: out std_logic;
		drp_we: in std_logic;

		common0_drpaddr: in std_logic_vector(15 downto 0);
		common0_drpdi: in std_logic_vector(15 downto 0);
		common0_drpen: in std_logic;
		common0_drpdo: out std_logic_vector(15 downto 0);
		common0_drprdy: out std_logic;
		common0_drpwe: in std_logic;

		gt0_drpaddr: in std_logic_vector(9 downto 0);
		gt0_drpdi: in std_logic_vector(15 downto 0);
		gt0_drpen: in std_logic;
		gt0_drpdo: out std_logic_vector(15 downto 0);
		gt0_drprdy: out std_logic;
		gt0_drpwe: in std_logic;
		gt1_drpaddr: in std_logic_vector(9 downto 0);
		gt1_drpdi: in std_logic_vector(15 downto 0);
		gt1_drpen: in std_logic;
		gt1_drpdo: out std_logic_vector(15 downto 0);
		gt1_drprdy: out std_logic;
		gt1_drpwe: in std_logic;
		gt2_drpaddr: in std_logic_vector(9 downto 0);
		gt2_drpdi: in std_logic_vector(15 downto 0);
		gt2_drpen: in std_logic;
		gt2_drpdo: out std_logic_vector(15 downto 0);
		gt2_drprdy: out std_logic;
		gt2_drpwe: in std_logic;
		gt3_drpaddr: in std_logic_vector(9 downto 0);
		gt3_drpdi: in std_logic_vector(15 downto 0);
		gt3_drpen: in std_logic;
		gt3_drpdo: out std_logic_vector(15 downto 0);
		gt3_drprdy: out std_logic;
		gt3_drpwe: in std_logic
	);
end entity cmac_usplus_1;

architecture sim of cmac_usplus_1 is
	constant CLK_PERIOD: time := 3103 ps; -- 322.265625 MHz
	constant BYTES_PER_CLOCK: real := LINE_RATE * 3.103e-9 / 8.0; -- wire bytes the line can carry per clock
	constant CREDIT_MAX: real := 2048.0; -- wire bytes the MAC may have buffered

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal tready: std_logic := '0';
begin
	clk <= not clk after CLK_PERIOD / 2;
	gt_txusrclk2 <= clk;
	gt_ref_clk_out <= gt_ref_clk_p;
	usr_tx_reset <= rst;
	tx_axis_tready <= tready;

	gt_txp_out <= (others => '0');
	gt_txn_out <= (others => '1');
	drp_do <= (others => '0');
	drp_rdy <= drp_en;
	common0_drpdo <= (others => '0');
	common0_drprdy <= common0_drpen;
	gt0_drpdo <= (others => '0'); gt0_drprdy <= gt0_drpen;
	gt1_drpdo <= (others => '0'); gt1_drprdy <= gt1_drpen;
	gt2_drpdo <= (others => '0'); gt2_drprdy <= gt2_drpen;
	gt3_drpdo <= (others => '0'); gt3_drprdy <= gt3_drpen;

	mac_proc: process
		file frames: text;
		variable file_is_open: boolean := FALSE;
		variable l: line;
		variable reset_ctr: integer := 0;
		variable backlog: real := 0.0; -- wire bytes accepted but not yet sent
		variable in_frame: boolean := FALSE;
		variable nbytes: integer;
	begin
		wait until rising_edge(clk);
		tx_ovfout <= '0';
		tx_unfout <= '0';

		if sys_reset = '1' or core_tx_reset = '1' or gtwiz_reset_tx_datapath = '1' then
			reset_ctr := 0;
		end if;
		if reset_ctr < 200 then
			reset_ctr := reset_ctr + 1;
			rst <= '1';
			tready <= '0';
			backlog := 0.0;
			in_frame := FALSE;
		else
			rst <= '0';

			-- A transfer happens when both tvalid and the tready we presented are high
			if tready = '1' and ctl_tx_enable = '1' then
				if tx_axis_tvalid = '1' then
					nbytes := 0;
					for i in 0 to 63 loop
						if tx_axis_tkeep(i) = '1' then
							assert nbytes = i report "cmac model: tkeep is not contiguous" severity FAILURE;
							hwrite(l, tx_axis_tdata(8 * i + 7 downto 8 * i));
							nbytes := nbytes + 1;
						end if;
					end loop;
					assert nbytes > 0 report "cmac model: transfer without any byte" severity FAILURE;
					assert tx_axis_tlast = '1' or nbytes = 64 report "cmac model: partial word before the end of a frame" severity FAILURE;
					backlog := backlog + real(nbytes);
					in_frame := tx_axis_tlast = '0';
					if tx_axis_tlast = '1' then
						backlog := backlog + real(WIRE_OVERHEAD_BYTES);
						if not file_is_open then
							file_open(frames, FRAME_FILE, write_mode);
							file_is_open := TRUE;
						end if;
						writeline(frames, l);
					end if;
				elsif in_frame then
					tx_unfout <= '1';
					assert FALSE report "cmac model: transmit underflow (tvalid dropped inside a frame)" severity FAILURE;
				end if;
			end if;

			-- The line drains the backlog at the line rate
			backlog := backlog - BYTES_PER_CLOCK;
			if backlog < 0.0 then
				backlog := 0.0;
			end if;
			tready <= '1' when backlog < CREDIT_MAX else '0';
		end if;
	end process mac_proc;

end architecture sim;
