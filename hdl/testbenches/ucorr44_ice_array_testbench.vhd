--------------------------------------------------------------------------------
-- ucorr44_ice_array_testbench
--
-- ICE corr16 UCORR44_ARRAY (two cascaded UCORR44 cores, one per bin of the 2-bin
-- HIRAX_3DSP word) with the generics computed exactly as chfpga.vhd does for
-- CONFIG_CORR_TYPE=UCORR44, CT_LEVEL=1 (NCHAN = NUMBER_OF_CHANNELIZERS = 16 on ICE).
--
-- * Elaboration check: reports the chfpga.vhd-derived generics; run_ucorr44_ice_array.sh -e
--   reads the generics actually elaborated in the array, both cores, both UCMAC44_ARRAYs
--   and an xpm_memory instance back with xsim get_value (xsim does not support external
--   names for constants).
-- * Dynamic run: drives a continuous 512-word frame (per-core stimulus identical on
--   all channels), lets the output FIFO drain one byte every TREADY_PERIOD out_clk
--   cycles, and records every packet of both cores together with the frame (since
--   the bank switch) at which each core captured it.
--
-- The software-visible control bytes keep their power-up defaults, which equal the
-- production settings: autocorr_only=0, no_accum=0, auto_bin_set=1, offset_encoding=0,
-- corr_id=0, integ_period=SOFT_NINTEG-1.
--
-- Generics: NCHAN (16 = ICE; smaller even values give a fast reduced model), STIM (1 or 2,
-- see ucorr44_ice_readout_testbench; core c, word w carries bin 512*c + w), N_INTEG,
-- N_READOUTS, TREADY_PERIOD, RUN_FRAMES (0 = automatic; -1 = elaboration report only).
-- Output: a<NCHAN>_s<STIM>_n<N>_tp<TREADY_PERIOD>_{packets,summary}.txt
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use std.textio.ALL;
use std.env.finish;

library work;
use work.chfpga_package.ALL;

entity ucorr44_ice_array_testbench is
	generic (
		NCHAN         : integer := 16;
		STIM          : integer := 1;
		N_INTEG       : integer := 4096;
		N_READOUTS    : integer := 2;
		TREADY_PERIOD : integer := 1;
		RUN_FRAMES    : integer := 0
	);
end entity ucorr44_ice_array_testbench;

architecture sim of ucorr44_ice_array_testbench is

	-- chfpga.vhd, case UCORR44, CT_LEVEL = 1, ICE corr16 configuration
	constant PLATFORM_TYPE: platform_type_enum := MGK7MB;
	constant FFT_TYPE: fft_type_enum := HIRAX_3DSP;
	constant CT_OUT_BITS_PER_BIN: integer := 4 + 4;
	constant NCORR: integer := FFT_INFO(FFT_TYPE).BINS_PER_WORD;
	constant BIN_DECIMATION_FACTOR: integer := 1;
	constant NBOARDS: integer := 1;
	constant NBINS_PER_CORR: integer := FFT_INFO(FFT_TYPE).SAMPLES_PER_FRAME / 2 / NBOARDS / NCORR;
	constant CT_OUT_WIDTH: integer := FFT_INFO(FFT_TYPE).BINS_PER_WORD * CT_OUT_BITS_PER_BIN * NCHAN;
	constant READOUT_BINS: integer_array(0 to NCORR - 1) := (0, 0); -- CONFIG_CORR_READOUT_BINS

	-- Values derived the way UCORR44_ARRAY / UCORR44 derive them (for the report)
	constant NCHAN_PER_CLK: integer := CT_OUT_WIDTH / NCORR / CT_OUT_BITS_PER_BIN;
	constant NCMAC: integer := NCHAN * (NCHAN + 1) / 2 / (BIN_DECIMATION_FACTOR * (NCHAN / NCHAN_PER_CLK));
	constant NWORDS: integer := NBINS_PER_CORR; -- words per frame (1 word per bin pair)

	constant CLK_PERIOD: time := 5 ns; -- ct_clk = 200 MHz
	constant OUT_CLK_PERIOD: time := 5 ns;
	constant PKT_BYTES: integer := 10 + 5 * NCMAC;
	constant TOTAL_FRAMES: integer := sel(RUN_FRAMES /= 0, RUN_FRAMES, N_INTEG * N_READOUTS + 64 +
	                                      2 * NWORDS * maximum(2, (PKT_BYTES * TREADY_PERIOD) / NWORDS + 1));
	constant TAG: string := "a" & to_string(NCHAN) & "_s" & to_string(STIM) & "_n" & to_string(N_INTEG) &
	                        "_tp" & to_string(TREADY_PERIOD);

	type int_array is array (natural range <>) of integer;

	function xval(b: integer; part: integer) return integer is
	begin

		if STIM = 2 then
			if part = 0 then
				return (b mod 7) - 3;
			else
				return ((b / 7) mod 7) - 3;
			end if;
		end if;
		return 1;

	end function xval;

	function pwr(b: integer) return integer is
	begin

		return xval(b, 0) ** 2 + xval(b, 1) ** 2;

	end function pwr;

	signal clk, out_clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal tdata: std_logic_vector(CT_OUT_WIDTH - 1 downto 0) := (others => '0');
	signal tvalid: std_logic := '0';
	signal tlast: std_logic := '0';
	signal m_tdata: std_logic_vector(7 downto 0);
	signal m_tvalid: std_logic;
	signal m_tlast: std_logic;
	signal m_tready: std_logic := '0';
	signal ocycle: integer := 0;
	signal done: boolean := false;
	signal cap_frame0, cap_frame1: int_array(0 to NWORDS - 1) := (others => -1);

begin

	clk     <= not clk after CLK_PERIOD / 2;
	out_clk <= not out_clk after OUT_CLK_PERIOD / 2;

	dut: entity work.UCORR44_ARRAY
		generic map (
			PLATFORM_TYPE         => PLATFORM_TYPE,
			INPUT_WIDTH           => CT_OUT_WIDTH,
			NCHAN                 => NCHAN,
			NCORR                 => NCORR,
			NBINS_PER_CORR        => NBINS_PER_CORR,
			BIN_DECIMATION_FACTOR => BIN_DECIMATION_FACTOR,
			SOFT_NINTEG           => N_INTEG,
			READOUT_BINS          => READOUT_BINS
		)
		port map (
			s_axis_data_tdata  => tdata,
			s_axis_data_tvalid => tvalid,
			s_axis_data_tlast  => tlast,
			clk                => clk,
			rst                => rst,
			m_axis_data_tdata  => m_tdata,
			m_axis_data_tvalid => m_tvalid,
			m_axis_data_tlast  => m_tlast,
			m_axis_data_tready => m_tready,
			out_clk            => out_clk,
			bsb_clk            => out_clk,
			bsb_rst            => rst
		);

	tready_proc: process(out_clk) begin
		if rising_edge(out_clk) then
			ocycle <= ocycle + 1;
			m_tready <= to_std_logic((ocycle mod TREADY_PERIOD) = 0);
		end if;
	end process;

	stim_proc: process

		variable v: std_logic_vector(CT_OUT_WIDTH - 1 downto 0);
		variable lsb: integer;
		variable l: line;

	begin
		write(l, "ELAB chfpga.vhd-derived: NCHAN=" & to_string(NCHAN) & " NCORR=" & to_string(NCORR) &
	      " BIN_DECIMATION_FACTOR=" & to_string(BIN_DECIMATION_FACTOR) & " NBINS_PER_CORR=" &
	      to_string(NBINS_PER_CORR) & " INPUT_WIDTH(CT_OUT_WIDTH)=" & to_string(CT_OUT_WIDTH) &
	      " READOUT_BINS=(" & to_string(READOUT_BINS(0)) & "," & to_string(READOUT_BINS(1)) & ")" &
	      " FPGA_SERIES=" & to_string(PLATFORM_INFO(PLATFORM_TYPE).FPGA_SERIES));
		writeline(output, l);
		write(l, "ELAB derived: NCHAN_PER_CLK=" & to_string(NCHAN_PER_CLK) & " NCMAC=" & to_string(NCMAC) &
	      " NPROD=" & to_string(NBINS_PER_CORR) & " packet=" & to_string(PKT_BYTES) & " bytes" &
	      " (internal generics: see the xsim get_value report)");
		writeline(output, l);
		if RUN_FRAMES < 0 then
			done <= true;
			wait;
		end if;
		rst <= '1';
		for i in 1 to 20 loop
			wait until rising_edge(clk);
		end loop;

		rst <= '0';
		for i in 1 to 40 loop
			wait until rising_edge(clk);
		end loop;

		report "TB " & TAG & ": running " & to_string(TOTAL_FRAMES) & " frames";
		for f in 0 to TOTAL_FRAMES - 1 loop
			for w in 0 to NWORDS - 1 loop
				for c in 0 to NCORR - 1 loop
					for ch in 0 to NCHAN - 1 loop
						lsb := CT_OUT_BITS_PER_BIN * ((NCORR - 1 - c) * NCHAN + (NCHAN - 1 - ch));
						v(lsb + 7 downto lsb) := std_logic_vector(to_signed(xval(NWORDS * c + w, 0), 4)) &
	                         std_logic_vector(to_signed(xval(NWORDS * c + w, 1), 4));
					end loop;

				end loop;

				tdata <= v;
				tvalid <= '1';
				tlast <= to_std_logic(w = NWORDS - 1);
				wait until rising_edge(clk);
			end loop;

			if f mod 1024 = 0 then
				report "TB " & TAG & ": frame " & to_string(f);
			end if;
		end loop;

		tvalid <= '0';
		tlast <= '0';
		for i in 1 to 4000 * TREADY_PERIOD loop
			wait until rising_edge(clk);
		end loop;

		done <= true;
		wait;
	end process;

	-- Readout capture monitors (frame index within the integration when each core captured bin k)
	mon_blk: block
		alias f0  is << signal .ucorr44_ice_array_testbench.dut.corr_gen(0).corr0.corr0.ctrl_blk.frame : unsigned(15 downto 0) >>;
		alias ro0 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(0).corr0.corr0.ctrl_blk.ro_word_ctr1 : unsigned(10 downto 0) >>;
		alias ra0 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(0).corr0.corr0.ctrl_blk.ro_active : std_logic >>;
		alias rs0 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(0).corr0.corr0.ctrl_blk.ro_shift : std_logic >>;
		alias rw0 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(0).corr0.corr0.ro_word2 : std_logic >>;
		alias f1  is << signal .ucorr44_ice_array_testbench.dut.corr_gen(1).corr0.corr0.ctrl_blk.frame : unsigned(15 downto 0) >>;
		alias ro1 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(1).corr0.corr0.ctrl_blk.ro_word_ctr1 : unsigned(10 downto 0) >>;
		alias ra1 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(1).corr0.corr0.ctrl_blk.ro_active : std_logic >>;
		alias rs1 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(1).corr0.corr0.ctrl_blk.ro_shift : std_logic >>;
		alias rw1 is << signal .ucorr44_ice_array_testbench.dut.corr_gen(1).corr0.corr0.ro_word2 : std_logic >>;
	begin

		process(clk) begin
			if rising_edge(clk) then
				-- ro_word2 is high on E_2 of the frame; the frame counter has been at the new value since E_-1
				if rw0 = '1' and ra0 = '1' and rs0 = '0' then
					cap_frame0(to_integer(ro0)) <= to_integer(f0);
				end if;
				if rw1 = '1' and ra1 = '1' and rs1 = '0' then
					cap_frame1(to_integer(ro1)) <= to_integer(f1);
				end if;
			end if;
		end process;

	end block mon_blk;

	dec_proc: process(out_clk)

		file     f_pkt : text open write_mode is TAG & "_packets.txt";
		file     f_sum : text open write_mode is TAG & "_summary.txt";
		variable l: line;
		variable bytes: slv8_array(0 to PKT_BYTES - 1);
		variable nb, npkt: integer := 0;
		variable sid: integer;
		variable flags: integer;
		variable ts: integer;
		variable core: integer;
		variable bin: integer;
		variable ro: integer;
		variable re: integer;
		variable im: integer;
		variable re0: integer;
		variable im0: integer;
		variable capf: integer;
		variable gbin: integer;
		variable exp_v: integer;
		variable w: std_logic_vector(39 downto 0);
		variable same: boolean;
		constant NMAX: integer := 16;
		variable n_pk, n_ok: int_array(0 to 2 * NMAX - 1) := (others => 0);
		variable vb: int_array(0 to 2 * NMAX * 6 - 1) := (others => -1);
		variable vf: int_array(0 to 2 * NMAX * 6 - 1) := (others => -1);
		variable nro: integer := 0;
		variable started: boolean := false;
		type     bins_t is array (0 to 5) of integer;

		constant BINS: bins_t := (0, 1, 2, 64, 256, 511);

	begin
		if rising_edge(out_clk) then
			if m_tvalid = '1' and m_tready = '1' then
				bytes(nb) := m_tdata;
				nb := nb + 1;
				if m_tlast = '1' then
					assert nb = PKT_BYTES
						report "packet length " & to_string(nb)
						severity error;
					sid   := to_integer(unsigned(bytes(1)) & unsigned(bytes(2)));
					flags := to_integer(unsigned(bytes(3)));
					ts    := to_integer(unsigned(bytes(4)) & unsigned(bytes(5)) & unsigned(bytes(6)) &
	                    unsigned(bytes(7)) & unsigned(bytes(8)) & unsigned(bytes(9)));
					core := sid / 2048; bin := sid mod 2048; ro := ts / N_INTEG;
					same := true;
					for p in 0 to NCMAC - 1 loop
						for k in 0 to 4 loop
							w(8 * k + 7 downto 8 * k) := bytes(10 + 5 * p + k);
						end loop;

						re := to_integer(signed(w(35 downto 18))); im := to_integer(signed(w(17 downto 0)));
						if p = 0 then
							re0 := re;
							im0 := im;
						elsif re /= re0 or im /= im0 then
							same := false;
						end if;
					end loop;

					capf := cap_frame0(bin) when core = 0 else cap_frame1(bin);
					gbin := NWORDS * core + bin;
					exp_v := minimum(N_INTEG * pwr(gbin), 131071);
					write(l, to_string(npkt) & " ro=" & to_string(ro) & " ts=" & to_string(ts) & " core=" & to_string(core) &
	      " bin=" & to_string(bin) & " flags=0x" & to_hstring(to_unsigned(flags, 8)) & " auto=" &
	      to_string(re0) & "+" & to_string(im0) & "j allsame=" & to_string(same) & " exp=" &
	      to_string(exp_v) & " capf=" & to_string(capf));
					writeline(f_pkt, l);
					if ro < NMAX and core < 2 then
						nro := maximum(nro, ro + 1);
						n_pk(2 * ro + core) := n_pk(2 * ro + core) + 1;
						if bin /= 0 and re0 = exp_v and im0 = 0 then
							n_ok(2 * ro + core) := n_ok(2 * ro + core) + 1;
						end if;
						for k in 0 to 5 loop
							if bin = BINS(k) then
								vb(12 * ro + 6 * core + k) := re0;
								vf(12 * ro + 6 * core + k) := capf;
							end if;
						end loop;

					end if;
					npkt := npkt + 1;
					nb := 0;
				end if;
			end if;
			if done and not started then
				started := true;
				write(l, "TB " & TAG & " N=" & to_string(N_INTEG) & " TREADY_PERIOD=" & to_string(TREADY_PERIOD) &
	      " packets=" & to_string(npkt));
				writeline(f_sum, l);
				write(l, string'("readout core npkts bins!=0_correct | auto bins 0 1 2 64 256 511 | capture frame of those bins | expected N|x|^2"));
				writeline(f_sum, l);
				for r in 0 to nro - 1 loop
					for c in 0 to 1 loop
						write(l, to_string(r) & " " & to_string(c) & " " & to_string(n_pk(2 * r + c)) & " " &
	      to_string(n_ok(2 * r + c)) & " |");
						for k in 0 to 5 loop
							write(l, " " & to_string(vb(12 * r + 6 * c + k)));
						end loop;

						write(l, string'(" |"));
						for k in 0 to 5 loop
							write(l, " " & to_string(vf(12 * r + 6 * c + k)));
						end loop;

						write(l, string'(" |"));
						for k in 0 to 5 loop
							write(l, " " & to_string(minimum(N_INTEG * pwr(NWORDS * c + BINS(k)), 131071)));
						end loop;

						writeline(f_sum, l);
					end loop;

				end loop;

				file_close(f_sum);
				report "TB " & TAG & ": DONE";
				finish;
			end if;
		end if;
	end process;

end architecture sim;
