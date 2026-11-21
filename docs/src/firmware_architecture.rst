*********************
Firmware Architecture
*********************

.. default-role:: entity

VHDL flavor
===========

The source code for `chfpga` is written in VHDL2008. Although the original code was written for VHDL93, the modules have gradually been using VHDL2008 as it significantly simplifies the code. We have not attempted to preserve VHDL93 compatibility.

All files in the project must be tagged to use the VHDL2008 file type, otherwise the synthesizer will fail to compile many files. The default file type of files added to a project is "VHDL", meaning VHDL93. It must explicitely be changed to VHDL2008.


.. _platform_wrappers:

Top module: platform wrappers
=============================


.. The platform wrapper take the constants defined in the package `chfpga_config`  and passes them to the `chFPGA` module instance in order to define the firmware capabilities. This section lists the firmware configurations that are currently implemented on IceBoard platform. Each of these files define the ``chfpga_config`` package, and the project must include one of those files to determine firmware capabilities of the build.


The platform wrapper is the top-level file of the project. It provides the logic and parameters that are specific to a specific platform:

- Hardware-specific constants to be passed to the `chfpga` module such as reference clock source and frequency, type of ADC etc.
- I/O Ports
- Clock and data buffers
- Instantiate the Processing System (PS) block diagram when applicable
- Repackaging of the external signals and buses to the format expected by the `chfpga` module

The platform wrapper is responsible for instantiating the  `chfpga` module and passing it all the hardware- and application-specific parameters taken from the firmware configuration file (see next section).

The platfom wrapper shall be named using the following format::

   chfpga_<platform name>.vhd

Configuration file
==================

The configuration file is a package that defines a number of constants needed to configure the firmware functionality. We refrain from including hardware-specific parameters in this file, e.g., parameters that can never change for a specific platform; those shall be defined in the platform-wrapper. Of course, some firmware functionalities are platform-specific (such as modules using UltraRAM for example) but could be implemented in other ways in the future, and shall therefore be defined in the configuration file.

Configuration files shall define a package named ``chfpga_config``. The selection of the configuration file for a particular build is done by including the desired configuration file in the project. Configuration files must therefore have unique names in the following format::

    chfpga_<platform name>_<config name>_config.vhd

The labels of all constants in the package shall have the format::

    CONFIG_<subsystem name>_<parameter name>


.. _config_param_reference:

Configuration parameter reference
=================================

This section defines each ``CONFIG_*`` constant used in firmware configuration files. Platform-specific config sections list which parameters they use and link here for full descriptions.

Channelizer parameters
----------------------

.. _config_chan_implement_fft:

- **CONFIG_CHAN_IMPLEMENT_FFT** (boolean): Enables the FFT block in channelizers. When TRUE, channelizers perform polyphase filtering and FFT; when FALSE, timestreams pass through without frequency-domain processing. Set TRUE for all current configs that include an F-Engine.

.. _config_chan_fft_type:

- **CONFIG_CHAN_FFT_TYPE** (fft_type_enum): Selects the FFT variant. Values: ``NONE``, ``CHIME``, ``D3A``, ``CHORD``, ``HIRAX``, ``HIRAX_3DSP``. CHORD uses 14-bit samples, 16384 samples/frame, 32+32 bit output (CRS/ZCU111). HIRAX and HIRAX_3DSP use 8-bit samples, 2048 samples/frame (IceBoard, KC705). HIRAX_3DSP uses 25+25 bit output for reduced resource usage.

.. _config_number_of_channelizers_with_fft:

- **CONFIG_NUMBER_OF_CHANNELIZERS_WITH_FFT** (integer): Number of channelizers that include an FFT. Typically equals the number of ADC channels. Configs with fewer channelizers than ADCs (e.g. CRS with 8) use this to match the ADC count.

.. _config_chan_scaler_use_complex_gains:

- **CONFIG_CHAN_SCALER_USE_COMPLEX_GAINS** (boolean): When TRUE, scaler uses complex gains; when FALSE, real gains. Set FALSE in all current configs for simpler logic and lower resource use.

.. _config_chan_capture_type:

- **CONFIG_CHAN_CAPTURE_TYPE** (chan_capture_type_enum): Selects the data capture engine. ``PROBER``: BRAM-based, per-channelizer capture (IceBoard, KC705). ``UCAP``: URAM-based centralized capture (CRS, ZCU111). UCAP requires Ultrascale+ URAM.

.. _config_chan_number_of_capture_sources:

- **CONFIG_CHAN_NUMBER_OF_CAPTURE_SOURCES** (integer): Number of capture sources (e.g. timestream vs FFT output). Typically 2. Used when CONFIG_CHAN_CAPTURE_TYPE is PROBER or UCAP.

Corner-turn parameters
----------------------

.. _config_ct_type:

- **CONFIG_CT_TYPE** (ct_type_enum): Corner-turn engine type. ``BCT``: CHIME-like, 32-bit input with packet headers, used for multi-board backplane shuffle. ``UCT``: CHORD-like, 32-bit input with 4x (4+4)-bit bins, simpler format. BCT used on IceBoard for crate-level shuffle; UCT used on CRS/ZCU111/KC705 for single-board or simpler topologies.

.. _config_ct_level:

- **CONFIG_CT_LEVEL** (integer): Corner-turn depth. 1 = single-board only, no backplane. 2 = crate-level shuffle (e.g. 3× PCB links). 3 = multi-crate shuffle (e.g. 3× PCB + 2× SFP). Higher levels require CONFIG_CT_LANE_TO_LINK_MAP to define lane-to-link mapping.

.. _config_ct_clk_source:

- **CONFIG_CT_CLK_SOURCE** (ct_clk_source_enum): Clock source for the corner-turn engine. ``BP_SHUFFLE_TXCLK``: backplane transmitter clock (~244 MHz), used when CT_LEVEL=3 and packet overhead is needed. ``ADC_CLK``: ADC clock (e.g. 400 MHz on CRS), used when CT_LEVEL=1 and no packet overhead. ``CORR_CLK``: 250 MHz clock from MMCM. ``CGE_CLK322``: 100G Ethernet clock.

.. _config_ct_lane_to_link_map:

- **CONFIG_CT_LANE_TO_LINK_MAP** (integer_array): Maps each CT lane to a backplane link index. -1 = bypass lane. Used when CT_LEVEL ≥ 2. Example: ``(-1, 6, 8, 10)`` = bypass + 3 PCB links for CORR32. ``(-1, 6, 8, 10, -1, -1, 0, 1)`` = CORR64 with CT3 SFP links.

Correlator parameters
---------------------

.. _config_corr_type:

- **CONFIG_CORR_TYPE** (corr_type_enum): Correlator type. ``NONE``: no correlator. ``UCORR44``: :math:`N^2` correlator with reduced precision. ``CORR44``: legacy correlator. ct configs use NONE; corr configs use UCORR44.

.. _config_corr_readout_bins:

- **CONFIG_CORR_READOUT_BINS** (integer_array): Which frequency bins to read out from the correlator. With CONFIG_CHAN_FFT_TYPE CHORD (ROTATE=TRUE), true bins 0, 1, 2, 3 map to indices 0, 1, 2, 3. Some configs use (0, 0) as placeholder; others specify bins for readout.

Data offload parameters
------------------------

.. _config_data_link_type:

- **CONFIG_DATA_LINK_TYPE** (data_link_type_enum): Real-time data offload type. ``NONE``: no offload. ``XGE``: 8×10G Ethernet. ``UPACK_CGE``: 100G Ethernet via UPACK + CGE. ct configs use XGE (IceBoard) or UPACK_CGE (CRS, ZCU111); corr configs typically use NONE.

- **CONFIG_NUMBER_OF_CGE_LINKS** (integer, CRS only): Number of 100G links with a 100G link type. ``1``: the QSFP28 port. ``2``: also a second link on the SFP28 cages 1 to 4 (second hard MAC), which carries only the raw ADC streams C and D of ``rawpack``.

.. _config_data_link_link_to_quad_map:

- **CONFIG_DATA_LINK_LINK_TO_QUAD_MAP** (integer_array): Maps each data link to a GTY quad index. Used when CONFIG_DATA_LINK_TYPE is UPACK_CGE. Example: ``(0 to 3 => 0)`` = single quad for 100G.

.. _config_data_link_quad_to_refclk_map:

- **CONFIG_DATA_LINK_QUAD_TO_REFCLK_MAP** (integer_array): Maps each GTY quad to a reference clock index. Used when CONFIG_DATA_LINK_TYPE is UPACK_CGE. Example: ``(0 => 0)`` = single refclk.

I/O buffers
===========

In general, the clock and data buffers shall be instantiated in the platform wrapper, as these are generally hardware-specific.

Note that some modules define their own clock or data buffers  instead having those be defined in the platform module. Some exceptions are:

- `clocks` module: defines the clock input buffer based on the clock source parameter.
-  SPI or I2C peripherals: defines their own data buffers to facilitate tristate operation or improve timing.
-  Modules using GTXes or GTYs typically define their own buffers.

In many cases the  exceptions exist mainly for historical reasons, but since having local buffers reduces the size and complexity of the platform file, we have not moved out the buffers from those modules.


Platform and configuration names
================================

The following platform and configuration names shall be used.

Platforms:

- IceBoard: ``mgk7mb_rev2``
- CRS: ``crs``
- KC705: ``kc705``
- ZCU111: ``zcu111``

Configurations:

- Channelizer and Corner-turn engine with real-time data offload: ``ct``
- Channelizer with on-board corner-turn and correlator: ``corr``



Parameter flow, generics and OOC modules
========================================

As a rule, we try to pass every parameter that a module (and its sub-module) might need as generics to that module. We try to avoid using the parameters defined in the configuration directly; those shall be passed to chFPGA as generics from the platform wrapper module.

There is one exception to this: out-of-context (OOC) module (i.e. modules that are synthesized once and mused multiple times, such as the channelizer). OOC modules cannot be instantiated with generics. The module itself *can* have generics, but the defaults must be used. In these case, the VHDL file that implements the entity imports the configuration file and use its constants to set the default values of the generics. The code in the module should then use these generics, not the configuration file constant. An example of this is the :entity: module.


`chfpga`: a module to rule them all
===================================

The core firmware for every configuration of the firmware for every platform is implemented using the same :entity:`chfpga` module.
Of course, this module takes a large number of generics that are passed by the hardware platform and configuration file to enable the various hardware- and application-specific modules with the desired geometry.


time_trig port semantics
------------------------

The :entity:`chfpga` module exposes a two-bit vector port ``time_trig(0 to 1)`` that carries external time and trigger information into the core firmware:

* ``time_trig(0)`` — backplane time / IRIG-B–derived time signal.
* ``time_trig(1)`` — backplane trigger signal (e.g. frame or event trigger).

Platform wrappers are responsible for receiving the board-specific time and trigger signals (typically IRIG-B and/or backplane timing lines), resampling them in the appropriate 10 MHz reference-clock domain, and combining them into ``time_trig`` before instantiating :entity:`chfpga`.

Inside :entity:`chfpga` and :entity:`system`, ``time_trig`` is pipelined on the rising edge of the internal 200 MHz ``clk200`` clock before being consumed by the IRIG-B decoder, reference-clock synchronization logic and time-tagging blocks. For this to yield deterministic timing, ``clk200`` **must** be generated from a clock source that is synchronous to the external clock domain used to generate ``time_trig`` (for example, a PLL output derived from the same 10 MHz reference and VCXO that drive the IRIG-B and backplane timing hardware). In other words, the time/trigger signals and ``clk200`` are expected to have a fixed, well-characterised phase relationship.


Data buses
==========

AXI4-Streaming bus usage
------------------------

We use exclusively AXI4-Streaming to carry both the science data and the control/monitoring system.
The protocol is well defined by standard, is lightweight, and is well supported by IP blocks.

Blocking vs non-blocking buses
------------------------------

Science data buses are generally non-blocking (no TREADY line). There is generally no point in blocking the main pipeline: data rate is so high that we can't block for a significant amout of time and not run out of memory. 

Control interfaces (e.g. BSB control bus) and slow capture buses (UCAP, PROBER and UCORR outputs)that send intermittent data over limited bandwidth pipes (e.g. feeding Ethernet interface) use blocking buses.

Blocking buses harder on timing.  Tready cannot be registered unless we introduce a 1-deep FIFO at each stage. 

Loose backpressure
------------------

We sometimes stray from the strict AXI-Stream handshaking and use a signal we call ``send`` instead of ``TREADY`` to implement a relaxed form of backpressure that makes the bus easy to pipeline. We don't use the ``TREADY`` signal to make it clear the backpresure works differently. 

In this protocol, we expect that both the data and send signals will be pipelined, which means that data won't start flowing immediately when it is asserted. This also means that the data won't stop immediately when deasserted, not until the pipeline has finished flushing. The receiver must therefore accept *any* data that is TVALID, independent of the send signal. This is different from the standard AXI-tream where a trasaction occurs only when both TVALID and TREADY are high in the same clock cycle.

This means that we place an elastic FIFO at the sink and drive ``send`` from its almost-full flag, so the source is told to stop before the FIFO runs out of space. The *almost_full* margin must be as large as the roundtrip latency of the pipeline (``send`` pipeline from sink to source plus data pipelining from source to sink) so it can absorb the extra data caused by the pipeline. We often already have to use a FIFO for clock-domain crossing preposes, so that comes for free. 

This approach is used at the output of the channelizer (to allow channel outputs to be aligned) and on the daisy-chained outputs of the correlator.


AXI4-Streaming Protocol
-----------------------

The AXI4-Stream protocol is used for applications that typically focus on a data-centric and data-flow paradigm where the concept of an address is not present or not required. Each AXI4-Stream acts as a single unidirectional channel for a handshake data flow. At this lower level of operation (compared to the memory mapped AXI protocol types), the mechanism to move data between IP is defined and efficient, but there is no unifying address context between IP. The AXI4-Stream IP can be better optimized for performance in data flow applications, but also tends to be more specialized around a given application space.

AXI-Stream Ports and Waveform

.. table::

    +------------------+--------------+-----------+----------------------------------------------------+
    | Port Name        | Width (bits) | Direction | Description                                        |
    +==================+==============+===========+====================================================+
    | TREADY           | 1            | In        | Indicates destination is to accept data            |
    +------------------+--------------+-----------+----------------------------------------------------+
    | TVALID           | 1            | Out       | Indicates TDATA is valid                           |
    +------------------+--------------+-----------+----------------------------------------------------+
    | TLAST            | 1            | Out       | Indicates last word of a transfer                  |
    +------------------+--------------+-----------+----------------------------------------------------+
    | TDATA            | 8            | Out       | Data                                               |
    +------------------+--------------+-----------+----------------------------------------------------+

Handshake rules
---------------

- **Transfer**: A beat is transferred only when **both** TVALID and TREADY are high in the **same** clock cycle.
- **TVALID**: Once the source asserts TVALID, it must keep it asserted until a transfer occurs (i.e. until TREADY is high in the same cycle). The source may deassert TVALID on the cycle after the handshake (or keep it high for the next beat). TVALID must not be deasserted before the handshake.
- **TREADY**: The sink may assert or deassert TREADY on any cycle; it can change from cycle to cycle. In practice it is often registered to avoid combinatorial paths from TREADY back to TVALID.


.. figure:: ./images/axi_stream_waveform.png
    :scale: 22
    :alt: AXI-Stream Interface Waveform


`Xilinx AXI Reference Guide <https://www.xilinx.com/support/documentation/ip_documentation/ug761_axi_reference_guide.pdf>`_


Command system
==============


Principle of operations
-----------------------

The operation of `chFPGA` is controlled by exclusively by reading or writing bytes to submodules registers and memory blocks. Each submodule has its own memory-papped address range.

- Control register page
- Status register page
- DRP (Direct reconfigurable ports) or Memory (BRAM or URAM) page



Address space / pages
---------------------

The address space is 19 bit wide. Commands can access one of the following 19-bit address spaces (pages):

The page to access is determined by the command code only, not the address. Each page therefore can access its own 19-bit address space independently, that is, the address space is not shared between pages.





Byte-Serial-Bus (BSB)
---------------------

In general, operating the FPGA is a set-and-forget operation. There is little need for a high-bandwidth interface for accessing the registers and memory buffers except for the initial setup, but the bus needs to propagate to each sub-sub-submodule. This is different from  real-time data pipeline which continuously needs a high bandwidth but has a linear and limited topology.

In order to preserve resources in the FPGA and make it easier to meet timing, access to the FPGA memory-mapped space is done using a Byte-serial-Bus protocol. BSB protocol is implemented using a 8-bit AXI-Stream command bus and a 8-bit AXI-stream reply bus. Commands are sent as packets, where the operation (read, write), byte-count andaddress are encoded in a 3-byte (24-bit) header, followed by any number of data bytes. Each command is acknowledge by a reply packet that contains the command status and the requested data.

A BSB operating at 125 MHz can accomodate the full bandwidth of a 1G Ethernet interface while making timing closure easy to meet.




Command and reply packet format
-------------------------------



Routing
-------

Control and status registers
----------------------------

Some rules have been set on how the control and register accesses should behave:

- Control registers are always read/write. Reading a control register will always return the last value written to it. All the bits of each register can be read back, even if these bits are not connected to any logic.
- Reading or writing a register shall never have any side-effect other than changing the register value or returning the result. Triggers shall be based changes in the register values, not the fact that a read/write transaction has occure. This means that writing a register multiple times with the same value shall be the same as writing it only once. This is necessary to allow safe retries in case of lost packets.
- Status registers are always read only.


RAM/DRP
-------

An BSB endpoint implements any number of control registers, status registers, and either a RAM or DRP interface.

DRP interface implements a 16-bit data bus, whereas a RAM interface has a 8-bit data bus.



The commands are:

- Write control register
- Write control register with mask
- Read control register
- Read status register
- Write DRP/RAM
- Read DRP/RAM


Software interface
==================

Configuration management
------------------------

- Software should determine the capability of the firmware by reading registers in order to instantiate and configure the corresponding Python objects accordingly.
- Capability registers that inform on whether a module is present or not are typically found in the GPIO module. Access to a module shall not be made unless we know the module is there to respond. The GPIO module shall be instantiated first to gather the firmware capability information before instantiating the rest of the objects. Presence of a module should **not** be detected by checking if  access to one of its registers succeeds.
- Module-specific capability registers can be placed in their specific modules.
- We generally try to put as much capability information in capability registers as possible to minimize the need to keep the Python code up to date with firmware changes. However, Python-based look up tables might be necessary to provide detailed configuration based on some FPGA capability register in order to minimize the amount of logic resources allocated to these registers. This is the case of platform-specific constants which are looked up from the PLATFORM_TYPE parameter found in GPIO.
-



Building Gotchas
================



Bad cell path/name in constraints
---------------------------------

When synthesizing and implementing, check for critical warnings.

- Object not found in the constraint file. This can be caused by hierarchical paths that have changed name because labels have been changed, or some code has been encapsulated in block or generate statements. Open the synthesized or implemented design and look at the ectual path of the object. Test the constraint in the TCL console.

not-found objects will cause timing and placement constraints nott be applied properly. This, for example, will likely cause the placer to fail for some obscure reason .

Incremental reuse overrides
---------------------------



Disable incremental reuse on implementation if physical constraints (e.g. PBLOCKS) are changes, otherwise the new constrains will be ignored.

This may apply to syhthesis as well.



Vivado quirks
=============

Simulation
----------

Vivado simulation (VS) does not seem to have a good reputation, sepecially for VHDL2008. Howeer, the tool seems to simulate the current code correctly, even as we ass more and more VHDL 2008 idioms in the code.

Older versions of VS had a hard time handling ``struct`` passed as port arguments, or indexing those right on the port assignments. We also discovered a buffer overrun condition where setting value in one field affected another one. But these seem to have been solved as of Vivado 2022.2.

Nevertherless, here are the list of strange behaviors that were observed


- Feb 2025, Vivado 2022.2: Crash caused by a assignment outside the range of a vector. No useful message. Had to bisect-disable code to find this out.
- Jan 2025, Vivado 2022.2: Got the impression that we could not use VHDL 2008 on the testbench, but it was ok for any submodules. But then it worked for another testbench, with or without the ``-2008`` simualtion option. Maybe an error on my part?
- 2022.2: restarting a simulation after adding signals at the bottom  of the waveform list sometimes just crashes the GUI. Save often.

Generic tricks

- When simulaiton does not work because of missing modules, restart a full simulation instead of using the re-run button.



FIFO implementation
===================


BRAM availability is a limiting factor in `chFPGA`, often followed closely by slice (LUT & REG) resources. We have to use BRAM is the most efficient way possible, and use embedded FIFOs whenever possible so the FIFO logic does not use fabric resources to make a FIFO out of a BRAM.

There can be only one FIFO per RAMB36 site, either a FIFO18 or a FIFO36. If the FIFO18 is used, the other part of the RAMB36 site can be used as a RAMB18.


.. image:: ./images/PLATFORMS/Kintex7/7-series_valid_FIFO_RAMB_combinations.png


RAMB18 & FIFO18 overestimation issue
------------------------------------

In places where we need lots of FIFOs, like in the Corner-Turn engine's bin selectors, we implement odd- and even-indexed FIFOs alternatively using embedded FIFO18 and a RAMB18 soft FIFOs in order to maximize RAM usage density and minimize fabric utilization.

Note that before placement, Vivado 2022.2 tools will for some reason assume that the FIFO18 and RAMB18 cannot share the same site and overestimate the resource requirements, and issues warnings if the assigned PBLOCK does not contain the overestimated number of sites (even if the placer will eventually fit everything as it should). It will fails placement if the IS_SOFT property of the PBLOCK is FALSE.

The solution for very tight PBLOCKS it to use IS_SOFT=TRUE and let the logic spill out of the block.

Instantiation method
--------------------

We used to use IP Generator blocks to instantiate FIFOs and RAMs, but those are stored in different files, per platform, and need to be regenerated each time the Vivado version changes, which is a pain to maintain.

We generally now prefer to instantiate FIFOs using XPM macros, since those are generally portable across platforms.

The exception to this rule are embedded (built-in) FIFOs: those are not supported by the XPM FIFO macro (as of Vivado 2022.2). We choose to instantiate the FIFO18 or FIFO36 directly, but need to have if-generate blocks to select the right version (E1 or E2)  based on the platform. See :entity:`CMAC44` for an example of this dual-platform use. Also look in the 1G Ethernet receiver for FIFO38, and UCAP and UCORR44 for Ultrascale memory generation


7-series FIFO output latencies for RAMB and Embedded (built-in) FWFT FIFO implementations
-----------------------------------------------------------------------------------------

On the 7-Series FPGAs, adding the embeded output register on RAMB-based soft FIFOs and built-in FIFOs dramatically helps timing closure (on a -2, TRCK_DO = 1.8 ns, TRCK_DO_REG=0.63 ns), but in some configurations it might create a extra latencies, even in FWFT mode.

- Builtin FIFO, FWFT, synchronous, DO_REG=True, Embedded only: **latency = 1**
- Builtin FIFO, FWFT, synchronous, DO_REG=False, Embedded only: latency = 0, (large TRCK_DO delay)
- Builtin FIFO, FWFT, asynchronous, DO_REG=True (mandatory in FIFO18 primitive): latency = 0
- BRAM FIFO, FWFT, synchronous, DO_REG=False, Latency = 0 (large TRCK_DO delay)
- BRAM FIFO, FWFT, synchronous, DO_REG=True, Embed only, Latency = 0
- BRAM FIFO, FWFT, synchronous, DO_REG=True, Fabric only, Latency = 0
- BRAM FIFO, FWFT, synchronous, DO_REG=True, Embed+Fabric, Latency = 0
- BRAM FIFO, FWFT, asynchronous, DO_REG=False, Latency = 0 (large TRCK_DO delay)
- BRAM FIFO, FWFT, asynchronous, DO_REG=True, Embed only, Latency = 0
- BRAM FIFO, FWFT, asynchronous, DO_REG=True, Fabric only, Latency = 0
- BRAM FIFO, FWFT, asynchronous, DO_REG=True, Embed+Fabric, Latency = 0

All configurations with output register (DO_REG=True) have a latency of 0, except for the synchronous builtin FIFO.

In other words, on a 7-series FPGA, if one need a zero latency on a low-resource embedded FIFO with output register, always use an asynchronous built-in FIFO, even if you need a synchronous one.

Resources
---------

- Kintex-7 memory resources (UG473):

   - Table 2-2, Figure 2-1
   - Table 2-5, DO_REG

- Kintex 7 datasheet - AC/DC characteristics (DS182)
- Play with parameters in the FIFO generator (13.2)

