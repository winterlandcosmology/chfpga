.. title:: Testbenches

Testbenches
===========

This section documents the VHDL testbenches used to verify the functionality of chFPGA modules. Testbenches are located in ``hdl/testbenches/``.

Channelizer Testbenches
-----------------------

ADCDAQ_timing_test
~~~~~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/ADCDAQ_timing_test/ADCDAQ_timing_test_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the timing characteristics of the ADCDAQ module, including clock domain crossing and data acquisition timing.

align
~~~~~

**File:** ``hdl/testbenches/align_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/shuffle_crossbar_testbench/`` (contains align testbench)

Tests the frame alignment module that synchronizes data streams from multiple channelizers. Verifies alignment logic, missing frame handling, and frame synchronization across multiple lanes.

align64
~~~~~~~

**File:** ``hdl/testbenches/align64_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/align64_testbench/``

Tests the 64-bit wide frame alignment module. Verifies packet alignment, lane error detection, and handling of missing frames, short frames, and timing delays.

chan_bin_sel
~~~~~~~~~~~~

**File:** ``hdl/testbenches/chan_bin_sel_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/chan_testbenches/`` or ``xilinx_projects/testbenches/chan_tests/``

Tests the first-stage corner-turn bin selector module. Verifies frequency bin selection, data filtering, packet header generation, and flag handling.

chan_crossbar
~~~~~~~~~~~~~

**File:** ``hdl/testbenches/chan_crossbar_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/chan_testbenches/`` or ``xilinx_projects/testbenches/chan_tests/``

Tests the first-stage corner-turn crossbar module. Verifies data routing, bin selection across multiple channelizers, and packet formatting.

chan_crossbar_shuffle_align
~~~~~~~~~~~~~~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/chan_crossbar_shuffle_align_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/chan_testbenches/`` or ``xilinx_projects/testbenches/chan_tests/``

Tests the integration of the channelizer crossbar with shuffle alignment logic. Verifies end-to-end data flow through the first-stage corner-turn.

chan_fifo
~~~~~~~~~

**File:** ``hdl/testbenches/chan_fifo_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/chan_fifo_testbench/``

Tests the channelizer FIFO module that handles clock domain crossing between the channelizer clock and output clock domains.

funcgen
~~~~~~~

**File:** ``hdl/testbenches/funcgen_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/funcgen_testbench/`` or ``xilinx_projects/testbenches/chan_testbenches/``

Tests the function generator module that provides test waveforms and data sources. Verifies waveform generation, LFSR functionality, and data source selection.

funcgen_clip_width
~~~~~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/funcgen_clip_width_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/chan_testbenches/`` or ``xilinx_projects/testbenches/chan_tests/``

Tests clipping and bit-width handling in the function generator module.

funcgen_lfsr
~~~~~~~~~~~~

**File:** ``hdl/testbenches/funcgen_lfsr_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/chan_testbenches/`` or ``xilinx_projects/testbenches/chan_tests/``

Tests the Linear Feedback Shift Register (LFSR) functionality within the function generator module.

prober
~~~~~~

**File:** ``hdl/testbenches/prober_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/prober_testbench/``

Tests the data capture (prober) module. Verifies data capture functionality, FIFO operation, and packet generation for debugging and monitoring.

scaler
~~~~~~

**File:** ``hdl/testbenches/scaler_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/scaler/``

Tests the scaler module that applies gain coefficients to FFT output data. Verifies scaling operations, quantization, overflow handling, and both real and complex gain modes.

scaler_mul
~~~~~~~~~~

**File:** ``hdl/testbenches/scaler_mul_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/scaler_mul/``

Tests the scaler multiplier core. Verifies signed/unsigned multiplication operations used in the scaling process.

ucap
~~~~

**File:** ``hdl/testbenches/ucap_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/UCAP/``

Tests the UltraRAM-based data capture module. Verifies UltraRAM write/read operations, frame capture, and data retrieval functionality.

Corner-Turn Testbenches
-----------------------

bp_shuffle_align
~~~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/bp_shuffle_align_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the backplane shuffle alignment module. Verifies data alignment across backplane links and handling of network delays and errors.

bp_sync
~~~~~~~

**File:** ``hdl/testbenches/bp_sync_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the backplane synchronization module. Verifies synchronization logic for multi-board systems.

cge
~~~

**File:** ``hdl/testbenches/cge_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/cge_tests/``

Tests the 100G Ethernet corner-turn engine (CGE). Verifies corner-turn operations, packet handling, and Ethernet interface integration.

rawpack
~~~~~~~

**File:** ``hdl/testbenches/rawpack_testbench.vhd``

**Run with:** ``xilinx_projects/testbenches/rawpack_testbench/run.sh [GENERIC=value ...]`` (Vivado simulator, no project needed)

Self-checking test of the raw ADC sample streamer. Drives a known pattern on the capture bus, enables the stream through the BSB registers and checks every packet: Ethernet/IP/UDP headers, IP checksum, the order of the two streams, the packet counter and the continuity of the timestamps of each stream, and every sample. Also checks that the upstream bus passes through before the stream is enabled and after it is disabled. Generics select the channels, the data source, single-channel mode (``SINGLE=1``), the packet size and gaps in the input (``GAP_PERIOD``). ``DUMP_FILE`` writes the packets to a file for use by host software tests.

rawpack_cge
~~~~~~~~~~~

**Files:** ``hdl/testbenches/rawpack_cge_testbench.vhd``, ``hdl/testbenches/cmac_usplus_1_sim_model.vhd``

**Run with:** ``xilinx_projects/testbenches/rawpack_testbench/run_chain.sh [GENERIC=value ...]``

Full-rate test of the chain capture bus, ``rawpack``, ``cge``. The Xilinx 100G MAC inside ``cge`` is replaced by a behavioural model that paces the transmit stream at the 100 Gb/s line rate (including preamble, FCS and inter-frame gap), fails on a transmit underflow and writes every frame to a file. The testbench fails if any FIFO overflows, and ``check_frames.py`` then checks all the frames: headers, no packet lost, every sample.

cge_test
~~~~~~~~

**File:** ``hdl/testbenches/cge_test_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/cge_tests/``

Additional testbench for the CGE module with different test scenarios. Tests normal mode, borderline delays, missing frames, and short frames.

shuffle_crossbar
~~~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/shuffle_crossbar_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/shuffle_crossbar_testbench/``

Tests the second and third-stage corner-turn crossbar (shuffle crossbar). Verifies align, remap, and shuffle_bin_sel functionality, data combining, and packet routing.

shuffle
~~~~~~~

**File:** ``hdl/testbenches/shuffle_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/shuffle_sim/``

Tests the shuffle network module. Verifies data shuffling operations and network routing.

two_crossbars
~~~~~~~~~~~~~

**File:** ``hdl/testbenches/two_crossbars_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the integration of two crossbar stages (channelizer crossbar and shuffle crossbar). Verifies end-to-end data flow through multiple corner-turn stages.

upack
~~~~~

**File:** ``hdl/testbenches/upack_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/upack_testbench/``

Tests the UltraRAM-based packetizer and corner-turn engine (UPACK). Verifies corner-turn operations using UltraRAM for data buffering.

u_ct
~~~~

**File:** ``hdl/testbenches/u_ct_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/uct_engine_level2_testbench/``

Tests the Ultrascale+ corner-turn engine (UCT). Verifies multi-level corner-turn operations (CT_LEVEL 1, 2, and 3) and link management.

uram_ct_cge
~~~~~~~~~~~

**File:** ``hdl/testbenches/uram_ct_cge_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/cge_tests/``

Tests the UltraRAM-based corner-turn engine for CGE. Verifies UltraRAM usage in corner-turn operations with 8 channels, 8k bins, and 16 frames.

Correlator Testbenches
----------------------

cmac
~~~~

**File:** ``hdl/testbenches/cmac_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/corr_core_testbench/``

Tests the Complex Multiply-and-Accumulate (CMAC) core. Verifies complex multiplication, accumulation, and correlation product calculations.

corr44
~~~~~~

**File:** ``hdl/testbenches/corr44_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/corr_core_testbench/``

Tests the (4+4) bit correlator core. Verifies correlation operations, integration periods, and output formatting.

CORR
~~~~

**File:** ``hdl/testbenches/CORR_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/corr_core_testbench/``

Tests the legacy correlator module. Verifies basic correlation functionality.

ucorr44
~~~~~~~

**File:** ``hdl/testbenches/ucorr44_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/ucorr44/``

Tests the UltraRAM-based (4+4) bit correlator. Verifies correlation operations using UltraRAM for data storage.

ucorr44_array
~~~~~~~~~~~~~

**File:** ``hdl/testbenches/ucorr44_array_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/ucorr44_array/``

Tests the array of UltraRAM-based correlators. Verifies multiple correlator instances working in parallel.

System Testbenches
------------------

axis_sync_fifo
~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/axis_sync_fifo_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/axis_sync_fifo_testbench/``

Tests the AXI4-Streaming synchronous FIFO. Verifies FIFO read/write operations, full/empty flags, and data integrity across clock cycles.

bsb_router_slave
~~~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/bsb_router_slave_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/bsb_regs_testbench/``

Tests the backplane serial bus (BSB) router and slave modules. Verifies command routing, address decoding, and register access.

chFPGA
~~~~~~

**File:** ``hdl/testbenches/chFPGA_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the top-level chFPGA module. Verifies system integration, command interface, GPIO, and overall system functionality.

cmd_slave
~~~~~~~~~

**File:** ``hdl/testbenches/cmd_slave_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the command slave module that implements memory-mapped registers. Verifies register read/write operations, control and status byte handling.

packetizer
~~~~~~~~~~

**File:** ``hdl/testbenches/packetizer_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the packetizer module. Verifies packet formatting, header generation, and data packaging for transmission.

sysmon
~~~~~~

**File:** ``hdl/testbenches/sysmon_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/sysmon_testbench/``

Tests the system monitor (SYSMON/XADC) module. Verifies analog-to-digital conversion, temperature and voltage monitoring.

Ethernet and Network Testbenches
---------------------------------

udp_mac
~~~~~~~

**File:** ``hdl/testbenches/udp_mac_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the UDP MAC module for 1G Ethernet. Verifies UDP packet transmission and reception, Ethernet frame handling, and GMII interface.

udp_mac_rx
~~~~~~~~~~

**File:** ``hdl/testbenches/udp_mac_rx_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/udp_mac_rx_testbench/``

Tests the UDP MAC receiver functionality. Verifies packet reception, frame parsing, and data extraction.

xge_udp_mac_tx
~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/xge_udp_mac_tx_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the 10G Ethernet UDP MAC transmitter. Verifies 10G packet transmission, XGMII interface, and high-speed data handling.

xge_udp_mac_tx_xglink
~~~~~~~~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/xge_udp_mac_tx_xglink_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the integration of 10G Ethernet UDP MAC transmitter with XGLINK serial links. Verifies end-to-end data transmission through Ethernet and serial interfaces.

XGMII_UDP_MAC
~~~~~~~~~~~~~

**File:** ``hdl/testbenches/XGMII_UDP_MAC_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/`` (project folder not found)

Tests the XGMII UDP MAC module. Verifies XGMII interface, 10G Ethernet packet handling, and protocol compliance.

Serial Link Testbenches
-----------------------

xglink_array
~~~~~~~~~~~~

**File:** ``hdl/testbenches/xglink_array_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/shuffle_sim/``

Tests the XGLINK serial link array. Verifies multiple serial link operation, data transmission, and link management.

xxvglink_array
~~~~~~~~~~~~~~

**File:** ``hdl/testbenches/xxvglink_array_testbench.vhd``

**Xilinx Project:** ``xilinx_projects/testbenches/xxvglink_testbench/``

Tests the 25G serial link array (XXVGLINK). Verifies 25Gbps packet transmission, link initialization, and array operation.
