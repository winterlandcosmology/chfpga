----------------------------------------------------------------------------------
-- Company: McGill University
-- Engineer: J.-F. Cliche
--
-- Create Date: 2024
-- Design Name: chFPGA
-- Module Name: UCMAC44_ARRAY
-- Target Devices: Ultrascale+
-- Tool versions: Vivado 2022.2 +
-- Description: Implements an compact array of UltraRAM-based (4+4)-bit complex multiplier/accumulator capable of processing up to 2048 individual products
-----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.math_complex.ALL;

library work;
use work.chFPGA_Package.ALL;

library UNISIM;
use UNISIM.VComponents.ALL;

library xpm;
use xpm.vcomponents.ALL;

-- --------------------------------------------------------------------------------------------------------------------------------------------
-- UCMAC44_ARRAY: Compact array of UltraRAM-based (4+4)-bit complex multiplier/accumulator capable of processing up to 2048 individual products
-- --------------------------------------------------------------------------------------------------------------------------------------------
--
-- This module implement an array of NCMAC (4+4) bit Complex vector multipliers-and-accumulators.
-- The array uses 2N DSP48 and NCMAC/2 UltraRAM, and is capable of processing up to 2048 products.
--
-- The AXI-Streaming input stream consist of a NCMAC pairs of (4+4) bit complex values (X and Y), each pair packed in a 16-bit word as packed as (X_re, X_im, Y_re, Y_im) from MSB to LSB.
-- On each clock cycle where s_axis_xy_tvalid=1,  the multipliers computes all the products :math`Z = X \cdot Y^*`,
-- and the products are stored and accumulated in a separate memory location. Up to 2048 separate products
-- can be stored.
--
-- Data is stored in two banks: one for accumulation and one for readout. The readout bank of every
-- CMAC is read on the first cycle of each frame, capturing NCMAC products. Each (18+18)=36-bit product
-- is packed into 5-bytes (40 bits). When m_axis_z_send='1', a 10 byte header and NCMAC*5-byte products are
-- streamed out byte-by-byte (10 + 5N bytes total) during the next 2047 clocks, while the rest of
-- the frame is being accumulated. A full readout requires 2048 frames, which sets the minimum
-- integration time. Once an integration is completed, banks are interchanged.
--
-- .. todo:
--   Document/deal with NCMAC=odd value
entity UCMAC44_ARRAY is
	generic (
		NCMAC           : integer := 8 * 9 / 2; -- Number of CMACs. There will be 2*NCMAC DSP48s, and min(URAM_MAX, NCMAC/2) UltraRAMs
		NPROD           : integer := 2048; -- Number of products to be stored by each CMAC. Sets memory depth. Must be 2048 if URAM_MAX > 0
		AUTOCORR_STRIDE : integer := 1; -- Spacing (in CMACs) between autocorrelation products. We assume there will be NCMAC/AUTOCORR_STRIDE-1 autocorrelations
		CORR_NUMBER     : integer; -- correlator number to be used in packet headers
		NCORR           : integer := 1; -- Total number of correlators. Used only in computing the STREAM_ID (id = bin*NCORR+CORR_NUMBER)
		URAM_MAX        : integer := 64; -- Maximum number of URAM that will be used. The rest will use BRAMs.
		READOUT_BIN     : integer := 0 -- Bin number sacrificed for the readout cycle
	);
	port (
		-- Data be correlated & integrated. NCMAC channels (NCMAC bytes). AXI4-Streaming, non-blocking.
		s_axis_xy_tdata  : in slv_array(0 to NCMAC - 1)(15 downto 0); -- Array of (4+4)-bit complex numbers to multiply. From MSB to LSB: A_re, A_im, B_re, B_im.
		s_axis_xy_tlast  : in std_logic;
		s_axis_xy_tvalid : in std_logic;
		s_axis_xy_swap   : in std_logic_vector(0 to NCMAC - 1); -- swap A and B (in practice, conjugate A instead of B)

		bin_set       : in std_logic_vector(3 downto 0) := "0000"; -- current bin set, used in header only.
		integ_period  : in std_logic_vector(15 downto 0);
		autocorr_only : in std_logic                    := '1';
		no_accum      : in std_logic                    := '1'; -- when '1', there is no accumulation: only the last product of the accumulation period is kept. (for debugging)
		corr_id       : in std_logic_vector(3 downto 0); -- Software-defined identifier placed in the MSB of the STREAM ID. Used to uniquely identify correlator packets from multiple boards.

		overrun       : out std_logic; -- indicates that data could not be streamed out fast enough and data was lost
		overrun_reset : in std_logic;

		-- Byte-serialized cascadable data input/outputs, AXI-Streaming, 8-bit, sloppy blocking via `send`
		m_axis_z_tdata  : out std_logic_vector(7 downto 0);
		m_axis_z_tlast  : out std_logic;
		m_axis_z_tvalid : out std_logic;
		m_axis_z_send   : in std_logic := '0'; -- for sims

		s_axis_z_tdata  : in std_logic_vector(7 downto 0) := (others => '0');
		s_axis_z_tlast  : in std_logic                    := '0';
		s_axis_z_tvalid : in std_logic                    := '0'; -- for sims
		s_axis_z_send   : out std_logic                   := '0'; -- for sims

		clk : in std_logic; -- clock
		rst : in std_logic -- rst
	);
end entity UCMAC44_ARRAY;


-- Compact (4+4) bit complex multiplier/accumulator array
--
-- The complex multiplier/accumulator (UCMAC44_ARRAY) implements an array of DSP- and BRAM or
-- UltraRAM-Based correlation and accumulator kernels. The unit takes advantage of the small bit
-- width if the incoming complex number (4-bit real, 4-bit imaginary) to implement a full complex
-- multiplier and accumulator using only two DSP48, requiring a very small amount of additional
-- logic and routing resources. The products are accumulated as (18+18) bits values using UltraRAM,
-- BRAMs, or a combination of both.
--
-- The CMACs allows continuous accumulation of products without any dead time. In order to do this, two memory banks are used:
-- one for the currently accumulation, and one for slow readout: once an accumulation is completed, the banks are switched
-- to allow a new accumulation.
-- It is assumed that the integration period is long enough so that the data can be sent out before
-- a new integration period starts.
--
-- The array is implemented with up to URAM_MAX UltraRAM blocks, and BRAMs are used for the rest. URAM_MAX can be set to 0 for a BRAM-only correlator..
--
-- Supporting UltraRAM brings some design constraints. Since UltraRAM is structured as 4096 words x 72 bits and cannot be changed.
-- Since accumulated products require 36 bits (18+18 bits), two CMAC cores are associated with each
-- UltraRAM. We can therefore store 4096 products per UltraRAM. However, this is twice as what is needed for our typical Ultrascale-based
-- correlators (2048 products). In order to not waste precious memory resources, we split each UltraRAM address space in two, one for the accumulation bank and one for the readout bank.
-- But since the UltraRAM does
-- not allow two fully independent read ports, we steal one accumulation read cycle  to read a word from the readout page.
-- We consequently lose one bin per CMAC array. The effect of this can be mitigated at the system level by having this bin aligned with an unused frequency.
--
-- When BRAM is used, a block BRAMs is implemented to simulate one UltraRAM, and is used in the exact same way, with the exception
-- that we can control the depth of the memory. We do not currently attempt to create two independent BRAMs blocks for the accumulator
-- and readout banks and use the extra read port to avoid the stolen read cycle that invalidates one bin, but this could be a future improvement.
--
-- Readout logic
-- -------------
--
-- The CMAC output is meant to be daisy-chained with other CMACs in order to stream the captured
-- accumulated products of all the units in the chain. Once the first unit of the chain has sent its data, the data
-- from the second CMAC is passed through the first one, and so on. This ensures that the routing needed to readout all the CMACs stays local.
--
-- Each CMAC has a `send` signal both on the upstream and downstram side to allow some degree of flow
-- control. On the downstream side, the `send` signal indicates a CMAC can send its data, or , when it is finished, it's neighbor's data.
-- The upstram `send` signal is enabled when the CMAC has finished sending its data to tells the neighbor that it can send its own data.
--
-- The `send` signal **does not** behave exactly as a AXI-S tREADY signal, which
-- *instantaneously* starts or stop data transfer. Implementing this behaviour in a daisy-chained (and
-- pipelined) data path involves more complex logic and data buffering to deal with data that
-- was sent based on delayed tready signal but can no longer be immediately accepted it when it
-- arrives at the sink.
--
-- Instead, the `send_in` signal is an instruction to start and stop sending data "as soon as
-- possible", meaning that  the data flow can start and stop some time after the signal is asserted.
-- This allows time for the `send_in` signal to propagate up to the targeted data source and for the
-- data to propagate back down through its pipeline stages. In other word, the `send` signal will
-- take effect only after the control and data pipeline latency.
--
-- Using such a *lazy* flow control scheme greatly simplifies the logic and storage requirements
-- (i.e flops) in each and every of the CMAC modules. However, an elastic buffer with sufficient
-- capacity is required at the end of the readout module to accomodate the time lag between the flow
-- control instruction and the actual effect of the flow. Since  we need to have a FIFO anyways to
-- cope with data width conversion and clock domain crossing, and that FIFO is needed only once
-- for every group of daisy-chained CMAC blocks, the resource usage is totally acceptable.
--
--
architecture impl of UCMAC44_ARRAY is


	-- Attributes definition
	attribute RPM_GRID: string;
	attribute RLOC: string;
	-- attribute HU_SET : string;
	attribute U_SET: string;
	attribute RLOC_ORIGIN: string;
	attribute KEEP_HIERARCHY: string;
	-- attribute HU_SET : string;


	-- Constants
	constant BYTES_PER_PRODUCT: integer := 5; -- (18+18) bits + 4 extra bits = 40 bits = 5 bytes
	--  constant NBINS_TO_READOUT: integer := 2048; -- maximum number of bins that will be read and sent
	constant LOG2_NCORR: integer := integer_log2(NCORR);
	-- RAM address layout: [bank bit][product index]. The bank bit must sit just above the
	-- product index so that both banks fit in the RAM depth: with the bank bit fixed at bit 11,
	-- any NPROD < 2048 (e.g. 512 on ICE corr16) maps bank 1 outside the 2*NPROD-word memory,
	-- the RAM ignores the upper address bits, and both banks alias onto the same words.
	constant PROD_ADDR_WIDTH: integer := width(NPROD); -- 11 for NPROD=2048, 9 for NPROD=512
	constant RAM_ADDR_WIDTH: integer := PROD_ADDR_WIDTH + 1; -- product index + bank bit

	attribute keep_hierarchy of impl: architecture is "YES";
	-- attribute RLOC_ORIGIN of Behavioral: architecture is ORIGIN;
	signal rst_reg: std_logic;


	signal ram_dout: slv_array(0 to NCMAC - 1)(35 downto 0);
	signal ram_din: slv_array(0 to NCMAC - 1)(35 downto 0);
	signal ram_wr_addr: std_logic_vector(RAM_ADDR_WIDTH - 1 downto 0); -- bank & product index (12 bits = 4096 words for NPROD=2048)
	signal ram_rd_addr: std_logic_vector(RAM_ADDR_WIDTH - 1 downto 0); -- bank & product index
	signal ram_wr_en: std_logic := '0';
	signal ram_rd_en: std_logic := '1';

	signal tvalid1, tvalid2, tvalid3, tvalid4: std_logic := '0';
	signal tlast1, tlast2, tlast3, tlast4: std_logic;
	signal ro_word1, ro_word2: std_logic := '1'; -- first word of frame
	signal last_frame1, last_frame2, last_frame3, last_frame4: std_logic;
	signal first_frame1, first_frame2: std_logic := '1'; -- init needed


begin

	ctrl_blk : block

		signal frame: unsigned(15 downto 0); -- 11-bits wide: 2048 integ, 12-bits wide: 4096 frame integration
		signal rd_word_ctr1: unsigned(10 downto 0); -- 2048 words/frame.
		signal ro_word_ctr1: unsigned(10 downto 0); -- readout word counter. 2048 words/frame.
		signal wr_word_ctr5: unsigned(10 downto 0); -- readout bank read address
		signal acc_bank1, acc_bank5: std_logic; -- Accumulator bank
		signal ro_word_ctr_max: unsigned(10 downto 0); -- Number of words to readout

		signal bytes: slv8_array(0 to FRAME_HEADER_BYTE_LENGTH + NCMAC * BYTES_PER_PRODUCT - 1); -- readout buffer: header + products
		signal byte_ctr: integer range 0 to bytes'LENGTH;
		signal ro_active: std_logic := '0'; -- bank readout busy
		signal ro_shift: std_logic := '0'; -- data available for shift out
		signal ro_last: std_logic := '0'; -- is the last shift out of the integ period
		signal ro_bin_set: std_logic_vector(3 downto 0); -- bin set to be placed in the headers
		signal dc_busy: std_logic := '0'; -- daisy chain readout busy
		signal timestamp, integ_timestamp, readout_timestamp: unsigned(47 downto 0);
	begin

		--    ram_rd_addr <= (not acc_bank1) & std_logic_vector(ro_word_ctr1) when rd_word_ctr1=READOUT_BIN else
		--                   acc_bank1 & std_logic_vector(rd_word_ctr1);
		assert NPROD <= 2 ** rd_word_ctr1'LENGTH report "UCMAC44_ARRAY: NPROD exceeds the word counter range" severity failure;
		ram_wr_addr <= acc_bank5 & std_logic_vector(wr_word_ctr5(PROD_ADDR_WIDTH - 1 downto 0));

		wr_proc: process(all)

			variable frame_header: frame_header_struct := (PROBE_ID => X"CF", others => (others => '0'));
			-- variable prod: integer range 0 to NCMAC; -- counts autocorr products (not NCMAC-1 because last increment?)
			variable prod_bytes: slv8_array(0 to BYTES_PER_PRODUCT - 1);
			variable next_timestamp: unsigned(47 downto 0);
			variable next_rd_word_ctr: unsigned(rd_word_ctr1'RANGE);
			variable next_acc_bank: std_logic;
			variable is_capture_word: boolean;

		begin
			if rising_edge(clk) then
				rst_reg <= rst;

				-------------
				-- CLOCK 1 - sign-corrected data is clocked into the DSP1 A & B registers, and we register sign and zero flags
				-------------


				-- Write state machine: count words and frames, and set the done signal
				--              src_readout_trig <= '0'; -- single clock pulse signal, overriden below
				if s_axis_xy_tvalid then
				    next_acc_bank := acc_bank1; -- get current accum bank
					next_rd_word_ctr := rd_word_ctr1 + 1;
					if s_axis_xy_tlast then
						ro_word_ctr_max <= rd_word_ctr1; -- capture the frame length so we can readout the same amount of words
						next_rd_word_ctr := (others => '0');
						frame <= frame + 1;
						next_timestamp := timestamp + 1;
						timestamp <= next_timestamp;
						if frame = unsigned(integ_period) then -- if last frame of the integration period
							frame <= (others => '0'); -- restart the readout from word 0
							overrun <= '1' when ro_active;
							ro_active <= '1'; -- start readout of the readout bank
							ro_bin_set <= bin_set; --  register the bin set on the last word of the last frame of the integ period
							readout_timestamp <= integ_timestamp;
							integ_timestamp <= next_timestamp; -- timestamp+1 should reuses the logic above
							s_axis_z_send <= '0'; -- tell the upstream cascaded correlators we stop accepting data
							next_acc_bank := not next_acc_bank; -- switch bank
						end if; -- last frame of integ_period
					end if; -- tlast
					-- set the next RAM address to read
					ram_rd_addr <= (not next_acc_bank) & std_logic_vector(ro_word_ctr1(PROD_ADDR_WIDTH - 1 downto 0)) when next_rd_word_ctr = READOUT_BIN else
	               next_acc_bank & std_logic_vector(next_rd_word_ctr(PROD_ADDR_WIDTH - 1 downto 0));
					acc_bank1 <= next_acc_bank;
					rd_word_ctr1 <= next_rd_word_ctr;
				end if; -- tvalid

				-- pipeline the control signals
				tvalid1 <= s_axis_xy_tvalid;
				tlast1 <= s_axis_xy_tlast;
				ro_word1 <= to_std_logic(rd_word_ctr1 = READOUT_BIN); -- active when we are reading the readout bin
				last_frame1 <= to_std_logic(frame = unsigned(integ_period)); -- last frame of accumulation
				first_frame1 <= to_std_logic(all_zeros(frame)); -- last frame of accumulation
				-------------
				-- CLOCK 2: The product is clocked in the M=XY register of DSP1, and we clock the correction in the C=Z register.
				-- We also present the FIFO output back into the C input of the DSP2.
				-------------

				-- pipeline the control signals
				tvalid2 <= tvalid1;
				tlast2 <= tlast1;
				ro_word2 <= ro_word1;
				last_frame2 <= last_frame1;
				first_frame2 <= first_frame1;

				-------------
				-- CLOCK 3: Pre-accumulation product (DSP1 sum XY+Z) was registered in DSP1.P
				--          RAM outputs registers the previous value for the same product, which is fed to DSP2.C.
				--          If this is the first word of the frame, RAM does not output the previous accumulated value but rather
				--          outputs at the current the readout address from the readout bank. We capture those in a byte array if we
				--          this array is free.
				-------------

				-- pipeline the control signals
				tvalid3 <= tvalid2;
				tlast3 <= tlast2;
				last_frame3 <= last_frame2;

				-- Clear tvalid. Is overriden below if a new byte is available.
				m_axis_z_tvalid <= '0';
				-- Clear send flag. Is overriden below when we are ready to forward data.
				s_axis_z_send <= '0'; -- m_axis_z_send;

				-- Send readout bytes from this correlator or from the down-cascaded correlator
				if ro_active then -- read data from this correlator
					if ro_shift then -- -- we have bytes to shift out
						s_axis_z_send <= '0';
						m_axis_z_tdata <= bytes(0);
						m_axis_z_tlast <= '0';
						m_axis_z_tvalid <= '0';
						if m_axis_z_send then -- we have a byte to shift out and we are allowed to send it
							m_axis_z_tvalid <= '1';
							if byte_ctr = 1 then -- tlast when last byte.
								m_axis_z_tlast <= '1';
								ro_shift <= '0'; -- stop shifting
								if ro_last then -- if last readout on integration period
									ro_active <= '0';
								end if; -- last word
							end if;
							-- Shift the byte vector. This affects a verly large number of registers, so control logic has a high fanout.
							-- Control logic: ro_word2, ro_active, ro_shift, m_axis_z_send, and autocorr_only (see below)
							bytes(0 to bytes'LENGTH - 2) <= bytes(1 to bytes'LENGTH - 1);
							byte_ctr <= byte_ctr - 1;
						end if; -- if m_axis_z_send='1'
					elsif ro_word2 then -- ro_shift=0 ,ro_active=1
						-- Readout is active, no shift is in progress, and are processing the 1st product word of the frame,
						-- meaning the RAM outputs data from the readout bank. .
						-- We therefore capture the products in the byte array, set the byte counter and enable ro_shift.

						-- Store the header in the bytes buffer
                        frame_header.STREAM_ID(15 downto 11) := to_slv(to_integer(unsigned(corr_id)) + CORR_NUMBER, 5);
                        frame_header.STREAM_ID(10 downto 0) := std_logic_vector(ro_word_ctr1);
						-- frame_header.STREAM_ID(LOG2_NCORR-1 downto 0) := to_slv(CORR_NUMBER, LOG2_NCORR);
                        frame_header.TIMESTAMP := std_logic_vector(readout_timestamp);
                        frame_header.SERIAL_FLAGS := ro_bin_set;
                        frame_header.FLAGS(0) := overrun;
                        frame_header.FLAGS(1) := autocorr_only;
						bytes(0 to FRAME_HEADER_BYTE_LENGTH - 1) <= struct_to_bytes(frame_header);

						-- Store the product bytes in the bytes buffer
						-- Capture the RAM outputs, slice them in 5-byte products,  and store them in the shift register
						-- This affects a large number of registers, implying large fanout controls
						for i in 0 to NCMAC - 1 loop
                            prod_bytes := to_slv8_array(reverse_bytes(std_logic_vector(resize(unsigned(ram_dout(i)), 8 * BYTES_PER_PRODUCT))));
							bytes(FRAME_HEADER_BYTE_LENGTH + BYTES_PER_PRODUCT * i to FRAME_HEADER_BYTE_LENGTH + BYTES_PER_PRODUCT * (i + 1) - 1) <= prod_bytes;
						end loop;

						-- Override the first product bytes after the frame header with the autocorrelation products if autocorr='1'
						if autocorr_only then
							for i in 0 to NCMAC / AUTOCORR_STRIDE - 2 loop -- assume that last one is not an autocorrelation (first N elements in N+1 high column are autocorrs)
                                prod_bytes := to_slv8_array(reverse_bytes(std_logic_vector(resize(unsigned(ram_dout(i * AUTOCORR_STRIDE)), 8 * BYTES_PER_PRODUCT))));
								bytes(FRAME_HEADER_BYTE_LENGTH + BYTES_PER_PRODUCT * i to FRAME_HEADER_BYTE_LENGTH + BYTES_PER_PRODUCT * (i + 1) - 1) <= prod_bytes;
							end loop;

						end if;

						-- set the byte counter to signify we now have data to send
						if autocorr_only then
							-- We send only the autocorrelations. We dont have the NCHAN parameter, but if we assume that
							-- we have NCMAC = (NCHAN+1)*AUTOCORR_STRIDE CMACs, we can deduct if with  NCHAN = NCMAC/AUTOCORR_STRIDE-1
							byte_ctr <= FRAME_HEADER_BYTE_LENGTH + (NCMAC / AUTOCORR_STRIDE - 1) * BYTES_PER_PRODUCT;
						else
							byte_ctr <= FRAME_HEADER_BYTE_LENGTH + NCMAC * BYTES_PER_PRODUCT;
						end if;
						ro_shift <= '1'; -- there is data to shift out
						ro_last <= '0'; -- is this the last readout? overriden below.
						-- Increment the readout word counter, or reset it if this is the last integration
						-- The readout word counter must be ready before we set the RAM read address for reading the first word of the next frame.
						-- Since we increment the counter 2 clocks after first word, and the next first word is almost one frame away,
						-- the counter is guaranteed to be ready
						ro_word_ctr1 <= ro_word_ctr1 + 1; -- next word to readout
						if ro_word_ctr1 = ro_word_ctr_max then -- last readout word
							-- Set the readout word counter(address) in preparation for the readout phase.
							ro_word_ctr1 <= (others => '0');
							ro_last <= '1';
						end if;
					end if; -- ro_shift, ro_word2


				else -- ro_active=0, sending cascade input data if any
					s_axis_z_send <= m_axis_z_send; -- pass on the send flag
					m_axis_z_tvalid <= s_axis_z_tvalid;
					m_axis_z_tdata <= s_axis_z_tdata;
					m_axis_z_tlast <= s_axis_z_tlast;
					if s_axis_z_tvalid then
						dc_busy <= '1';
						if s_axis_z_tlast then
							dc_busy <= '0';
							s_axis_z_send <= '0';
						end if;
					end if;
				end if; -- if ro_active


				-------------
				-- CLOCK 4: Register the accumulated product in DSP2.P and set the RAM wr_en signal if data is valid.
				-------------

				--= pipeline control signals
				tvalid4 <= tvalid3;
				tlast4 <= tlast3; -- last word
				last_frame4 <= last_frame3; -- last frame
				ram_wr_en <= tvalid3; -- write the data

				-------------
				-- CLOCK 5:  Increment write address once data has been written. Switch write bank if last frame is completed.
				-------------

				-- Increment ram write address post-write
				if tvalid4 then
					wr_word_ctr5 <= wr_word_ctr5 + 1;
					if tlast4 then
						wr_word_ctr5 <= (others => '0');
					end if;
					if tlast4 and last_frame4 then
						acc_bank5 <= not acc_bank5;
					end if;
				end if;


				if overrun_reset then
					overrun <= '0';
				end if;

				-- Synchronous resets (overrides signals above)
				if rst_reg then
					rd_word_ctr1 <= (others => '0');
					ro_word_ctr1 <= (others => '0'); -- prepare readout word counter for first readout.
					ram_rd_addr <= (others => '0'); -- always zero since acc_bank=0 and rd/ro_word_ctr=0 as well

					frame <= (others => '0');
					ro_active <= '0';
					overrun <= '0';

					timestamp <= (others => '0');
					integ_timestamp <= (others => '0');

					tvalid1 <= '0';
					tvalid2 <= '0';
					tvalid3 <= '0';
					tvalid4 <= '0';


					acc_bank1 <= '0';
					acc_bank5 <= '0';
					wr_word_ctr5 <= (others => '0');

				--          first_frame2 <= '1';
				--          last_frame4 <= '0';
				end if;

			end if; -- CLK
		end process wr_proc;

	end block ctrl_blk;


	-----------------------------
	-- DSPs
	-----------------------------
	-- Implement a complex multiplier and accumulator (CMAC) for each product. Each CMAC consist of a DSP pair.
	--
	-- The first DSP implements the multiplier with correction factors, which yields the ac, (ad-bc) and bd terms in its output registers.
	-- a and c are assumed to be unsigned. Corrections are applied by the adder to compensate for overlaps between the bd and (ad-bc) terms.
	-- results are presented on the P and PC (calcaded P)  ports.
	--
	-- The second DSP adds `ad` and `-bc` to form the real part the product, and  adds the previously accumulated Re and Im parts from the RAM.
	-- The output of DSP2 is saturated if the sum overflows, of if the value from the RAM was already overflown. The saturated product is then
	-- written back to the accumulator RAM.
	--
	dsp_gen: for i in 0 to NCMAC - 1 generate
		-- attribute U_SET of dsp1, dsp2 : label is "CORR" & integer'IMAGE(CORR_NUMBER);
		attribute rpm_grid of dsp1: label is "GRID";  -- coordinates in unit of RPM_X and RPM_Y. All element sin the same group will automatically use that grid.
		--    attribute U_SET of dsp1, dsp2 : label is RPM_NAME;
		-- attribute RLOC of dsp1: label is rpm_to_string(RPM_COORDS.DSP1);
		-- attribute RLOC of dsp2: label is rpm_to_string(RPM_COORDS.DSP2);

		constant XCONJ: std_logic := '0'; -- when '1', uses the complex conjugate of A
		constant YCONJ: std_logic := '1'; -- when '1', uses the complex conjugate of B

		signal dsp1_a: std_logic_vector(29 downto 0);
		signal dsp1_b: std_logic_vector(17 downto 0);
		signal dsp1_c: std_logic_vector(47 downto 0);
		-- signal dsp1_c_dly: std_logic_vector(47 downto 0);
		signal dsp1_p: std_logic_vector(47 downto 0);
		signal dsp1_pcout: std_logic_vector(47 downto 0);
		signal dsp1_alumode: std_logic_vector(3 downto 0);
		signal dsp1_cin: std_logic;


		signal dsp2_ab: std_logic_vector(47 downto 0);
		signal dsp2_c: std_logic_vector(47 downto 0);
		signal dsp2_p: std_logic_vector(47 downto 0);
		signal dsp2_cin: std_logic;
		signal dsp2_opmode: std_logic_vector(6 downto 0);
		signal dsp2_c_im_sign3: std_logic;
		signal dsp2_c_im_sign4: std_logic;
		signal dsp2_c_re_sign3: std_logic;
		signal dsp2_c_re_sign4: std_logic;
		signal im_sat3: std_logic;
		signal re_sat3: std_logic;
		signal im_sat4: std_logic;
		signal re_sat4: std_logic;
		signal dsp2_ab_im_sign4: std_logic;

		signal a: signed(3 downto 0); --
		signal b: signed(3 downto 0); --
		signal c: signed(3 downto 0); --
		signal d: signed(3 downto 0); --

		signal a1: unsigned(3 downto 0); -- ranges from 0 to 8
		signal b1: signed(4 downto 0); -- ranges from -8 to 8
		signal c1: unsigned(3 downto 0); -- ranges from 0 to 8
		signal d1: signed(4 downto 0); -- ranges from -8 to 8
		signal a1_zero: std_logic;
		signal b1_zero: std_logic;
		signal c1_zero: std_logic;
		signal d1_zero: std_logic;
		signal b1_neg: std_logic;
		signal d1_neg: std_logic;
		signal neg1: std_logic;

	begin

		-- We want to compute the product of (a+jb)*(c-jd)
		-- Extract a,b,c and d from the AXI4-S input word. These are all 4-bit signed values. This does not require any logic, just wiring.
		a <= signed(s_axis_xy_tdata(i)(15 downto 12)); -- A_re
		b <= signed(s_axis_xy_tdata(i)(11 downto 8)); -- A_im
		c <= signed(s_axis_xy_tdata(i)(7 downto 4)); -- B_re
		d <= signed(s_axis_xy_tdata(i)(3 downto 0)); -- B_im


		-- Make sure that a and c are always positive. If a was negative and is negated, then negate b so
		-- the entire complex value (a+jb) is negated. Likewise, if c is negated, negate d as well. We will
		-- invert the sign of the product if either one of a or b was negated (see the neg1 flag)
		--
		-- Since the second dsp inverts the real part of the result (we get (bd-ad) instead of (ad-bd)), we
		-- will compute instead -(*X)(*Y) = -(a-jb)(c-jd) = -((ac-bd)+j(-ad-bc)) = (bd-ac)+j(ad+bc), which,
		-- after the dsp2 stage, will yield (ac-bd)+j(ad+bc). We therefore take the complex conjugate of X
		-- and Y (i.e invert the sign of b and d), and we will invert the neg1 flag.
		--
		-- The signs of b and d can also be inverted individually to allow the user to use the complex
		-- conjugate of either X and Y.
		--
		-- a1 & c1 are 4 bit unsigned values since they store positive values from 0 to 8.
		-- b1 & d1 are 5 bit signed values since they store signed values from -8 to 8.
		-- The negation operations involves some combinatorial logic, which is not too costly here because we operate on 4-bit values.

		a1 <= unsigned(-a) when a(3) = '1' else unsigned(a); -- 4-bit unsigned (0-8)
		b1 <= -resize(b, 5) when (a(3) xor xconj xor s_axis_xy_swap(i)) = '0' else resize(b, 5); -- use conjugate if a was NOT inverted or if requested
		c1 <= unsigned(-c) when c(3) = '1' else unsigned(c); -- 4-bit unsigned (0-8)
		d1 <= -resize(d, 5) when (c(3) xor yconj xor s_axis_xy_swap(i)) = '0' else resize(d, 5); -- use conjugate if a was NOT inverted or if requested

		-- Pack a1, b1, c1 and d1 into the A and B port of the first DSP
		-- b1 and d1 are sign-entended to 9 bits, a1 and c1 are sign-extended to the left (all zeros since always positive)
		-- we have a combinatorial 4-bit negater between the module input and the DSP.

		dsp1_a <= "0000000000000" & std_logic_vector(a1) & "0000" & std_logic_vector(resize(b1, 9));
		dsp1_b <= "0" & std_logic_vector(c1) & "0000" & std_logic_vector(resize(d1, 9));

		-- The XY products contain:
		-- b1*d1:  products spans 17:0, bits 17:13 nulled by correction, bits 12:8 unused, final product in 7:0 ( 8 bits)
		-- (ad+bc): product spans 23:13, +1 added if negated, final product in 21:13 (9 bits)
		-- a1*c1: product spans 47:26, correction applied to set 47:45 to '1', final product in 44:26 (19 bits)
		--
		-- In summary:
		--     dsp1_p (48 bits) = [111][ac, 19 bits][xxxx][ad+bc, 9 bits][xxxxx][bd, 8 bits]
		--------------------------------------------


		-- Corrections for overlaps and to negate values. This imply some combinatorial logic between registered signals and the dsp1_c input.


		-- No need to correct the lower b1*d1
		dsp1_c(12 downto 0) <= (others => '0');

		-- Compute correction in C port to compensate for the b*d product overlap with ad+bc (all ones), and to add 1 to ad+bc if we negate
		dsp1_c(18 downto 13) <= "100000" when b1_neg = '1' and d1_neg = '1' and neg1 = '1' else -- # correct for bd/im overlap and add 1 to negate im. No carry proparates from negating bd because bd!=0
		                        "011111" when b1_neg = '1' and d1_neg = '1' and neg1 = '0' else -- # correct for bd/im overlap. We don't negate so no need to add 1.
		                        "000001" when b1_zero = '0' and d1_zero = '0' and neg1 = '1' else -- # There is no bd overlap, so no correction for this. But add 1 to im to negate if there is no carry from bd while negating.
		                        "000000"; -- no correction needed
		dsp1_c(25 downto 19) <= (others => '0');
		-- Add one to ac if we negate and if we don't have a carry from (ab+bc) that does that for us
		dsp1_c(26)           <= '1' when neg1 = '1' and ((a1_zero = '0' and d1_zero = '0') or (b1_zero = '0' and c1_zero = '0')) else -- # add 1 to ac if im is not zero
		              '0';
		dsp1_c(44 downto 27) <= (others => '0');

		-- Set upper msbs to '111' to prepare for the following accumulation
		dsp1_c(47 downto 45) <= "001" when neg1 = '0' else -- 000-001=111
		                        "111" when (a1_zero = '1' or c1_zero = '1') else -- neg=1 and ac=0, cancel the carry
		                        "000"; --- neg=1, we already have 111, do nothing

		-- dsp1_c(45) <= neg1;
		-- dsp1_c(47 downto 46) <= (others=>'0');


		-- Set ALUMODE and CIN so we negate (X+Y) if neg=1.
		dsp1_alumode <= "0011" when neg1 = '1' else  -- p = corr - (p + 0) = corr-p ,  P = Z-(X+Y+CIN)
		                "0001"; -- p = ~corr + (p + 1) = p-corr # P = ~Z+(X+Y+CIN)
		dsp1_cin     <= not neg1; -- adds one to ~bd so we don't have to include this 'one' to the dsp1_c correction

		-- We bypass the DSP2 multiplier, and we bring the 48-bit AB signal directly to the adder
		-- The AB=X signal of DSP2 is composed of slices of the P (fabric) output of DSP1.
		-- The Y signal of the DSP2 adder is the DSP2 C input (the accumulator output)
		-- The Z input of the adder of DSP2 is the cascaded link between DSP1 (PC) shifted right by 17 bits

		dsp2_ab(47 downto 30) <= std_logic_vector(resize(signed(dsp1_p(13 + 9 - 1 downto 13)), 18)); -- im=ac-bd, dsp1_p(21 downto 13) (9 bits wide), casted into 19 bits wide, p[21] copied 10 times,
		dsp2_ab(29 downto 28) <= "00"; -- guard bit, prevents the sum of re part from overflowing in the im part
		dsp2_ab(27 downto 9)  <= std_logic_vector(resize(signed(dsp1_p(7 downto 0)), 19)); -- bd
		dsp2_ab(8 downto 0)   <= dsp1_p(25 downto 17);

		-- AB = ((im & 0x7FFFF) << 29) | (( bin_to_int(p, 8) & 0x7FFFF)<<9) |(bit(p, 25) << 8)  # im, 9 bits, sign extended to 19 bits, in AB[47:29]. bd, 8 bits, is sign extended to 19 bits and is in AB[27:9].
		-- dsp2_c(47 downto 29) <= (others=>'0'); -- im
		dsp2_c(47 downto 30) <= ram_dout(i)(17 downto 0); -- im
		dsp2_c(29 downto 28) <= "00"; -- guard bits
		dsp2_c(27)           <= ram_dout(i)(35);
		dsp2_c(26 downto 9)  <= ram_dout(i)(35 downto 18); -- im
		dsp2_c(8 downto 0)   <= (others => '0');
		dsp2_cin             <= '1';
		dsp2_opmode          <= "1010011" when first_frame2 = '1' or no_accum = '1' else -- X=A:B, Y=0, Z=PCIN>>17
		               "1011111"; -- X=A:B, Y=C, Z=PCIN>>17


		-- Instantiate the two DSPs
		dsp1: DSP48E1
			generic map (
				-- Feature Control Attributes: Data Path Selection
				A_INPUT   => "DIRECT", -- Selects A input source, "DIRECT" (A port) or "CASCADE" (ACIN port)
				B_INPUT   => "DIRECT", -- Selects B input source, "DIRECT" (B port) or "CASCADE" (BCIN port)
				USE_DPORT => FALSE, -- Select D port usage (TRUE or FALSE)
				USE_MULT  => "MULTIPLY", -- Select multiplier usage ("MULTIPLY", "DYNAMIC", or "NONE")
				USE_SIMD  => "ONE48", -- SIMD selection ("ONE48", "TWO24", "FOUR12")
				-- Pattern Detector Attributes: Pattern Detection Configuration
				AUTORESET_PATDET   => "NO_RESET", -- "NO_RESET", "RESET_MATCH", "RESET_NOT_MATCH"
				MASK               => X"3fffffffffff", -- 48-bit mask value for pattern detect (1=ignore)
				PATTERN            => X"000000000000", -- 48-bit pattern match for pattern detect
				SEL_MASK           => "MASK", -- "C", "MASK", "ROUNDING_MODE1", "ROUNDING_MODE2"
				SEL_PATTERN        => "PATTERN", -- Select pattern value ("PATTERN" or "C")
				USE_PATTERN_DETECT => "NO_PATDET", -- Enable pattern detect ("PATDET" or "NO_PATDET")
				-- Register Control Attributes: Pipeline Register Configuration
				ACASCREG      => 1, -- Number of pipeline stages between A/ACIN and ACOUT (0, 1 or 2)
				ADREG         => 1, -- Number of pipeline stages for pre-adder (0 or 1)
				ALUMODEREG    => 1, -- Number of pipeline stages for ALUMODE (0 or 1)
				AREG          => 1, -- Number of pipeline stages for A (0, 1 or 2)
				BCASCREG      => 1, -- Number of pipeline stages between B/BCIN and BCOUT (0, 1 or 2)
				BREG          => 1, -- Number of pipeline stages for B (0, 1 or 2)
				CARRYINREG    => 1, -- Number of pipeline stages for CARRYIN (0 or 1)
				CARRYINSELREG => 1, -- Number of pipeline stages for CARRYINSEL (0 or 1)
				CREG          => 1, -- Number of pipeline stages for C (0 or 1)
				DREG          => 1, -- Number of pipeline stages for D (0 or 1)
				INMODEREG     => 1, -- Number of pipeline stages for INMODE (0 or 1)
				MREG          => 1, -- Number of multiplier pipeline stages (0 or 1)
				OPMODEREG     => 1, -- Number of pipeline stages for OPMODE (0 or 1)
				PREG          => 1 -- Number of pipeline stages for P (0 or 1)
			)
			port map (
				-- Cascade: 30-bit (each) output: Cascade Ports
				acout        => open, -- 30-bit output: A port cascade output
				bcout        => open, -- 18-bit output: B port cascade output
				carrycascout => open, -- 1-bit output: Cascade carry output
				multsignout  => open, -- 1-bit output: Multiplier sign cascade output
				pcout        => dsp1_pcout, -- 48-bit output: Cascade output
				p            => dsp1_p, -- 48-bit output: Primary data output
				-- Control: 1-bit (each) output: Control Inputs/Status Bits
				overflow       => open, -- 1-bit output: Overflow in add/acc output
				patternbdetect => open, -- 1-bit output: Pattern bar detect output
				patterndetect  => open, -- 1-bit output: Pattern detect output
				underflow      => open, -- 1-bit output: Underflow in add/acc output
				-- Data: 4-bit (each) output: Data Ports
				carryout => open, -- 4-bit output: Carry output
				-- Cascade: 30-bit (each) input: Cascade Ports
				acin        => (others => '0'), -- 30-bit input: A cascade data input
				bcin        => (others => '0'), -- 18-bit input: B cascade input
				carrycascin => '0', -- 1-bit input: Cascade carry input
				multsignin  => '0', -- 1-bit input: Multiplier sign input
				pcin        => (others => '0'), -- 48-bit input: P cascade input
				-- Control: 4-bit (each) input: Control Inputs/Status Bits
				alumode    => dsp1_alumode, -- 4-bit input: ALU control input
				carryinsel => "000", -- 3-bit input: Carry select input
				clk        => clk, -- 1-bit input: Clock input
				inmode     => "00000", -- 5-bit input: INMODE control input
				opmode     => "0110101", -- 7-bit input: Operation mode input, X/Y=M, P=C
				-- Data: 30-bit (each) input: Data Ports
				a       => dsp1_a, -- 30-bit input: A data input
				b       => dsp1_b, -- 18-bit input: B data input
				c       => dsp1_c, -- 48-bit input: C data input
				carryin => dsp1_cin, -- 1-bit input: Carry input signal
				d       => (others => '0'), -- 25-bit input: D data input
				-- Reset/Clock Enable: 1-bit (each) input: Reset/Clock Enable Inputs
				cea1          => '1', -- 1-bit input: Clock enable input for 1st stage AREG
				cea2          => '1', -- 1-bit input: Clock enable input for 2nd stage AREG
				cead          => '0', -- 1-bit input: Clock enable input for ADREG
				cealumode     => '1', -- 1-bit input: Clock enable input for ALUMODE
				ceb1          => '1', -- 1-bit input: Clock enable input for 1st stage BREG
				ceb2          => '1', -- 1-bit input: Clock enable input for 2nd stage BREG
				cec           => '1', -- 1-bit input: Clock enable input for CREG
				cecarryin     => '1', -- 1-bit input: Clock enable input for CARRYINREG
				cectrl        => '1', -- 1-bit input: Clock enable input for OPMODEREG and CARRYINSELREG
				ced           => '0', -- 1-bit input: Clock enable input for DREG
				ceinmode      => '1', -- 1-bit input: Clock enable input for INMODEREG
				cem           => '1', -- 1-bit input: Clock enable input for MREG
				cep           => '1', -- 1-bit input: Clock enable input for PREG
				rsta          => '0', -- 1-bit input: Reset input for AREG
				rstallcarryin => '0', -- 1-bit input: Reset input for CARRYINREG
				rstalumode    => '0', -- 1-bit input: Reset input for ALUMODEREG
				rstb          => '0', -- 1-bit input: Reset input for BREG
				rstc          => '0', -- 1-bit input: Reset input for CREG
				rstctrl       => '0', -- 1-bit input: Reset input for OPMODEREG and CARRYINSELREG
				rstd          => '0', -- 1-bit input: Reset input for DREG and ADREG
				rstinmode     => '0', -- 1-bit input: Reset input for INMODEREG
				rstm          => '0', -- 1-bit input: Reset input for MREG
				rstp          => '0' -- 1-bit input: Reset input for PREG
			);

		-- Second DSP: sums the ad and bd terms, and adds the accumulator output to the (ac+bd) and (ad-bc)
		-- terms, with guard bits to allow for overflow detection.
		dsp2: DSP48E1
			generic map (
				-- Feature Control Attributes: Data Path Selection
				A_INPUT   => "DIRECT", -- Selects A input source, "DIRECT" (A port) or "CASCADE" (ACIN port)
				B_INPUT   => "DIRECT", -- Selects B input source, "DIRECT" (B port) or "CASCADE" (BCIN port)
				USE_DPORT => FALSE, -- Select D port usage (TRUE or FALSE)
				USE_MULT  => "MULTIPLY", -- Select multiplier usage ("MULTIPLY", "DYNAMIC", or "NONE")
				USE_SIMD  => "ONE48", -- SIMD selection ("ONE48", "TWO24", "FOUR12")
				-- Pattern Detector Attributes: Pattern Detection Configuration
				AUTORESET_PATDET   => "NO_RESET", -- "NO_RESET", "RESET_MATCH", "RESET_NOT_MATCH"
				MASK               => X"3fffffffffff", -- 48-bit mask value for pattern detect (1=ignore)
				PATTERN            => X"000000000000", -- 48-bit pattern match for pattern detect
				SEL_MASK           => "MASK", -- "C", "MASK", "ROUNDING_MODE1", "ROUNDING_MODE2"
				SEL_PATTERN        => "PATTERN", -- Select pattern value ("PATTERN" or "C")
				USE_PATTERN_DETECT => "NO_PATDET", -- Enable pattern detect ("PATDET" or "NO_PATDET")
				-- Register Control Attributes: Pipeline Register Configuration
				ACASCREG      => 0, -- Number of pipeline stages between A/ACIN and ACOUT (0, 1 or 2)
				ADREG         => 1, -- Number of pipeline stages for pre-adder (0 or 1)
				ALUMODEREG    => 1, -- Number of pipeline stages for ALUMODE (0 or 1)
				AREG          => 0, -- Number of pipeline stages for A (0, 1 or 2)
				BCASCREG      => 0, -- Number of pipeline stages between B/BCIN and BCOUT (0, 1 or 2)
				BREG          => 0, -- Number of pipeline stages for B (0, 1 or 2)
				CARRYINREG    => 1, -- Number of pipeline stages for CARRYIN (0 or 1)
				CARRYINSELREG => 1, -- Number of pipeline stages for CARRYINSEL (0 or 1)
				CREG          => 1, -- Number of pipeline stages for C (0 or 1)
				DREG          => 1, -- Number of pipeline stages for D (0 or 1)
				INMODEREG     => 1, -- Number of pipeline stages for INMODE (0 or 1)
				MREG          => 1, -- Number of multiplier pipeline stages (0 or 1)
				OPMODEREG     => 1, -- Number of pipeline stages for OPMODE (0 or 1)
				PREG          => 1 -- Number of pipeline stages for P (0 or 1)
			)
			port map (
				-- Cascade: 30-bit (each) output: Cascade Ports
				acout        => open, -- 30-bit output: A port cascade output
				bcout        => open, -- 18-bit output: B port cascade output
				carrycascout => open, -- 1-bit output: Cascade carry output
				multsignout  => open, -- 1-bit output: Multiplier sign cascade output
				pcout        => open, -- 48-bit output: Cascade output
				p            => dsp2_p, -- 48-bit output: Primary data output
				-- Control: 1-bit (each) output: Control Inputs/Status Bits
				overflow       => open, -- 1-bit output: Overflow in add/acc output
				patternbdetect => open, -- 1-bit output: Pattern bar detect output
				patterndetect  => open, -- 1-bit output: Pattern detect output
				underflow      => open, -- 1-bit output: Underflow in add/acc output
				-- Data: 4-bit (each) output: Data Ports
				carryout => open, -- 4-bit output: Carry output
				-- Cascade: 30-bit (each) input: Cascade Ports
				acin        => (others => '0'), -- 30-bit input: A cascade data input
				bcin        => (others => '0'), -- 18-bit input: B cascade input
				carrycascin => '0', -- 1-bit input: Cascade carry input
				multsignin  => '0', -- 1-bit input: Multiplier sign input
				pcin        => dsp1_pcout, -- 48-bit input: P cascade input
				-- Control: 4-bit (each) input: Control Inputs/Status Bits
				alumode    => "0001", -- 4-bit input: ALU control input:
				carryinsel => "000", -- 3-bit input: Carry select input
				clk        => clk, -- 1-bit input: Clock input
				inmode     => "00000", -- 5-bit input: INMODE control input
				opmode     => dsp2_opmode, -- 7-bit input: Operation mode input
				-- Data: 30-bit (each) input: Data Ports
				a       => dsp2_ab(47 downto 18), -- 30-bit input: A data input
				b       => dsp2_ab(17 downto 0), -- 18-bit input: B data input
				c       => dsp2_c, -- 48-bit input: C data input
				carryin => dsp2_cin, -- 1-bit input: Carry input signal
				d       => (others => '0'), -- 25-bit input: D data input
				-- Reset/Clock Enable: 1-bit (each) input: Reset/Clock Enable Inputs
				cea1          => '0', -- 1-bit input: Clock enable input for 1st stage AREG
				cea2          => '0', -- 1-bit input: Clock enable input for 2nd stage AREG
				cead          => '0', -- 1-bit input: Clock enable input for ADREG
				cealumode     => '1', -- 1-bit input: Clock enable input for ALUMODE
				ceb1          => '0', -- 1-bit input: Clock enable input for 1st stage BREG
				ceb2          => '0', -- 1-bit input: Clock enable input for 2nd stage BREG
				cec           => '1', -- 1-bit input: Clock enable input for CREG
				cecarryin     => '1', -- 1-bit input: Clock enable input for CARRYINREG
				cectrl        => '1', -- 1-bit input: Clock enable input for OPMODEREG and CARRYINSELREG
				ced           => '0', -- 1-bit input: Clock enable input for DREG
				ceinmode      => '1', -- 1-bit input: Clock enable input for INMODEREG
				cem           => '1', -- 1-bit input: Clock enable input for MREG
				cep           => '1', -- 1-bit input: Clock enable input for PREG
				rsta          => '0', -- 1-bit input: Reset input for AREG
				rstallcarryin => '0', -- 1-bit input: Reset input for CARRYINREG
				rstalumode    => '0', -- 1-bit input: Reset input for ALUMODEREG
				rstb          => '0', -- 1-bit input: Reset input for BREG
				rstc          => '0', -- 1-bit input: Reset input for CREG
				rstctrl       => '0', -- 1-bit input: Reset input for OPMODEREG and CARRYINSELREG
				rstd          => '0', -- 1-bit input: Reset input for DREG and ADREG
				rstinmode     => '0', -- 1-bit input: Reset input for INMODEREG
				rstm          => '0', -- 1-bit input: Reset input for MREG
				rstp          => '0' -- 1-bit input: Reset input for PREG
			);

		dsp_proc: process(all) begin
			if rising_edge(clk) then
				-------------
				-- CLOCK 1 - sign-corrected data is clocked into the DSP1 A & B registers, and we register sign and zero flags
				-------------

				-- We need to compensate for these sign inversions so the result have the correct sign
				-- z = (Sa*a*Sc*c - Sa*b*Sc*d) + j(Sa*a*Sc*d + Sa*b*Sc*c) = SaSc(ac-bd) + jSaSc(ad+bc) = SaSc[(ac-bd) +j(ad+bc)]
				-- if both a and c are positive (Sa=Sc=1), nothing is negated, and the result has the right sign
				-- if both a and c are negative (Sa=Sc=-1), all of a,b,c and c are therefore negated, so the result has the right sign. No need to invert the result.
				-- if either a or c is negative Sa=1 & Sc=-1 or Sa=-1 and Sc=1, then we need to invert the result.
				-- neg indicates whether this sign inversion is needed. The inversion will be done by the DSP ALU unit if needed.
				--
				-- Also, to compensate for the sign inversion of the real part of the result, we actually compute -(*X)(*Y).
				-- We therefore invert to negate signal the result.
				b1_neg <= b1(4);
				d1_neg <= d1(4);
				neg1 <= not (a(3) xor c(3));

				-- x = A | B
				-- y = C | D
				-- P = AC | AD+BC | BD
				a1_zero <= to_std_logic(a = 0);
				b1_zero <= to_std_logic(b = 0);
				c1_zero <= to_std_logic(c = 0);
				d1_zero <= to_std_logic(d = 0);


				-------------
				-- CLOCK 3: Register the  saturation flags based on the ram output while that output is registered in DSP2.C
				-- The flags will be used to force saturation of the sum output.
				-------------


				dsp2_c_re_sign3 <= ram_dout(i)(35); -- register the real part sign bit
				re_sat3 <= to_std_logic(first_frame2 = '0' and (
	                                                ram_dout(i)(35 downto 18) = "011111111111111111" or
	                                                ram_dout(i)(35 downto 18) = "100000000000000000"));

				dsp2_c_im_sign3 <= ram_dout(i)(17); -- register the imaginary part sign bit
				im_sat3 <= to_std_logic(first_frame2 = '0' and (
	                                                ram_dout(i)(17 downto 0) = "011111111111111111" or
	                                                ram_dout(i)(17 downto 0) = "100000000000000000"));

				-------------
				-- CLOCK 4: Register the post-accumulation result in DSP2.P
				-------------

				-- pipeline the sign bits
				dsp2_c_re_sign4 <= dsp2_c_re_sign3;
				dsp2_c_im_sign4 <= dsp2_c_im_sign3;
				-- pipeline the pre-accumulation saturation flags
				re_sat4 <= re_sat3;
				im_sat4 <= im_sat3;
				dsp2_ab_im_sign4 <= dsp2_ab(47); -- register the AB sign bit


			end if; -- clk
		end process dsp_proc;

		-----------------------------------------------
		-- Saturate accumulated sum before storing it into the RAM
		-- This implies combinatorial logic between the DSP P output and the FIFO/BRAM inputs
		-- Real part:
		ram_din(i)(35 downto 18) <= "011111111111111111" when (re_sat4 = '1' and dsp2_c_re_sign4 = '0') or (dsp2_p(26) = '1' and dsp2_p(27) = '0') else
			"100000000000000000" when (re_sat4 = '1' and dsp2_c_re_sign4 = '1') or (dsp2_p(26) = '0' and dsp2_p(27) = '1') else
			dsp2_p(26 downto 9);

		-- Imaginary part:
		ram_din(i)(17 downto 0) <= "011111111111111111" when (im_sat4 = '1' and dsp2_c_im_sign4 = '0') or (dsp2_c_im_sign4 = '0' and dsp2_ab_im_sign4 = '0' and dsp2_p(47) = '1') else
			"100000000000000000" when (im_sat4 = '1' and dsp2_c_im_sign4 = '1') or (dsp2_c_im_sign4 = '1' and dsp2_ab_im_sign4 = '1' and dsp2_p(47) = '0') else
			dsp2_p(47 downto 30);


	end generate dsp_gen;

	-----------------------------
	-- RAM blocks
	-----------------------------
	-- We have 1 block for each 2 CMUL since ultraRAM bus width is fixed at 72 bits, so we can
	-- store two (18+18) bit products for each RAM.

	ram_gen: for i in 0 to integer((NCMAC + 1) / 2) - 1 generate
		signal ram_din_word: std_logic_vector(71 downto 0);
		signal ram_dout_word: std_logic_vector(71 downto 0);

		constant MEM_TYPE: string := sel(i < URAM_MAX, "ultra", "block");
	begin
		-- combine the din from 2 CMAC in to the ram din
		ram_din_word <= ram_din(2 * i) & ram_din(2 * i + 1);
		-- Split ram dout into 2 dout for the CMAC
		ram_dout(2 * i)     <= ram_dout_word(71 downto 36);
		ram_dout(2 * i + 1) <= ram_dout_word(35 downto 0);

		-- Implement RAM for a pair of CMACs.
		--
		-- Depending on MEM_TYPE, we either implement the memory as an ULTRARAM block or a BRAM array that offers the same storage. We need 8 RAMB36 to implement the equivalent of a UltraRAM.
		--
		-- We use a READ latency of 2 (READ_LATENCY_B=2). The DSP pipeline is designed to accomodate that exact latency.
		--
		-- When using Ultraram,
		--   we have to use ``write_mode=write_first``, otherwise we get the error::
		--
		--     [Synth 8-6058] Synth Error: [XPM_MEMORY 40-9] READ_LATENCY_B (2) specifies fewer than 3 stages, but simple dual port RAM configurations targeting UltraRAM and using write-first mode for port B must use a read latency of at least 3 for port B.   ["/tools/Xilinx/Vivado/2022.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv":588]
		--
		--   It works ok with ``write_mode=read_first``.
		--
		-- When using BRAM, the placement of the 8 BRAM cascade is critical with such a low latency.
		-- The BRAM can be placed in a single column or two adjacent columns, and in the later case,
		-- the 2 groups of 4 BRAM can be swapped, but all the BRAMs must be in the same clock
		-- region, otherwise we have a hold timing error. The placer does not always get it right,
		-- so it might need help by adding PBLOCKs for each correlator core.
		--
		ram0: xpm_memory_sdpram
			generic map (
				MEMORY_PRIMITIVE => MEM_TYPE,      -- force the use of UltraRAM ("ultra") or Block RAM ("block")
				-- write bus A
				ADDR_WIDTH_A       => RAM_ADDR_WIDTH,   -- bank & product index; 12 bits (4k words, one URAM) for NPROD=2048
				WRITE_DATA_WIDTH_A => 72,        -- 2 x (18+18) bits wide write bus
				BYTE_WRITE_WIDTH_A => 72,          -- We use 8-bit-wide-byte-enabled write, i.e. we have 8 byte enable bits
				-- Read bus B
				ADDR_WIDTH_B      => RAM_ADDR_WIDTH,   -- same
				READ_DATA_WIDTH_B => 72,         -- 2 x (18+18) bits wide read bus
				MEMORY_SIZE       => 72 * 2 ** RAM_ADDR_WIDTH, -- two banks; 72-bit word * 4096 words = 1 x URAM288 or 8 x RAMB36 (72 x 512 each) for NPROD=2048
				READ_LATENCY_B    => 2,     -- Needs to be >= of cascade height to allow registering. Synthesis ask for more than 4 to have full pipelining (4 is partial).
				SIM_ASSERT_CHK    => 1,             -- DECIMAL; 0=disable simulation messages, 1=enable simulation messages
				-- USE_EMBEDDED_CONSTRAINT => 0,    -- DECIMAL
				WRITE_MODE_B  => "read_first",     -- URAM is either read_first or write_first. Need read_first to allow a latency of 2.
				WRITE_PROTECT => 1               -- DECIMAL
			)
			port map (
				-- Write port
				dina  => ram_din_word,
				addra => ram_wr_addr,
				ena   => ram_wr_en,
				wea   => "1",

				-- read port
				doutb => ram_dout_word,
				addrb => ram_rd_addr,
				enb   => ram_rd_en,

				-- clock and reset
				clka => clk,
				rstb => rst_reg,

				-- unused signals
				sleep          => '0',
				injectsbiterra => '0',
				injectdbiterra => '0',
				regceb         => '1',
				clkb           => '0'
			);

	end generate ram_gen;


end architecture impl;

