----------------------------------------------------------------------------------
-- Company: Mc Gill University
-- Engineer: J.-F. Cliche
--
-- Create Date:    2011-08-24
-- Design Name:    chFPGA
-- Module Name:    system - impl
-- Project Name:
-- Target Devices: Virtex 6, 7 series, Ultrascale+
-- Tool versions: ISE 13.1, 14.2 ... Vivado 2022.2


library IEEE;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use ieee.std_logic_misc.ALL; -- for or_reduce()


library UNISIM;
use UNISIM.VComponents.ALL;

library xpm;
use xpm.vcomponents.ALL;

use work.chFPGA_package.ALL;

-- The SYSTEM module provides general support functions such as GPIOs, SPI and I2C interfaces,
-- clock generation, system monitoring, and reference clock management. It acts as a container
-- for all system-level infrastructure modules that are not part of the main signal processing
-- pipeline.
--
-- The SYSTEM module consists of the following sub-modules:
--
-- - `GPIO`: General purpose I/O, buck synchronization, IRIG-B decoder/generator/trigger, IRIG-B tagging of Reference clock counter and Frame counters
-- - `sysmon`: FPGA system monitor (temperature, voltage)
-- - `FREQ_CTR`: Frequency counter for clock monitoring
-- - `SPI`: SPI master interface
-- - `REFCLK`: Reference clock and synchronization management
-- - `I2C`: I2C master interface
-- - `BLINKER`: Heartbeat LED blinker
--
entity system is
	generic (
		PLATFORM_TYPE: platform_type_enum; -- identifies the type of platform on which the firmware is running
		COOKIE: integer := 16#42#;
		PROTOCOL_VERSION: integer; -- Protocol version used to determins compatibility with the python support software

		-- ADC info

		NUMBER_OF_ADCS: integer; -- Number of adcs that are implemented
		CHAN_CLK_SOURCE_LANE: integer; -- ADC channel from which the channelizers clocks are derived
		ADC_SAMPLES_PER_FRAME: integer;
		ADC_SAMPLES_PER_WORD: integer;
		ADC_BITS_PER_SAMPLE: integer;
		NUMBER_OF_ADC_BOARDS: integer := 1;
		-- Channelizer info

		NUMBER_OF_CHANNELIZERS: integer; -- Number of channelizers that are implemented
		NUMBER_OF_CHANNELIZERS_WITH_FFT: integer; 
		FFT_TYPE: fft_type_enum;

		-- Corner-turn Engine info
		CT_TYPE: ct_type_enum;
		CT_LEVEL: integer;
		NUMBER_OF_CT_INPUTS: integer;
		NUMBER_OF_CT_CB1_OUTPUTS: integer;
        NUMBER_OF_CT_REFCLKS: integer;
        -- Real-time data link info

		NUMBER_OF_GPU_LINKS: integer;
        NUMBER_OF_GPU_REFCLKS: integer;

		-- Correlator info

		NUMBER_OF_CORRELATORS: integer; -- Number of correlator blocks (CH_DIST+CORR+ACC) that are implemented if IMPLEMENT_CORR=TRUE
		NUMBER_OF_CHANNELIZERS_TO_CORRELATE: integer; -- Number of channels to be correlated for each frequency channel.


		-- Buck regulator SYNC control

		NUMBER_OF_BUCK_SYNC_LINES: integer := 16;
		BUCK_SYNC_ENABLE: boolean          := True; -- default state of the buck sync enable at startup
		BUCK_CLK_DIVIDE_FACTOR: integer    := 12; -- Buck frequency is 200MHz/BUCK_CLK_DIVIDE_FACTOR/16


        -- SYSTEM info

        NUMBER_OF_SPI_PORTS: integer;
        NUMBER_OF_I2C_PORTS: integer;

		MAC_ADDRESS_OUI_CODE: std_logic_vector(23 downto 0) := X"000A35"; -- Xilinx OUI code used to identify the first 3 bytes of the MAC address
		NUMBER_OF_USER_SMA_SIGNALS: integer                 := 8;
		IMPLEMENT_LCD: BOOLEAN                              := FALSE;
		IMPLEMENT_SWITCHER_SYNC: BOOLEAN                    := TRUE;
		IMPLEMENT_FAN: BOOLEAN                              := TRUE;
		IMPLEMENT_ARM_SPI: BOOLEAN                          := TRUE;
        BLINKER_PRESENT: BOOLEAN := TRUE;
		SIM: boolean                                        := FALSE;

		-- derived parameters

	   NUMBER_OF_ADCS_OR_CHANNELIZERS: integer := max(NUMBER_OF_ADCS, NUMBER_OF_CHANNELIZERS)

	);
	port (
		-- Control interface
		s_axis_bsb_tdata: in std_logic_vector(7 downto 0);
		s_axis_bsb_tvalid: in std_logic;
		s_axis_bsb_tlast: in std_logic;
		s_axis_bsb_tready: out std_logic;
		m_axis_bsb_tdata: out std_logic_vector(7 downto 0);
		m_axis_bsb_tvalid: out std_logic;
		m_axis_bsb_tlast: out std_logic;
		m_axis_bsb_tready: in std_logic;
		bsb_clk: in std_logic;
		bsb_rst: in std_logic;

		-- IP Port setting

		host_frame_read_rate: out std_logic_vector(4 downto 0);
		local_mac_addr: out std_logic_vector(47 downto 0);
		local_ip_addr: out std_logic_vector(31 downto 0);
		local_ip_port: out std_logic_vector(15 downto 0);
		remote_mac_addr: out std_logic_vector(47 downto 0);
		remote_ip_addr: out std_logic_vector(31 downto 0);
		remote_ip_port0: out std_logic_vector(15 downto 0); -- normally set to zero to reply to the same port as the last command
		remote_ip_port1: out std_logic_vector(15 downto 0);

		-- Communication link monitoring

		udp_tx_frame: in std_logic;
		udp_rx_frame: in std_logic;
		udp_tx_overflow: in std_logic;
		udp_rx_overflow: in std_logic;
		sfp_status_vector: in std_logic_vector(15 downto 0);
		sfp_config_vector: out std_logic_vector(31 downto 0);
		cmd_packet_counter: in std_logic_vector(7 downto 0);
		rply_packet_counter: in std_logic_vector(7 downto 0);
		udp_stack_reset: out std_logic;
		ctrl_master_reset: out std_logic;


		-- ARM SPI interface

		arm_spi_sck: in std_logic;
		arm_spi_miso: out std_logic;
		arm_spi_mosi: in std_logic;
		arm_spi_cs_n: in std_logic;

		-- Various unused signals, defined for testing

		arm_irq_in: in std_logic;
		arm_irq_out: out std_logic;
		arm_irq_oe: out std_logic;

		flash_cs_in: in std_logic;
		flash_cs_out: out std_logic;
		flash_cs_oe: out std_logic;

		gpio_irq_in: in std_logic;
		gpio_irq_out: out std_logic;
		gpio_irq_oe: out std_logic;  -- Active-high: enables GPIO reset output driver.

		gpio_rst_in: in std_logic;
		gpio_rst_out: out std_logic;
		gpio_rst_oe: out std_logic;  -- Active-high: enables GPIO reset output driver.

		uart_rx_in: in std_logic;
		uart_rx_out: out std_logic;
		uart_rx_oe: out std_logic;

		uart_tx_in: in std_logic;
		uart_tx_out: out std_logic;
		uart_tx_oe: out std_logic;

		-- Backplane global interrupt line. Could be used to communicate between boards.

		bp_gpio_int_out: out std_logic;
		bp_gpio_int_in: in std_logic;
		bp_gpio_int_oe: out std_logic;

		-- Buck converters synchronization signal
		
		bp_buck_sync: inout std_logic;
		buck_sync: out std_logic_vector(0 to NUMBER_OF_BUCK_SYNC_LINES - 1);


		-- TIME & TRIG signals

		time_trig: in std_logic_vector(0 to 1);


		-- Event (Frame) counter

		event_ctr_clk: in std_logic;
		event_ctr_en: in std_logic;
		event_ctr_inc: in std_logic;
		event_ctr_reset: in std_logic;

		-- PWM signal

		pwm_clk: in std_logic;
		pwm_ctr_en: in std_logic; -- Active when the pwm counter is to be enabled.
		pwm_reset: in std_logic;

		-- External PLL control

		pll_sync: out std_logic;

		-- User output selection

		user_mux_in: in std_logic_vector(0 to NUMBER_OF_USER_SMA_SIGNALS - 1); -- User selectable signals (typically PWM, 1PPS, SYNC, ?)
		user_mux_out: out std_logic_vector(0 to 3); -- User selected signal
		user_mux_oe: out std_logic_vector(0 to 3);

		-- ADC control signals

		adc_rst: out std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1);
		refclk_m2c_p: in std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1) := (others => '0'); -- copy of the 10 MHz reference clock received by the FMC boards (through its SMA connector )and forwarded to the FPGA as a LVDS signal. May contain encoded SYNC information.
		refclk_m2c_n: in std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1)  := (others => '1');
		fmc_refclk: out std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1); -- Delayed and BUFG'ed version of refclk_m2c
		adc_sync_p: out std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1); -- SYNC signal to the ADC (or the recynchronization circuit that drives the ADC SYNC)
		adc_sync_n: out std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1);

		adc_pll_lock: in std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1); -- Lock signal for the ADC PLL on each mezzanine
		adc_cal_freeze: out std_logic_vector(0 to NUMBER_OF_ADCS - 1);
		adc_cal_frozen: in std_logic_vector(0 to NUMBER_OF_ADCS - 1)        := (others => '0');
		adc_cal_signal_detect: in std_logic_vector(0 to NUMBER_OF_ADCS - 1) := (others => '0');
		adc_clear_or: out std_logic_vector(0 to NUMBER_OF_ADCS - 1)         := (others => '0');
		adc_clear_ov: out std_logic_vector(0 to NUMBER_OF_ADCS - 1)         := (others => '0');
		adc_cm_ov: in std_logic_vector(0 to NUMBER_OF_ADCS - 1)             := (others => '0');
		adc_cm_uv: in std_logic_vector(0 to NUMBER_OF_ADCS - 1)             := (others => '0');
		adc_or: in std_logic_vector(0 to NUMBER_OF_ADCS - 1)                := (others => '0');
		adc_ot1: in std_logic_vector(0 to NUMBER_OF_ADCS - 1)               := (others => '0');
		adc_ot2: in std_logic_vector(0 to NUMBER_OF_ADCS - 1)               := (others => '0');
		adc_ov: in std_logic_vector(0 to NUMBER_OF_ADCS - 1)                := (others => '0');

		-- FAN control signals (for on-board fan found on some evaluation boards)

		fan_pwm: out std_logic; -- PWM control of the fan
		fan_tach: in std_logic; -- Tachymeter input from the fan (two pulses per revolution). A debouncer cleans this signal before measuring the fan frequency.

		-- OLED or LCD Display (on some evaluation boards)

		lcd_db: out  std_logic_vector(7 downto 4);
		lcd_e: out  std_logic;
		lcd_rs: out  std_logic;
		lcd_rw: out  std_logic;

		-- LEDs

		gpio_led: out  std_logic_vector(7 downto 0); -- Row of 8 leds on the Motherboard

		-- SPI Interface

		spi_rst_n: out std_logic; -- SPI Reset signal directly controlled by a register bitfield
		spi_sck: out std_logic; -- SPI clock output
		spi_miso: in std_logic_vector(0 to NUMBER_OF_SPI_PORTS - 1); -- Data input from each SPI device
		spi_mosi: out std_logic; -- Data output , common to all slave devices
		spi_cs_n: out std_logic_vector(0 to NUMBER_OF_SPI_PORTS - 1); -- Active low chip select signals. Only the bit specified in the SPI port register is active low during the transaction
		spi_addr: out std_logic_vector(2 downto 0);


		-- I2C Interface
		
		i2c_sck: inout std_logic_vector(0 to NUMBER_OF_I2C_PORTS - 1);
		i2c_sda: inout std_logic_vector(0 to NUMBER_OF_I2C_PORTS - 1);

		--  SYSMON Current and voltage monitors
		
		vaux_curr_n: in  std_logic;
		vaux_curr_p: in  std_logic; -- External current monitor on the 12V supply line
		vaux_volt_n: in  std_logic;
		vaux_volt_p: in  std_logic; -- External voltage monitor on the 12V supply line
		vp: in  std_logic;
		vn: in  std_logic;


		-- Clock monitoring signals
		
		adc_clk_div2: in std_logic_vector(0 to NUMBER_OF_ADCS_OR_CHANNELIZERS - 1);
		fmc_mgt_pll_refclk_div2: in std_logic_vector(0 to max(NUMBER_OF_ADC_BOARDS, 4) - 1);
		gpu_refclk_div2: in std_logic_vector(0 to NUMBER_OF_GPU_REFCLKS - 1);
		gpu_txclk_div2: in std_logic;
		bp_shuffle_refclk_div2: in std_logic_vector(0 to NUMBER_OF_CT_REFCLKS - 1);
		bp_shuffle_txclk_div2: in std_logic;
		ct_clk_div2: in std_logic;
		corr_clk_div2: in std_logic;
		raw_clk10_div2: in std_logic;
		clk10_div2: in std_logic;
		clk200_div2: in std_logic;
		ctrl_clk_div2: in std_logic;
		chan_clk_div2: in std_logic;
		sysmon_clk_div2: in std_logic;
		mgt_clk100_div2: in std_logic;
		mgt_clk200_div2: in std_logic;
		mgt_clk125_div2: in std_logic;
		pll_oscout_div2: in std_logic;
        sfp_refclk_div2: in std_logic;

		-- REFCLK signals

		refclk_adcdaq_reset: out std_logic; -- CHAN/CT/CORR Reset sequencer start signal
		clk10_out: out  std_logic; -- delayed REFCLK

		-- Clocks & Resets

		clk200: in std_logic; -- 200 MHz clock, used for many things
		clk200_reset: in std_logic; --

		clk10: in std_logic; -- 10 MHZ reference clock, in phase for every board in the system
		clk10_sel: out std_logic; -- 10 MHz reference source selection

		sysmon_clk: in std_logic; -- SYSMON & DNA clock (max 97 MHz)
        sysmon_reset: in std_logic;
		sysmon_clk_enable: out std_logic; -- from GPIO: enables the SYSMON clock buffer in the clock generator

		adcdaq_reset_async: out std_logic; -- Manual user ADCDAQ reset

   		chan_clk: in std_logic; -- Channelizer clock from channel 0
        chan_reset: in std_logic;
   		chan_clk_sel: out std_logic; -- channelizer PLL clock selection
		chan_clk_reset_async: out std_logic; -- Channelizer PLL reset
		chan_reset_async: out std_logic; -- Manual user chan reset

		corr_reset_async: out std_logic; -- Manual user corr reset

		ctrl_reset_pulse: out std_logic := '0'; -- User initiated BSB reset pulse

		user_reset: out std_logic -- Manual user general reset


	);
end entity system;

architecture impl of system is


	attribute TARGET_PBLOCK: string; -- custom attribute
	attribute DONT_TOUCH: string;
	--attribute IOB: string;

	-- SYSTEM sub-modules port numbers

	constant MODULE_GPIO_ADDR: integer      := 0;
	constant MODULE_SYSMON_ADDR: integer    := 1;
	constant MODULE_FREQ_CTR_ADDR: integer  := 2;
	constant MODULE_SPI_ADDR: integer       := 3;
	constant MODULE_REFCLK_ADDR: integer    := 4;
	constant MODULE_I2C_ADDR: integer       := 5;
	constant NUMBER_OF_SYS_MODULES: integer := 6;

	constant FPGA_SERIES: fpga_series_enum := PLATFORM_INFO(PLATFORM_TYPE).FPGA_SERIES;


	-- System ROUTER output interface buses
	signal sys_router_bsb_cmd_tdata: slv8_array(0 to NUMBER_OF_SYS_MODULES - 1);
	signal sys_router_bsb_cmd_tvalid: std_logic_vector(0 to NUMBER_OF_SYS_MODULES - 1);
	signal sys_router_bsb_cmd_tlast: std_logic_vector(0 to NUMBER_OF_SYS_MODULES - 1);
	signal sys_router_bsb_cmd_tready: std_logic_vector(0 to NUMBER_OF_SYS_MODULES - 1);
	signal sys_router_bsb_rply_tdata: slv8_array(0 to NUMBER_OF_SYS_MODULES - 1);
	signal sys_router_bsb_rply_tvalid: std_logic_vector(0 to NUMBER_OF_SYS_MODULES - 1);
	signal sys_router_bsb_rply_tlast: std_logic_vector(0 to NUMBER_OF_SYS_MODULES - 1);
	signal sys_router_bsb_rply_tready: std_logic_vector(0 to NUMBER_OF_SYS_MODULES - 1);

	-- GLobal REFCLK - GPIO signals
	signal irigb_before_target: std_logic;
	signal sync_out: std_logic;

	signal fan_tach_div2: std_logic; -- logic signal pulsing at half the fan rotation speed
	signal fmc_refclk_div2: std_logic_vector(0 to max(NUMBER_OF_ADC_BOARDS, 2) - 1); -- Need  minimum of two for freq ctr assignments

	signal blinker_reset: std_logic; -- from GPIO to BLINKER
	signal sysmon_user_reset: std_logic; -- from GPIO to SYSMON

    -- debug
	signal debug2: std_logic := '0';


begin

	-- SYSTEM Memory Map
	--
	-- |#   |  Addr           | Module                       | Description |
	-- |----|-----------------|------------------------------|-------------|
	-- | 0  | Base + 0x00000  | GPIO                         |             |
	-- | 1  | Base + 0x01000  | SYSMON                       |             |
	-- | 2  | Base + 0x02000  | FREQ_CTR                     |             |
	-- | 3  | Base + 0x03000  | SPI                          |             |
	-- | 4  | Base + 0x04000  | REFCLK                       |             |
	-- | 5  | Base + 0x05000  | I2C                          |             |
	-- | 6  | Base + 0x06000  | (unused)                     |             |
	-- | 7  | Base + 0x07000  | (unused)                     |             |

	sysrtr_blk: block
		attribute TARGET_PBLOCK of sys_router0: label is "SYSTEM"; -- assign system router to SYSTEM Pblock

		signal bsb_rst_reg1, bsb_rst_reg2: std_logic;
		attribute DONT_TOUCH of bsb_rst_reg1, bsb_rst_reg2: signal is "true";
	begin

		-- Pipeline reset signal
		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				bsb_rst_reg1 <= bsb_rst;
				bsb_rst_reg2 <= bsb_rst_reg1;
			end if;
		end process;

		---------------------------------------------------------------------
		-- System command interface router
		-- Routes one of the top-level command bus to the system modules (SPI, GPIO etc.)
		---------------------------------------------------------------------
		sys_router0: entity work.bsb_router
			generic map (
				NUMBER_OF_PORTS => NUMBER_OF_SYS_MODULES,
				ADDRESS_MASK => "---1111------------" -- '1': used to generate port index, '-' = don't care,
			)
			port map (
				-- Upstream BSB interface
				s_axis_bsb_tdata => s_axis_bsb_tdata,
				s_axis_bsb_tvalid => s_axis_bsb_tvalid,
				s_axis_bsb_tlast => s_axis_bsb_tlast,
				s_axis_bsb_tready => s_axis_bsb_tready,
				m_axis_bsb_tdata => m_axis_bsb_tdata,
				m_axis_bsb_tvalid => m_axis_bsb_tvalid,
				m_axis_bsb_tlast => m_axis_bsb_tlast,
				m_axis_bsb_tready => m_axis_bsb_tready,

				-- Downstream BSB interface
				m_axis_routed_bsb_tdata => sys_router_bsb_cmd_tdata,
				m_axis_routed_bsb_tvalid => sys_router_bsb_cmd_tvalid,
				m_axis_routed_bsb_tlast => sys_router_bsb_cmd_tlast,
				m_axis_routed_bsb_tready => sys_router_bsb_cmd_tready,
				s_axis_routed_bsb_tdata => sys_router_bsb_rply_tdata,
				s_axis_routed_bsb_tvalid => sys_router_bsb_rply_tvalid,
				s_axis_routed_bsb_tlast => sys_router_bsb_rply_tlast,
				s_axis_routed_bsb_tready => sys_router_bsb_rply_tready,

				cmd_overflow => open,

				clk => bsb_clk,
				rst => bsb_rst_reg2
			);
	end block sysrtr_blk;

	---------------------------------------------------------------------
	-- GPIO interface instantiation
	---------------------------------------------------------------------
	--  Controls the global hardware lines and system registers like the ADC RESET, LCD, Buck Regulators  etc.
	gpio_blk: block is
		signal clk200_reset_reg: std_logic;
		attribute DONT_TOUCH of clk200_reset_reg: signal is "true";

		--signal gpio_event_ctr_en: std_logic;
		--signal gpio_event_ctr_inc: std_logic;
		signal gpio_event_ctr_en_reg: std_logic;
		signal gpio_event_ctr_inc_reg: std_logic;
		signal gpio_event_ctr_reset_reg: std_logic;
		attribute DONT_TOUCH of gpio_event_ctr_reset_reg: signal is "true";


		signal time_trig_reg: std_logic_vector(0 to 1);

		signal irib_mux_in: std_logic_vector(0 to 7);
		signal pwm_ctr_en_reg1: std_logic;
		signal pwm_ctr_en_reg2: std_logic;
		constant NUMBER_OF_USER_SMA_SIGNALS: integer := 16;
		signal gpio_user_mux_signals: std_logic_vector(0 to NUMBER_OF_USER_SMA_SIGNALS - 1);

		signal pwm_out: std_logic;
		signal pps_out: std_logic;
		signal irigb_gen_out: std_logic;

		signal user_bit: std_logic_vector(1 downto 0);

		signal irigb_delay: std_logic_vector(4 downto 0);
		signal irigb_delay_reset: std_logic;

		signal bsb_rst_reg1, bsb_rst_reg2: std_logic;
		attribute DONT_TOUCH of bsb_rst_reg1, bsb_rst_reg2: signal is "true";
	begin

		-- Pipeline reset signal
		process(all) begin
			if rising_edge(bsb_clk) then
				bsb_rst_reg1 <= bsb_rst;
				bsb_rst_reg2 <= bsb_rst_reg1;
			end if; -- clk
		end process;

		-- Pipeline the clk200 reset
		process(all) begin
			if rising_edge(clk200) then
				clk200_reset_reg <= clk200_reset;
			end if; -- clk
		end process;

		-- Pipeline backplane time (IRIG-B) and trig signals
		process(all) begin
			if rising_edge(clk200) then
				time_trig_reg <= time_trig;
			end if; -- RST/CLK
		end process;



		 -- Sources for the IRIG-B signals
		 irib_mux_in <= (
		 	0 => time_trig_reg(1), -- backplane trig signal
		 	1 => time_trig_reg(0), -- backplane time signal
    	 	2 => irigb_gen_out, -- internal IRIG-B generator
		 	3 => bp_gpio_int_in, -- backplane interrupt line (connects to every board in a crate)
		 	4 => user_mux_in(0), -- sma_a
		 	5 => user_mux_in(1), -- led2_sma_b
		 	6 => user_mux_in(2), -- led1_bp_sma
		 	7 => user_mux_in(3)
		 	);

		gpio_user_mux_signals <= ( -- source of the USER--controlled SMA output
			0 => sync_out, -- Sync signal
			1 => pps_out, -- Pulse-Per_second signal derived from the IRIG-B input
			2 => pwm_out, -- Frame-aligned programmable pulse generator
			3 => not irigb_before_target,
			4 => time_trig_reg(1),
			5 => time_trig_reg(0),
			6 => clk10,
			7 => irigb_gen_out,
			8 => gpio_led(4), -- heartbeat LED
			9 => gpio_led(7), -- out of phase heartbeat LED
			10 => adc_clk_div2(4 * to_integer(unsigned(user_bit))), -- was debug1. Modified to debug ADC clock output instabilities
			11 => debug2,
			12 => user_bit(0),
			13 => user_bit(1),
			14 => '0', -- formerly fmc_refclk selected by user_bit - but this is an illegal null range when fmc_refclk'length is 0
			15 => '0'  -- output is disabled - use to read signals from the SMA on user_mux_in()
			);


		-- Pipeline event counter signals since they need to go across the FPGA from the ADCDAQ to GPIO areas
		process(all) begin
			if rising_edge(event_ctr_clk) then
				gpio_event_ctr_en_reg <= event_ctr_en; -- pipeline. we have a long way to go between ADCDAQ[0] and GPIO
				gpio_event_ctr_inc_reg <= event_ctr_inc; -- pipeline. we have a long way to go between ADCDAQ[0] and GPIO
				gpio_event_ctr_reset_reg <= event_ctr_reset;

			end if; -- RST/CLK
		end process;

		process(all) begin
			if rising_edge(pwm_clk) then
				pwm_ctr_en_reg1 <= pwm_ctr_en;
				pwm_ctr_en_reg2 <= pwm_ctr_en_reg1; -- pipeline. we have a long way to go between ADCDAQ[0] and GPIO
			end if; -- clk
		end process;


		gpio0: entity work.gpio
			generic map (
				PLATFORM_TYPE => PLATFORM_TYPE,
				PROTOCOL_VERSION => PROTOCOL_VERSION,

				-- ADC info
				NUMBER_OF_ADCS        => NUMBER_OF_ADCS,
				ADC_SAMPLES_PER_FRAME => ADC_SAMPLES_PER_FRAME,
				ADC_SAMPLES_PER_WORD  => ADC_SAMPLES_PER_WORD,
				ADC_BITS_PER_SAMPLE   => ADC_BITS_PER_SAMPLE,
				NUMBER_OF_ADC_BOARDS  => NUMBER_OF_ADC_BOARDS,

				-- F-Engine/Channelizer info
				CHANNELIZERS_CLOCK_SOURCE       => CHAN_CLK_SOURCE_LANE,
				NUMBER_OF_CHANNELIZERS          => NUMBER_OF_CHANNELIZERS,
				NUMBER_OF_CHANNELIZERS_WITH_FFT => NUMBER_OF_CHANNELIZERS_WITH_FFT,
				FFT_TYPE                        => FFT_TYPE,

				-- Corner-turn Engine Info
				CT_TYPE                     => CT_TYPE,
				CT_LEVEL                    => CT_LEVEL,
				NUMBER_OF_CT_INPUTS   => NUMBER_OF_CT_INPUTS,
				NUMBER_OF_CT_CB1_OUTPUTS => NUMBER_OF_CT_CB1_OUTPUTS,
				NUMBER_OF_GPU_LINKS         => NUMBER_OF_GPU_LINKS,

				-- X-Engine/Correlator info
				NUMBER_OF_CORRELATORS               => NUMBER_OF_CORRELATORS,
				NUMBER_OF_CHANNELIZERS_TO_CORRELATE => NUMBER_OF_CT_INPUTS,

				-- Peripherals
				NUMBER_OF_USER_SMA_SIGNALS => NUMBER_OF_USER_SMA_SIGNALS,
				IMPLEMENT_LCD              => IMPLEMENT_LCD,
				IMPLEMENT_SWITCHER_SYNC    => IMPLEMENT_SWITCHER_SYNC,
				IMPLEMENT_FAN              => IMPLEMENT_FAN,
				IMPLEMENT_ARM_SPI          => IMPLEMENT_ARM_SPI,
				BUCK_SYNC_ENABLE           => BUCK_SYNC_ENABLE,
				BUCK_CLK_DIVIDE_FACTOR     => BUCK_CLK_DIVIDE_FACTOR,
				SIM                        => SIM
			)
			port map (
				-- Control interface
				s_axis_bsb_tdata => sys_router_bsb_cmd_tdata(MODULE_GPIO_ADDR),
				s_axis_bsb_tvalid => sys_router_bsb_cmd_tvalid(MODULE_GPIO_ADDR),
				s_axis_bsb_tlast => sys_router_bsb_cmd_tlast(MODULE_GPIO_ADDR),
				s_axis_bsb_tready => sys_router_bsb_cmd_tready(MODULE_GPIO_ADDR),
				m_axis_bsb_tdata => sys_router_bsb_rply_tdata(MODULE_GPIO_ADDR),
				m_axis_bsb_tvalid => sys_router_bsb_rply_tvalid(MODULE_GPIO_ADDR),
				m_axis_bsb_tlast => sys_router_bsb_rply_tlast(MODULE_GPIO_ADDR),
				m_axis_bsb_tready => sys_router_bsb_rply_tready(MODULE_GPIO_ADDR),
				bsb_clk          => bsb_clk,
				bsb_rst          => bsb_rst_reg2,

				-- IP Port setting
				host_frame_read_rate => host_frame_read_rate,
				local_mac_addr       => local_mac_addr,
				local_base_ip_addr   => local_ip_addr,
				local_base_ip_port   => local_ip_port,
				remote_mac_addr1     => remote_mac_addr,
				remote_ip_addr1      => remote_ip_addr,
				remote_ip_port0      => remote_ip_port0,
				remote_ip_port1      => remote_ip_port1,

				udp_stack_reset   => udp_stack_reset,
				ctrl_master_reset => ctrl_master_reset,

				arm_spi_sck  => arm_spi_sck,
				arm_spi_miso => arm_spi_miso,
				arm_spi_mosi => arm_spi_mosi,
				arm_spi_cs_n => arm_spi_cs_n,

				arm_irq_in   => arm_irq_in,
				arm_irq_out  => arm_irq_out,
				arm_irq_oe   => arm_irq_oe,

				flash_cs_in  => flash_cs_in,
				flash_cs_out => flash_cs_out,
				flash_cs_oe  => flash_cs_oe,


				gpio_rst_in  => gpio_rst_in,
				gpio_rst_out => gpio_rst_out,
				gpio_rst_oe  => gpio_rst_oe,

				gpio_irq_in  => gpio_irq_in,
				gpio_irq_out => gpio_irq_out,
				gpio_irq_oe  => gpio_irq_oe,


				uart_rx_in   => uart_rx_in,
				uart_rx_out  => uart_rx_out,
				uart_rx_oe   => uart_rx_oe,

				uart_tx_in   => uart_tx_in,
				uart_tx_out  => uart_tx_out,
				uart_tx_oe   => uart_tx_oe,

				-- Backplane signals

				bp_buck_sync     => bp_buck_sync,

				bp_gpio_int_in => bp_gpio_int_in,
				bp_gpio_int_out => bp_gpio_int_out,
				bp_gpio_int_oe => bp_gpio_int_oe,

				-- IRIG-B decoder
				irigb_mux_in => irib_mux_in,
				irigb_before_target => irigb_before_target, -- out
				irigb_pps => pps_out, -- To user output mux
				irigb_out => irigb_gen_out,

				-- Event counter (counts and capture frame numbers with time)
				event_ctr_clk => event_ctr_clk,
				event_ctr_en => gpio_event_ctr_en_reg,
				event_ctr_inc => gpio_event_ctr_inc_reg,
				event_ctr_reset => gpio_event_ctr_reset_reg,


				-- PWM Generator (generates Frame-aligned PWM waveform)
				pwm_clk => pwm_clk,
				pwm_ctr_en => pwm_ctr_en_reg2,
				pwm_reset => pwm_reset, -- just a register version of chan(0) reset
				pwm_out => pwm_out,

				-- External pll

				pll_sync => pll_sync,

				-- User muxed outputs
				user_mux_in => gpio_user_mux_signals, -- input port
				user_mux_out => user_mux_out, -- output port
				user_mux_oe => user_mux_oe,  -- output port
				user_bit => user_bit, -- output to user mux signals

				-- Fan control
				FAN_PWM       => FAN_PWM, -- output port
				FAN_TACH      => FAN_TACH, -- input port
				FAN_TACH_DIV2 => fan_tach_div2, -- output to frequency counter

				-- Communication link monitoring with UDP/Ethernet packetizer and BSB bus arbiter
				udp_tx_frame    => udp_tx_frame, -- input from port
				udp_rx_frame    => udp_rx_frame, -- input from port
				udp_tx_overflow => udp_tx_overflow, -- input from port
				udp_rx_overflow => udp_rx_overflow, -- inpot from port
				sfp_status_vector => sfp_status_vector, -- input from port
				sfp_config_vector => sfp_config_vector, -- output to port
				cmd_packet_counter => cmd_packet_counter,
				rply_packet_counter => rply_packet_counter,

				-- Mezzanine ADC & PLL Interface
				ADC_RST => ADC_RST,
				adc_pll_lock => adc_pll_lock,
				adc_cal_frozen => adc_cal_frozen,
				adc_cal_freeze => adc_cal_freeze,
				adc_cal_signal_detect => adc_cal_signal_detect,
				adc_clear_or => adc_clear_or,
				adc_clear_ov => adc_clear_ov,
				adc_cm_ov => adc_cm_ov,
				adc_cm_uv => adc_cm_uv,
				adc_or => adc_or,
				adc_ot1 => adc_ot1,
				adc_ot2 => adc_ot2,
				adc_ov => adc_ov,

				-- Display
				LCD_DB => LCD_DB,
				LCD_E  => LCD_E,
				LCD_RS => LCD_RS,
				LCD_RW => LCD_RW,


				-- Resets
				--  ADC_DAQ_BUFR_SYNC=>GPIO_BUFR_RST,
				user_reset         => user_reset, -- output to port
				ctrl_reset_pulse   => ctrl_reset_pulse, -- output to port
				sysmon_user_reset  => sysmon_user_reset, -- output to port
				sysmon_clk_enable  => sysmon_clk_enable, -- output to port
				ADCDAQ_RESET_ASYNC => ADCDAQ_RESET_ASYNC, -- output to port
				CHAN_RESET_ASYNC   => chan_reset_async, -- output to port
				CORR_RESET_ASYNC   => CORR_RESET_ASYNC, -- output to port
				blinker_reset      => blinker_reset, -- to blinker

				-- Buck sync
				buck_sync => buck_sync, -- output to port

				chan_clk_sel => chan_clk_sel, -- '0': ADC clock, '1': internal 200 MHz clock
				chan_clk_reset_async => chan_clk_reset_async,

				-- Clocks
				clk200 => clk200,
				clk200_reset => clk200_reset_reg,
				clk10 => clk10, -- Backplane reference clock
				clk10_sel => clk10_sel, -- reference clock selector signal

				DNA_CLK => sysmon_clk
			);
	end block gpio_blk;



	---------------------------------------------------------------------
	-- Instantiate the SPI Interface
	---------------------------------------------------------------------
	gen_spi: if NUMBER_OF_SPI_PORTS > 0 generate

		signal bsb_rst_reg1, bsb_rst_reg2: std_logic;
		attribute DONT_TOUCH of bsb_rst_reg1, bsb_rst_reg2: signal is "true";
		signal spi_rst: std_logic;
		attribute DONT_TOUCH of spi_rst: signal is "true";

	begin
		-- Reset output signal that can be used by some boards to reset SPI devices.

		-- Pipeline reset signal

		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				bsb_rst_reg1 <= bsb_rst;
				bsb_rst_reg2 <= bsb_rst_reg1;
			end if;
		end process;

		-- Pipeline the clk200 reset
		spi_rst_proc: process(all) begin
			if rising_edge(clk200) then
				spi_rst <= clk200_reset;
			end if;
		end process;

		spi0: entity work.spi
			generic map (
				NUMBER_OF_PORTS => NUMBER_OF_SPI_PORTS
			)
			port map (
				-- Control interface
				s_axis_bsb_tdata => sys_router_bsb_cmd_tdata(MODULE_SPI_ADDR),
				s_axis_bsb_tvalid => sys_router_bsb_cmd_tvalid(MODULE_SPI_ADDR),
				s_axis_bsb_tlast => sys_router_bsb_cmd_tlast(MODULE_SPI_ADDR),
				s_axis_bsb_tready => sys_router_bsb_cmd_tready(MODULE_SPI_ADDR),
				m_axis_bsb_tdata => sys_router_bsb_rply_tdata(MODULE_SPI_ADDR),
				m_axis_bsb_tvalid => sys_router_bsb_rply_tvalid(MODULE_SPI_ADDR),
				m_axis_bsb_tlast => sys_router_bsb_rply_tlast(MODULE_SPI_ADDR),
				m_axis_bsb_tready => sys_router_bsb_rply_tready(MODULE_SPI_ADDR),
				bsb_clk          => bsb_clk,
				bsb_rst          => bsb_rst_reg2,

				-- SPI Interface
				spi_rst_n => spi_rst_n,
				spi_sck   => spi_sck,
				spi_miso  => spi_miso,
				spi_mosi  => spi_mosi,
				spi_addr  => spi_addr,
				spi_cs_n  => spi_cs_n,

				clk200 => clk200,

				rst => spi_rst
			);
	end generate gen_spi;

	---------------------------------------------------------------------
	-- I2C Interface
	---------------------------------------------------------------------
	gen_i2c: if NUMBER_OF_I2C_PORTS > 0 generate
		signal bsb_rst_reg1, bsb_rst_reg2: std_logic;
		attribute DONT_TOUCH of bsb_rst_reg1, bsb_rst_reg2: signal is "true";
		signal i2c_rst: std_logic;
		attribute DONT_TOUCH of i2c_rst: signal is "true";
	begin
		-- Pipeline the BSB reset
		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				bsb_rst_reg1 <= bsb_rst;
				bsb_rst_reg2 <= bsb_rst_reg1;
			end if;
		end process;

		-- Pipeline the clk200 reset
		i2c_rst_proc: process(all) begin
			if rising_edge(clk200) then
				i2c_rst <= clk200_reset;
			end if;
		end process;

		I2C0: entity work.i2c
			generic map (
				NUMBER_OF_PORTS => NUMBER_OF_I2C_PORTS
			)
			port map (
				-- BSB Control interface
				s_axis_bsb_tdata => sys_router_bsb_cmd_tdata(MODULE_I2C_ADDR),
				s_axis_bsb_tvalid => sys_router_bsb_cmd_tvalid(MODULE_I2C_ADDR),
				s_axis_bsb_tlast => sys_router_bsb_cmd_tlast(MODULE_I2C_ADDR),
				s_axis_bsb_tready => sys_router_bsb_cmd_tready(MODULE_I2C_ADDR),
				m_axis_bsb_tdata => sys_router_bsb_rply_tdata(MODULE_I2C_ADDR),
				m_axis_bsb_tvalid => sys_router_bsb_rply_tvalid(MODULE_I2C_ADDR),
				m_axis_bsb_tlast => sys_router_bsb_rply_tlast(MODULE_I2C_ADDR),
				m_axis_bsb_tready => sys_router_bsb_rply_tready(MODULE_I2C_ADDR),
				bsb_clk          => bsb_clk,
				bsb_rst          => bsb_rst_reg2,

				-- I2C Interface
				i2c_sck => i2c_sck,
				i2c_sda => i2c_sda,

				-- System interfaces
				clk200 => clk200,
				rst => i2c_rst
			);

	end generate gen_i2c;

	---------------------------------------------------------------------
	-- System Monitor / XADC interface
	---------------------------------------------------------------------
	--   Accesses the FPGA`s system monitors, which measures the FPGA core voltages, temperature and a few external analog lines.
	sysmon_blk: block
		signal sysmon_rst: std_logic;
		attribute DONT_TOUCH of sysmon_rst: signal is "true";

		signal sysmon_reset_all: std_logic;

		signal bsb_rst: std_logic;
		attribute DONT_TOUCH of bsb_rst: signal is "true";
	begin
		-- Pipeline the BSB resets to help them propagate across the chip

		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				bsb_rst <= bsb_rst;
			end if;
		end process;

		sysmon_reset_all <= sysmon_reset or sysmon_user_reset;

		sysmon0: entity work.sysmon
			generic map (
				PLATFORM_TYPE => PLATFORM_TYPE
			)
			port map (
				-- Control interface
				s_axis_bsb_tdata => sys_router_bsb_cmd_tdata(MODULE_SYSMON_ADDR),
				s_axis_bsb_tvalid => sys_router_bsb_cmd_tvalid(MODULE_SYSMON_ADDR),
				s_axis_bsb_tlast => sys_router_bsb_cmd_tlast(MODULE_SYSMON_ADDR),
				s_axis_bsb_tready => sys_router_bsb_cmd_tready(MODULE_SYSMON_ADDR),
				m_axis_bsb_tdata => sys_router_bsb_rply_tdata(MODULE_SYSMON_ADDR),
				m_axis_bsb_tvalid => sys_router_bsb_rply_tvalid(MODULE_SYSMON_ADDR),
				m_axis_bsb_tlast => sys_router_bsb_rply_tlast(MODULE_SYSMON_ADDR),
				m_axis_bsb_tready => sys_router_bsb_rply_tready(MODULE_SYSMON_ADDR),
				bsb_clk => bsb_clk,
				bsb_rst => bsb_rst, -- pipelined synchronous reset

				-- Analog inputs
				VAUX_CURR_N => VAUX_CURR_N,
				VAUX_CURR_P => VAUX_CURR_P,
				VAUX_VOLT_N => VAUX_VOLT_N,
				VAUX_VOLT_P => VAUX_VOLT_P,
				VP => VP,
				VN => VN,

				-- debug_out => debug_out,
				sysmon_clk => sysmon_clk,
				SYSMON_RST => sysmon_reset_all
			);
	end block sysmon_blk;

	---------------------------------------------------------------------
	-- Frequency counter
	---------------------------------------------------------------------
	--   Measures the toggling frequency of a number of logic signals.
	freq_ctr_blk: block is
		-- Frequency counter-related signals and constants
		constant NUMBER_OF_FREQ_CTR_PORTS: integer := 41;
		signal freq_ctr_in_vect: std_logic_vector(0 to NUMBER_OF_FREQ_CTR_PORTS - 1);

		signal bsb_rst_reg1, bsb_rst_reg2: std_logic;
		attribute DONT_TOUCH of bsb_rst_reg1, bsb_rst_reg2: signal is "true";
	begin
		-- Pipeline the BSB reset signal
		process(all) begin
			if rising_edge(bsb_clk) then
				bsb_rst_reg1 <= bsb_rst;
				bsb_rst_reg2 <= bsb_rst_reg1;
			end if;
		end process;

		-- Here we assign the clock monitoring signal to each of the frequency counter input channels
		freq_ctr_in_vect(0 to adc_clk_div2'LENGTH - 1) <= adc_clk_div2; -- monitor up to 16 ADC clocks
		freq_ctr_in_vect(16) <= fmc_mgt_pll_refclk_div2(0); -- MGT
		freq_ctr_in_vect(17) <= fmc_refclk_div2(1);
		freq_ctr_in_vect(18) <= fmc_refclk_div2(0);
		freq_ctr_in_vect(19) <= clk200_div2;
		freq_ctr_in_vect(20) <= ctrl_clk_div2;
		freq_ctr_in_vect(21) <= fan_tach_div2;
		freq_ctr_in_vect(22) <= chan_clk_div2;
		freq_ctr_in_vect(23) <= ct_clk_div2;
		freq_ctr_in_vect(24) <= sysmon_clk_div2;

		gen_freq25: if NUMBER_OF_GPU_REFCLKS > 0 generate
			freq_ctr_in_vect(25) <= gpu_refclk_div2(0); -- MGT
		end generate gen_freq25;

		freq_ctr_in_vect(26) <= gpu_txclk_div2;

		gen_freq27: if NUMBER_OF_CT_REFCLKS > 0 generate
			freq_ctr_in_vect(27) <= bp_shuffle_refclk_div2(0); -- MGT
		end generate gen_freq27;

		freq_ctr_in_vect(28) <= bp_shuffle_txclk_div2;
		freq_ctr_in_vect(29) <= fmc_mgt_pll_refclk_div2(1); -- MGT
		freq_ctr_in_vect(30) <= fmc_mgt_pll_refclk_div2(2); -- MGT
		freq_ctr_in_vect(31) <= fmc_mgt_pll_refclk_div2(3); -- MGT
		freq_ctr_in_vect(32) <= raw_clk10_div2;
		freq_ctr_in_vect(33) <= mgt_clk100_div2; -- MGT
		freq_ctr_in_vect(34) <= mgt_clk200_div2; -- MGT
		freq_ctr_in_vect(35) <= sfp_refclk_div2; -- MGT
		freq_ctr_in_vect(36) <= clk10_div2; -- MGT
		freq_ctr_in_vect(37) <= mgt_clk125_div2; -- MGT

		gen_freq38: if NUMBER_OF_CT_REFCLKS > 1 generate
			freq_ctr_in_vect(38) <= bp_shuffle_refclk_div2(1); -- MGT
		end generate gen_freq38;

		freq_ctr_in_vect(39) <= pll_oscout_div2;

		freq_ctr_in_vect(40) <= corr_clk_div2;

		freq_ctr0: entity work.freq_ctr
			generic map (
				FPGA_SERIES => FPGA_SERIES,
				NUMBER_OF_CLK_IN_PORTS => NUMBER_OF_FREQ_CTR_PORTS
			)
			port map (
				s_axis_bsb_tdata => sys_router_bsb_cmd_tdata(MODULE_FREQ_CTR_ADDR),
				s_axis_bsb_tvalid => sys_router_bsb_cmd_tvalid(MODULE_FREQ_CTR_ADDR),
				s_axis_bsb_tlast => sys_router_bsb_cmd_tlast(MODULE_FREQ_CTR_ADDR),
				s_axis_bsb_tready => sys_router_bsb_cmd_tready(MODULE_FREQ_CTR_ADDR),
				m_axis_bsb_tdata => sys_router_bsb_rply_tdata(MODULE_FREQ_CTR_ADDR),
				m_axis_bsb_tvalid => sys_router_bsb_rply_tvalid(MODULE_FREQ_CTR_ADDR),
				m_axis_bsb_tlast => sys_router_bsb_rply_tlast(MODULE_FREQ_CTR_ADDR),
				m_axis_bsb_tready => sys_router_bsb_rply_tready(MODULE_FREQ_CTR_ADDR),
				bsb_clk          => bsb_clk,
				bsb_rst          => bsb_rst_reg2,

				clk200 => clk200,
				CLK_IN_DIV2 => freq_ctr_in_vect, -- vector of 'NUMBER_OF_FREQ_CTR_PORTS' signals for which we want to measure the frequencies
				RST => clk200_reset
			);
	end block freq_ctr_blk;

	-------------------------------------------------------------------------
	-- FMC reference clock
	-------------------------------------------------------------------------
	-- Handles the FMC reference clock generation and reception and ADC SYNC generation/alignment

	-- Implements the LVDS ADC SYNC output to the FMC board

	refclk_blk: block
		signal refclk_bsb_rst: std_logic;
		attribute DONT_TOUCH of refclk_bsb_rst: signal is "true";

		signal refclk_rst: std_logic;
		attribute DONT_TOUCH of refclk_rst: signal is "true";
	begin
		-- Pipeline the BSB resets to help them propagate across the chip
		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				refclk_bsb_rst <= bsb_rst;
			end if; -- RST/CLK
		end process;

		-- Pipeline the clk200 reset
		refclk_rst_proc: process(all) begin
			if rising_edge(clk200) then
				refclk_rst <= clk200_reset;
			end if;
		end process;

		refclk0: entity work.refclk
			generic map (
				PLATFORM_TYPE => PLATFORM_TYPE,
				NUMBER_OF_MEZZANINES => NUMBER_OF_ADC_BOARDS,
				SIM => SIM
			)
			port map (
				s_axis_bsb_tdata => sys_router_bsb_cmd_tdata(MODULE_REFCLK_ADDR),
				s_axis_bsb_tvalid => sys_router_bsb_cmd_tvalid(MODULE_REFCLK_ADDR),
				s_axis_bsb_tlast => sys_router_bsb_cmd_tlast(MODULE_REFCLK_ADDR),
				s_axis_bsb_tready => sys_router_bsb_cmd_tready(MODULE_REFCLK_ADDR),
				m_axis_bsb_tdata => sys_router_bsb_rply_tdata(MODULE_REFCLK_ADDR),
				m_axis_bsb_tvalid => sys_router_bsb_rply_tvalid(MODULE_REFCLK_ADDR),
				m_axis_bsb_tlast => sys_router_bsb_rply_tlast(MODULE_REFCLK_ADDR),
				m_axis_bsb_tready => sys_router_bsb_rply_tready(MODULE_REFCLK_ADDR),
				bsb_clk          => bsb_clk,
				bsb_rst          => refclk_bsb_rst,

				FMC_REFCLK_P => refclk_m2c_p, -- IBUFDS instantiated by the module
				FMC_REFCLK_N => refclk_m2c_n,

				fmc_refclk => fmc_refclk, -- BUFG'ed reference clocks from the 2 mezzanones
				FMC_REFCLK_DIV2 => fmc_refclk_div2(0 to NUMBER_OF_ADC_BOARDS - 1), -- Logic signal toggling at 1/2 the Mezzanine's reference clocks, for the frequency counter

				ADC_SYNC_P => adc_sync_p, -- Differential SYNC signal to the ADC. OBUFDS is instantiated by the REFCLK module
				ADC_SYNC_N => adc_sync_n,

				clk10 => clk10, -- Backplane reference clock
				-- Sync source signals
				sync_in => (0 => time_trig(1), -- Corresponds to source #2 in REFCLK
							1 => not irigb_before_target, -- Corresponds to source #3
							2 => time_trig(0), -- Corresponds to source #4
							3 => bp_gpio_int_in, -- Corresponds to source #5
							4 => user_mux_in(0), -- Corresponds to source #6 - sma_a
							5 => user_mux_in(1) -- Corresponds to source #7 - sma_b
							),
				clk10_out => clk10_out,

				sync_out => sync_out,

				ADCDAQ_RESET => refclk_adcdaq_reset,

				clk200 => clk200,
				RST => refclk_rst
			);


	end block refclk_blk;


	-----------------------------------------------------------------------
	---- LED blinking, for a comfortable user experience
	-----------------------------------------------------------------------
	blinker_blk: block
		signal bsb_rst_reg1, bsb_rst_reg2: std_logic;
		attribute DONT_TOUCH of bsb_rst_reg1, bsb_rst_reg2: signal is "true";
		signal blinker_reset_all: std_logic; --
		signal blinker_rst: std_logic;
		signal blinker_kick: std_logic;
	begin

		-- Pipeline reset signal
		bsb_rst_proc: process(all) begin
			if rising_edge(bsb_clk) then
				bsb_rst_reg1 <= bsb_rst;
				bsb_rst_reg2 <= bsb_rst_reg1;
			end if;
		end process;

		blinker_reset_all <= bsb_rst_reg2 or blinker_reset;
		blinker_rst <= blinker_reset_all or (not sfp_status_vector(0)); -- do not blink if Link Status = 0
		--blinker_kick <= udp_rx_tvalid and udp_rx_tlast; -- blink faster when packets are received
		blinker_kick <= udp_rx_frame; -- blink faster when packets are received

		blinker0: entity work.blinker
			generic map (
				DUMMY => not BLINKER_PRESENT,
				PING_PONG => is_in(PLATFORM_TYPE, (ZCU111, KC705, ML605)) -- Eight LEDs on these platforms for the status light pattern
			)
			port map (
				rst  => blinker_rst, -- do not blink if Link Status = 0
				clk  => bsb_clk,
				leds => gpio_led,
				kick => blinker_kick -- blink faster when packets are received
			);
	end block blinker_blk;


end architecture impl;