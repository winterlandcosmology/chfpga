----------------------------------------------------------------------------------
-- Company: McGill University
-- Engineer: JF Cliche
--
-- Create Date:   Q1 2011
-- Design Name:  chFPGA
-- Module Name:    Package
-- Project Name: CHIME
-- Target Devices: Virtex 6, Kintex 7
-- Tool versions: ISE 14.4, Vivado 2012.4
-- Description: Implements module and global variable definitions
--
-- Dependencies:
--
-- Revision:
-- 2011-09-14 JFC: Created this header block
-- 2013-01-28 JFC: Modified chFPGA_V6 to chFPGA


----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.ALL;
use IEEE.math_real.all; -- needed for ceil()
use IEEE.math_complex.all;
use IEEE.STD_LOGIC_MISC.ALL; -- for or_reduce()
use std.textio.all;
use IEEE.std_logic_textio.all;

-------- chFPGA Package ------------

-- Defines the system-level constants and data types, declares the components used in the system, and provide support functions and procedures
package chFPGA_Package is

type slv_array is array (NATURAL RANGE <>) of std_logic_vector; -- VHDL2008 only
type signed_array is array (NATURAL RANGE <>) of signed; -- VHDL2008 only
type unsigned_array is array (NATURAL RANGE <>) of unsigned; -- VHDL2008 only
type integer_array is array (natural range <>) of integer;
type integer_array_array is array (natural range <>) of integer_array; -- Can be sliced
type integer_2d_array is array (natural range <>, natural range <>) of integer; -- Can't be sliced
type bool_array is array (natural range <>) of boolean;
type bool_array_array is array (natural range <>) of bool_array; -- Can be sliced

-- generic types and subtypes
subtype Byte is std_logic_vector(7 downto 0);
subtype slv is std_logic_vector;
subtype slv1 is std_logic_vector(0 downto 0);
subtype slv2 is std_logic_vector(1 downto 0);
subtype slv3 is std_logic_vector(2 downto 0);
subtype slv4 is std_logic_vector(3 downto 0);
subtype slv5 is std_logic_vector(4 downto 0);
subtype slv6 is std_logic_vector(5 downto 0);
subtype slv7 is std_logic_vector(6 downto 0);
subtype slv8 is std_logic_vector(7 downto 0);
subtype slv9 is std_logic_vector(8 downto 0);
subtype slv10 is std_logic_vector(9 downto 0);
subtype slv12 is std_logic_vector(11 downto 0);
subtype slv16 is std_logic_vector(15 downto 0);
subtype slv17 is std_logic_vector(16 downto 0);
subtype slv18 is std_logic_vector(17 downto 0);
subtype slv19 is std_logic_vector(18 downto 0);
subtype slv20 is std_logic_vector(19 downto 0);
subtype slv24 is std_logic_vector(23 downto 0);
subtype slv32 is std_logic_vector(31 downto 0);
subtype slv33 is std_logic_vector(32 downto 0);
subtype slv34 is std_logic_vector(33 downto 0);
subtype slv35 is std_logic_vector(34 downto 0);
subtype slv36 is std_logic_vector(35 downto 0);
subtype slv48 is std_logic_vector(47 downto 0);
subtype slv64 is std_logic_vector(63 downto 0);
subtype slv65 is std_logic_vector(64 downto 0);
subtype slv72 is std_logic_vector(71 downto 0);
subtype slv80 is std_logic_vector(79 downto 0);
subtype slv112 is std_logic_vector(111 downto 0);
subtype slv144 is std_logic_vector(143 downto 0);
type ByteArray8 is array (0 to 7) of std_logic_vector(7 downto 0);
type ByteArray is array (NATURAL RANGE <>) of std_logic_vector(7 downto 0);



type slv2_array is array (NATURAL RANGE <>) of std_logic_vector(1 downto 0);
type slv3_array is array (NATURAL RANGE <>) of std_logic_vector(2 downto 0);
type slv4_array is array (NATURAL RANGE <>) of std_logic_vector(3 downto 0);
type slv5_array is array (NATURAL RANGE <>) of std_logic_vector(4 downto 0);
type slv6_array is array (NATURAL RANGE <>) of std_logic_vector(5 downto 0);
type slv7_array is array (NATURAL RANGE <>) of std_logic_vector(6 downto 0);
type slv8_array is array (NATURAL RANGE <>) of std_logic_vector(7 downto 0);
type slv9_array is array (NATURAL RANGE <>) of std_logic_vector(8 downto 0);
type slv10_array is array (NATURAL RANGE <>) of std_logic_vector(9 downto 0);
type slv11_array is array (NATURAL RANGE <>) of std_logic_vector(10 downto 0);
type slv12_array is array (NATURAL RANGE <>) of std_logic_vector(11 downto 0);
type slv13_array is array (NATURAL RANGE <>) of std_logic_vector(12 downto 0);
type slv14_array is array (NATURAL RANGE <>) of std_logic_vector(13 downto 0);
type slv15_array is array (NATURAL RANGE <>) of std_logic_vector(14 downto 0);
type slv16_array is array (NATURAL RANGE <>) of std_logic_vector(15 downto 0);
type slv24_array is array (NATURAL RANGE <>) of std_logic_vector(23 downto 0);
type slv27_array is array (NATURAL RANGE <>) of std_logic_vector(26 downto 0);
type slv28_array is array (NATURAL RANGE <>) of std_logic_vector(27 downto 0);
type slv32_array is array (NATURAL RANGE <>) of std_logic_vector(31 downto 0);
type slv33_array is array (NATURAL RANGE <>) of std_logic_vector(32 downto 0);
type slv34_array is array (NATURAL RANGE <>) of std_logic_vector(33 downto 0);
type slv35_array is array (NATURAL RANGE <>) of std_logic_vector(34 downto 0);
type slv36_array is array (NATURAL RANGE <>) of std_logic_vector(35 downto 0);
type slv48_array is array (NATURAL RANGE <>) of std_logic_vector(47 downto 0);
type slv64_array is array (NATURAL RANGE <>) of std_logic_vector(63 downto 0);
type slv65_array is array (NATURAL RANGE <>) of std_logic_vector(64 downto 0);
type slv66_array is array (NATURAL RANGE <>) of std_logic_vector(65 downto 0);
type slv68_array is array (NATURAL RANGE <>) of std_logic_vector(67 downto 0);
type slv72_array is array (NATURAL RANGE <>) of std_logic_vector(71 downto 0);
type slv80_array is array (NATURAL RANGE <>) of std_logic_vector(79 downto 0);
type slv112_array is array (NATURAL RANGE <>) of std_logic_vector(111 downto 0);
type slv128_array is array (NATURAL RANGE <>) of std_logic_vector(127 downto 0);
type slv144_array is array (NATURAL RANGE <>) of std_logic_vector(143 downto 0);
type slv256_array is array (NATURAL RANGE <>) of std_logic_vector(255 downto 0);
type Word3Array is array (NATURAL RANGE <>) of std_logic_vector(2 downto 0);
type Word32Array is array (NATURAL RANGE <>) of std_logic_vector(31 downto 0);
type Word33Array is array (NATURAL RANGE <>) of std_logic_vector(32 downto 0);
type u2_array is array (NATURAL RANGE <>) of unsigned(1 downto 0);
type u3_array is array (NATURAL RANGE <>) of unsigned(2 downto 0);
type u4_array is array (NATURAL RANGE <>) of unsigned(3 downto 0);
type u8_array is array (NATURAL RANGE <>) of unsigned(7 downto 0);
type u9_array is array (NATURAL RANGE <>) of unsigned(8 downto 0);
type u10_array is array (NATURAL RANGE <>) of unsigned(9 downto 0);
type u11_array is array (NATURAL RANGE <>) of unsigned(10 downto 0);
type u12_array is array (NATURAL RANGE <>) of unsigned(11 downto 0);
type u13_array is array (NATURAL RANGE <>) of unsigned(12 downto 0);
type u16_array is array (NATURAL RANGE <>) of unsigned(15 downto 0);
type u24_array is array (NATURAL RANGE <>) of unsigned(23 downto 0);
type u48_array is array (NATURAL RANGE <>) of unsigned(47 downto 0);
type int8_array is array (NATURAL RANGE <>) of signed(7 downto 0);
type int35_array is array (NATURAL RANGE <>) of signed(34 downto 0);


-- Implement static maps (dictionaries) for lookups. See sel() to lookup.
type si_map_item is record -- string-integer map element
	key: string;
	value: integer;
end record;
type si_map is array (NATURAL RANGE <>) of si_map_item; -- string-integer map as a list of string-integer tuples

type ii_map_item is record -- integer-integer map element
	key: integer;
	value: integer;
end record;
type ii_map is array (NATURAL RANGE <>) of ii_map_item; -- string-integer map as a list of string-integer tuples


constant NULL_INTEGER_ARRAY: integer_array(1 to 0) := (others => 0);


-- Platform IDs
--
-- Is used both by the HDL source code and runtime software to identify the
-- hardware (FPGA and PCB type) on which the firmware runs
--
-- The enum position preserves the legacy integer encoding.
type platform_type_enum is (
	ML605,
	KC705,
	UNUSED,
	MGK7MB,
	ZCU111,
	CRS
	);

type platform_type_enum_array is array (natural range <>) of platform_type_enum;

-- FPGA series encoding
--
-- Dummy entries preserve the legacy integer values for the real FPGA families:
--  - 6: VIRTEX6
--  - 7: KINTEX7
--  - 8: ULTRASCALE
--  - 9: ULTRASCALEPLUS
type fpga_series_enum is (
	RESERVED0,
	RESERVED1,
	RESERVED2,
	RESERVED3,
	RESERVED4,
	RESERVED5,
	VIRTEX6,
	KINTEX7,
	ULTRASCALE,
	ULTRASCALEPLUS
	);

-- Platform information structure
type PLATFORM_INFO_STRUCT is
	record
		FPGA_SERIES: fpga_series_enum; -- indicates the series of the FPGA. Is typically used to select low level primitives
		DSP_TILE_DELTA_RPM_Y: integer; -- vertical spacing between DSP tiles in RPM coordinates
		DSP_BEL_DELTA_RPM_Y: integer; -- vertical spacing between DSPs BELs within a tile, in RPM coordinates
		BRAM_TILE_DELTA_RPM_Y: integer; -- vertical spacing between BRAM tiles in RPM coordinates
		BRAM_BEL_DELTA_RPM_Y: integer; -- vertical spacing between BRAMs BELs within a tile, in RPM coordinates
	end record;

type PLATFORM_INFO_ARRAY is array (platform_type_enum range <>) of PLATFORM_INFO_STRUCT;

-- Define platform-specific constants
constant PLATFORM_INFO: PLATFORM_INFO_ARRAY := (
	ML605 => (
		FPGA_SERIES => VIRTEX6,
		DSP_TILE_DELTA_RPM_Y => 0, -- to be defined of ever needed again
		DSP_BEL_DELTA_RPM_Y => 0,
		BRAM_TILE_DELTA_RPM_Y => 0,
		BRAM_BEL_DELTA_RPM_Y => 0
		),

	KC705 => (
		FPGA_SERIES => KINTEX7,
		DSP_TILE_DELTA_RPM_Y => 5,
		DSP_BEL_DELTA_RPM_Y => 5,
		BRAM_TILE_DELTA_RPM_Y => 5,
		BRAM_BEL_DELTA_RPM_Y => 5
		),

	UNUSED => (
		FPGA_SERIES => KINTEX7,
		DSP_TILE_DELTA_RPM_Y => 5,
		DSP_BEL_DELTA_RPM_Y => 5,
		BRAM_TILE_DELTA_RPM_Y => 5,
		BRAM_BEL_DELTA_RPM_Y => 5
		),

	MGK7MB => (
		FPGA_SERIES => KINTEX7,
		-- site spacing in slice coordinates
		--DSP_TILE_DELTA_RPM_Y => 2, -- was 10
		--DSP_BEL_DELTA_RPM_Y => 1, -- was 5
		--BRAM_TILE_DELTA_RPM_Y => 2, -- was 10
		--BRAM_BEL_DELTA_RPM_Y => 1 -- was 5

		-- site spacing in RPM_GRID coordinates
		DSP_TILE_DELTA_RPM_Y => 10,
		DSP_BEL_DELTA_RPM_Y => 5, -- DSPs within a tile are spaced by 5 RPM_Y grid units
		BRAM_TILE_DELTA_RPM_Y => 10,
		BRAM_BEL_DELTA_RPM_Y => 1 -- BRAMs within a tile are spaced by 1 RPM_Y grip unit (yeah, different from DSPs!)
		),

	ZCU111 => (
		FPGA_SERIES => ULTRASCALEPLUS,
		DSP_TILE_DELTA_RPM_Y => 10,
		DSP_BEL_DELTA_RPM_Y => 1,
		BRAM_TILE_DELTA_RPM_Y => 10,
		BRAM_BEL_DELTA_RPM_Y => 1
		),


	CRS => (
		FPGA_SERIES => ULTRASCALEPLUS,
		DSP_TILE_DELTA_RPM_Y => 10,
		DSP_BEL_DELTA_RPM_Y => 1,
		BRAM_TILE_DELTA_RPM_Y => 10,
		BRAM_BEL_DELTA_RPM_Y => 1
		)

	);

-- Hardware-related constants
constant NUMBER_OF_CHANNELIZERS_MAX: INTEGER :=16; -- Maximum number of channelizers supported by the system
constant NUMBER_OF_ADCS_MAX: INTEGER :=16; -- Maximum number of ADC inputs supported by the system

-- ------------------------------------------------------------------------------
--   Enumerations
-- ------------------------------------------------------------------------------

type clk_source_enum is (
    SYSCLK,
	SYSCLK_BUFG,
	CLK10_BUFG,
	SFP_REFCLK
	);

-- BSB Monitor & control interface type
type bsb_interface_enum is (UDP_GMII, UDP_SGMII, AXIS);

-- Capture bus interface type
type cap_interface_enum is (BSB, AXIS);

-- PHY type (1G Ethernet interface)
type phy_type_enum is (GMII, SGMII); 
type bsb_to_phy_map_type is array (bsb_interface_enum range <>) of phy_type_enum; -- converts bsb_interface_enum to phy_type_enum
type phy_clk_source_enum is (REFCLK);
type adc_type_enum IS (EV8AQ160, AXIS);

-- Channelizer clock sources and data capture engine type
type chan_clk_source_enum is (MMCM, ADC);

-- Capture engine types and info
type chan_capture_type_enum is (PROBER, UCAP);
type chan_capture_info_struct is
    record
        INPUT_WIDTH: integer;
        NUMBER_OF_SOURCES: integer;
    end record;
type chan_capture_info_type is array (chan_capture_type_enum) of chan_capture_info_struct;
constant CHAN_CAPTURE_INFO: chan_capture_info_type := (
    PROBER => (INPUT_WIDTH => 32, NUMBER_OF_SOURCES=>2),
    UCAP => (INPUT_WIDTH =>128, NUMBER_OF_SOURCES=>2)
    ); -- bit width of the capture engine input

type fft_type_enum is (NONE, CHIME, D3A, CHORD, HIRAX, HIRAX_3DSP); -- Position of enum can index the FFT_INFO array

-- Platform information structure
type fft_info_struct is
	record
		SAMPLES_PER_FRAME : integer;
		LATENCY: integer; --
		BITS_PER_SAMPLE: integer; -- Number of bits per sample
		SAMPLES_PER_WORD: integer; -- Number of ADC samples in an input word
		BITS_PER_BIN: integer; -- Number of bits per bin (Re+Im)
		BINS_PER_WORD: integer; -- Number of bins per output word
		ROTATE: boolean; -- Rotate the FFT lanes for every clock when TRUE
	end record;
type fft_info_array is array (fft_type_enum) of FFT_INFO_STRUCT;


-- Types of FFT as integers, for transient back-compatibility - to be obsoleted
constant FFT_TYPE_NONE: integer := fft_type_enum'POS(NONE);
constant FFT_TYPE_CHIME: integer := fft_type_enum'POS(CHIME);
constant FFT_TYPE_D3A: integer := fft_type_enum'POS(D3A);
constant FFT_TYPE_CHORD: integer := fft_type_enum'POS(CHORD);
constant FFT_TYPE_HIRAX: integer := fft_type_enum'POS(HIRAX);

constant FFT_INFO: FFT_INFO_ARRAY := (
	NONE => (
		SAMPLES_PER_FRAME => 0,
		LATENCY => 0,
		BITS_PER_SAMPLE => 0,
		SAMPLES_PER_WORD => 0,
		BITS_PER_BIN => 0,
		BINS_PER_WORD => 0,
		ROTATE => FALSE
		),
    CHIME => (
		SAMPLES_PER_FRAME => 2048,
		LATENCY => 3230,
		BITS_PER_SAMPLE => 8,
		SAMPLES_PER_WORD => 4,
		BITS_PER_BIN => 18+18,
		BINS_PER_WORD => 2,
		ROTATE => FALSE
		),

    D3A => (
		SAMPLES_PER_FRAME => 16384,
		LATENCY => 12533,
		BITS_PER_SAMPLE => 14,
		SAMPLES_PER_WORD => 8,
		BITS_PER_BIN => 18+18,
		BINS_PER_WORD => 4,
		ROTATE => FALSE
		),

    CHORD => (
		SAMPLES_PER_FRAME => 16384,
		LATENCY => 10452,
		BITS_PER_SAMPLE => 14,
		SAMPLES_PER_WORD => 8,
		BITS_PER_BIN => 32+32,
		BINS_PER_WORD => 4,
		ROTATE => TRUE
		),

	HIRAX => (
		SAMPLES_PER_FRAME => 2048,
		LATENCY => 3230,
		BITS_PER_SAMPLE => 8,
		SAMPLES_PER_WORD => 4,
		BITS_PER_BIN => 29+29,
		BINS_PER_WORD => 2,
		ROTATE => FALSE
		),

	HIRAX_3DSP => (
		SAMPLES_PER_FRAME => 2048,
		LATENCY => 2733,
		BITS_PER_SAMPLE => 8,
		SAMPLES_PER_WORD => 4,
		BITS_PER_BIN => 24+24,
		BINS_PER_WORD => 2,
		ROTATE => FALSE
		)
	);

-- Corner-Turn Engine types
type ct_type_enum is (NONE, BCT, UCT);
type ct_info_struct is
    record
        INPUT_WIDTH: integer; -- bit width of the ct-engine input bus
    end record;
type ct_info_array is array (ct_type_enum) of ct_info_struct;
constant CT_INFO: ct_info_array := (
    NONE => (INPUT_WIDTH => 0),
    BCT => (INPUT_WIDTH => 32), -- 2x (8+8)-bit bins
    UCT => (INPUT_WIDTH =>32) -- 4x (4+4)-bit bins
    );

constant CT_TYPE_NONE: integer := ct_type_enum'POS(NONE); -- integer representations to be obsoleted
constant CT_TYPE_BCT: integer := ct_type_enum'POS(BCT);
constant CT_TYPE_UCT: integer := ct_type_enum'POS(UCT);

-- Corner turn engine clock sources
type ct_clk_source_enum IS (BP_SHUFFLE_TXCLK, ADC_CLK, CGE_CLK322, CORR_CLK);

-- Correlator types
type corr_type_enum IS (CORR44, UCORR44, NONE);

-- real-time offload link types


type data_link_type_enum is (NONE, XGE, UPACK_CGE, RAW_CGE); -- RAW_CGE: 100G link carrying only the raw ADC streamer (no UPACK)


constant NUMBER_OF_CORRELATORS_MAX: INTEGER :=8; -- Maximum number of correlators supported by the system

-- maximum number of CMACs in a CORR44 core.  The factor of two is because CORR44 needs to process two vectors at the same time so the results are coming out as fast at the data is pushed in
constant NUMBER_OF_CMACS_MAX : integer := (NUMBER_OF_CHANNELIZERS_MAX + 1) * 2;


-- Basic system configuration
-- These global constants are defined globally in this package so they can be used by OOC modules
constant GLOBAL_SIM: boolean := FALSE;
constant GLOBAL_NUMBER_OF_GPU_LINKS: integer := 8; -- (0- NUMBER_OF_CHANNELIZERS) Number of 10Gb Ethernet links to connecto to the GPUs
constant GLOBAL_NUMBER_OF_GPU_REFCLKS: integer := 1; -- Number of Reference clocks provided for the 10GE links to the GPU




--constant FRAME_LENGTH: integer:= 2048; -- 2048 time samples per frame (1024 frame samples per frame)
--constant LOG2_FRAME_LENGTH: integer :=11; -- Number of time samples per frame. 2^11 = 2048 time samples per frame
--constant LOG2_FREQ_SAMPLES_PER_FRAME: integer :=LOG2_FRAME_LENGTH-1; -- Number of frequency samples per frame. 1/2 of the time samples as we discard negative frequencies
--constant LOG2_WORDS_PER_FRAME: integer :=LOG2_FRAME_LENGTH-2; -- Number of words per frame. One word is 4 8-bit time samples or 2 8+8-bits frequency samples.

--type frame_word_ctr_array is array (natural range <>) of unsigned(LOG2_WORDS_PER_FRAME-1 downto 0);

--	Control bus parameters
constant CTRL_CMD_BYTE_LENGTH: integer :=3; -- Number of bytes in the command word
constant CTRL_CMD_WORD_WIDTH: integer := CTRL_CMD_BYTE_LENGTH * 8; -- Number of bits in the command word
constant CTRL_CMD_BYTE_COUNT_WIDTH: integer :=2; -- number of bits requird to count the number of bytes in a command
constant CTRL_CMD_OPCODE_WIDTH: integer :=3; -- Number of bits in the opcode
constant CTRL_CMD_COUNT_WIDTH: integer:=2;
constant CTRL_CMD_ADDR_WIDTH: integer := CTRL_CMD_WORD_WIDTH - CTRL_CMD_OPCODE_WIDTH - CTRL_CMD_COUNT_WIDTH; -- Total number of address bits. The address is in the LSBs of the command word (i.e. downto 0)

-- AXI4 STREAMING data structure used for the control system (Command and Reply buses)
type AXIS8_DAT_STRUCT is -- control/data bus used to communicate from  master to slave
	record
		--DUMMY: std_logic; -- needed to cirvumvent simulator bug on VIvado 2012.4 and 2013.1. Otherwise the control bus doesnot work in simulation.
		TVALID: std_logic; -- indicates that the master is driving a valid value
		TDATA : std_logic_vector(7 downto 0); -- data from the master
		TLAST: std_logic; -- indicated that the master is driving the last byte of the frame
	end record;

type AXIS8_RDY_STRUCT is  -- control bus used to communicate from  slave to master
	record
		TREADY: std_logic; -- indicates that the slave device is ready to accept data. The transaction occurs when TREA|DY and TVALID are both '1';
	end record;

type AXIS8_DAT_STRUCT_ARRAY is ARRAY (natural range <>) of AXIS8_DAT_STRUCT;
type AXIS8_RDY_STRUCT_ARRAY is ARRAY (natural range <>) of AXIS8_RDY_STRUCT;

-- 32-bit wide AXI4 STREAMING data structure used for the time-based (4 sampels per word) and spectrum (2 samples per word) data streams
type AXIS32_DAT_STRUCT is -- control/data bus used to communicate from  master to slave
	record
		TVALID: std_logic; -- indicates that the master is driving a valid value
		TDATA : std_logic_vector(31 downto 0); -- data from the master
		TLAST: std_logic; -- indicated that the master is driving the last byte of the frame
		TUSER : std_logic_vector(3 downto 0); -- Used to transfer ancilliary information (overflows, frame info etc). Meaning is specific to each bus segments
	end record;
type AXIS32_DAT_STRUCT_ARRAY is ARRAY (natural range <>) of AXIS32_DAT_STRUCT;

type AXIS32_RDY_STRUCT is  -- control bus used to communicate from  slave to master. Not normally used since data streams flow is not handshaked
	record
		TREADY: std_logic; -- indicates that the slave device is ready to accept data. The transaction occurs when TREA|DY and TVALID are both '1';
	end record;
type AXIS32_RDY_STRUCT_ARRAY is ARRAY (natural range <>) of AXIS32_RDY_STRUCT;

-- 64-bit wide AXI4 STREAMING data structure
type AXIS64_DAT_STRUCT is -- control/data bus used to communicate from  master to slave
	record
		TVALID: std_logic; -- indicates that the master is driving a valid value
		TDATA : std_logic_vector(63 downto 0); -- data from the master
		TLAST: std_logic; -- indicated that the master is driving the last byte of the frame
		TUSER : std_logic_vector(3 downto 0); -- Used to transfer ancilliary information (overflows, frame info etc). Meaning is specific to each bus segments
	end record;
type AXIS64_DAT_STRUCT_ARRAY is ARRAY (natural range <>) of AXIS64_DAT_STRUCT;


-- 72-bit wide AXI4 STREAMING bus used for the FFT output consisting of two (18+18) bits wide frequency samples
type AXIS72_DAT_STRUCT is
	record
		TVALID: std_logic; -- indicates that the master is driving a valid value
		TDATA : std_logic_vector(71 downto 0); -- data from the master
		TLAST: std_logic; -- indicated that the master is driving the last byte of the frame
		TUSER : std_logic_vector(3 downto 0); -- Used to transfer ancilliary information (overflows, frame info etc). Meaning is specific to each bus segments
	end record;

-- 34-bit wide AXI4 STREAMING bus used for the complex multiplier output (17+17) bits
type AXIS34_DAT_STRUCT is
	record
		TVALID: std_logic; -- indicates that the master is driving a valid value
		TDATA : std_logic_vector(33 downto 0); -- data from the master
		TLAST: std_logic; -- indicated that the master is driving the last byte of the frame
		TUSER : std_logic_vector(3 downto 0); -- Used to transfer ancilliary information (overflows, frame info etc). Meaning is specific to each bus segments
	end record;
type AXIS34_DAT_STRUCT_ARRAY is ARRAY (natural range <>) of AXIS34_DAT_STRUCT;

-- 108-bit wide AXI4 STREAMING bus used for the complex accumulator output (54+54) bits
-- 1/850e6 samples/s * 2048 samples/frame * 2^(54-17) accumulated frames before overflow = 331 147 s = 92h
type AXIS108_DAT_STRUCT is
	record
		TVALID: std_logic; -- indicates that the master is driving a valid value
		TDATA : std_logic_vector(107 downto 0); -- data from the master
		TLAST: std_logic; -- indicated that the master is driving the last byte of the frame
		TUSER : std_logic_vector(3 downto 0); -- Used to transfer ancilliary information (overflows, frame info etc). Meaning is specific to each bus segments
	end record;
type AXIS108_DAT_STRUCT_ARRAY is ARRAY (natural range <>) of AXIS108_DAT_STRUCT;

-- Channelizer AXIS bus TUSER bit definitions
---------------------------------------------
-- From  ADCDAQ:
--   Bits 0-3 are overflow flags for sample 0-3 in each word
-- From FUNCGEN
-- constant TUSER_CAPTURE_BIT: INTEGER :=0; -- Set by FUNCGEN and passed downstream to indicate to the PROBER that the data should be captured if continuous capture  mode is enabled

-- Flags that are set on the last N words of each packet.
--  TLAST - 0: ADC Overflow (Downstream of FUNCGEN only)
--  TLAST - 1: FFT Overflow (Downstream of FFT only)
--  TLAST - 2: Gain Bank (Downstream of SCALER only)
-- constant TUSER_SERIAL_FLAGS_BIT: INTEGER :=3;

constant TUSER_ADC_OVERFLOW_BIT: INTEGER :=0; -- Set by SRCSEL ont he last word of a frame to indicate that ADC saturation has occured on a sample of the frame.
constant TUSER_FFT_OVERFLOW_BIT: INTEGER :=1; -- Set by SRCSEL and passed downstream to indicate to the PROBER that the data should be captured if continuous capture  mode is enabled
constant TUSER_GAINBANK_BIT: INTEGER := 2;    -- Set by scaler on last word of frame to indicate which gainbank was being employed
constant TUSER_SCALER_LOW_OVERFLOW_BIT: INTEGER :=1; -- Set by SCALER to indicate ovweflow on the sample in the Low part of the word
constant TUSER_SCALER_HIGH_OVERFLOW_BIT: INTEGER :=2; -- -- Set by SCALER to indicate ovweflow on the sample in the high part of the word
constant TUSER_EVEN_SCALER_OVERFLOW_BIT: INTEGER := TUSER_SCALER_HIGH_OVERFLOW_BIT; -- -- Set by SCALER to indicate ovweflow on the sample in the high part of the word
constant TUSER_ODD_SCALER_OVERFLOW_BIT: INTEGER := TUSER_SCALER_LOW_OVERFLOW_BIT; -- -- Set by SCALER to indicate ovweflow on the sample in the high part of the word

type FREQ_SAMPLE_STRUCT is
	record
		Re: signed(7 downto 0);
		Im: signed(7 downto 0);
	end record;
constant FREQ_SAMPLE_ZERO: FREQ_SAMPLE_STRUCT := (Re=>(others=>'0'),Im=>(others=>'0'));
type FREQ_SAMPLE_STRUCT_ARRAY is array (NATURAL RANGE <>) of FREQ_SAMPLE_STRUCT;


-- Complex number at the output of the corrleator multiplier
type COMPLEX17_STRUCT is -- (17 Re + 17 Im) = 34 bits wide combined
	record
		Re: signed(16 downto 0);
		Im: signed(16 downto 0);
	end record;
type COMPLEX17_STRUCT_ARRAY is array (NATURAL RANGE <>) of COMPLEX17_STRUCT;

-- Complex number stored in the accumulator
type COMPLEX48_STRUCT is -- (54 Re + 54 Im) = 108 bits wide combined -- maximum width of 3 RAMB18K (which is the height of the complex multiplier)
	record
		Re: signed(47 downto 0);
		Im: signed(47 downto 0);
	end record;
type COMPLEX48_STRUCT_ARRAY is array (NATURAL RANGE <>) of COMPLEX48_STRUCT;

-- Raw data capture (PROBER) frame header
constant FRAME_HEADER_BYTE_LENGTH: integer := 10; -- Number of 32-bit words taken by a header
type FRAME_HEADER_STRUCT is
	record  -- In transmission order (bytewise)
		-- Byte 0
		PROBE_ID: std_logic_vector(7 downto 0); -- 1 byte, user-defined. Generally a cookie, but can be used by user to convey more info (e.g. extend the number of channels)
		-- Bytes 1-2
		STREAM_ID: std_logic_vector(15 downto 0); -- 16 bit value used to uniquely define the data stream and lookup . Defined as listed below:
			-- Bits 15-12 (4 bits). Software defined. Identifies the data source (0 = adc/funcgen, 1=fft/scaler).
			-- Bits 12-8 (4 bits). Software defined. Identifies the crate_number.
			-- Bits 7-4 (4 bits). Software defined. Identifies slot number (zero-based).
			-- Bits 3-0 (4 bits). Hardware defined. Identifies the 10Gb/s lane (1st shuffle has 15 lanes, 2nd shuffle has 4 lanes, GPU link has 8 lanes).
		-- Byte 3
		SERIAL_FLAGS: std_logic_vector(3 downto 0); -- last 4 bits of the TUSER_SERIAL_FLAGS_BIT field (meaning depends on the data source)
		FLAGS: std_logic_vector(3 downto 0); -- 4 bits: aggregated TUSER bits at the input source
		-- Bytes 4-9
		TIMESTAMP: std_logic_vector(47 downto 0); --6 bytes (48 bits), system-defined
	end record;

constant SHUFFLE_FRAME_HEADER_WORD_LENGTH: integer :=4; -- Number of 32-bit words taken by a header
constant SHUFFLE_FRAME_HEADER_COOKIE: std_logic_vector(7 downto 0) := x"CF";
constant SHUFFLE_FRAME_HEADER_PROTOCOL_VERSION: std_logic_vector(3 downto 0) := X"1";

type SHUFFLE_FRAME_HEADER_STRUCT is
	record
		-- Word 0
		STREAM_ID: std_logic_vector(15 downto 0); -- 16 bit value used to uniquely define the data stream and lookup . Defined as listed below:
			-- Bits 15-12 (4 bits). Software defined. Identifies the data source within the internal pipeline (1st shuffle, 2nd shufle, raw data etc.).
			-- Bits 12-8 (4 bits). Software defined. Identifies the crate_number.
			-- Bits 7-4 (4 bits). Software defined. Identifies slot number (zero-based).
			-- Bits 3-0 (4 bits). Hardware defined. Identifies the 10Gb/s lane (1st shuffle has 15 lanes, 2nd shuffle has 4 lanes, GPU link has 8 lanes).
		PROTOCOL_VERSION: std_logic_vector(3 downto 0); -- Along with the cookie, identifies how the data is encoded in this header and the data. The cookie will have to change if we run out of space for versions.
		HEADER_LENGTH_IN_WORDS: std_logic_vector(3 downto 0); -- Number of 32-bit words in this header, to help the GPU skip this part if needed
		COOKIE: std_logic_vector(7 downto 0); -- 8 Bits (hardcoded) used to identify the type of frame. The cookie is last in the word so it appears first in the packet.
		-- Word 1
		ENCODING: std_logic_vector(3 downto 0); -- bit 0: '0' = 8 bit mode, '1' = 4 bit mode; bit 1: '0'= 2's complement, '1'=offset binary, bits 2-3: reserved
		NUMBER_OF_FRAMES: std_logic_vector(3 downto 0); -- number of frames per packet (1-255)
		NUMBER_OF_BINS: std_logic_vector(11 downto 0); -- Number of frequency bins included in each frame (1-4095) (there are up to 1024 bins in full CHIME)
		NUMBER_OF_CHANNELS: std_logic_vector(11 downto 0); -- Number of channels included for each frequency bin (1-4095) (there are up to 2560 channels in full CHIME)

		-- Word 2
		ANCILLARY_DATA: std_logic_vector(31 downto 0); -- Ancillary data channel to trickle a statistical (or other low rate) data stream

		-- Word 3
		TIMESTAMP: std_logic_vector(31 downto 0); -- -- 32-bit frame number of the *first* frame in the packet. The data sampling time relative to the last SYNC event is directly computed from the frame number. Rolls back every ~3h @ 800MSPS, 2048 time samples/frame.
	end record;

type rpm_coord_struct is record
	x: integer;
	y: integer;
end record;
--type rpm_coord_struct_array is array (NATURAL RANGE <>) of rpm_coord_struct;

-- Structure that defines the RPM coordinates of each element (2 DSPs and 2 BRAMs) in a CORR44
--    - DSP1 computes the product
--    - DSP2 finalizes/combines the products and adds the previous values
--    - FIFO is the vecrtor accumulator
--    - BRAM stores the final accumuled products and trickle them out while the new integration is under way
type cmac44_rpm_coord_struct is record
	DSP1, DSP2, FIFO, BRAM: rpm_coord_struct;
end record;

-- Array that describes the relative location of each CMAC44 elements in a CORR44
type cmac44_rpm_coord_struct_array is array (NATURAL RANGE 0 to NUMBER_OF_CMACS_MAX -1) of cmac44_rpm_coord_struct;

-- Structure that describes the layout and absolute location a CORR44 core
-- The positions are absolute RPM_GRID coordinates.
-- The coordinate specify the lower left corner of the CORR44 core, which can be a DSP, BRAM/FIFO depending on the layout
type corr44_rloc_origin_struct is record
	loc: rpm_coord_struct; -- Absolute location of lower left cell (type of site depends on layout)
	layout: string(1 to 4); -- layout of the CMAC44 (e.g. "BDDB" or "DBBD" )
end record;

-- Array that describes the layout and absolute positions of the corr44 cores in a CORR44_ARRAY
type corr44_rloc_origins_struct_array is array (NATURAL RANGE 0 to NUMBER_OF_CORRELATORS_MAX -1) of corr44_rloc_origin_struct;



function bit_reverse(s1:std_logic_vector) return std_logic_vector; -- reverses left-right bit order of a vector AND the direction of the vector
function reverse_bits_same_dir(s1:std_logic_vector) return std_logic_vector; -- reverses left-right bit order of a vector but keep the vector original direction
function reverse_bits_and_dir(s1:std_logic_vector) return std_logic_vector ; -- reverse both the bit order and  direction of vector.
function reverse_bytes(s1:std_logic_vector) return std_logic_vector; -- reverses byte order of a vector. Input vector length must be a multiple of 8.

function get_subword(v: std_logic_vector; subword_width:integer; index: integer; from_msb:boolean := FALSE) return std_logic_vector;
procedure set_subword(signal dst: inout std_logic_vector; src: std_logic_vector; index: integer; from_msb:boolean := FALSE);


function lsb(s1:unsigned; width:integer) return unsigned; -- returns least significant byte of a word
function lsb(s1:std_logic_vector; width:integer) return std_logic_vector;
function msb(v:unsigned) return std_logic;
function msb(v:signed) return std_logic;
function msb(s1:signed; width:integer) return signed;
function msb(s1:std_logic_vector; width:integer) return std_logic_vector;
function msb_pad(s1:std_logic_vector; width:integer) return std_logic_vector; -- returns ``width`` leftmost bits of ``s1`, right-pad with zeros if ``s1`` is shorter then ``width`
function sign_bit(i:signed) return std_logic; -- Returns the sign bit (the MSB) of a signed number
function sign_bit(i:unsigned) return std_logic; -- Returns the sign bit (the MSB) of an unsigned number
function sign_bit(i:std_logic_vector) return std_logic; -- Returns the sign bit (the MSB) of a std_logic_vector

function sel(b: BOOLEAN; if_true: string; if_false: string) return string;
function sel(b: BOOLEAN; if_true: real; if_false: real) return real;
function sel(b: BOOLEAN; if_true: integer; if_false: integer) return integer;
function sel(b: BOOLEAN; if_true: time; if_false: time) return time;
function sel(b: BOOLEAN; if_true: std_logic; if_false: std_logic) return std_logic;
function sel(b: BOOLEAN; if_true: std_logic_vector; if_false: std_logic_vector) return std_logic_vector;
function sel(b: BOOLEAN; if_true: slv_array; if_false: slv_array) return slv_array;
function sel(b: BOOLEAN; if_true: slv32_array; if_false: slv32_array) return slv32_array;
function sel(b: std_logic; if_true: std_logic_vector; if_false: std_logic_vector) return std_logic_vector;
function sel(key: bsb_interface_enum; dict: bsb_to_phy_map_type) return phy_type_enum;
function sel(key:string; imap: si_map) return integer;
function sel(key:integer; imap: ii_map) return integer;


FUNCTION max_value(v:signed) return integer;
FUNCTION min_value(v:signed) return integer;
FUNCTION max_value_vect(v:signed) return signed;
FUNCTION min_value_vect(v:signed) return signed;

function max(LEFT, RIGHT: INTEGER) return INTEGER;
function max(vin: integer_array) return integer;

function min(LEFT, RIGHT: INTEGER) return INTEGER;
function min(vin: integer_array) return integer;
function min(LEFT, RIGHT: unsigned) return unsigned;

function count(vin: integer_array; target:integer) return integer;
function divided_ramp(N: natural; d: positive) return integer_array;
function to_std_logic(i:boolean) return std_logic; -- converts bool to std_logic
function to_slv(i:integer; n: integer) return std_logic_vector; -- converts integer to standard_logic_vector with specified number of bits
function to_slv(r:real; n: integer) return std_logic_vector; -- converts real to standard_logic_vector with specified number of bits
function to_slv(i:std_logic) return std_logic_vector; -- converts a std_logic into a one element vector
function to_slv(i:unsigned) return std_logic_vector; -- converts unsigned to STD_LOGIC_VECTOR
function to_slv(i:unsigned; n: integer) return std_logic_vector; -- resize and converts unsigned to STD_LOGIC_VECTOR
function to_slv(i:ByteArray; n: integer) return std_logic_vector; -- concatenate bytes in a ByteAray and return the n LSBs as a STD_LOGIC_VECTOR
function to_slv(i:ByteArray) return std_logic_vector; -- concatenated bytes in a ByteAray and return them as a STD_LOGIC_VECTOR
function to_slv(i:slv8_array; n: integer) return std_logic_vector; -- concatenate bytes in a slv8_array and return the n LSBs as a STD_LOGIC_VECTOR
function to_slv(i:slv8_array) return std_logic_vector; -- concatenated bytes in a slv8_array and return them as a STD_LOGIC_VECTOR
function to_bit_vector(i:integer; n: integer) return bit_vector; -- converts integer to bit_vector with specified number of bits

function resize(i:std_logic_vector; n: integer) return std_logic_vector; -- resizes a STD_LOGIC_VECTOR. Truncates or adds zero padding.
function to_ByteArray(i:std_logic_vector) return ByteArray;-- spilt a slv in ia ByteArray. The SLV length must be multiples of 8 bits.
function to_ByteArray(i:unsigned) return ByteArray;-- spilt a unsigned in ia ByteArray. The SLV length must be multiples of 8 bits.
function to_ByteArray(i:slv8_array) return ByteArray; -- Convert slv8_array to ByteArray (for legacy compatibility).
function to_slv8_array(i:std_logic_vector) return slv8_array;-- spilt a unsigned in ia ByteArray. The SLV length must be multiples of 8 bits.
function to_slv8_array(i:unsigned) return slv8_array;-- spilt a unsigned in ia ByteArray. The SLV length must be multiples of 8 bits.
function to_slv8_array_le(i:slv32_array) return slv8_array; -- split a slv32_array byte-wise in a slv8_array in the Little Endian order i(0)(7 downto 0)) is in result(0).
function to_unsigned(i:ByteArray; n: integer) return unsigned; -- concatenate bytes in a ByteAray and return them as a n-bit unsigned
function to_unsigned(i:ByteArray) return unsigned; -- concatenate bytes in a ByteAray and return them as an unsigned
function to_unsigned(i:slv8_array; n: integer) return unsigned; -- concatenate bytes in a ByteAray and return them as a n-bit unsigned
function to_unsigned(i:slv8_array) return unsigned; -- concatenate bytes in a slv8_array and return them as an unsigned
function to_unsigned(i:std_logic) return unsigned; -- converts a std_logic into a one element unsigned
function str(i:integer) return string; -- converts integer to a string. Allows expressions, contrary to to_string().
function repeat( V: std_logic_vector; N: natural) return std_logic_vector; -- Concatenates a vector N times
function xpm_fifo_features(
    overflow, data_valid, prog_full, wr_data_count, almost_full, wr_ack,
    underflow, prog_empty, rd_data_count, almost_empty : boolean := FALSE
  ) return string; -- XPM xpm_fifo_async / xpm_fifo_sync USE_ADV_FEATURES hex string

function log2(v: integer) return real; -- Returns the log2 of an integer as a real (overloads the library log2())
function integer_log2(v: integer) return integer; -- Returns the log2 of an integer as an integer
function integer_log2(v: real) return integer; -- Returns the log2 of a real as an integer
function width(len: integer) return integer; -- computes the minimum number of bits needed to represent len-1
function bitwidth(value: integer) return integer;-- Computes the minimum number of bits needed to represent value

function shift_left(i:std_logic_vector; n: integer) return std_logic_vector; -- shift left a STD_LOGIC_VECTOR
function shift_left(ARG:slv8_array; COUNT: natural) return slv8_array; -- shift left a byte array

-- Delay-line / index-range shift toward 'RIGHT by n, filling vacated 'LEFT bits with '0'.
-- Works for both ascending (`to`) and descending (`downto`) ranges: elements move toward
-- arg'RIGHT; the n slots at arg'LEFT become '0'. Oldest pipeline value is at 'RIGHT.
-- n < 1 returns arg unchanged; n >= arg'LENGTH returns all zeros. Call as shift_right(pipe, 1).
function shift_right(arg: std_logic_vector; n: integer) return std_logic_vector;

-- One-step delay line: shift_right(arg, n) then replace arg'LEFT with insert.
-- Only n = 1 is supported (one vacated slot). Simulation asserts n = 1 with severity failure.
-- Always call with a named association: shift_right(pipe, 1, insert => new_bit).
function shift_right(arg: std_logic_vector; n: natural; insert: std_logic) return std_logic_vector;

-- Delay-line / index-range shift of an slv_array toward 'RIGHT by n, filling vacated 'LEFT
-- elements with (others => '0'). Works for both `to` and `downto` index ranges. Element width
-- is taken from x(x'LEFT). n < 1 returns x unchanged; n >= x'LENGTH returns all-zero elements.
-- Call as shift_right(pipe, 1). The one-argument form shift_right(x) is removed.
function shift_right(x: slv_array; n: natural) return slv_array;

-- One-step slv_array delay line: shift_right(x, n) then replace x'LEFT with insert.
-- insert is one element (std_logic_vector), not a bit. Only n = 1 is supported.
-- Simulation asserts n = 1 with severity failure.
-- Always call with a named association: shift_right(pipe, 1, insert => new_word).
function shift_right(x: slv_array; n: natural; insert: std_logic_vector) return slv_array;
function clip(v:signed; width_minus_one:integer)  return signed;
function any_one(v: std_logic_vector) return boolean; -- Return TRUE if any bit is '1'.
function any_one(v: unsigned) return boolean; -- Return TRUE if any bit is '1'.
function any_zero(v: std_logic_vector) return boolean; -- Return TRUE if any bit is '1'.
function any_zero(v: unsigned) return boolean; -- Return TRUE if any bit is '1'.

function all_ones(v: std_logic_vector) return boolean; -- Return TRUE if all bits are '1'.
function all_ones(v: unsigned) return boolean; -- Return TRUE if all bits are '1'.
function all_ones(v: signed) return boolean; -- Return TRUE if all bits are '1'.
function all_ones(v: std_logic_vector; high:integer; low:integer) return boolean;
function all_ones(v: unsigned; high:integer; low:integer) return boolean;

function all_zeros(v: std_logic_vector) return boolean; -- Return TRUE if all bits are '0'.
function all_zeros(v: unsigned) return boolean; -- Return TRUE if all bits are '0'.
function all_zeros(v: signed) return boolean; -- Return TRUE if all bits are '0'.
function all_zeros(v: std_logic_vector; high:integer; low:integer) return boolean;
function all_zeros(v: unsigned; high:integer; low:integer) return boolean;

function all_same(v: std_logic_vector; high:integer; low:integer) return boolean;
function all_same(v: signed; high:integer; low:integer) return boolean;

function is_in(i:integer; list:integer_array) return boolean;
function is_in(x: platform_type_enum; x_array: platform_type_enum_array) return boolean;
function num_ones(v: std_logic_vector) return integer; -- Return number of bits that are '1'.

function cmplx(re, im:integer) return complex; -- Create a complex value out of two integer values
function cmplx(re, im:signed) return complex; -- Create a complex value out of two signed values


FUNCTION struct_to_bytes(s:FRAME_HEADER_STRUCT) return slv8_array; -- Converts a FRAME_HEADER structure into a word array
-- function word_to_struct(w: Word32Array) return FRAME_HEADER_STRUCT; -- Converts a word array into a FRAME_HEADER structure

function struct_to_word(s:SHUFFLE_FRAME_HEADER_STRUCT) return slv32_array; -- Converts a SHUFFLE_FRAME_HEADER structure into a word array
function word_to_struct(w: slv32_array(0 to SHUFFLE_FRAME_HEADER_WORD_LENGTH-1):= (others=>(others=>'0'))) return SHUFFLE_FRAME_HEADER_STRUCT; -- Converts a word array into a SHUFFLE_FRAME_HEADER structure

--FUNCTION resize(s:signed; constant size:integer) return signed;
PROCEDURE axis32_write_buffer(buffer_in: in Word32Array; signal stream_out: out AXIS32_DAT_STRUCT; signal clk: in std_logic);

function rpm_to_string(rpm: rpm_coord_struct) return string; -- convert a RPM coordinate pair into a "XnYn" string
function get_cmac44_rpm_coords_struct_array(platform_type: platform_type_enum; N_CHAN: integer; layout: string) return cmac44_rpm_coord_struct_array; -- returns the locations of the CMAC44 DSPs and BRAMs for a corr44 correlator core with specified layout
function get_corr44_rloc_origins_struct_array(platform_type: platform_type_enum; N_CHAN: integer) return corr44_rloc_origins_struct_array; -- returns the layout and absolute location of each corr4 core in a corr44_array

pure function flatten(x : slv_array) return std_logic_vector;
pure function unflatten(s : std_logic_vector; num_slices : positive) return slv_array;

end chFPGA_Package;

package body chFPGA_Package is

-- Same as reverse_bits_and_dir()
-- Reverses both the left-right bit order and the direction of the vector.
FUNCTION bit_reverse(s1:std_logic_vector) return std_logic_vector is
	variable result: std_logic_vector(s1'REVERSE_RANGE);
begin
	for i in s1'RANGE loop
		result(i) := s1(i);
	end loop;
	return result;
end bit_reverse;

-- reverses the order of the bits but yield a vector indexed in the same direction
-- i.e. x(3 downto 0) := "1100"; y(3 downto 0) = reverse_bits_same_dir(x) = "0011"
FUNCTION reverse_bits_same_dir(s1:std_logic_vector) return std_logic_vector is
	variable result: std_logic_vector(s1'RANGE);
begin
	for i in s1'RANGE loop
		result(i) := s1(s1'LOW + (s1'HIGH-i)); -- alternate way to do it without alias
	end loop;
	return result;
end reverse_bits_same_dir;

-- Reverses the order of the bits but yield a vector indexed in the opposite direction
-- i.e. x(3 downto 0) := "1100"; y(0 downto 3) = reverse_bits_same_dir(x) = "0011"
FUNCTION reverse_bits_and_dir(s1:std_logic_vector) return std_logic_vector is
	variable result: std_logic_vector(s1'REVERSE_RANGE);
begin
	for i in s1'RANGE loop
		result(i) := s1(i);
	end loop;
	return result;
end reverse_bits_and_dir;


FUNCTION reverse_bytes(s1:std_logic_vector) return std_logic_vector is
     variable rr : std_logic_vector(s1'high downto s1'low);
	 variable num_bytes: integer;
begin
  num_bytes := s1'LENGTH/8;
  for i in 0 to (num_bytes-1) loop
	rr(8*i+7+s1'low downto 8*i+s1'low) := s1(8*(num_bytes-1-i)+7+s1'low downto 8*(num_bytes-1-i)+s1'low);
  end loop;
	return rr;
end reverse_bytes;

function get_subword(v: std_logic_vector; subword_width:integer; index: integer; from_msb:boolean := FALSE) return std_logic_vector is
begin
    if from_msb then
        return v(v'LENGTH - subword_width * index - 1 downto v'LENGTH - subword_width * (index + 1));
    else
        return v((subword_width + 1) * index -1 downto subword_width * index);
    end if;
end get_subword;

procedure set_subword(signal dst: inout std_logic_vector; src: std_logic_vector; index: integer; from_msb: boolean := FALSE) is
begin
    if from_msb then
        dst(dst'LENGTH - src'LENGTH *index -1 downto dst'LENGTH - src'LENGTH * (index + 1)) <= src;
    else
        dst((src'LENGTH + 1)*index -1 downto src'LENGTH * index) <= src;
    end if;
end set_subword;

FUNCTION lsb(s1:unsigned; width:integer) return unsigned is
begin
	return s1(width-1 downto 0);
end lsb;

FUNCTION lsb(s1:std_logic_vector; width:integer) return std_logic_vector is
begin
	return s1(width-1 downto 0);
end lsb;


FUNCTION msb(v:signed) return std_logic is
begin
	return v(v'LEFT);
end msb;

FUNCTION msb(v:unsigned) return std_logic is
begin
	return v(v'LEFT);
end msb;

FUNCTION msb(s1:signed; width:integer) return signed is
begin
	return s1(s1'LEFT downto s1'LEFT-width+1);
end msb;

FUNCTION msb(s1:std_logic_vector; width:integer) return std_logic_vector is
begin
	return s1(s1'LEFT downto s1'LEFT-width+1);
end msb;

FUNCTION msb_pad(s1:std_logic_vector; width:integer) return std_logic_vector is
	variable r: std_logic_vector(width-1 downto 0) := (others => '0');
	variable min_width: integer := minimum(width, s1'LENGTH);
begin
	r(width-1 downto width-min_width) := s1(s1'LEFT downto s1'LEFT-min_width+1);
	return r;
end msb_pad;

FUNCTION sign_bit(i:signed) return std_logic is --
begin
	return i(i'LENGTH-1);
end sign_bit;

FUNCTION sign_bit(i:unsigned) return std_logic is --
begin
	return i(i'LENGTH-1);
end sign_bit;

FUNCTION sign_bit(i:std_logic_vector) return std_logic is --
begin
	return i(i'LENGTH-1);
end sign_bit;

FUNCTION max_value(v:signed) return integer is
begin
	return 2**(v'LENGTH - 1) - 1;
end max_value;

FUNCTION max_value_vect(v:signed) return signed is
begin
	return to_signed(max_value(v), v'LENGTH);
end max_value_vect;

FUNCTION min_value(v:signed) return integer is
begin
	return -(2**(v'LENGTH - 1));
end min_value;

FUNCTION min_value_vect(v:signed) return signed is
begin
	return to_signed(min_value(v), v'LENGTH);
end min_value_vect;

-- stolen from std_numeric
function MAX(LEFT, RIGHT: INTEGER) return INTEGER is
begin
	if LEFT > RIGHT then
		return LEFT;
	else
		return RIGHT;
	end if;
end MAX;

function max(vin: integer_array) return integer is
	variable vout: integer;
begin
	vout := integer'LOW;
	for j in 0 to vin'Length-1 loop
		if vin(j) > vout then
			vout := vin(j);
		end if;
	end loop;
	return vout;
end max;

function min(vin: integer_array) return integer is
	variable vout: integer;
begin
	vout := integer'HIGH;
	for j in 0 to vin'LENGTH-1 loop
		if vin(j) < vout then
			vout := vin(j);
		end if;
	end loop;
	return vout;
end min;


-- stolen from std_numeric
function MIN(LEFT, RIGHT: INTEGER) return INTEGER is
begin
	if LEFT < RIGHT then
		return LEFT;
	else
		return RIGHT;
	end if;
end MIN;

function min(LEFT, RIGHT: unsigned) return unsigned is
begin
	if LEFT < RIGHT then
		return LEFT;
	else
		return RIGHT;
	end if;
end min;

function count(vin: integer_array; target: integer) return integer is
	variable vout: integer := 0;
begin
	for j in vin'RANGE loop
		if vin(j) = target then
			vout := vout + 1;
		end if;
	end loop;
	return vout;
end count;

function divided_ramp(N: natural; d: positive) return integer_array is
	variable v: integer_array(0 to N - 1);
begin
	for i in 0 to N - 1 loop
		v(i) := i / d;
	end loop;
	return v;
end divided_ramp;

FUNCTION to_std_logic(i:boolean) return std_logic is -- converts bool to std_logic
begin
	if i then
		return '1';
	else
		return '0';
	end if;
end to_std_logic;

function xpm_fifo_features(
    overflow, data_valid, prog_full, wr_data_count, almost_full, wr_ack,
    underflow, prog_empty, rd_data_count, almost_empty : boolean := FALSE
  ) return string is
	variable v: std_logic_vector(15 downto 0);
begin
	v := (0 => to_std_logic(overflow),
	      1 => to_std_logic(prog_full),
	      2 => to_std_logic(wr_data_count),
	      3 => to_std_logic(almost_full),
	      4 => to_std_logic(wr_ack),
	      8 => to_std_logic(underflow),
	      9 => to_std_logic(prog_empty),
	      10 => to_std_logic(rd_data_count),
	      11 => to_std_logic(almost_empty),
	      12 => to_std_logic(data_valid),
	      others => '0');
	return to_hstring(unsigned(v));
end xpm_fifo_features;

FUNCTION to_slv(i:integer; n: integer) return std_logic_vector is -- converts integer to standard_logic_vector with specified number of bits
begin
	return std_logic_vector(to_unsigned(i,n));
end to_slv;

FUNCTION to_slv(r:real; n: integer) return std_logic_vector is -- converts real to std_logic_vector with specified number of bits
begin
	return std_logic_vector(to_signed(integer(r), n));
end to_slv;

FUNCTION to_slv(i:unsigned) return std_logic_vector is -- converts unsigned to STD_LOGIC_VECTOR
begin
	return std_logic_vector(i);
end to_slv;

FUNCTION to_slv(i:unsigned; n: integer) return std_logic_vector is -- resizes and converts unsigned to STD_LOGIC_VECTOR
begin
	return std_logic_vector(resize(i,n));
end to_slv;

FUNCTION to_bit_vector(i:integer; n: integer) return bit_vector is -- converts integer to bit_vector with specified number of bits
begin
	return to_bit_vector(std_logic_vector(to_unsigned(i,n)));
end to_bit_vector;

FUNCTION resize(i:std_logic_vector; n: integer) return std_logic_vector is -- resizes a STD_LOGIC_VECTOR. Truncates or adds zero padding.
begin
	return std_logic_vector(resize(unsigned(i),n));
end resize;

FUNCTION to_slv(i:ByteArray; n: integer) return std_logic_vector is -- concatenate bytes in a ByteAray and return them as a n bit STD_LOGIC_VECTOR
	variable v:std_logic_vector(n-1 downto 0);
	variable ix: integer;
begin
	v := (others=>'0'); -- clear all bits by default in case we ask for more bits than there are in the byte array
	ix := i'Right;
	for j in 0 to n-1 loop
		if i'Ascending then
			v(j) := i(ix-j/8)(j mod 8);
		else
			v(j) := i(ix+j/8)(j mod 8);
		end if;
	end loop;
	return v;
end to_slv;

FUNCTION to_slv(i:slv8_array; n: integer) return std_logic_vector is -- concatenate bytes in a slv8_array and return them as a n bit STD_LOGIC_VECTOR
	variable v:std_logic_vector(n-1 downto 0);
	variable ix: integer;
begin
	v:=(others=>'0'); -- clear all bits by default in case we ask for more bits than there are in the byte array
	ix:=i'Right;
	for j in 0 to n-1 loop
		if i'Ascending then
			v(j):=i(ix-j/8)(j mod 8);
		else
			v(j):=i(ix+j/8)(j mod 8);
		end if;
	end loop;
	return v;
end to_slv;

FUNCTION to_slv8_array(i:std_logic_vector) return slv8_array is -- split a slv in a slv8_array in the Big Endian order (result(0) is the MSB). The slv is treated as unsigned and is zero padded to the next multiple of 8 bits.
	variable N: integer := (i'LENGTH+7)/8;
	variable v: slv8_array(0 to N-1);
	variable ii: std_logic_vector(N*8-1 downto 0) := resize(i, N * 8); -- zero padded to multiple of 8 bits
begin
	v:=(others=>(others=>'0')); -- clear all bytes by default
	for j in 0 to N-1 loop
		v(j):=ii((N-j)*8-1 downto (N-j)*8-8);
	end loop;
	return v;
end to_slv8_array;

FUNCTION to_slv8_array(i:unsigned) return slv8_array is -- split a unsigned in a slv8_array. The SLV length must be multiples of 8 bits.
begin
	return to_slv8_array(std_logic_vector(i));
end to_slv8_array;

FUNCTION to_slv8_array_le(i:slv32_array) return slv8_array is -- split a slv32_array byte-wise in a slv8_array in the Little Endian order i(0)(7 downto 0)) is in result(0).
	variable N: integer := i'LENGTH; -- number of words
	variable v: slv8_array(0 to 4*N-1);
begin
	for j in 0 to N-1 loop
		for k in 0 to 3 loop
			v(4*j+k):=i(j)(k*8+7 downto k*8);
		end loop;
	end loop;
	return v;
end to_slv8_array_le;

FUNCTION to_ByteArray(i:slv8_array) return ByteArray is -- Convert slv8_array to ByteArray (for legacy compatibility).
	variable v:ByteArray(i'range);
begin
	for j in i'range loop
		v(j):=i(j);
	end loop;
	return v;
end to_ByteArray;

FUNCTION to_ByteArray(i:std_logic_vector) return ByteArray is -- split a slv in ia ByteArray.
begin
	return to_ByteArray(to_slv8_array(i));
end to_ByteArray;

FUNCTION to_ByteArray(i:unsigned) return ByteArray is -- split a unsigned in ia ByteArray. The SLV length must be multiples of 8 bits.
begin
	return to_ByteArray(std_logic_vector(i));
end to_ByteArray;

FUNCTION to_slv(i:ByteArray) return std_logic_vector is -- concatenate bytes in a ByteAray and return them as a STD_LOGIC_VECTOR
begin
	return to_slv(i,8*i'Length);
end to_slv;

FUNCTION to_slv(i:slv8_array) return std_logic_vector is -- concatenate bytes in a ByteAray and return them as a STD_LOGIC_VECTOR
begin
	return to_slv(i,8*i'Length);
end to_slv;

FUNCTION to_slv(i:std_logic) return std_logic_vector is -- converts a std_logic into a one element vector
	variable v: std_logic_vector(0 downto 0);
begin
	v(0) := i;
	return v;
end to_slv;

FUNCTION to_unsigned(i:std_logic) return unsigned is -- converts a std_logic into a one element unsigned
	variable v: unsigned(0 downto 0);
begin
	v(0) := i;
	return v;
end to_unsigned;

FUNCTION to_unsigned(i:ByteArray; n: integer) return unsigned is -- concatenated bytes in a ByteAray and return them as a unsigned
begin
	return unsigned(to_slv(i,n));
end to_unsigned;

FUNCTION to_unsigned(i:ByteArray) return unsigned is -- concatenated bytes in a ByteAray and return them as a unsigned
begin
	return to_unsigned(i,8*i'Length);
end to_unsigned;

FUNCTION to_unsigned(i:slv8_array; n: integer) return unsigned is -- concatenated bytes in a ByteAray and return them as a unsigned
begin
	return unsigned(to_slv(i,n));
end to_unsigned;

FUNCTION to_unsigned(i:slv8_array) return unsigned is -- concatenated bytes in a ByteAray and return them as a unsigned
begin
	return to_unsigned(i,8*i'Length);
end to_unsigned;

FUNCTION str(i:integer) return string is -- converts integer to a string. Allows expressions, contrary to to_string().
begin
	return to_string(i);
end str;

-- Return the Raw data capture frame header structure as a byte array
FUNCTION struct_to_bytes(s:FRAME_HEADER_STRUCT) return slv8_array is
	variable b: slv8_array(0 to FRAME_HEADER_BYTE_LENGTH - 1);
	variable w: std_logic_vector(8 * FRAME_HEADER_BYTE_LENGTH - 1 downto 0);
begin
	w := s.PROBE_ID & s.STREAM_ID & s.SERIAL_FLAGS & s.FLAGS & s.TIMESTAMP;
	for i in 0 to FRAME_HEADER_BYTE_LENGTH-1 loop
		b(i) := w(8 * (FRAME_HEADER_BYTE_LENGTH - i) - 1 downto 8 * (FRAME_HEADER_BYTE_LENGTH - i - 1));
	end loop;
	return b;
end struct_to_bytes;

FUNCTION struct_to_word(s:SHUFFLE_FRAME_HEADER_STRUCT) return slv32_array is
	variable w : slv32_array(0 to SHUFFLE_FRAME_HEADER_WORD_LENGTH-1);
begin
	w(0):= (s.STREAM_ID & s.PROTOCOL_VERSION & s.HEADER_LENGTH_IN_WORDS & s.COOKIE );
	w(1):= (s.ENCODING & s.NUMBER_OF_FRAMES & s.NUMBER_OF_BINS & s.NUMBER_OF_CHANNELS);
	w(2):= s.ANCILLARY_DATA;
	w(3):= s.TIMESTAMP;
	return w;
end struct_to_word;

FUNCTION word_to_struct(w: slv32_array(0 to SHUFFLE_FRAME_HEADER_WORD_LENGTH-1) := (others=>(others=>'0'))) return SHUFFLE_FRAME_HEADER_STRUCT is
	-- We use an constrained array as parameter 'w' so we can use s=word_to_struct((word_index=>word)) to easily  extract fields from a single word in the strcuture
	variable s : SHUFFLE_FRAME_HEADER_STRUCT;
begin
	-- Word 0
	s.STREAM_ID              := w(0)(31 downto 16);
	s.PROTOCOL_VERSION       := w(0)(15 downto 12);
	s.HEADER_LENGTH_IN_WORDS := w(0)(11 downto 8);
	s.COOKIE                 := w(0)(7 downto 0);
	-- Word 1
	s.ENCODING           := w(1)(31 downto 28);
	s.NUMBER_OF_FRAMES   := w(1)(27 downto 24);
	s.NUMBER_OF_BINS     := w(1)(23 downto 12);
	s.NUMBER_OF_CHANNELS := w(1)(11 downto 0);
	-- Word 2
	s.ANCILLARY_DATA := w(2);
	-- Word 3
	s.TIMESTAMP := w(3);
	return s;
end word_to_struct;

FUNCTION sel(b: BOOLEAN; if_true: std_logic; if_false: std_logic) return std_logic is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

FUNCTION sel(b: BOOLEAN; if_true: std_logic_vector; if_false: std_logic_vector) return std_logic_vector is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

FUNCTION sel(b: BOOLEAN; if_true: slv32_array; if_false: slv32_array) return slv32_array is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

FUNCTION sel(b: BOOLEAN; if_true: slv_array; if_false: slv_array) return slv_array is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

FUNCTION sel(b: BOOLEAN; if_true: real; if_false: real) return real is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

FUNCTION sel(b: BOOLEAN; if_true: string; if_false: string) return string is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

FUNCTION sel(b: BOOLEAN; if_true: integer; if_false: integer) return integer is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

FUNCTION sel(b: BOOLEAN; if_true: time; if_false: time) return time is
begin
	if b then
		return if_true;
	else
		return if_false;
	end if;
end sel;

function sel(key: bsb_interface_enum; dict: bsb_to_phy_map_type) return phy_type_enum is
begin
	return dict(key);
end;

FUNCTION sel(b: std_logic; if_true: std_logic_vector; if_false: std_logic_vector) return std_logic_vector is
begin
	if b then
		return if_true;
	elsif not b then
		return if_false;
	else
		report "Test value in sel(test_value, if_true, if_false) is neither '0' or '1'" severity failure;
		return if_false;
	end if;
end sel;

FUNCTION sel(key:string; imap: si_map) return integer is
begin
    for i in 0 to imap'LENGTH-1 loop
        if imap(i).key = key then
            return imap(i).value;
        end if;
    end loop;
    assert FALSE report "Invalid key: " & key severity failure;
end sel;

FUNCTION sel(key:integer; imap: ii_map) return integer is
begin
    for i in 0 to imap'LENGTH-1 loop
        if imap(i).key = key then
            return imap(i).value;
        end if;
    end loop;
    assert FALSE report "Invalid key: " & to_string(key) severity failure;
end sel;

function repeat( V: std_logic_vector; N: natural) return std_logic_vector is
	constant L: natural := V'length;
	variable result: std_logic_vector(0 to N*L - 1);
begin
	for i in 0 to N-1 loop
		result(i*L to i*L + L - 1) := V;
	end loop;
	return result;
end repeat;

--Returns TRUE if any bit is '1'
function any_one(v: std_logic_vector) return boolean is
begin
	return or(v) = '1';
end function;

--Returns TRUE if any bits is '1'
function any_one(v: unsigned) return boolean is
begin
	return or(v) = '1';
end function;

--Returns TRUE if any bit is '0'
function any_zero(v: std_logic_vector) return boolean is
begin
	return and(v) = '0';
end function;

--Returns TRUE if any bit is '0'
function any_zero(v: unsigned) return boolean is
begin
	return and(v) = '0';
end function;

--Returns TRUE if all bits are '1'
function all_ones(v: std_logic_vector) return boolean is
begin
	return and(v) = '1';
end function;


--Returns TRUE if all bits are '1'
function all_ones(v: unsigned) return boolean is
begin
	return and(v) = '1';
end function;

--Returns TRUE if all bits are '1'
function all_ones(v: signed) return boolean is
begin
	return and(v) = '1';
end function;

--Returns TRUE if bits in specified range are all '1'
function all_ones(v: std_logic_vector; high:integer; low:integer) return boolean is
	variable ones: std_logic_vector(v'range) := (others => '1');
begin
	--	return and(v(high downto low)) = '1'; -- Error: Cannot have variable length slice in component instantiation
    -- return signed(v(high downto low)) = -1; --Does not work! Synthesis raises no error but logic is wrong
    return v(high downto low) = ones(high downto low);
end function;

function all_ones(v: unsigned; high:integer; low:integer) return boolean is
begin
	return all_ones(std_logic_vector(v), high, low);
end function;


--Returns TRUE if all bits are 'o'
function all_zeros(v: std_logic_vector) return boolean is
begin
	return or(v) = '0';
end function;


--Returns TRUE if all bits are '0'
function all_zeros(v: unsigned) return boolean is
begin
	return or(v) = '0';
end function;

--Returns TRUE if all bits are '0'
function all_zeros(v: signed) return boolean is
begin
	return or(v) = '0';
end function;

--Returns TRUE if bits in specified range are all '0'
function all_zeros(v: std_logic_vector; high:integer; low:integer) return boolean is
	variable zeros: std_logic_vector(v'range) := (others => '0');
begin
	--	return or(v(high downto low)) = '0'; -- Error: Cannot have variable length slice in component instantiation
	-- return signed(v(high downto low)) = 0; -- Synthesis raises no error but logic is wrong
	return v(high downto low) = zeros(high downto low);
end function;

function all_zeros(v: unsigned; high:integer; low:integer) return boolean is
begin
	return all_zeros(std_logic_vector(v), high, low);
end function;


--Returns TRUE if bits in specified range are all the same
function all_same(v: std_logic_vector; high:integer; low:integer) return boolean is
	variable bits: std_logic_vector(v'range) := (others => v(v'HIGH));
begin
    return v(high downto low) = bits(high downto low);
end function;


function all_same(v: signed; high:integer; low:integer) return boolean is
begin
	return all_same(std_logic_vector(v), high, low);
end function;

function is_in(i:integer; list:integer_array) return boolean is
begin
    for ii in list'RANGE loop
        if list(ii) = i then
        	return TRUE;
        end if;
    end loop;
    return FALSE;
end function;

function is_in(x: platform_type_enum; x_array: platform_type_enum_array) return boolean is
begin
	for i in x_array'range loop
		if x = x_array(i) then
			return TRUE;
		end if;
	end loop;
	return FALSE;
end function;


function num_ones(v: std_logic_vector) return integer is
	variable count: integer := 0;
begin
    for i in v'RANGE loop
        count := (count + 1) when v(i);
    end loop;
    return count;
end function;

--Returns the log2 of a integer as a real value
function log2(v: integer) return real is
begin
	return log2(real(v));
end function;

--Returns the log2 of a integer as an integer
function integer_log2(v: integer) return integer is
begin
	return integer(log2(real(v)));
end function;

--Returns the log2 of a real as an integer
function integer_log2(v: real) return integer is
begin
	return integer(log2(v));
end function;

-- Compute the number of bits needed to represent `len` values (from 0 to len-1)
function width(len: integer) return integer is
begin
	return integer(ceil(log2(real(len))));
end function;

-- Compute the number of bits needed to represent 'value' as an unsigned value
function bitwidth(value: integer) return integer is
begin
	return integer(ceil(log2(real(value+1))));
end function;

-- shift left a STD_LOGIC_VECTOR
function shift_left(i:std_logic_vector; n: integer) return std_logic_vector is
begin
	return std_logic_vector(shift_left(unsigned(i), n));
end function;


function shift_left(ARG:slv8_array; COUNT: natural) return slv8_array is -- shift left a byte array
	constant ARG_L: INTEGER := ARG'LENGTH-1;
	alias XARG: slv8_array(ARG_L downto 0) is ARG;
	variable RESULT: slv8_array(ARG_L downto 0) := (others=>(others => '0'));
begin
	if COUNT <= ARG_L then
		RESULT(ARG_L downto COUNT) := XARG(ARG_L-COUNT downto 0);
	end if;
	return RESULT;
end function;

-- Delay-line shift toward 'RIGHT; vacated 'LEFT bits are '0'. See package declaration.
function shift_right(arg: std_logic_vector; n: integer) return std_logic_vector is
	variable r: std_logic_vector(arg'RANGE) := (others => '0');
begin
	if n < 1 then
		return arg;
	elsif n < arg'LENGTH then
		if arg'ASCENDING then
			r(arg'LEFT + n to arg'RIGHT) := arg(arg'LEFT to arg'RIGHT - n);
		else
			r(arg'LEFT - n downto arg'RIGHT) := arg(arg'LEFT downto arg'RIGHT + n);
		end if;
	end if;
	return r;
end function;

-- One-step delay line: shift then write insert at 'LEFT. n must be 1.
function shift_right(arg: std_logic_vector; n: natural; insert: std_logic) return std_logic_vector is
	variable t: std_logic_vector(arg'RANGE);
begin
	assert n = 1
		report "shift_right(std_logic_vector, n, insert) only supports n = 1"
		severity failure;
	t := shift_right(arg, n);
	t(arg'LEFT) := insert;
	return t;
end function;

-- Delay-line shift toward 'RIGHT; vacated 'LEFT elements are zero. See package declaration.
function shift_right(x: slv_array; n: natural) return slv_array is
	variable r: slv_array(x'RANGE)(x(x'LEFT)'RANGE) := (others => (others => '0'));
begin
	if n < 1 then
		return x;
	elsif n < x'LENGTH then
		if x'ASCENDING then
			r(x'LEFT + n to x'RIGHT) := x(x'LEFT to x'RIGHT - n);
		else
			r(x'LEFT - n downto x'RIGHT) := x(x'LEFT downto x'RIGHT + n);
		end if;
	end if;
	return r;
end function;

-- One-step slv_array delay line: shift then write insert at 'LEFT. n must be 1.
function shift_right(x: slv_array; n: natural; insert: std_logic_vector) return slv_array is
	variable t: slv_array(x'RANGE)(x(x'LEFT)'RANGE);
begin
	assert n = 1
		report "shift_right(slv_array, n, insert) only supports n = 1"
		severity failure;
	t := shift_right(x, n);
	t(x'LEFT) := insert;
	return t;
end function;

-- clip (saturate) the signed value to the specified bit width

function clip(v:signed; width_minus_one:integer)  return signed is
	variable r: signed(v'RANGE);
	variable v_slv: std_logic_vector(v'RANGE) := std_logic_vector(v);
begin
	-- If the sign bit of the word is 0 but all the clipped bits are not 0, saturate to max positive value
	if v_slv(v_slv'HIGH) = '0' and not all_zeros(v_slv, v_slv'HIGH, width_minus_one) then
		r := (others => '0');
		r(width_minus_one-1 downto 0) := (others => '1');
	-- If the sign bit of the word is 1 but all the bits down and including the MSB of our byte are not 1, saturate to most negative value
	elsif v_slv(v_slv'HIGH) = '1' and not all_ones(v_slv, v_slv'HIGH, width_minus_one) then
		r := (others => '1');
		r(width_minus_one-1 downto 0) := (others => '0');
	-- There is no saturation
	else
		r := v;
	end if;
	return r;
end function;



function cmplx(re, im:integer) return complex is -- Create a complex value out of two integer values
begin
	return cmplx(real(re), real(im));
end function;

function cmplx(re, im:signed) return complex is -- Create a complex value out of two signed values
begin
	return cmplx(real(to_integer(re)), real(to_integer(im)));
end function;

PROCEDURE axis32_write_buffer(buffer_in: in Word32Array; signal stream_out: out AXIS32_DAT_STRUCT; signal clk: in std_logic) is
	variable i : integer:=0;
begin
	for i in 0 to buffer_in'LENGTH-1 loop
		stream_out.TDATA<=buffer_in(i);
		stream_out.TVALID<='1';
		if i=buffer_in'LENGTH-1 then
			stream_out.TLAST<='1';
		else
			stream_out.TLAST<='0';
		end if;
		wait until rising_edge(CLK);
		wait for 1 ps; -- make sure the other processes do not see the changes on the same clock
--		end if; -- CLK
	end loop;
--			if i=buffer_in'LENGTH then
--		wait until rising_edge(CLK);
--		wait for 1 ps; -- make sure the other processes do not see the changes on the same clock
	stream_out.TVALID<='0';
--			return;
--			end if;
--			i:=i+1;
end procedure;

------------------------
-- RPM-related functions
------------------------


-- Converts a rpm_coord struct into a "XxYy" string for use in RPM-related attributes
function rpm_to_string(rpm: rpm_coord_struct) return string is
begin
	return "X" & integer'IMAGE(rpm.x) & "Y" & integer'IMAGE(rpm.y);
end function rpm_to_string;



--type corr44_rpm_coord_struct is record
--	DSP: rpm_coord_struct_array(0 to NUMBER_OF_CMACS_MAX -1);
--	BRAM: rpm_coord_struct_array(0 to NUMBER_OF_CMACS_MAX -1);
--end record;

-- Returns a structure that defines the layout of CORR44 core expressed as the relative RPM position of the CMAC44 correlator elements in the fabric
--
--    N_CHAN (integer): Number of inputs to correlate
--    layout (string): Layout to use
--
-- For layout = "BDDB" and layout="DBBD", the CORR44 layout is implemented as two columns of DSPs with their associated two columns of BRAMs.
-- For a N-channel correlator, each CORR44 is N DSP tiles high, or 2*N DSP high.
-- The layout can be provided for columns ordered as BRAM-DSP-DSP-BRAM (layout="BDDB") or BRAM-DSP-DSP-BRAM (layout="DBBD").
-- In the first case, the origin (0,0) refer to a FIFO. In the second case, it refers to a DSP.
function get_cmac44_rpm_coords_struct_array(platform_type: platform_type_enum; N_CHAN: integer; layout:string) return cmac44_rpm_coord_struct_array is
 	variable rpm: cmac44_rpm_coord_struct_array;
 	variable pf_info: PLATFORM_INFO_STRUCT;
 	variable DSP_XL, DSP_XR, FIFO_XL, FIFO_XR, DSP_Y0, FIFO_Y0: integer;
begin


	pf_info := PLATFORM_INFO(platform_type);

	if platform_type = MGK7MB then

	 	--DSP_X0L:=361;
	 	--DSP_X0R:=381;
	 	--DSP_X1L := 425;
	 	--DSP_X1R := 473;
	 	--FIFO_X0L := 350;
	 	--FIFO_X0R := 394;
	 	--BRAM_X1L := 438;
	 	--BRAM_X1R := 462;
	 	--DSP_Y0 := 0;
	 	--DSP_Y1 := DSP_Y0 + DSP_TILE_DELTA_Y*(N+1); -- :=170 -- A corr44 is two columns of (N+1) CMAC44, each one being DSP tile high
	 	--DSP_Y2 := 450;
	 	--DSP_Y3 := DSP_Y2 + DSP_TILE_DELTA_Y*(N+1); -- =620

	 	-- Slice coordinates (RPM_GRID not defined).
	 	-- Does not work: it says capture_bram0 is not on a RAMB site
	 	--DSP_X0L:=8;
	 	--DSP_X0R:=9;
	 	--DSP_X1L := 10;
	 	--DSP_X1R := 11;
	 	--FIFO_X0L := 8;
	 	--FIFO_X0R := 9;
	 	--BRAM_X1L := 10;
	 	--BRAM_X1R := 11;
	 	--DSP_Y0 := 0;
	 	--DSP_Y1 := DSP_Y0 + DSP_TILE_DELTA_Y*(N+1); -- :=170 -- A corr44 is two columns of (N+1) CMAC44, each one being DSP tile high
	 	--DSP_Y2 := 36;
	 	--DSP_Y3 := DSP_Y2 + DSP_TILE_DELTA_Y*(N+1); -- =620

	 	-- using RPM_GRID="GRID" (uses RPM_X and RPM_Y)
	 	-- Here we use the RPM_X and RPM_Y cooordinates of the leftmost pair of DSP/BRAM columns (BRAM-DSP-DSP-BRAM)
	 	--DSP_X0L:=45-45;
	 	--DSP_X0R:=65-45;
	 	--DSP_X1L := 121-45;
	 	--DSP_X1R := 141-45;
	 	--FIFO_X0L := 34-34;
	 	--FIFO_X0R := 78-34;
	 	--BRAM_X1L := 110-34;
	 	--BRAM_X1R := 154-34;
	 	if layout="BDDB" then
		 	FIFO_XL := 350-350; -- relative location of the FIFO in left column. This is our origin point.  Should be 0.
		 	DSP_XL := 361-350; -- relative location of dsp1 on leftmost column.
		 	DSP_XR := 381-350; -- relative location of dsp1 on rightmost column
		 	FIFO_XR := 394-350;
		elsif layout="DBBD" then
		 	DSP_XL := 425-425; -- relative location of dsp1 on leftmost column. This is our origin point.  Should be 0.
		 	FIFO_XL := 438-425; -- relative location of the FIFO in left column.
		 	FIFO_XR := 462-425;
		 	DSP_XR := 473-425; -- relative location of dsp1 on rightmost column
		else
			assert FALSE report "Invalid CORR44 layout CONFIG string";
		end if;

	 	DSP_Y0 := 0; -- should be zero.
	 	FIFO_Y0 := 0; -- position of the FIFO, which must be at the bottom


	elsif platform_type = ZCU111 or platform_type = CRS then


	 	if layout="BDDB" then
		 	FIFO_XL := 3360; -- relative location of the FIFO in left column. This is our origin point.
		 	DSP_XL := 3520; -- relative location of dsp1 on leftmost column.
		 	DSP_XR := 3592; -- relative location of dsp1 on rightmost column
		 	FIFO_XR := 3664;
		elsif layout="DBBD" then
		 	DSP_XL := 2840; -- relative location of dsp1 on leftmost column. This is our origin point.
		 	FIFO_XL := 2872; -- relative location of the FIFO in left column.
		 	FIFO_XR := 3048;
		 	DSP_XR := 3120; -- relative location of dsp1 on rightmost column
		else
			assert FALSE report "Invalid CORR44 layout CONFIG string";
		end if;

		FIFO_XL := FIFO_XL - FIFO_XL;
		DSP_XL := DSP_XL - FIFO_XL;
		DSP_XR := DSP_XR - FIFO_XL;
		FIFO_XR := FIFO_XR - FIFO_XL;
	 	DSP_Y0 := 2; -- bottom.
	 	FIFO_Y0 := 2; -- position of the FIFO, which must be at the bottom


		--assert N_CHAN=8 report "Unsupported N for this platform" severity ERROR;
	 	--DSP_XL := 0;--3;
	 	--DSP_XR :=1;--4;
	 	--FIFO_XL  := 0;--2;
	 	--FIFO_XR  := 1;--3;
	 	--DSP_Y0  := 0;--72;
	 	--FIFO_Y0  := 0;--72;

		--	for i in 0 to NUMBER_OF_CORRELATORS_MAX-1 loop
		--	rpm(i).DSP1 := (DSP_XL;
		--	rpm(i).LEFT_BRAM_X   := FIFO_XL;
		--	rpm(i).RIGHT_DSP_X   := DSP_XR;
		--	rpm(i).RIGHT_BRAM_X  := FIFO_XR;
		--	rpm(i).DSP_BOTTOM_Y  := DSP_Y0 + pf_info.DSP_TILE_DELTA_RPM_Y*(N_CHAN+1)*i; -- Each CORR44 is (N+1) DSP tile high
		--	rpm(i).BRAM_BOTTOM_Y := FIFO_Y0 + pf_info.DSP_TILE_DELTA_RPM_Y*(N_CHAN+1)*i; --
		--end loop;
		--return rpm;

	else
		assert FALSE report "UNSUPPORTED PLATFORM" severity ERROR;
		return rpm;
	end if;

	-- The code below assumes a two column layout
	for i in 0 to NUMBER_OF_CMACS_MAX-1 loop
		rpm(i).DSP1 := (X => sel((i mod 2)=0, DSP_XL, DSP_XR), Y=> DSP_Y0 + (i/2) * pf_info.DSP_TILE_DELTA_RPM_Y); -- Each CMAC44 is 1 DSP tile (2 DSP) high
		rpm(i).DSP2 := (X => sel((i mod 2)=0, DSP_XL, DSP_XR), Y=>  DSP_Y0 + (i/2) * pf_info.DSP_TILE_DELTA_RPM_Y + pf_info.DSP_BEL_DELTA_RPM_Y);
		rpm(i).FIFO := (X => sel((i mod 2)=0, FIFO_XL, FIFO_XR), Y => FIFO_Y0 + (i/2) * pf_info.BRAM_TILE_DELTA_RPM_Y);
		rpm(i).BRAM := (X => sel((i mod 2)=0, FIFO_XL, FIFO_XR), Y => FIFO_Y0 + (i/2) * pf_info.BRAM_TILE_DELTA_RPM_Y + pf_info.BRAM_BEL_DELTA_RPM_Y);
	end loop;
	return rpm;

end function get_cmac44_rpm_coords_struct_array;



-- Return the platform-specific layout and locations of the corr44 cores
--
function get_corr44_rloc_origins_struct_array(platform_type: platform_type_enum; N_CHAN: integer) return corr44_rloc_origins_struct_array is
 	variable locs: corr44_rloc_origins_struct_array;
 	variable CORR44_DELTA_Y, X0, X1, Y0, Y1, Y2, Y3: integer;

begin

	CORR44_DELTA_Y := PLATFORM_INFO(platform_type).DSP_TILE_DELTA_RPM_Y * (N_CHAN+1);

	if platform_type = MGK7MB then
		-- This is the absolute locations of the CORR44 cores on the 7K420.
		-- Coordinates are in the RPM_GRID system. They refer to the bottom-left corner of the CORR44, which is a BRAM/FIFO.
		-- Coordinates provide dby this function must therefore only refer only to FIFO18E1 sites.
		-- See RPM_X and RPM_Y properties of BRAM sites for those coordinates (in the Vivado Device view).
		--
		-- The cores are placed in a 4-high by 2-wide array. A first 4 are in
		-- a 2x2 array vertically spanning the lower 7 clock regions, and the
		-- remaining 4 span the upper 7 clock regions.
		--
		-- On the Kintex 7, the CMACS are located at the right of the chip,
		-- and unfortunately, the organization of the DSP and BRAM columns is
		-- not the same for the leftmost and righmost CMAC44s, so we have so
		-- specify different CMAC44 layouts. In the left column, we have a
		-- BRAM-DSP-DSP-BRAM columns ("BDDR" layout), whereas we have a
		-- DSP-BRAM-BRAM-DSP columns (layout "DBBD" in the right column).
		--
		-- A 16-channel CORR44 is 17 DSP tiles (34 DSPs) high. There are 10
		-- DSPs per clock region. Two CORR44 are 68 DSP high. 7 clock regions
		-- provide 70 DSPs. Nice fit.

		X0 := 350; -- Left colums, BDDB layout, FIFO site
		X1 := 425; -- Right column, DBBD layout, DSP site
		-- Lower CORR44s
		Y0 := 0;
		Y1 := Y0 + CORR44_DELTA_Y; -- :=170 -- A corr44 is two columns of (N+1) CMAC44, each one being DSP tile high
		-- Upper CORR44s
		Y2 := 450;
		Y3 := Y2 + CORR44_DELTA_Y; -- =620

		locs := (
			0 => (layout => "BDDB", loc => (X0, Y0)),
			1 => (layout => "DBBD", loc => (X1, Y0)),
			2 => (layout => "BDDB", loc => (X0, Y1)),
			3 => (layout => "DBBD", loc => (X1, Y1)),
			4 => (layout => "BDDB", loc => (X0, Y2)),
			5 => (layout => "DBBD", loc => (X1, Y2)),
			6 => (layout => "BDDB", loc => (X0, Y3)),
			7 => (layout => "DBBD", loc => (X1, Y3)),
			others => (layout => "unknown", loc => (-1,-1))
			);
		return locs;
	else -- if platform_type
		assert FALSE report "UNSUPPORTED PLATFORM for correlator" severity ERROR;
	end if; -- if platform_type

end function;

pure function unflatten(s : std_logic_vector; num_slices : positive)
return slv_array
is
	constant w : positive := s'length / num_slices;
	alias sa : std_logic_vector(s'length-1 downto 0) is s;
	variable r : slv_array(0 to num_slices-1)(w-1 downto 0);
begin
	for i in r'range loop
		r(i) := sa((i+1)*w-1 downto i*w);
	end loop;
	return r;
end function;

-- Pack an array of SLVs back into a flat SLV.
pure function flatten(x : slv_array) return std_logic_vector is
	constant w : natural := x(x'low)'length;
	constant n : natural := x'length;
	variable r : std_logic_vector(n*w-1 downto 0);
begin
	for i in x'range loop
		r((i-x'low+1)*w-1 downto (i-x'low)*w) := x(i);
	end loop;
	return r;
end function;

end chFPGA_Package;
