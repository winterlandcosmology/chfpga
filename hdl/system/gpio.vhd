----------------------------------------------------------------------------------
-- Company: Mc Gill University
-- Engineer: J.-F. Cliche
--
-- Create Date:    2011-08-24
-- Design Name:    chFPGA
-- Module Name:    GPIO - impl
-- Project Name:
-- Target Devices: Virtex 6, 7 series, Ultrascale+
-- Tool versions: ISE 13.1, 14.2 ... Vivado 2022.2
--
-- Revision:
--  2011-08-29 JFC: Added USER_ACCESS to obtain the bitstream date (or other user info inserted at bitstream-generation time)
--  2011-09-14 JFC: Added global reset signal
--  2012-09-18 JFC: Cleanup. Added comments. Removed version Generics
--  2012-09-23 JFC: Moved fan readout (debouncing) circuitry in here.
--  2012-11-05 JFC: Removed RST from the fan tachymeter measurment logic to slightly reduce logic.
--  2013-01-30 JFC: Added PLATFORM_TYPE field to allow the Python software to instantiate the appropriate handlers for the specific platform
----------------------------------------------------------------------------------

library IEEE;
use ieee.std_logic_1164.ALL;
use ieee.numeric_std.ALL;
use ieee.std_logic_misc.ALL; -- for or_reduce()


use work.chFPGA_Package.ALL; -- Get all component definitions

use work.irigb_package.slv32_array;
use work.irigb_package.irigb;

library UNISIM;
use UNISIM.VComponents.ALL;

library xpm;
use xpm.vcomponents.ALL;

-- Implements general I/O common to all the devices
--
-- Includes
--
-- - Core registers accessible via BSB and external SPI link
-- - IRIG-B decoder/generator and comparator
-- - Frame/time capture
-- - Global data capture/injection trigger
-- - Global channelizer and correlator resets
-- - LCD Interface bits
-- - Buck switching supply SYNC signal generation
-- - FMC ADC Reset line
-- - ADC status and control (calibration freeze, overrange/overvoltage, PLL lock)
-- - Fan speed readout
-- - Network configuration (MAC, IP, port) and UDP link monitoring
-- - IP Port offsets for the data capture and correlator outputs
-- - Event-synchronized PWM generation
-- - User output mux (selectable signals to SMA)
-- - 10 MHz reference clock source selection and external PLL sync
-- - Backplane buck sync and GPIO interrupt
-- - IceBoard I/O (UART, GPIO, flash, ARM IRQ)
-- - Channelizer clock source selection
-- - FPGA DNA/serial number and firmware timestamp
--
entity gpio is
	generic (
		PLATFORM_TYPE: platform_type_enum; -- identifies the type of platform on which the firmware is running
		COOKIE: integer := 16#42#;
		PROTOCOL_VERSION: integer; -- Protocol version used to determins compatibility with the python support software

		-- ADC info

		NUMBER_OF_ADCS: integer; -- Number of adcs that are implemented
		CHANNELIZERS_CLOCK_SOURCE: integer; -- ADC channel from which the channelizers clocks are derived
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
		NUMBER_OF_GPU_LINKS: integer;

		-- Correlator info

		NUMBER_OF_CORRELATORS: integer; -- Number of correlator blocks (CH_DIST+CORR+ACC) that are implemented if IMPLEMENT_CORR=TRUE
		NUMBER_OF_CHANNELIZERS_TO_CORRELATE: integer; -- Number of channels to be correlated for each frequency channel.


		-- Buck regulator SYNC control

		NUMBER_OF_BUCK_SYNC_LINES: integer := 16;
		BUCK_SYNC_ENABLE: boolean          := True; -- default state of the buck sync enable at startup
		BUCK_CLK_DIVIDE_FACTOR: integer    := 12; -- Buck frequency is 200MHz/BUCK_CLK_DIVIDE_FACTOR/16


		MAC_ADDRESS_OUI_CODE: std_logic_vector(23 downto 0) := X"000A35"; -- Xilinx OUI code used to identify the first 3 bytes of the MAC address
		NUMBER_OF_USER_SMA_SIGNALS: integer                 := 8;
		IMPLEMENT_LCD: BOOLEAN                              := FALSE;
		IMPLEMENT_SWITCHER_SYNC: BOOLEAN                    := TRUE;
		IMPLEMENT_FAN: BOOLEAN                              := TRUE;
		IMPLEMENT_ARM_SPI: BOOLEAN                          := TRUE;
		SIM: boolean                                        := FALSE
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

		-- UDP local Rx networking configuration
		
		local_mac_addr: out std_logic_vector(47 downto 0);
		local_base_ip_addr: out std_logic_vector(31 downto 0);
		local_base_ip_port: out std_logic_vector(15 downto 0);
		-- UDP TX channel 0 remote network configuration
		--   MAC & IP addresses are hardwired to be those of the perviously received packet
		
		remote_ip_port0: out std_logic_vector(15 downto 0); -- normally set to zero to reply to the same port as the last command

		-- UDP TX channel 1 remote network configuration
		
		remote_mac_addr1: out std_logic_vector(47 downto 0);
		remote_ip_addr1: out std_logic_vector(31 downto 0);
		remote_ip_port1: out std_logic_vector(15 downto 0);

		-- Buck control signals

		buck_sync: out std_logic_vector(0 to NUMBER_OF_BUCK_SYNC_LINES - 1);

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

		-- FAN control signals (for on-board fan found on some evaluation boards)

		fan_pwm: out std_logic; -- PWM control of the fan
		fan_tach: in std_logic; -- Tachymeter input from the fan (two pulses per revolution). A debouncer cleans this signal before measuring the fan frequency.
		fan_tach_div2: out std_logic; -- logic signal pulsing at half the fan rotation speed

		-- ADC mezzanine control signals

		adc_rst: out std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1);
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
		adc_pll_lock: in std_logic_vector(0 to NUMBER_OF_ADC_BOARDS - 1); -- Lock signal for the ADC PLL on each mezzanine

		-- Display interface (on some boards only)

		lcd_db: out  std_logic_vector(7 downto 4);
		lcd_e: out  std_logic;
		lcd_rs: out  std_logic;
		lcd_rw: out  std_logic;


		-- Backplane synchronization signal

		bp_buck_sync: inout std_logic;

		-- Backplane global interrupt line

		bp_gpio_int_out: out std_logic;
		bp_gpio_int_in: in std_logic;
		bp_gpio_int_oe: out std_logic;

		-- UDP Communication link monitoring

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

		-- General signals

		-- Clocks

		clk200: in std_logic; -- 200 MHz clock, used for many things
		clk200_reset: in std_logic; --
		clk10: in std_logic; -- 10 MHZ reference clock, in phase for every board in the system
		clk10_sel: out std_logic;
		dna_clk: in std_logic; -- DNA port clock (max 97 MHz)

		-- External PLL control

		pll_sync: out std_logic;

		-- PWM signal

		pwm_clk: in std_logic;
		pwm_ctr_en: in std_logic; -- Active when the pwm counter is to be enabled.
		pwm_reset: in std_logic;
		pwm_out: out std_logic;

		-- Event (Frame) counter

		event_ctr_clk: in std_logic;
		event_ctr_en: in std_logic;
		event_ctr_inc: in std_logic;
		event_ctr_reset: in std_logic;

		-- User output selection

		user_mux_in: in std_logic_vector(0 to NUMBER_OF_USER_SMA_SIGNALS - 1); -- User selectable signals (typically PWM, 1PPS, SYNC, ?)
		user_mux_out: out std_logic_vector(0 to 3); -- User selected signal
		user_mux_oe: out std_logic_vector(0 to 3);
		user_bit: out std_logic_vector(1 downto 0);

		-- IRIG-B time

		irigb_mux_in: in std_logic_vector(0 to 7); -- IRIG-B time signals
		irigb_before_target: out std_logic;
		irigb_pps: out std_logic;
		irigb_out: out std_logic;

		-- Channelizer clock source selection

		chan_clk_sel: out std_logic;  -- channelizer clock source selection (on bsb_clk)

		-- User-controlled global resets

		user_reset: out std_logic;
		ctrl_reset_pulse: out std_logic := '0'; -- single reset pulse (on bsb_clk) that can be generated by the user. Used to reset the bsb_interfaces
		sysmon_user_reset: out std_logic; -- manual user SYSMON reset (on bsb_clk) from GPIO
		sysmon_clk_enable: out std_logic; -- enables the SYSMON clock buffer (BUFGCE in the clock generator). '0' stops the 62.5 MHz sysmon_clk, whose edges couple into the RF-ADC inputs (12.5 MHz comb at 3.2 GSPS)
		adcdaq_reset_async: out std_logic; -- manual user ADCDAQ reset (on bsb_clk)
		chan_clk_reset_async: out std_logic; -- manual user channelizer PLL reset (on bsb_clk)
		chan_reset_async: out std_logic; -- manual user channelizer reset (on bsb_clk)
		corr_reset_async: out std_logic; -- manual user correlator reset (on bsb_clk)
		blinker_reset: out std_logic -- manual user blinker reset (on bsb_clk)
	);
end entity gpio;

architecture impl of gpio is

	attribute ASYNC_REG: string;

	constant FPGA_SERIES: fpga_series_enum := PLATFORM_INFO(PLATFORM_TYPE).FPGA_SERIES;
	constant WORDS_PER_FRAME: integer := ADC_SAMPLES_PER_FRAME / ADC_SAMPLES_PER_WORD;
	constant LOG2_WORDS_PER_FRAME: integer := integer_log2(WORDS_PER_FRAME); -- Number of words per frame. One word is 4 8-bit time samples or 2 8+8-bits frequency samples.
	constant LOG2_SAMPLES_PER_FRAME: integer := integer_log2(ADC_SAMPLES_PER_FRAME);
	constant LOG2_SAMPLES_PER_WORD: integer := integer_log2(ADC_SAMPLES_PER_WORD);
	constant NUMBER_OF_ADC_FLAGS: integer := min(NUMBER_OF_ADCS, 8); -- GPIO registers cannot store flags for more than 8 ADCs. It's ok  as those are used only for the RfSoC platforms, which have 8 ADCs or less.

	signal clk_ctr: unsigned(7 downto 0) := (others => '0'); -- Divides the ADC clock by up to 255
	signal ce: std_logic := '0';

	signal firmware_timestamp: std_logic_vector(31 downto 0);
	signal user_data_valid: std_logic;

	--- Define Control word and its signals

	signal control_bytes: slv8_array(0 to 50); -- default value set in the CMD_SLAVE
	signal status_bytes: slv8_array(0 to 43); -- default value set in the CMD_SLAVE

	signal ctrl_flag_buck_sync_enable: std_logic;
	signal ctrl_flag_adcdaq_reset: std_logic;
	signal ctrl_flag_global_trig: std_logic;
	signal ctrl_flag_buck_clk_div: unsigned(7 downto 0);
	signal buck_sync_int: std_logic := '0';
	signal buck_phase: std_logic_vector(NUMBER_OF_BUCK_SYNC_LINES * 4 - 1 downto 0);
	signal buck_phase_ctr: unsigned(3 downto 0) := (others => '0'); -- Counts the 16 possible phasess. Initialized to avoid metata on '=' for simulations.

	-- ARM-SPI interface

	signal spi_addr, spi_rdat, spi_wdat: std_logic_vector(31 downto 0) := (others => '0');
	signal spi_rreq, spi_rack, spi_wreq, spi_wack: std_logic := '0'; -- important to have default value in case the ARM SPI receiver is not instantiated.

	constant NUMBER_OF_CORE_REGISTERS: integer := 26;
	signal   core_reg_wr_value: work.irigb_package.slv32_array(0 to NUMBER_OF_CORE_REGISTERS - 1);
	signal   core_reg_rd_value: work.irigb_package.slv32_array(0 to NUMBER_OF_CORE_REGISTERS - 1);
	constant CORE_REG_DEFAULT_VALUES: work.irigb_package.slv32_array(0 to NUMBER_OF_CORE_REGISTERS - 1) := (
	 7      => X"00000000", -- MAC
	 8      => X"0000_0000", -- MAC, Port
	 9      => X"00000000", -- IP
	 others => X"00000000"
	);

	-- Fan related signals

	signal fan_tach_ctr: unsigned(16 downto 0); -- the length of this counter sets the number of clk200 cycles  the debouncing waits before deciding that the state is stable
	signal fan_tach_target: std_logic := '0'; --
	signal fan_tach_div2_int: std_logic := '0';

	signal dna_dout: std_logic;
	signal dna_read: std_logic := '1'; -- First clock is a read
	signal dna_shift: std_logic := '1'; -- Will start shifting as soon as read is disabled
	signal dna_ctr: unsigned(5 downto 0) := to_unsigned(57 - 1, 6); -- Will shift 57 times

	signal firmware_crc32: std_logic_vector(31 downto 0);

	signal fpga_serial_number: std_logic_vector(56 downto 0) := (others => '0'); -- Need to initialize because we do not shift all the 64 bits
	signal target_fpga_serial_number: std_logic_vector(56 downto 0);

	signal target_network_config_source: std_logic_vector(1 downto 0);

	signal core_reg_wr_en: std_logic; -- indicates if the FPGA serial number matches the target serial number

	signal bsb_core_din: std_logic_vector(7 downto 0);
	signal bsb_core_dout: std_logic_vector(7 downto 0);
	signal bsb_core_addr: std_logic_vector(6 downto 0); -- 5 bit word number (max 32 registers) + 2 bits (4 bytes per word)
	signal bsb_core_wr_en: std_logic;
	signal bsb_core_rd_en: std_logic;

	-- Network parameters from the core registers
	signal spi_fpga_local_ip_address: std_logic_vector(31 downto 0) := X"0A0A0A0B";
	signal spi_fpga_local_ip_port: std_logic_vector(15 downto 0) := X"A028"; -- 41000
	signal spi_fpga_local_mac_address: std_logic_vector(47 downto 0) := X"123456789ABC";
	signal spi_fpga_ch0_remote_ip_port: std_logic_vector(15 downto 0);
	signal spi_fpga_ch1_remote_ip_address: std_logic_vector(31 downto 0);
	signal spi_fpga_ch1_remote_ip_port: std_logic_vector(15 downto 0);
	signal spi_fpga_ch1_remote_mac_address: std_logic_vector(47 downto 0);

	-- Mux signals

	signal user_mux_source: slv4_array(0 to 3);

	-- IRIG-B receiver

	signal irig_source: std_logic_vector(2 downto 0) := "000";
	signal irig_pol: std_logic := '0'; -- irig-b signal polarity: 0=normal, 1=inverted
	signal ts: irigb; -- Current time as obtained by the IRIG-B decoder
	signal pps_ctr: unsigned(5 downto 0);
	signal pps_int: std_logic;

	signal ts_sample: irigb; -- Sampled time
	signal ts_sample_event_trig_in: std_logic; -- Automatically generated by the event counter trigger (on the event_ctr_clk). Toggled on every trigger event.
	signal ts_sample_event_trig_out: std_logic; --

	signal ts_sample_refclk_trig_in: std_logic; -- Automatically generated by the event counter trigger (on the event_ctr_clk). Toggled on every trigger event.
	signal ts_sample_refclk_trig_out: std_logic;

	signal ts_target: irigb; -- Target time used with the time comparator
	signal ts_compare_enable: std_logic;
	signal ts_force: std_logic;
	signal ts_before_target: std_logic;

	signal refclk_sample: unsigned(63 downto 0);

	-- PWM signals

	signal pwm_period: unsigned(31 downto 0);
	signal pwm_high_time: unsigned(31 downto 0);
	signal pwm_offset: unsigned(31 downto 0);
	signal pwm_ctr: unsigned(31 downto 0);
	signal pwm_active: std_logic;
	signal pwm_soft_reset: std_logic;

	-- Event counter and capture

	signal event_sample: unsigned(47 downto 0); -- Captured value

	signal manual_event_sample_trig: std_logic;

	signal event_sample_done: std_logic;
	attribute async_reg of event_sample_done: signal is "true";

	-- Reference clock counter capture logic

	signal manual_refclk_sample_trig: std_logic; -- indicates when to capture the reference counter
	signal manual_refclk_sample_trig_reg: std_logic; -- 1st stage of the synchronizer
	attribute async_reg of manual_refclk_sample_trig_reg: signal is "true";
	signal manual_refclk_sample_trig_reg2: std_logic; -- delayed version used to detect the rising edge and do clock synchronization (needs ASYNC_REG)
	attribute async_reg of manual_refclk_sample_trig_reg2: signal is "true";
	signal manual_refclk_sample_trig_reg3: std_logic;
	signal refclk_sample_done: std_logic;
	attribute async_reg of refclk_sample_done: signal is "true";
	signal ts_sample_trig10: std_logic := '0';
	signal ts_sample_trig10_ack: std_logic;
	signal ts_sample_done: std_logic;

	-- External PLL

	signal pll_sync_pre: std_logic;
	signal ctrl_reset_trig: std_logic := '0';

begin

	-----------------------------------------------------------------------------------
	-- CONTROL and STATUS Bytes
	-----------------------------------------------------------------------------------
	--
	-- GPIO Module
	--
	-- |  Page   | Addr|Bit(s)|     Name                    | Description |
	-- |---------|-----|------|-----------------------------|-------------|
	-- | CONTROL |  0  |  7   | CTRL_FLAG_GLOBAL_TRIG       | (Possibly unused) |
	-- |         |     |  6   | CTRL_FLAG_BUCK_SYNC_ENABLE  | Enables the generation of the Buck switcher synchronization signals. If '0', all sync lines are held low to let the switcher free-run.|
	-- |         |     |  5   | CHAN_CLK_RESET              | Resets the MMCM that generates the channelizer clocks |
	-- |         |     |  4   | CHAN_CLK_Sel             | Selects the source of the channelizer clocks: 0: ADC clock, 1: 200 MHz system clock. CHAN_CLK_RESET or ADCDAQ_RESET must be asserted after the change for the MMCM to relock.|
	-- |         |     |  3   | ADCDAQ_RESET                | Resets all ADCDAQ modules. This also resets the channelizer clock MMCM, the channelizers and the correlators.|
-- |         |     |  2   | (unused)                    | |
-- |         |     | 1:0  | ADC_RESET                   | ADC RESET line (active High) for each FMC ADC boards (bit 0 is for ADC board 0, etc). Number of bits depends on NUMBER_OF_ADC_BOARDS generic. |
	-- |         |  1  | 7:0  | CTRL_FLAG_BUCK_CLK_DIV      | System clock frequency divider ratio used to set the buck sync frequency|
	-- |         |  2  |  7   | LCD_E                       | LCD Enable |
	-- |         |     |  6   | LCD_RS                      | LCD Command/Data flag|
	-- |         |     |  5   | LCD_RW                      | LCD Read/Write flag|
	-- |         |     |  4   | (unused)                    | |
	-- |         |     | 3:0  | LCD_DB                      | LCD data bus (4 bits) |
	-- |         |  3  |  7   | BLINKER_RESET               | |
	-- |         |     |  6   | CHAN_RESET_ASYNC            | Resets all channelizers |
	-- |         |     |  5   | CORR_RESET_ASYNC            | Resets all correlators |
	-- |         |     |  4   | ctrl_reset_trig             | Generates a BSB reset pulse when a rising edge of this signal is detected |
	-- |         |     |  3   | sysmon_user_reset           | Resets the SYSMON module |
	-- |         |     |  2   | clk10_sel                   | CRS platform: Selects the source of the 10 MHz reference clock |
	-- |         |     |  1   | pll_sync_pre                | CRS: Pulses the External PLL SYNC line and causes its clocks to resynchronize |
	-- |         |     |  0   | sysmon_clk_enable           | Enables the SYSMON clock (default 1). Set to 0 to stop the 62.5 MHz SYSMON clock during data taking; set to 1 before reading the SYSMON or the device DNA |
	-- |         |  4  | 7:5  | (unused)                    | |
	-- |         |     | 4:0  | HOST_FRAME_READ_RATE        | Indicates how often the host reads its UDP buffers in order to throttle the Ethernet output data rate. The read period is 2*(2^HOST_FRAME_READ_RATE)*(1/bsb_clk) where CTRL lk is 125 MHz|
	-- |         |5-12 | 63:0 | BUCK_PHASE                  | Phase of each of the 16 Buck sync lines. There are 16 possible phase values for each line. Bits 3:0 is for phase 0, bits 7:4 for phase 1 etc.|
	-- |         |  13 | 7:0  | adc_cal_freeze              | RfSoC ADC calibration freeze control (bits 0-7 => ADC 0-7) |
	-- |         |  14 | 7:0  | adc_clear_or                | RfSoC ADC overrange flag clear (bits 0-7 => ADC 0-7) |
	-- |         |  15 | 7:0  | adc_clear_ov                | RfSoC ADC overvoltage flag clear (bits 0-7 => ADC 0-7)|
	-- |         |16-24|      | (unused)                    | |
	-- |         |25-32| 63:57| (unused)                    | |
-- |         |     | 56:0 | target_fpga_serial_number   | Target FPGA serial number: The core registers can be written via BSB commands if this target serial number matches the actual serial number of the FPGA |
-- |         |  33 | 3:2  | target_network_config_source| Selects when core registers are writable. "00": core reg write always enabled; "01", "10" or "11": core reg write only when target serial matches the FPGA's serial |
	-- |         |34-37| 31:0 | pwm_offset                  | Number of events (frames) to delay before starting to generate the first High of the PWM output|
	-- |         |38-41| 31:0 | pwm_high_time               | Number of events (frames) to keep the PWM output at High|
	-- |         |42-45| 31:0 | pwm_period                  | Number of events (frames) between PWM High (i.e PWM period)|
	-- |         | 46  | 7    | pwm_soft_reset              | Software reset of the PWM module. Active high. |
	-- |         |     | 6:4  | (unused)                    | |
	-- |         |     |  5   | bp_gpio_int_out             | IceBoard: GPIO_INT Output signal (when output enable is enabled) |
	-- |         |     |  4   | bp_gpio_int_oe              | IceBoard: Enables tristate output of GPIO_INT_OE |
	-- |         |     | 3:0  | user_mux_source(0)          | Selects which user source to send to the user output 0. |
	-- |         | 47  |  7   | uart_tx_oe                  | IceBoard I/O |
	-- |         |     |  6   | uart_tx_out                 | IceBoard I/O |
	-- |         |     |  5   | uart_rx_oe                  | IceBoard I/O |
	-- |         |     |  4   | uart_rx_out                 | IceBoard I/O |
	-- |         |     |  3   | gpio_rst_oe                 | IceBoard I/O |
	-- |         |     |  2   | gpio_rst_out                | IceBoard I/O |
	-- |         |     |  1   | arm_irq_oe                  | IceBoard I/O |
	-- |         |     |  0   | arm_irq_out                 | IceBoard I/O |
	-- |         | 48  | 7:4  | user_mux_source(3)          | Selects the output sent to user output 3 |
	-- |         |     |  3   | gpio_irq_oe                 | IceBoard I/O |
	-- |         |     |  2   | gpio_irq_out                | IceBoard I/O |
	-- |         |     |  1   | flash_cs_oe                 | IceBoard I/O |
	-- |         |     |  0   | flash_cs_out                | IceBoard I/O |
	-- |         | 49  | 7:4  | user_mux_source(2)          | Selects the output sent to user output 2 |
	-- |         |     | 3:0  | user_mux_source(1)          | Selects the output sent to user output 1 |
	-- |         | 50  |  7   | user_bit(1)                 | User bit 1 (multiple functions) |
	-- |         |     |  6   | user_bit(0)                 | user bit 0 (multiple functions) |
	-- |         |     |  5   | (unused)                    | |
	-- |         |     | 4:0  | (unused)                    | |
	-- | STATUS  |  0  |  7   | USER_DATA_VALID             | is '1' when the ACCESS0 register data (firmware timestamp) is valid |
	-- |         |     | 6:0  | COOKIE                      | Defined as a GENERIC (default = 0x42)|
	-- |         |  1  | 7:5  | LOG2_SAMPLES_PER_WORD       | Base-2 log of the number of samples per word |
	-- |         |     | 4:0  | LOG2_SAMPLES_PER_FRAME      | Base-2 log of the number of samples per frame |
	-- |         |  2  | 7:0  | NUMBER_OF_CHANNELIZERS      | Number of channelizers implemented in the firmware |
	-- |         |  3  | 7:0  | NUMBER_OF_CORRELATORS       | Number of correlators implemented in the firmware |
	-- |         |  4  | 7:0  | NUMBER_OF_CHANNELIZERS_TO_CORRELATE | Number of channelizers connected to the correlators. Only channelizers 0 to N-1 will be connected. This sets the numbe rof parallel multipliers and accumulators in the correlator. |
	-- |         |  5  | 7:0  | NUMBER_OF_CHANNELIZERS_WITH_FFT   | Indicates how many channelizers have a FFT module. Those will be channeizers 0 to N-1|
	-- |         |  6  | 7:0  | NUMBER_OF_GPU_LINKS         | Indicates how GPU Links are implemented. If zero, the GPU module is not present at all (not even the common registers)|
	-- |         | 7-10| 31:0 | firmware_timestamp          | 32-bit word containing the timestamp of the firmware inserted during the bitgen process |
	-- |         |  11 | 7:0  | PLATFORM_TYPE                 | Type of platform on which the firmware is running. 0=ML605, 1=KC705, 3=MGK7MB, 4=ZCU111 |
	-- |         |12-19| 63:57| (unused)                    | (unused) |
	-- |         |     | 56:0 | FPGA_DNA                    | FPGA unique serial number|
	-- |         |  20 | 7:0  | NUMBER_OF_CT_INPUTS   | Indicates how many channelizers are connected to the crossbar inputs. Those will be channeizers 0 to N-1|
	-- |         |  21 | 7:0  | NUMBER_OF_CROSSBAR1_OUTPUTS | Indicates the number of crossbar1 outputs. Those outputs feed the GPU links and the FPGA correlators (if implemented).
	-- |         |22-23| 15:0 | PROTOCOL_VERSION            | 16-bit value indicating the protocol version. A change in the version means that some change is needed on host control software. |
	-- |         |  24 | 7:0  | CHANNELIZERS_CLOCK_SOURCE   | ADC channel from which the channelizer clocks are derived. Useful to know if we should expect the clock to be missing and use alternate internal clock.
	-- |         |  25 | 7:0  | NUMBER_OF_ADCS              | Number of ADC channels implemented in this design |
	-- |         |  26 | 7:0  | ADC_BITS_PER_SAMPLE         | Number of bits in an ADC sample |
	-- |         |  27 | 7:0  | adc_cal_frozen              | RfSoC ADC calibration frozen (bit 0-7 => ADC0-7) |
	-- |         |  28 | 7:0  | adc_cal_signal_detect       | RfSoC ADC calibration signal detected (bit 0-7 => ADC0-7) |
	-- |         |  29 | 7:0  | adc_or                      | RfSoC ADC overrange (bit 0-7 => ADC0-7) |
	-- |         |  30 | 7:0  | adc_ov                      | RfSoC ADC overvoltage (bit 0-7 => ADC0-7) |
	-- |         |  31 | 7:0  | (unused)                    | (unused) |
	-- |         |  32 | 7:0  | (unused)                    | (unused) |
	-- |         |  33 | 7:6  | adc_pll_lock                | ICEBoard Mezzanine PLL lock signal |
	-- |         |     | 5:0  | (unused)                    | |
	-- |         |  34 | 7:0  | cmd_packet_counter          | Number of command packets received |
	-- |         |  35 | 7:0  | rply_packet_counter         | Number of replies sent |
	-- |         |  36 | 7:0  | (unused)                    | (unused) |
	-- |         |  37 |  7   | core_reg_wr_en              | (debug) High when writing to the core register is allowed |
	-- |         |     |  6   | bp_gpio_int_in              | IceBoard I/O |
	-- |         |     |  5   | gpio_irq_in                 | IceBoard I/O |
	-- |         |     |  4   | flash_cs_in                 | IceBoard I/O |
	-- |         |     |  3   | uart_tx_in                  | IceBoard I/O |
	-- |         |     |  2   | uart_rx_in                  | IceBoard I/O |
	-- |         |     |  1   | gpio_rst_in                 | IceBoard I/O |
	-- |         |     |  0   | arm_irq_in                  | IceBoard I/O |
	-- |         |  38 | 7:0  | adc_cm_ov                   | RfSoC ADC common mode ovevoltage (bit 0-7 => ADC0-7) |
	-- |         |  39 | 7:0  | adc_cm_uv                   | RfSoC ADC common mode undervoltage (bit 0-7 => ADC0-7) |
	-- |         |  40 | 7:0  | adc_ot1                     | RfSoC ADC over threshold 1 (bit 0-7 => ADC0-7) |
	-- |         |  41 | 7:0  | adc_ot2                     | RfSoC ADC over threshold 2 (bit 0-7 => ADC0-7) |
	-- |         |  42 | 7:4  | CT_LEVEL                    | Corner-turn level |
	-- |         |     | 3:0  | CT_TYPE                    | Corner-turn type |
	-- |         |  43 | 3:0  | FFT_TYPE                    | FFT type |
	-- |         |     | 7:4  | (unused)                    | |
	--  ------------------------------------------------------------------------------
	--

	-- CONTROL Byte 0: Buck converter sync enable, channelizer clock source, various resets

	ctrl_flag_global_trig      <= control_bytes(0)(7);
	ctrl_flag_buck_sync_enable <= control_bytes(0)(6);
	chan_clk_reset_async       <= control_bytes(0)(5);
	chan_clk_sel            <= control_bytes(0)(4);
	adcdaq_reset_async         <= control_bytes(0)(3);
	adc_rst                    <= reverse_bits_and_dir(control_bytes(0)(NUMBER_OF_ADC_BOARDS - 1 downto 0));

	-- CONTROL Byte 1: Buck converter switching frequency control

	ctrl_flag_buck_clk_div <= unsigned(control_bytes(1));

	-- CONTROL Byte 2: LCD control

	lcd_gen: if IMPLEMENT_LCD generate
		lcd_e  <= control_bytes(2)(7);
		lcd_rs <= control_bytes(2)(6);
		lcd_rw <= control_bytes(2)(5);
		lcd_db <= control_bytes(2)(3 downto 0);
	else generate -- make sure the outputs are driven while the associated bsb_regs logic is synthesized out
		lcd_e  <= '0';
		lcd_rs <= '0';
		lcd_rw <= '0';
		lcd_db <= (others => '0');
	end generate lcd_gen;

	-- CONTROL Byte 3: Various reset and clock selection controls

	user_reset          <= '0';
	blinker_reset       <= control_bytes(3)(7);
	chan_reset_async    <= control_bytes(3)(6);
	corr_reset_async    <= control_bytes(3)(5);
	ctrl_reset_trig     <= control_bytes(3)(4);
	sysmon_user_reset   <= control_bytes(3)(3);
	clk10_sel           <= control_bytes(3)(2);
	pll_sync_pre        <= control_bytes(3)(1);
	sysmon_clk_enable   <= control_bytes(3)(0);

	-- CONTROL Byte 4: UDP data throttling control

	host_frame_read_rate    <= control_bytes(4)(4 downto 0);

	-- CONTROL bytes 5-12: Buck converter phases (8 phases)

	gen_sw_sync: if IMPLEMENT_SWITCHER_SYNC generate
		buck_phase <= to_slv(control_bytes(5 to 12));
	end generate gen_sw_sync;

	-- CONTROL bytes 13-15: RfSoC ADC controls

	adc_cal_freeze(0 to NUMBER_OF_ADC_FLAGS - 1) <= reverse_bits_and_dir(control_bytes(13)(NUMBER_OF_ADC_FLAGS - 1 downto 0)); -- ADC calibration freeze control
	adc_clear_or(0 to NUMBER_OF_ADC_FLAGS - 1)   <= reverse_bits_and_dir(control_bytes(14)(NUMBER_OF_ADC_FLAGS - 1 downto 0)); -- Clear ADC overrange flag
	adc_clear_ov(0 to NUMBER_OF_ADC_FLAGS - 1)   <= reverse_bits_and_dir(control_bytes(15)(NUMBER_OF_ADC_FLAGS - 1 downto 0)); -- Clear ADC overvoltage flag

	-- CONTROL bytes 16-24: Unused

	-- CONTROL bytes 25-32: Target serial number

	target_fpga_serial_number(56)          <= control_bytes(25)(0);
	target_fpga_serial_number(55 downto 0) <= to_slv(control_bytes(26 to 32));

	-- CONTROL byte 33: serial-based core register write control

	target_network_config_source <= control_bytes(33)(3 downto 2); -- "00": core reg write always enabled; "01", "10" or "11": core reg write only when target serial matches the FPGA's serial

	-- CONTROL byte 34-45: PWM control

	pwm_offset    <= to_unsigned(control_bytes(34 to 37));
	pwm_high_time <= to_unsigned(control_bytes(38 to 41));
	pwm_period    <= to_unsigned(control_bytes(42 to 45));

	-- CONTROL byte 46: PWM reset, IO for QC tests, user output 0 mux control

	pwm_soft_reset     <= control_bytes(46)(7);
	bp_gpio_int_out    <= control_bytes(46)(5);
	bp_gpio_int_oe     <= control_bytes(46)(4);
	user_mux_source(0) <= control_bytes(46)(3 downto 0);

	-- CONTROL byte 47: IceBoard IO's for QC tests

	uart_tx_oe   <= control_bytes(47)(7);
	uart_tx_out  <= control_bytes(47)(6);
	uart_rx_oe   <= control_bytes(47)(5);
	uart_rx_out  <= control_bytes(47)(4);
	gpio_rst_oe  <= control_bytes(47)(3);
	gpio_rst_out <= control_bytes(47)(2);
	arm_irq_oe   <= control_bytes(47)(1);
	arm_irq_out  <= control_bytes(47)(0);

	-- CONTROL byte 48 -- User output 3 mux control, various IO's for QC tests

	user_mux_source(3) <= control_bytes(48)(7 downto 4);
	gpio_irq_oe        <= control_bytes(48)(3);
	gpio_irq_out       <= control_bytes(48)(2);
	flash_cs_oe        <= control_bytes(48)(1);
	flash_cs_out       <= control_bytes(48)(0);


	-- CONTROL byte 49 -- User output 1 & 2 mux control

	user_mux_source(2) <= control_bytes(49)(7 downto 4);
	user_mux_source(1) <= control_bytes(49)(3 downto 0);

	-- CONTROL byte 50 -- User bits, IRIG-B delay control

	user_bit(1)       <= control_bytes(50)(7);
	user_bit(0)       <= control_bytes(50)(6);

	-- STATUS Byte 0

	status_bytes(0)(7)          <= user_data_valid;
	status_bytes(0)(6 downto 0) <= to_slv(COOKIE, 7);

	-- STATUS Byte 1 - ADC data frame geometry

	status_bytes(1)(4 downto 0) <= to_slv(LOG2_SAMPLES_PER_FRAME, 5); -- 16384=14
	status_bytes(1)(7 downto 5) <= to_slv(LOG2_SAMPLES_PER_WORD, 3);  -- 2: 4 samples/word, 3: 8 samples/word

	-- STATUS Byte 2

	status_bytes(2) <= to_slv(NUMBER_OF_CHANNELIZERS, 8);

	-- STATUS Byte 3

	status_bytes(3) <= to_slv(NUMBER_OF_CORRELATORS, 8);

	-- STATUS Byte 4-6

	status_bytes(4) <= to_slv(NUMBER_OF_CHANNELIZERS_TO_CORRELATE, 8);
	status_bytes(5) <= to_slv(NUMBER_OF_CHANNELIZERS_WITH_FFT, 8);
	status_bytes(6) <= to_slv(NUMBER_OF_GPU_LINKS, 8);

	-- STATUS Bytes 7-10

	status_bytes(7 to 10) <= to_slv8_array(firmware_timestamp); -- ** ToDo: still used by Python, but redundant with core regs.

	-- STATUS Bytes 11: Platform ID

	status_bytes(11) <= to_slv(platform_type_enum'pos(PLATFORM_TYPE), 8);

	-- STATUS Bytes 12-19: FPGA serial number

	status_bytes(12)(7 downto 1) <= (others => '0');
	status_bytes(12)(0)          <= fpga_serial_number(56);
	status_bytes(13 to 19)       <= to_slv8_array(fpga_serial_number(55 downto 0));

	-- STATUS Bytes 20-21: Corner-turn engine configuration Part 1

	status_bytes(20) <= to_slv(NUMBER_OF_CT_INPUTS, 8);
	status_bytes(21) <= to_slv(NUMBER_OF_CT_CB1_OUTPUTS, 8);

	-- STATUS Bytes 22-23: Protocol version

	status_bytes(22 to 23) <= to_slv8_array(to_slv(PROTOCOL_VERSION, 16));

	-- STATUS Bytes 24: Channelizer clock source

	status_bytes(24) <= to_slv(CHANNELIZERS_CLOCK_SOURCE, 8);

	-- STATUS Bytes 25

	status_bytes(25) <= to_slv(NUMBER_OF_ADCS, 8);

	-- STATUS Bytes 26

	status_bytes(26) <= to_slv(ADC_BITS_PER_SAMPLE, 8);

	-- STATUS Bytes 27-30: ADC flags

	status_bytes(27)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_cal_frozen(0 to NUMBER_OF_ADC_FLAGS - 1));        -- ADC calibration frozen flags (for 8 ADCs)
	status_bytes(28)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_cal_signal_detect(0 to NUMBER_OF_ADC_FLAGS - 1)); -- ADC calibration signal detect flags (for 8 ADCs)
	status_bytes(29)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_or(0 to NUMBER_OF_ADC_FLAGS - 1));
	status_bytes(30)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_ov(0 to NUMBER_OF_ADC_FLAGS - 1));

	-- STATUS Bytes 31-32

	status_bytes(31) <= (others => '0'); -- Unused
	status_bytes(32) <= (others => '0'); -- Unused

	-- STATUS Bytes 33: FMC PLLs

	status_bytes(33)(7 downto 8 - NUMBER_OF_ADC_BOARDS) <= reverse_bits_and_dir(adc_pll_lock);

	-- STATUS Bytes 34-35: Command/replay Packet counters

	status_bytes(34) <= cmd_packet_counter;
	status_bytes(35) <= rply_packet_counter;

	-- STATUS Byte 36 - Corner-turn engine config Part 2

	status_bytes(36) <= (others => '0'); -- Unused

	-- STATUS Byte 37: IceBoard Extra I/Os

	status_bytes(37)(0) <= arm_irq_in;
	status_bytes(37)(1) <= gpio_rst_in;
	status_bytes(37)(2) <= uart_rx_in;
	status_bytes(37)(3) <= uart_tx_in;
	status_bytes(37)(4) <= flash_cs_in;
	status_bytes(37)(5) <= gpio_irq_in;
	status_bytes(37)(6) <= bp_gpio_int_in;
	status_bytes(37)(7) <= core_reg_wr_en; -- debug

	-- STATUS Bytes 38-41: More ADC flags (RfSoC)

	status_bytes(38)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_cm_ov(0 to NUMBER_OF_ADC_FLAGS - 1)); -- ADC common mode overflow for each ADC
	status_bytes(39)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_cm_uv(0 to NUMBER_OF_ADC_FLAGS - 1)); -- ADC common mode underflow for each ADC
	status_bytes(40)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_ot1(0 to NUMBER_OF_ADC_FLAGS - 1));   -- ADC over threshold 1 for each ADC
	status_bytes(41)(NUMBER_OF_ADC_FLAGS - 1 downto 0)  <= reverse_bits_and_dir(adc_ot2(0 to NUMBER_OF_ADC_FLAGS - 1));   -- ADC over threshold 2 for each ADC

	-- STATUS Byte 42 - Corner-turn engine config Part 3

	status_bytes(42)(3 downto 0) <= to_slv(ct_type_enum'POS(CT_TYPE), 4);
	status_bytes(42)(7 downto 4) <= to_slv(CT_LEVEL, 4);

	-- STATUS Byte 43 - FFT config Part 1

	status_bytes(43)(3 downto 0) <= to_slv(fft_type_enum'POS(FFT_TYPE), 4);


	-----------------------------------------------------------------------------------
	-- Memory-Mapped interface
	-----------------------------------------------------------------------------------
	-- Instantiates a memory-mapped interface to the control and status bytes
	bsb_regs0: entity work.bsb_regs
		generic map (
			NUMBER_OF_CONTROL_BYTES => control_bytes'Length(1), -- Length of array in the first dimension: number of bytes
			NUMBER_OF_STATUS_BYTES  => status_bytes'Length(1),
			DEFAULT_CONTROL_BYTES   => ('0' & to_std_logic(BUCK_SYNC_ENABLE) & "010000" & -- Byte 0
			                      to_slv(BUCK_CLK_DIVIDE_FACTOR, 8) & -- Byte 1
			                      X"00" & -- Byte 2: LCD
			                      X"61" & -- Byte 3: Reset and clock control (bit 0: SYSMON clock enabled)
			                      X"14" & -- Byte 4: HOST_FRAME_READ_RATE
			                      X"FEDCBA9876543210" & -- Bytes 5-12: Buck sync phases
			                      X"00_00_00" & -- Byte 13-15: ADC cal freeze, adc_or_clear, adc_ov_clear
			                      X"00_00_00_00_00_00_00_00_00" & -- Bytes 16-24: Unused
			                      X"0000000000000000" & -- Bytes 25-32: Target FPGA ID
			                      X"00" & -- Byte 33: Core reg write mode
			                      X"00000000_0002faf0_0005f5e1" & -- Bytes 34-45: PWM offset/high time/period
			                      X"00" & -- Byte 46: PWM reset, IO for QC tests, user output 0 mux control
			                      X"00" & -- Byte 47: IceBoard IO's for QC tests
			                      X"00" & -- Byte 48: User output 3 mux control, various IO's for QC tests
			                      X"89" & -- Byte 49: User output 1 & 2 mux control
			                      X"00"), -- Byte 50: User bits
			RAM_DATA_WIDTH          => 8, -- 8 or 16 bits
			RAM_ADDR_WIDTH          => 5 + 2,  -- 6 bits (32 register words) + 2 bits (4 bytes per word)
			RAM_LATENCY             => 1
		)
		port map (
			-- Control interface (command and reply stream buses)
			s_axis_bsb_tdata => s_axis_bsb_tdata,
			s_axis_bsb_tvalid => s_axis_bsb_tvalid,
			s_axis_bsb_tlast => s_axis_bsb_tlast,
			s_axis_bsb_tready => s_axis_bsb_tready,
			m_axis_bsb_tdata => m_axis_bsb_tdata,
			m_axis_bsb_tvalid => m_axis_bsb_tvalid,
			m_axis_bsb_tlast => m_axis_bsb_tlast,
			m_axis_bsb_tready => m_axis_bsb_tready,
			bsb_clk          => bsb_clk,
			bsb_rst          => bsb_rst,

			control_bytes => control_bytes,
			status_bytes  => status_bytes,

			ram_din   => bsb_core_din,
			ram_dout  => bsb_core_dout,
			ram_addr  => bsb_core_addr,
			ram_wr_en => bsb_core_wr_en,
			ram_rd_en => bsb_core_rd_en
		);


	-- ctrl_reset pulse generator
	-----------------------------
	-- Generates a long pulse on ctrl_reset_pulse when a low-to-high transition is seen on ctrl_reset_trig.
	-- Operates on bsb_clk.
	ctrl_reset_blk: block
		signal ctrl_reset_trig_reg: std_logic := '0';
		signal ctrl_reset_ctr: unsigned(3 downto 0) := (others => '0');
	begin

		ctrl_reset_proc: process(all) begin
			if rising_edge(bsb_clk) then
				ctrl_reset_trig_reg <= ctrl_reset_trig;

				if all_ones(ctrl_reset_ctr) then
					ctrl_reset_pulse <= '0';
				else
					ctrl_reset_ctr <= ctrl_reset_ctr + 1;
				end if;

				if ctrl_reset_trig = '1' and ctrl_reset_trig_reg = '0' then
					ctrl_reset_pulse <= '1';
					ctrl_reset_ctr <= (others => '0');
				end if;

			end if; -- clk
		end process;

	end block ctrl_reset_blk;

	gen_armspi: if IMPLEMENT_ARM_SPI generate

		arm_spi0: entity work.arm_spi
			port map (
				-- SPI interface
				sck  => arm_spi_sck,
				miso => arm_spi_miso,
				mosi => arm_spi_mosi,
				cs_n => arm_spi_cs_n,

				-- Master bus interface
				addr => spi_addr,
				din  => spi_rdat,
				dout => spi_wdat,
				rreq => spi_rreq,
				rack => spi_rack,
				wreq => spi_wreq,
				wack => spi_wack,

				clk   => bsb_clk,
				reset => '0' -- redundant; cs_n does the same thing

			);
	end generate gen_armspi;


	-------------------------
	-- Core Register assignments
	-------------------------
	-- Register write values

	-- Register Read values
	-- Registers 0-2
	core_reg_rd_value(0) <= X"BEEFFACE";        -- (Read only) Core firmware cookie
	core_reg_rd_value(1) <= to_slv(COOKIE, 32); -- (Read only) Application firmware cookie
	core_reg_rd_value(2) <= X"00000000";        -- (Read only) Application Flags: Kintex 7

	-- Register 3
	core_reg_rd_value(3) <= firmware_crc32; -- (Read/Write with readback) Firmware CRC32, computed by the host application and stored here for future reference
	firmware_crc32       <= core_reg_wr_value(3);

	-- Registers 4-6
	core_reg_rd_value(4) <= firmware_timestamp;                           -- (Read only) Firmware timestamp, taken from the USER_ACCESS data filled in when the bitstream file was generated
	core_reg_rd_value(5) <= fpga_serial_number(31 downto 0);              -- (Read only)
	core_reg_rd_value(6) <= "0000000" & fpga_serial_number(56 downto 32); -- (Read only)

	-------------------------
	-- Application-specific registers
	-------------------------

	-- Networking configuration -- Local Rx MAC/IP/PORT numbers
	------------------------------------------------------------
	-- Register 7 - FPGA Network interface MAC address

	core_reg_rd_value(7)                     <= spi_fpga_local_mac_address(31 downto 0); -- (Read/Write with readback)
	spi_fpga_local_mac_address(31 downto 0)  <= core_reg_wr_value(7);

	-- Register 8 - FPGA Network interface MAC address and listening command port

	core_reg_rd_value(8)                     <= spi_fpga_local_mac_address(47 downto 32) & spi_fpga_local_ip_port; -- (Read/Write with readback)
	spi_fpga_local_mac_address(47 downto 32) <= core_reg_wr_value(8)(31 downto 16);
	spi_fpga_local_ip_port                   <= core_reg_wr_value(8)(15 downto 0);
	-- Register 9  - FPGA Network interface IP address
	core_reg_rd_value(9)                     <= spi_fpga_local_ip_address; -- (Read/Write with readback)
	spi_fpga_local_ip_address                <= core_reg_wr_value(9);

	-- IRIG-B timestamp registers
	-------------------------

	-- Register 10 (_IRIGB_SAMPLE0_ADDR)

	core_reg_rd_value(10)(31 downto 26) <= to_slv(pps_ctr);     -- (Read only)
	core_reg_rd_value(10)(25 downto 8)  <= ts_sample.sbs;       -- (Read only)
	core_reg_rd_value(10)(7 downto 0)   <= to_slv(ts_sample.y); -- (Read only)

	-- Register 11 (_IRIGB_SAMPLE1_ADDR)

	core_reg_rd_value(11)(31 downto 30) <= to_slv(ts_sample.source(1 downto 0)); -- (Read only)
	core_reg_rd_value(11)(29)           <= ts_sample.recent;                     -- (Read only)
	core_reg_rd_value(11)(28 downto 20) <= to_slv(ts_sample.d);                  -- (Read only)
	core_reg_rd_value(11)(19 downto 14) <= to_slv(ts_sample.h);                  -- (Read only)
	core_reg_rd_value(11)(13 downto 7)  <= to_slv(ts_sample.m);                  -- (Read only)
	core_reg_rd_value(11)(6 downto 0)   <= to_slv(ts_sample.s);                  -- (Read only)

	-- Register 12 (_IRIGB_SAMPLE2_ADDR)

	core_reg_rd_value(12)(31 downto 30) <= irig_source(1 downto 0);   -- (Read/Write with readback)
	core_reg_rd_value(12)(29)           <= manual_refclk_sample_trig; -- (Read/Write with readback)
	core_reg_rd_value(12)(28)           <= manual_event_sample_trig;  -- (Read/Write with readback)
	core_reg_rd_value(12)(27 downto 0)  <= to_slv(ts_sample.ss);      -- (Read only)
	irig_source(1 downto 0)             <= core_reg_wr_value(12)(31 downto 30);
	manual_refclk_sample_trig           <= core_reg_wr_value(12)(29);
	manual_event_sample_trig            <= core_reg_wr_value(12)(28);

	-- Register 13 (_IRIGB_TARGET0_ADDR)

	core_reg_rd_value(13)(31)          <= irig_source(2);                    -- (Read/Write with readback)
	core_reg_rd_value(13)(7 downto 0)  <= core_reg_wr_value(13)(7 downto 0); -- (Readback)
	ts_target.y                        <= unsigned(core_reg_wr_value(13)(7 downto 0));
	irig_source(2)                     <= core_reg_wr_value(13)(31);

	-- Register 14 (_IRIGB_TARGET1_ADDR)

	core_reg_rd_value(14)(31)          <= ts_before_target;                   -- (Read-only)
	core_reg_rd_value(14)(30)          <= event_sample_done;                  -- (Read only)
	core_reg_rd_value(14)(29)          <= refclk_sample_done;                 -- (Read-only)
	core_reg_rd_value(14)(28 downto 0) <= core_reg_wr_value(14)(28 downto 0); -- (Readback)
	ts_target.d                        <= unsigned(core_reg_wr_value(14)(28 downto 20));
	ts_target.h                        <= unsigned(core_reg_wr_value(14)(19 downto 14));
	ts_target.m                        <= unsigned(core_reg_wr_value(14)(13 downto 7));
	ts_target.s                        <= unsigned(core_reg_wr_value(14)(6 downto 0));

	-- Register 15 (_IRIGB_TARGET2_ADDR)

	ts_compare_enable                  <= core_reg_wr_value(15)(31);
	core_reg_rd_value(15)(31)          <= ts_compare_enable; -- (Readback)
	ts_force                           <= core_reg_wr_value(15)(30);
	core_reg_rd_value(15)(30)          <= ts_force;          -- (Readback)
	irig_pol                           <= core_reg_wr_value(15)(29);
	core_reg_rd_value(15)(29)          <= irig_pol;          -- (Readback)
	ts_target.ss                       <= unsigned(core_reg_wr_value(15)(27 downto 0));
	-- (make sure the rest of ts_target is driven to prevent warnings)
	ts_target.c                        <= (others => '0');
	ts_target.sbs                      <= (others => '0');
	ts_target.recent                   <= '0';
	ts_target.source                   <= (others => '0');
	core_reg_rd_value(15)(27 downto 0) <= core_reg_wr_value(15)(27 downto 0); -- (Readback)


	-- Register 16 (_IRIGB_EVENT_CTR_ADDR)

	core_reg_rd_value(16) <= std_logic_vector(event_sample(31 downto 0)); -- (Read-only)

	-- Registers 17 (_IRIGB_EVENT_CTR_ADDR2)

	core_reg_rd_value(17)(15 downto 0)  <= std_logic_vector(event_sample(47 downto 32)); -- (read-only)
	core_reg_rd_value(17)(31 downto 16) <= (others => '0');                              -- (read-only)

	-- Registers 18 (_SFP_CONFIG_ADDR)

	sfp_config_vector                   <= core_reg_wr_value(18); -- read-write
	core_reg_rd_value(18)               <= core_reg_wr_value(18); -- (Readback)

	-- Register 19 (_SFP_STATUS_ADDR)

	core_reg_rd_value(19)(31 downto 18) <= core_reg_wr_value(19)(31 downto 18); -- (readback)
	core_reg_rd_value(19)(17)           <= udp_tx_overflow;                     -- (Read only)
	core_reg_rd_value(19)(16)           <= udp_rx_overflow;                     -- (Read only)
	core_reg_rd_value(19)(15 downto 0)  <= sfp_status_vector;                   -- (Read-only)
	udp_stack_reset                     <= core_reg_wr_value(19)(31);
	ctrl_master_reset                   <= core_reg_wr_value(19)(30);

	-- Register 20 (_REMOTE_IP_PORT_ADDR) - FPGA command reply port

	spi_fpga_ch0_remote_ip_port         <= core_reg_wr_value(20)(15 downto 0);
	core_reg_rd_value(20)(15 downto 0)  <= spi_fpga_ch0_remote_ip_port; -- (Readback)

	-- Register 21 (_IRIGB_REFCLK_SAMPLE)

	core_reg_rd_value(21)             <= std_logic_vector(refclk_sample(31 downto 0)); -- read

	-- Register 22 (_IRIGB_REFCLK_SAMPLE2)
	core_reg_rd_value(22)             <= std_logic_vector(refclk_sample(63 downto 32)); -- read

	-- Data Channel networking parameters

	-- Register 23 - Data packet destination MAC address

	core_reg_rd_value(23)                         <= spi_fpga_ch1_remote_mac_address(31 downto 0); -- (Read/Write with readback)
	spi_fpga_ch1_remote_mac_address(31 downto 0)  <= core_reg_wr_value(23);

	-- Register 24 - Data packet destination MAC address and destination port

	core_reg_rd_value(24)                         <= spi_fpga_ch1_remote_mac_address(47 downto 32) & spi_fpga_ch1_remote_ip_port; -- (Read/Write with readback)
	spi_fpga_ch1_remote_mac_address(47 downto 32) <= core_reg_wr_value(24)(31 downto 16);
	spi_fpga_ch1_remote_ip_port                   <= core_reg_wr_value(24)(15 downto 0);

	-- Register 25 - Data packet destination IP address

	core_reg_rd_value(25)                    <= spi_fpga_ch1_remote_ip_address; -- (Read/Write with readback)
	spi_fpga_ch1_remote_ip_address           <= core_reg_wr_value(25);


	core_regs0: entity work.core_registers
		generic map (
			ADDRESS_MASK            => X"000000" & "------XX",
			NUMBER_OF_REGISTERS     => NUMBER_OF_CORE_REGISTERS,
			DEFAULT_REGISTER_VALUES => core_reg_default_values,
			ADDRESS_WIDTH           => 32,
			SIM                     => False -- Indicates this is running as a simulation. Used to accelerate simulations
		)
		port map (
			-- Control interface (*** JFC: to be replaced by an AXI4-Lite bus)
			s_addr => spi_addr,
			s_wdat => spi_wdat,
			s_rdat => spi_rdat,
			s_wreq => spi_wreq,
			s_wack => spi_wack,
			s_rreq => spi_rreq,
			s_rack => spi_rack,


			-- Simplified byte r/w interface
			din   => bsb_core_din,
			dout  => bsb_core_dout,
			addr  => bsb_core_addr,
			wr_en => bsb_core_wr_en and core_reg_wr_en, -- write only if we match the serial number
			rd_en => bsb_core_rd_en,

			-- Register interface
			reg_wr_value => core_reg_wr_value,
			reg_rd_value => core_reg_rd_value,

			clk => bsb_clk -- Clocks both control and register interface
		);

	-----------------------
	-- IRIG-B decoder
	-----------------------
	-- irig_vect <=  sync_in & time_in & '0' & '0'; -- Combine all irig signal source in a single vector

	irigb_decoder0: entity work.irigb_decoder
		port map (
			clk_200mhz => clk200,
			irig       => irigb_mux_in,
			source     => unsigned(irig_source),
			pol        => irig_pol,
			pps        => pps_int,
			ts         => ts
		);

	irigb_before_target <= ts_before_target;

	irigb_comparator0: entity work.irigb_comparator
		port map (
			current_ts    => ts,
			target_ts     => ts_target,
			compare_en    => ts_compare_enable,
			force_sync    => ts_force,
			before_target => ts_before_target, -- Is '1' when current time is before the target time, and '0' when it is equal of after. There is 7 clocks latency compared to current time input.
			clk_200mhz    => clk200
		);

	irigb_encoder0: entity work.irigb_encoder
		port map (
			clk_200mhz => clk200,
			ts_out     => irigb_out
		);


	irigb_pps <= pps_int;

	-----------------------
	-- IRIG-B Time capture
	-----------------------
	--
	-- This process is used to capture the IRIG-B time and count the PPS pulses.
	-- IRIG-B capture is triggered either by capturing the reference clock counter
	-- or by capturing the event/frame event.
	--
	-- `event_ts_sample_trig` is handled by the event/frame capture logic, which operates
	-- on on the event_ctr_clk (chan_clk(0), 200 MHz derived from the ADC or
	-- multi-phase PLL).
	--
	--
	-- ts_sample_trig10 is handled by the refclk counter capture logic, which is
	-- clocked on clk10.
	--
	-- This process operates in the clk200 clock domain. Ultimately all the
	-- trigger clocks are derived from clk10, but they have an unknown phase. So
	-- he have to deal with clock domain crossing on the trigger.
	--
	-- Triggering is done by inverting the state of `event_ts_sample_trig` or
	-- `ts_sample_trig10`. The capture is done when  the signal differ from the
	-- correspnding acknowledge bit. The acknowledge bit is then set to the
	-- trigger signal to indicate that the caapture is done.
	--
	-- Note that the acknowledge signals are on clk200, not on the clock of their
	-- corresponding trigger.
	--
	irigb_capture_blk: block
		signal ts_sample_refclk_trig_in_resync: std_logic;
		signal ts_sample_event_trig_in_resync: std_logic;
		signal pps_int_dly: std_logic;
	begin

		-- Synchronize the trigger signal from the 10 MHz manual/refclk trigger to the clk200 irigb clock
		refclk_trig_cdc0: xpm_cdc_single
			generic map (
				SRC_INPUT_REG => 0
			)
			port map (
				src_clk  => clk10, -- source clock provided (even with SRC_INPUT_REG=0) so XPM can generate proper max-delay timing constraints
				src_in   => ts_sample_refclk_trig_in,
				dest_clk => clk200,
				dest_out => ts_sample_refclk_trig_in_resync
			);


		-- Synchronize the trigger signal from the frame/event clock to the clk200 irigb clock
		event_trig_cdc0: xpm_cdc_single
			generic map (
				SRC_INPUT_REG => 0
			)
			port map (
				src_clk  => event_ctr_clk, -- source clock provided so XPM can generate proper max-delay timing constraints
				src_in   => ts_sample_event_trig_in,
				dest_clk => clk200,
				dest_out => ts_sample_event_trig_in_resync
			);

		irigb_ctr_proc: process(all) begin
			if rising_edge(clk200) then
				-- Count the pps pulses on the rising edge of the PPS signal. This
				-- is used mainly for debugging. This counter is never resetted.
				pps_int_dly <= pps_int;

				if pps_int = '1' and pps_int_dly = '0' then
					pps_ctr <= pps_ctr + 1;
				end if;

				-- Sample the IRIG-B timestamp when the event or refclk triggers change state
				ts_sample_event_trig_out <= ts_sample_event_trig_in_resync;
				ts_sample_refclk_trig_out <= ts_sample_refclk_trig_in_resync;
				if ts_sample_event_trig_in_resync /= ts_sample_event_trig_out or
	 ts_sample_refclk_trig_in_resync /= ts_sample_refclk_trig_out then
					ts_sample <= ts; -- register the current IRIG-B time
				end if;
			end if;  -- if clk200
		end process;

	end block irigb_capture_blk;

	--------------------------------
	-- Event (frame) counter capture
	--------------------------------
	-- On the rising edge of manual_event_sample_trig, we arm the trigger. When the end
	-- of frame is detected, we enable the sampling to capture the frame counter
	-- and the timestamp on the first sample of the nest frame. The capture is
	-- also enabled after reset so we capture the time of the first word of the
	-- first frame after reset.
	--
	-- Typically:
	--    event_ctr_en <= axis_adc_tvalid(0);
	--    event_ctr_inc <= axis_adc_tlast(0);
	--
	event_capture_blk: block
		signal event_ctr: unsigned(47 downto 0);

		signal ts_sample_event_trig_out_resync: std_logic;
		signal manual_event_sample_trig_dly: std_logic;
		signal event_sample_done_int: std_logic;
		signal event_sample_en: std_logic;
		signal event_sample_arm: std_logic;
	begin

		-- Synchronize the trigger signal from the 10 MHz manual/refclk trigger to the clk200 irigb clock
		ts_trig_cdc0: xpm_cdc_single
			generic map (
				SRC_INPUT_REG => 0
			)
			port map (
				src_clk  => clk200, -- source clock provided so XPM can generate proper max-delay timing constraints
				src_in   => ts_sample_event_trig_out,
				dest_clk => event_ctr_clk,
				dest_out => ts_sample_event_trig_out_resync
			);


		event_proc: process(all) begin
			if rising_edge(event_ctr_clk) then
				-- Capture the event info
				if event_ctr_en then -- when tvalid=1
					-- Count events
					if event_ctr_inc then
						event_ctr <= event_ctr + 1;
					end if;
					-- Sample event
					event_sample_en <= '0'; -- Single clock pulse. Overriden below.
					if event_sample_en then
						event_sample <= event_ctr;
						event_sample_done_int <= '1';
						ts_sample_event_trig_in <= not ts_sample_event_trig_in; -- cause a transition to indicate that the timestamp should be sampled now
					end if;
				end if;


				if not manual_event_sample_trig then
					event_sample_done_int <= '0';
				end if;

				event_sample_done <= to_std_logic(event_sample_done_int = '1' and ts_sample_event_trig_in = ts_sample_event_trig_out_resync);

				-- Arm the sampling at the rising edge of manual_event_sample_trig
				manual_event_sample_trig_dly <= manual_event_sample_trig;
				if manual_event_sample_trig = '1' and manual_event_sample_trig_dly = '0' then
					event_sample_arm <= '1';
				elsif event_sample_arm = '1' and event_ctr_en = '1' and event_ctr_inc = '1' then
					event_sample_arm <= '0';
					event_sample_en <= '1';
				end if;

				if event_ctr_reset = '1' then
					event_ctr <= (others => '0');
					event_sample_arm <= '0';
					event_sample_en <= '1'; -- sample the first incoming frame after reset
				end if;
			end if; -- CLK
		end process;

	end block event_capture_blk;

	--------------------------------------
	-- 10 MHz reference clock time capture
	--------------------------------------
	-- Count the reference clock cycles and capture the current count on the
	-- rising edge of `manual_refclk_sample_trig`. A reference counter capture also
	-- automaatically triggers the IRIB-time capture.
	--
	-- The 10 MHz clock cycles in a free-running counter. This is our
	-- internal time reference, independent from the data frames, and is not
	-- affected by sync. The 10 MHz clock might come from a maser, and is not
	-- necessarily perfectly aligned to the IRIG-B time that is sent by the GPS.
	--
	-- The process also capture the current reference clock counter and IRIG-B
	-- when a rising edge is seen on `manual_refclk_sample_trig`. `refclk_sample_done`
	-- will go high (on the clk10 clock) when the IRIG-B has finished sampling
	-- both the counter AND the IRIG-B (sampling the counter is instantaneous so
	-- we don`t have to worry about synchronizing this one). Note that this does
	-- not guarantee that the IRIG-B is valid, just that the timestamp was
	-- registered properly and is stable and ready for reading. You have to check
	-- the timestamp flags to check if the time was updated lately.
	--
	-- To be clear: the capture is done at any time - it is not synchronized to a frame/event.
	--
	-- The IRIG-B sampling happens a few clocks after the counte capture due to the synchronization regitering.
	-- This can be used to obtain a correspondance between the maser time (as
	-- represented by the reference counter) and the GPS time (as obtained by the
	-- IRIG-B capture)
	--
	refclk_capture_blk: block is
		signal manual_refclk_sample_trig_resync: std_logic;
		signal manual_refclk_sample_trig_dly: std_logic;
		signal ts_sample_refclk_trig_out_resync: std_logic;
		signal refclk_ctr: unsigned(63 downto 0);
	begin

		-- Synchronize the manual trigger signal to the 10 MHz clock
		man_trig_cdc0: xpm_cdc_single
			generic map (
				SRC_INPUT_REG => 0
			)
			port map (
				src_clk  => bsb_clk, -- source clock provided (even with SRC_INPUT_REG=0) so XPM can generate proper max-delay timing constraints
				src_in   => manual_refclk_sample_trig,
				dest_clk => clk10,
				dest_out => manual_refclk_sample_trig_resync
			);
		-- Synchronize the trigger feedback signal to the 10 MHz clock
		ts_trig_cdc0: xpm_cdc_single
			generic map (
				SRC_INPUT_REG => 0
			)
			port map (
				src_clk  => clk200, -- source clock provided so XPM can generate proper max-delay timing constraints
				src_in   => ts_sample_refclk_trig_out,
				dest_clk => clk10,
				dest_out => ts_sample_refclk_trig_out_resync
			);

		refclk_capture_proc: process(all) begin
			if rising_edge(clk10) then
				-- Count the 10 MHz clocks continuously
				refclk_ctr <= refclk_ctr + 1;

				-- Capture the counter value on the rising edge of `manual_refclk_sample_trig`.
				-- This automatically triggers capture of the IRIG-B time (about 2xclk200 later)`

				manual_refclk_sample_trig_dly <= manual_refclk_sample_trig_resync;
				if manual_refclk_sample_trig_resync = '1' and manual_refclk_sample_trig_dly = '0' then
					refclk_sample <= refclk_ctr; -- register the current counter
					ts_sample_refclk_trig_in <= not ts_sample_refclk_trig_in; -- triggers the sampling of the IRIG-B time
					refclk_sample_done <= '0';
				else
					refclk_sample_done <= to_std_logic(ts_sample_refclk_trig_in = ts_sample_refclk_trig_out_resync);
				end if;
			end if; -- CLK
		end process;

	end block refclk_capture_blk;


	-- PLL sync
	pll_sync <= pll_sync_pre;

	-- User muxed output selection
	user_gen: for i in 0 to 3 generate
		user_mux_out(i) <= user_mux_in(to_integer(unsigned(user_mux_source(i))));
		user_mux_oe(i)  <= '0' when signed(user_mux_source(i)) = -1 else '1';
	end generate user_gen;

	-- Implement USR_ACCESS for VIRTEX6-based platforms
	usraccess_v6: if FPGA_SERIES = VIRTEX6 generate

		usr_access0: USR_ACCESS_VIRTEX6
			port map (
				cfgclk    => open, -- 1-bit Configuration Clock output
				data      => firmware_timestamp, -- 32-bit Configuration Data output
				datavalid => user_data_valid -- 1-bit Active high data validoutput
			);
	end generate usraccess_v6;

	-- Implement USR_ACCESS for 7-series platforms

	usraccess_7: if FPGA_SERIES = KINTEX7 or FPGA_SERIES = ULTRASCALEPLUS generate

		usr_access0: USR_ACCESSE2
			port map (
				cfgclk    => open, -- 1-bit Configuration Clock output
				data      => firmware_timestamp, -- 32-bit Configuration Data output
				datavalid => user_data_valid -- 1-bit Active high data validoutput
			);
	end generate usraccess_7;

	gen_dna7: if FPGA_SERIES = KINTEX7 generate

		dna0: DNA_PORT
			generic map (
				SIM_DNA_VALUE => X"000000000000000" -- Specifies a sample 57-bit DNA value for simulation
			)
			port map (
				dout  => dna_dout, -- 1-bit output: DNA output data.
				clk   => dna_clk, -- 1-bit input: Clock input.
				din   => '0', -- 1-bit input: User data input pin.
				read  => dna_read, -- 1-bit input: Active high load DNA, active low read input.
				shift => dna_shift -- 1-bit input: Active high shift enable input.
			);
	end generate gen_dna7;

	gen_dnaup: if FPGA_SERIES = ULTRASCALEPLUS generate
		-- The core currently reads only 57 bits
		dna0: DNA_PORTE2
			port map (
				dout  => dna_dout, -- 1-bit output: DNA output data.
				clk   => dna_clk, -- 1-bit input: Clock input.
				din   => '0', -- 1-bit input: User data input pin.
				read  => dna_read, -- 1-bit input: Active high load DNA, active low read input.
				shift => dna_shift -- 1-bit input: Active high shift enable input.
			);
	end generate gen_dnaup;


	-- Read the 57-bit DNA
	dna_proc: process(all) begin
		if rising_edge(dna_clk) then
			dna_read <= '0';
			if dna_read = '0' and dna_shift = '1' then -- when data is ready and we have not finished shifting
				fpga_serial_number <= std_logic_vector(shift_left(unsigned(fpga_serial_number), 1));
				fpga_serial_number(0) <= dna_dout;
				dna_ctr <= dna_ctr - 1;
				if dna_ctr = 0 then
					dna_shift <= '0';
				end if;
			end if;
		end if;
	end process;

	network_setup_proc: process(all) begin
		if rising_edge(bsb_clk) then
			-- Set core_reg_wr_en to conditionally enable writing to the core registers.
			-- When target_network_config_source="00", core register writes are always allowed.
			-- When target_network_config_source/="00", core register writes are allowed only if the target FPGA serial number matches the actual FPGA serial number.
			-- This feature allows the networking parameters of one specific board to be configured by
			--   1) broadcast a write command to configure the target board FPGA serial number and set target_network_config_source to "01"
			--   2) broadcast write commands to set the networking parameters; only the target board will accept the configuration
			-- The serial number of all FPGAs on the network can be obtain through a broadcast read command. Further board information (board model, serial number, slot number etc) can be obtained from GPIO and I2C acceses.
			-- This provides a simple way to setup the networking parameters of the FPGAs without requiring an on-board network-enabled processor.

			core_reg_wr_en <= to_std_logic(fpga_serial_number = target_fpga_serial_number or target_network_config_source = "00");


			-- FPGA network interface addresses
			local_mac_addr     <= spi_fpga_local_mac_address;
			local_base_ip_addr <= spi_fpga_local_ip_address;

			-- Control Channel(UDP Channel 0) parameters
			local_base_ip_port <= spi_fpga_local_ip_port; -- command listening port
			-- Command reply IP and MAC: hardwired to be the same as the the source addres of the previous incoming command packets
			remote_ip_port0  <= spi_fpga_ch0_remote_ip_port; -- command reply destination port

			-- Data Channel (UDP Channel 1) parameters
			remote_ip_addr1     <= spi_fpga_ch1_remote_ip_address; -- Data packet destination IP addres
			remote_mac_addr1    <= spi_fpga_ch1_remote_mac_address; -- Data packets destination MAC address
			remote_ip_port1     <= spi_fpga_ch1_remote_ip_port; -- Data packets destination port

		end if;
	end process;

	gen_sw_sync_proc: if IMPLEMENT_SWITCHER_SYNC generate
		-- Generates the buck switching regulator synchronization signal
		buckproc: process(all) begin
			if rising_edge(clk200) then
				if not ctrl_flag_buck_sync_enable then
					clk_ctr <= (0=> '1', others => '0');
					buck_phase_ctr <= (others => '0');
					buck_sync <= (others => '0'); -- Make sure both phases are not driving the Bucks after reset and until we enable the buck sync
				else
					if (clk_ctr = ctrl_flag_buck_clk_div) then
						clk_ctr <= (0=> '1', others => '0');
						buck_phase_ctr <= buck_phase_ctr + 1;
					else
						clk_ctr <= clk_ctr + 1;
					end if;

					for i in 0 to NUMBER_OF_BUCK_SYNC_LINES - 1 loop
						if unsigned(buck_phase(4 * i + 3 downto 4 * i)) = buck_phase_ctr then
							buck_sync(i) <= '1';
						elsif unsigned(buck_phase(4 * i + 3 downto 4 * i)) = buck_phase_ctr + 8 then -- wraps around
							buck_sync(i) <= '0';
						end if;
					end loop;

				end if; -- RST
			end if; -- CLK
		end process;

	end generate gen_sw_sync_proc;


	gen_fan: if IMPLEMENT_FAN generate
		------ Fan process  ------------------
		-- Debounce the fan tachometer signal
		-- Implements the ML605 Tachometer readout with debouncing and provides a logic signal toggling at half the fan rotation frequency.
		-- The tachometer signal pulses twices a revolution, but each pulse is very noisy.
		-- This process implements some basic debouncing so we can read the rotation speed correctly using the general frequency counter
		--
		-- There is no RST clause since this is reset as soon as the first chang eof tachymeter value is encountered, which is needed anyways for an accurate frequency count.
		fanproc: process(all) begin
			if rising_edge(clk200) then
				if fan_tach /= fan_tach_target then
					fan_tach_ctr <= (others => '0');
				elsif signed(fan_tach_ctr) = -1 then -- if we reach the end of the counter without encountering a change in the signal state
					fan_tach_target <= not fan_tach_target; -- toggle the target bit. The loop will now look for that target to be stable
					fan_tach_ctr <= (others => '0');
					if fan_tach_target then -- generate a divide by 2 frequency signal to be used by the frequency counter
						fan_tach_div2_int <= not fan_tach_div2_int;
					end if;
				else
					fan_tach_ctr <= fan_tach_ctr + 1;
				end if;
			end if; -- CLK
		end process;

		fan_tach_div2 <= fan_tach_div2_int;
		fan_pwm       <= '1'; -- Fan is always operating at 100% speed
	end generate gen_fan;


	------ PWM generator process  ------------------
	pwm_proc: process(all) begin
		if rising_edge(pwm_clk) then
			if pwm_ctr_en then
				pwm_ctr <= pwm_ctr + 1;
				if not pwm_active then
					if pwm_ctr = pwm_offset then
						pwm_active <= '1';
						pwm_ctr <= (others => '0');
						pwm_out <= '1';
					end if;
				else
					if pwm_ctr = pwm_high_time then
						pwm_out <= '0';
					elsif pwm_ctr = pwm_period then
						pwm_ctr <= (others => '0');
						pwm_out <= '1';
					end if;
				end if;
			end if; -- if ctr_en
			-- Synchronous Reset
			if pwm_reset or pwm_soft_reset then
				pwm_active <= '0';
				pwm_ctr <= (others => '0');
				pwm_out <= '0';
			end if;
		end if; -- CLK
	end process;

end architecture impl;

