--------------------------------------------------------------------------------
-- ucorr44_ice_readout_testbench
--
-- Regression testbench for the ICE corr16 UCORR44 readout. Written to reproduce the
-- Nov 2026 bank-aliasing fault (UCMAC44_ARRAY placed the bank bit at RAM address bit
-- 11 while the NPROD=512 RAM is only 1024 words deep, so both banks shared the same
-- words); passes on the fixed RTL.
--
-- Drives one UCORR44 core with the ICE corr16 generics (NCHAN=16, NCHAN_PER_CLK=16,
-- NBINS=512, NDECIM=1, URAM_MAX=0 -> BRAM, NPROD=512) with a frame of 512 words that
-- is identical on all 16 channels and identical in every frame, decodes the
-- byte-serial output packets, and compares every packet with:
--   * the correct value N * |x_b|^2 (N = integration period), and
--   * the "bank aliasing" prediction: the readout reads the physical word that the
--     accumulator has been rebuilding since the bank switch, i.e. f * |x_b|^2 when
--     bin b is captured on frame f of the next integration (f - 1 for the last 4
--     words, which are written back after the readout read).
--
-- VHDL-2008 external names are used to observe the UCMAC44_ARRAY internals and
-- produce three logs: per-packet results, readout captures (which physical RAM word
-- the readout reads versus when the accumulator last wrote it), and a cycle trace
-- around the first bank switches.
--
-- PASS criterion: every complete readout has all 512 packets, every bin except
-- READOUT_BIN (whose slot is sacrificed to the readout by design) equals N * |x_b|^2
-- (|x_b|^2 with NO_ACCUM=1), and every header is correct. The summary file ends with
-- "RESULT: PASS" or "RESULT: FAIL".
--
-- Output files (in the simulation directory), with
-- <tag> = c<NCHAN>_s<STIM>_n<N>_na<NO_ACCUM>_id<CORR_ID>_sp<SEND_PERIOD>:
--   <tag>_packets.txt  one line per packet
--   <tag>_captures.txt one line per readout capture
--   <tag>_word0.txt    READOUT_BIN (word 0) read/write history over integrations 1-2
--   <tag>_trace.txt    cycle trace around the first bank switches
--   <tag>_summary.txt  per-readout summary and the bins of interest
--
-- Generics:
--   STIM        1: x = 1+1j on all bins; 2: re = (b mod 7)-3, im = ((b/7) mod 7)-3;
--               3: read 512 lines "re im" from STIM_FILE
--   N_INTEG     integration period N (integ_period = N-1)
--   N_READOUTS  number of complete integrations to read out
--   NO_ACCUM    0/1
--   CORR_ID     0..15
--   SEND_PERIOD z_out_send is asserted one cycle out of SEND_PERIOD (1 = always)
--   RUN_FRAMES  if > 0, overrides the computed simulation length (frames)
--   NCHAN       16 for ICE; a reduced model (e.g. 4) exercises the same control/address logic faster
--   RAM_AW      width of UCMAC44_ARRAY's ram_rd_addr/ram_wr_addr: 10 since the fix
--               (bank bit at bit width(NPROD)); 12 for RTL predating the fix
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use std.textio.ALL;
use std.env.finish;

library work;
use work.chfpga_package.ALL;

entity ucorr44_ice_readout_testbench is
	generic (
		STIM        : integer := 1;
		NCHAN       : integer := 16; -- ICE corr16: 16. Smaller (even, NCHAN*(NCHAN+1)/2 even) values give a fast reduced model
		N_INTEG     : integer := 2048;
		N_READOUTS  : integer := 4;
		NO_ACCUM    : integer := 0;
		CORR_ID     : integer := 8;
		SEND_PERIOD : integer := 1;
		RUN_FRAMES  : integer := 0;
		RAM_AW      : integer := 10;
		STIM_FILE   : string  := "stim.txt"
	);
end entity ucorr44_ice_readout_testbench;

architecture sim of ucorr44_ice_readout_testbench is

	constant CLK_PERIOD: time    := 5 ns; -- 200 MHz ct_clk
	constant NPROD: integer := 512; -- words per frame = bins per core
	constant NCMAC: integer := NCHAN * (NCHAN + 1) / 2;
	constant READOUT_BIN: integer := 0;
	constant WR_LAT: integer := 4; -- word j is read at E_j and written back at E_j+4

	constant TAG: string := "c" & to_string(NCHAN) & "_s" & to_string(STIM) & "_n" & to_string(N_INTEG) & "_na" & to_string(NO_ACCUM) &
	                        "_id" & to_string(CORR_ID) & "_sp" & to_string(SEND_PERIOD);

	-- Frames: N_READOUTS+1 integrations (the last one hosts the last readout), plus the
	-- readout itself (<= 1024 frames at one byte per clock, more if send is throttled).
	constant TOTAL_FRAMES: integer := sel(RUN_FRAMES > 0, RUN_FRAMES,
	                                      N_INTEG * N_READOUTS + 2 * NPROD * SEND_PERIOD + 64);

	type int_array is array (natural range <>) of integer;

	-- Stimulus: per-bin (re, im), identical on every channel and in every frame

	impure function load_stim return int_array is

		variable v: int_array(0 to 2 * NPROD - 1);
		file     f       : text;
		variable l: line;
		variable re, im: integer;
		variable status: file_open_status;

	begin

		for b in 0 to NPROD - 1 loop
			-- (re, im) of bin b

			case STIM is

				when 1 =>
					re := 1;
					im := 1;

				when 2 =>
					re := (b mod 7) - 3;
					im := ((b / 7) mod 7) - 3;

				when others =>
					re := 0;
					im := 0;

			end case;

			v(2 * b)     := re;
			v(2 * b + 1) := im;
		end loop;

		if STIM = 3 then
			file_open(status, f, STIM_FILE, read_mode);
			assert status = open_ok
				report "cannot open " & STIM_FILE
				severity failure;
			for b in 0 to NPROD - 1 loop
				readline(f, l); read(l, re); read(l, im);
				v(2 * b) := re; v(2 * b + 1) := im;
			end loop;

			file_close(f);
		end if;
		return v;

	end function load_stim;

	constant XV: int_array(0 to 2 * NPROD - 1) := load_stim;

	function pwr(b: integer) return integer is
	begin

		return XV(2 * b) ** 2 + XV(2 * b + 1) ** 2;

	end function pwr;

	function xbyte(b: integer) return std_logic_vector is
	begin

		return std_logic_vector(to_signed(XV(2 * b), 4)) & std_logic_vector(to_signed(XV(2 * b + 1), 4));

	end function xbyte;

	function verdict(p: boolean) return string is
	begin

		if p then
			return "PASS";
		end if;
		return "FAIL";

	end function verdict;

	function hex(v: std_logic_vector) return string is
	begin

		return to_hstring(v);

	end function hex;

	signal clk: std_logic := '0';
	signal rst: std_logic := '1';
	signal tdata: slv_array(0 to NCHAN - 1)(7 downto 0) := (others => (others => '0'));
	signal tvalid: std_logic := '0';
	signal tlast: std_logic := '0';
	signal z_tdata: std_logic_vector(7 downto 0);
	signal z_tlast: std_logic;
	signal z_tvalid: std_logic;
	signal z_send: std_logic := '1';
	signal overrun: std_logic;
	signal cycle: integer := 0;
	signal gframe: integer := -1; -- input frame index (TB side)
	signal gword: integer := -1; -- input word index (TB side)
	signal done: boolean := false;

	-- capture frame of each bin in the current readout, written by the monitor
	signal cap_frame: int_array(0 to NPROD - 1) := (others => -1);

begin

	clk <= not clk after CLK_PERIOD / 2;

	dut: entity work.UCORR44
		generic map (
			PLATFORM_TYPE => MGK7MB,
			NCHAN         => NCHAN,
			NCHAN_PER_CLK => NCHAN,
			NBINS         => NPROD,
			NDECIM        => 1,
			CORR_NUMBER   => 0,
			NCORR         => 2,
			URAM_MAX      => 0,
			READOUT_BIN   => READOUT_BIN
		)
		port map (
			s_axis_tdata    => tdata,
			s_axis_tlast    => tlast,
			s_axis_tvalid   => tvalid,
			bin_set         => "0000",
			auto_bin_set    => '1',
			offset_encoding => '0',
			integ_period    => std_logic_vector(to_unsigned(N_INTEG - 1, 16)),
			autocorr_only   => '0',
			no_accum        => to_std_logic(NO_ACCUM = 1),
			corr_id         => std_logic_vector(to_unsigned(CORR_ID, 4)),
			overrun         => overrun,
			overrun_reset   => '0',
			z_out_tdata     => z_tdata,
			z_out_tlast     => z_tlast,
			z_out_tvalid    => z_tvalid,
			z_out_send      => z_send,
			z_in_tdata      => (others => '0'),
			z_in_tlast      => '0',
			z_in_tvalid     => '0',
			z_in_send       => open,
			clk             => clk,
			rst             => rst
		);

	-- z_out_send pattern
	send_proc: process(clk) begin
		if rising_edge(clk) then
			cycle <= cycle + 1;
			z_send <= to_std_logic((cycle mod SEND_PERIOD) = 0);
		end if;
	end process;

	------------------------------------------------------------------
	-- Stimulus: continuous 512-word frames, tlast on word 511
	------------------------------------------------------------------
	stim_proc: process
	begin
		rst <= '1';
		for i in 1 to 20 loop
			wait until rising_edge(clk);
		end loop;

		rst <= '0';
		for i in 1 to 20 loop
			wait until rising_edge(clk);
		end loop;

		report "TB " & TAG & ": running " & to_string(TOTAL_FRAMES) & " frames";
		for f in 0 to TOTAL_FRAMES - 1 loop
			for w in 0 to NPROD - 1 loop
				for ch in 0 to NCHAN - 1 loop
					tdata(ch) <= xbyte(w);
				end loop;

				tvalid <= '1';
				tlast <= to_std_logic(w = NPROD - 1);
				gframe <= f;
				gword <= w;
				wait until rising_edge(clk);
			end loop;

			if f mod 1024 = 0 then
				report "TB " & TAG & ": frame " & to_string(f);
			end if;
		end loop;

		tvalid <= '0';
		tlast <= '0';
		for i in 1 to 2000 loop
			wait until rising_edge(clk);
		end loop;

		done <= true;
		wait;
	end process;

	------------------------------------------------------------------
	-- Internal monitors (external names must follow the DUT instance)
	------------------------------------------------------------------
	mon_blk: block
		alias m_frame     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.frame : unsigned(15 downto 0) >>;
		alias m_rdctr     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.rd_word_ctr1 : unsigned(10 downto 0) >>;
		alias m_roctr     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.ro_word_ctr1 : unsigned(10 downto 0) >>;
		alias m_wrctr     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.wr_word_ctr5 : unsigned(10 downto 0) >>;
		alias m_romax     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.ro_word_ctr_max : unsigned(10 downto 0) >>;
		alias m_bank1     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.acc_bank1 : std_logic >>;
		alias m_bank5     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.acc_bank5 : std_logic >>;
		alias m_ro_active is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.ro_active : std_logic >>;
		alias m_ro_shift  is << signal .ucorr44_ice_readout_testbench.dut.corr0.ctrl_blk.ro_shift : std_logic >>;
		alias m_ro_word1  is << signal .ucorr44_ice_readout_testbench.dut.corr0.ro_word1 : std_logic >>;
		alias m_ro_word2  is << signal .ucorr44_ice_readout_testbench.dut.corr0.ro_word2 : std_logic >>;
		alias m_ff1       is << signal .ucorr44_ice_readout_testbench.dut.corr0.first_frame1 : std_logic >>;
		alias m_ff2       is << signal .ucorr44_ice_readout_testbench.dut.corr0.first_frame2 : std_logic >>;
		alias m_rd_addr   is << signal .ucorr44_ice_readout_testbench.dut.corr0.ram_rd_addr : std_logic_vector(RAM_AW - 1 downto 0) >>;
		alias m_wr_addr   is << signal .ucorr44_ice_readout_testbench.dut.corr0.ram_wr_addr : std_logic_vector(RAM_AW - 1 downto 0) >>;
		alias m_wr_en     is << signal .ucorr44_ice_readout_testbench.dut.corr0.ram_wr_en : std_logic >>;
		alias m_dout      is << signal .ucorr44_ice_readout_testbench.dut.corr0.ram_dout : slv_array(0 to NCMAC - 1)(35 downto 0) >>;
		alias m_din       is << signal .ucorr44_ice_readout_testbench.dut.corr0.ram_din : slv_array(0 to NCMAC - 1)(35 downto 0) >>;
		alias m_xy_tvalid is << signal .ucorr44_ice_readout_testbench.dut.xy_tvalid : std_logic >>;
		alias m_xy_tlast  is << signal .ucorr44_ice_readout_testbench.dut.xy_tlast : std_logic >>;

		-- Physical depth of the XPM memory instance (MEMORY_SIZE / 72): 2*NPROD words both
		-- before and after the fix
		constant DEPTH: integer := 2 * NPROD;
	begin

		mon_proc: process(clk)

			file     f_cap   : text open write_mode is TAG & "_captures.txt";
			file     f_w0    : text open write_mode is TAG & "_word0.txt";
			file     f_tr    : text open write_mode is TAG & "_trace.txt";
			variable l: line;
			variable header_done: boolean := false;
			-- last write into each physical word (CMAC 0 real part)
			variable lw_addr: int_array(0 to DEPTH - 1) := (others => -1);
			variable lw_frame: int_array(0 to DEPTH - 1) := (others => -1);
			variable lw_val: int_array(0 to DEPTH - 1) := (others => 0);
			-- snapshot of the word-0 read
			variable r0_addr: integer := -1;
			variable r0_eff: integer := -1;
			variable r0_frame: integer := -1;
			variable r0_lw_addr: integer := -1;
			variable r0_lw_frame: integer := -1;
			variable r0_lw_val: integer := -1;
			variable switch_ctr: integer := 0;
			variable tr: boolean;
			variable a, e: integer;

			function re_of(v: std_logic_vector(35 downto 0)) return integer is
			begin

				if is_x(v) then
					return -999999;
				end if;
				return to_integer(signed(v(35 downto 18)));

			end function re_of;

			function im_of(v: std_logic_vector(35 downto 0)) return integer is
			begin

				if is_x(v) then
					return -999999;
				end if;
				return to_integer(signed(v(17 downto 0)));

			end function im_of;

		begin
			if rising_edge(clk) then
				if not header_done then
					write(l, string'("# cycle gframe gword | frame bank1 bank5 ro_active ro_shift ro_word1 ro_word2 ff1 ff2 rd_ctr ro_ctr ro_max wr_ctr | rd_addr(eff) wr_en wr_addr(eff) | dout0.re dout0.im din0.re din0.im"));
					writeline(f_tr, l);
					write(l, string'("# capture: frame bin rd_addr eff_word | dout0.re  pred_alias | that physical word was last written by wr_addr at frame (value)"));
					writeline(f_cap, l);
					write(l, string'("# word0: R frame rd_addr(eff) dout0.re  -- read of word 0 (READOUT_BIN slot);  W frame wr_addr(eff) din0.re -- write of word 0"));
					writeline(f_w0, l);
					header_done := true;
				end if;

				-- All values below are pre-edge values, i.e. what the DUT flops sample on this edge.

				-- cycle trace around the first two bank switches and the first readout captures
				tr := (gframe >= N_INTEG - 1 and gframe <= N_INTEG + 6 and (gword >= NPROD - 4 or gword <= 8)) or
	      (gframe >= 2 * N_INTEG - 1 and gframe <= 2 * N_INTEG + 2 and (gword >= NPROD - 4 or gword <= 8));
				if tr then
					write(l, to_string(cycle) & " " & to_string(gframe) & " " & to_string(gword) & " | " &
	      to_string(to_integer(m_frame)) & " " & to_string(m_bank1) & " " & to_string(m_bank5) & " " &
	      to_string(m_ro_active) & " " & to_string(m_ro_shift) & " " & to_string(m_ro_word1) & " " &
	      to_string(m_ro_word2) & " " & to_string(m_ff1) & " " & to_string(m_ff2) & " " &
	      to_string(to_integer(m_rdctr)) & " " & to_string(to_integer(m_roctr)) & " " &
	      to_string(to_integer(m_romax)) & " " & to_string(to_integer(m_wrctr)) & " | 0x" &
	      hex(m_rd_addr) & "(" & to_string(to_integer(unsigned(m_rd_addr)) mod DEPTH) & ") " &
	      to_string(m_wr_en) & " 0x" & hex(m_wr_addr) & "(" &
	      to_string(to_integer(unsigned(m_wr_addr)) mod DEPTH) & ") | " &
	      to_string(re_of(m_dout(0))) & " " & to_string(im_of(m_dout(0))) & " " &
	      to_string(re_of(m_din(0))) & " " & to_string(im_of(m_din(0))));
					writeline(f_tr, l);
				end if;

				-- E_0 of a frame: the RAM samples the word-0 (READOUT_BIN) read address now
				if m_xy_tvalid = '1' and m_rdctr = READOUT_BIN then
					r0_addr  := to_integer(unsigned(m_rd_addr));
					r0_eff   := r0_addr mod DEPTH;
					r0_frame := to_integer(m_frame);
					r0_lw_addr := lw_addr(r0_eff); r0_lw_frame := lw_frame(r0_eff); r0_lw_val := lw_val(r0_eff);
				end if;

				-- E_2: word-0 data is on ram_dout; capture happens if the readout is idle-waiting
				if m_ro_word2 = '1' then
					if gframe >= N_INTEG - 2 and gframe < 3 * N_INTEG + 2 then
						write(l, "R " & to_string(r0_frame) & " 0x" & to_hstring(to_unsigned(r0_addr, RAM_AW)) & "(" &
	      to_string(r0_eff) & ") " & to_string(re_of(m_dout(0))));
						writeline(f_w0, l);
					end if;
					if m_ro_active = '1' and m_ro_shift = '0' then
						a := to_integer(m_roctr);
						cap_frame(a) <= r0_frame;
						write(l, to_string(r0_frame) & " " & to_string(a) & " 0x" & to_hstring(to_unsigned(r0_addr, RAM_AW)) &
	      " " & to_string(r0_eff) & " | " & to_string(re_of(m_dout(0))) & " | wr_addr 0x" &
	      to_hstring(to_unsigned(r0_lw_addr mod 2 ** RAM_AW, RAM_AW)) & " frame " & to_string(r0_lw_frame) &
	      " (" & to_string(r0_lw_val) & ")");
						writeline(f_cap, l);
					end if;
				end if;

				-- RAM write on this edge
				if m_wr_en = '1' then
					a := to_integer(unsigned(m_wr_addr));
					e := a mod DEPTH;
					lw_addr(e) := a; lw_frame(e) := to_integer(m_frame); lw_val(e) := re_of(m_din(0));
					if (a mod 2 ** (RAM_AW - 1)) = READOUT_BIN and gframe >= N_INTEG - 2 and gframe < 3 * N_INTEG + 2 then
						write(l, "W " & to_string(to_integer(m_frame)) & " 0x" & hex(m_wr_addr) & "(" & to_string(e) & ") " &
	      to_string(re_of(m_din(0))));
						writeline(f_w0, l);
					end if;
				end if;
			end if;
		end process;

	end block mon_blk;

	------------------------------------------------------------------
	-- Output packet decoder and checker
	------------------------------------------------------------------
	dec_proc: process(clk)

		constant PKT_BYTES: integer := 10 + 5 * NCMAC;
		constant NMAX_RO: integer := 64;
		file     f_pkt : text open write_mode is TAG & "_packets.txt";
		file     f_sum : text open write_mode is TAG & "_summary.txt";
		variable l: line;
		variable bytes: slv8_array(0 to PKT_BYTES - 1);
		variable nb: integer := 0;
		variable npkt: integer := 0;
		variable sid: integer;
		variable flags: integer;
		variable ts: integer;
		variable core: integer;
		variable bin: integer;
		variable ro: integer;
		variable w: std_logic_vector(39 downto 0);
		variable re: integer;
		variable im: integer;
		variable re0: integer;
		variable im0: integer;
		variable same: boolean;
		variable sat: integer;
		variable exp_v: integer;
		variable ali_v: integer;
		variable f: integer;
		variable hdr_ok: boolean;
		variable last_f511: integer := -1; -- capture frame of bin 511 in the previous readout
		variable started: boolean := false;
		-- per-readout statistics
		variable n_pk: int_array(0 to NMAX_RO - 1) := (others => 0);
		variable n_ok: int_array(0 to NMAX_RO - 1) := (others => 0);
		variable n_al: int_array(0 to NMAX_RO - 1) := (others => 0);
		variable n_same: int_array(0 to NMAX_RO - 1) := (others => 0);
		variable v_bins: int_array(0 to NMAX_RO * 6 - 1) := (others => -1);
		variable bin0_al: int_array(0 to NMAX_RO - 1) := (others => -1);
		variable nro: integer := 0;
		variable hdr_err: integer := 0;
		variable pass: boolean;
		variable ncomplete: integer;
		type     bins_t is array (0 to 5) of integer;

		constant BINS: bins_t := (0, 1, 2, 64, 256, 511);

	begin
		if rising_edge(clk) then
			if z_tvalid = '1' then
				bytes(nb) := z_tdata;
				nb := nb + 1;
				if z_tlast = '1' then
					assert nb = PKT_BYTES
						report "packet length " & to_string(nb) & " /= " & to_string(PKT_BYTES)
						severity error;
					sid   := to_integer(unsigned(bytes(1)) & unsigned(bytes(2)));
					flags := to_integer(unsigned(bytes(3)));
					ts    := to_integer(unsigned(bytes(4)) & unsigned(bytes(5)) & unsigned(bytes(6)) &
	                    unsigned(bytes(7)) & unsigned(bytes(8)) & unsigned(bytes(9)));
					core  := sid / 2048;
					bin   := sid mod 2048;
					ro    := ts / N_INTEG;
					hdr_ok := bytes(0) = X"CF" and core = CORR_ID and (ts mod N_INTEG) = 0 and (flags mod 16) = 0;
					if not hdr_ok then
						hdr_err := hdr_err + 1;
					end if;
					-- products: 40-bit little-endian words
					same := true; sat := 0;
					for p in 0 to NCMAC - 1 loop
						for k in 0 to 4 loop
							w(8 * k + 7 downto 8 * k) := bytes(10 + 5 * p + k);
						end loop;

						re := to_integer(signed(w(35 downto 18)));
						im := to_integer(signed(w(17 downto 0)));
						if w(39 downto 36) /= "0000" then
							sat := sat + 1;
						end if;
						if p = 0 then
							re0 := re;
							im0 := im;
						elsif re /= re0 or im /= im0 then
							same := false;
						end if;
					end loop;

					-- correct value and aliasing prediction
					if NO_ACCUM = 1 then
						exp_v := pwr(bin);
						ali_v := pwr(bin);
					else
						exp_v := N_INTEG * pwr(bin);
						f := cap_frame(bin);
						if bin = READOUT_BIN then
							if last_f511 < 0 then
								ali_v := N_INTEG * pwr(bin);
							else
								ali_v := (last_f511 - 1) * pwr(NPROD - 1) + (N_INTEG - last_f511) * pwr(bin);
							end if;
						elsif bin >= NPROD - WR_LAT then
							ali_v := (f - 1) * pwr(bin);
						else
							ali_v := f * pwr(bin);
						end if;
					end if;
					ali_v := minimum(ali_v, 131071);
					exp_v := minimum(exp_v, 131071);
					if bin = NPROD - 1 then
						last_f511 := cap_frame(bin);
					end if;
					write(l, to_string(npkt) & " ro=" & to_string(ro) & " ts=" & to_string(ts) & " sid=0x" &
	      to_hstring(to_unsigned(sid, 16)) & " core=" & to_string(core) & " bin=" & to_string(bin) &
	      " flags=0x" & to_hstring(to_unsigned(flags, 8)) & " auto=" & to_string(re0) & "+" &
	      to_string(im0) & "j allsame=" & to_string(same) & " sat=" & to_string(sat) &
	      " exp=" & to_string(exp_v) & " alias=" & to_string(ali_v) & " capf=" &
	      to_string(cap_frame(bin)) & " overrun=" & to_string(overrun));
					writeline(f_pkt, l);
					if ro < NMAX_RO then
						nro := maximum(nro, ro + 1);
						n_pk(ro) := n_pk(ro) + 1;
						if same and im0 = 0 then
							n_same(ro) := n_same(ro) + 1;
						end if;
						if bin /= READOUT_BIN and re0 = exp_v and im0 = 0 then
							n_ok(ro) := n_ok(ro) + 1;
						end if;
						if re0 = ali_v and im0 = 0 then
							n_al(ro) := n_al(ro) + 1;
						end if;
						for k in 0 to 5 loop
							if bin = BINS(k) then
								v_bins(6 * ro + k) := re0;
							end if;
						end loop;

						if bin = READOUT_BIN then
							bin0_al(ro) := ali_v;
						end if;
					end if;
					npkt := npkt + 1;
					nb := 0;
				end if;
			end if;

			if done and not started then
				started := true;
				write(l, "TB " & TAG & "  N=" & to_string(N_INTEG) & " NO_ACCUM=" & to_string(NO_ACCUM) &
	      " CORR_ID=" & to_string(CORR_ID) & " SEND_PERIOD=" & to_string(SEND_PERIOD) &
	      " packets=" & to_string(npkt) & " header_errors=" & to_string(hdr_err));
				writeline(f_sum, l);
				write(l, string'("readout ts  npkts  products_identical  bins!=0_correct(N|x|^2)  alias_model_match | bin0 bin1 bin2 bin64 bin256 bin511 | expected(N|x|^2) for those bins | bin0 alias pred"));
				writeline(f_sum, l);
				for r in 0 to nro - 1 loop
					write(l, to_string(r) & " " & to_string(r * N_INTEG) & "  " & to_string(n_pk(r)) & "  " &
	      to_string(n_same(r)) & "  " & to_string(n_ok(r)) & "  " & to_string(n_al(r)) & " |");
					for k in 0 to 5 loop
						write(l, " " & to_string(v_bins(6 * r + k)));
					end loop;

					write(l, string'(" |"));
					for k in 0 to 5 loop
						if NO_ACCUM = 1 then
							write(l, " " & to_string(pwr(BINS(k))));
						else
							write(l, " " & to_string(minimum(N_INTEG * pwr(BINS(k)), 131071)));
						end if;
					end loop;

					write(l, " | " & to_string(bin0_al(r)));
					writeline(f_sum, l);
				end loop;

				-- verdict over the complete readouts
				pass := hdr_err = 0;
				ncomplete := 0;
				for r in 0 to nro - 1 loop
					if n_pk(r) = NPROD then
						ncomplete := ncomplete + 1;
						if n_ok(r) /= NPROD - 1 or n_same(r) /= NPROD then
							pass := false;
						end if;
					end if;
				end loop;

				pass := pass and ncomplete > 0;
				write(l, "complete readouts: " & to_string(ncomplete));
				writeline(f_sum, l);
				write(l, "RESULT: " & verdict(pass));
				writeline(f_sum, l);
				file_close(f_sum);
				file_close(f_pkt);
				report "TB " & TAG & ": DONE, RESULT: " & verdict(pass);
				finish;
			end if;
		end if;
	end process;

end architecture sim;
