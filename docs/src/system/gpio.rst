.. title:: gpio

*********************************************************
:entity:`gpio` (*gpio.vhd*): General Purpose Input/Output
*********************************************************

.. toctree::
   :maxdepth: 1
   :hidden:

   irigb_decoder
   irigb_encoder
   irigb_comparator
   core_registers
   arm_spi
   ../navbar_separator


The :entity:`gpio` provides a bank of configuration registers as well as:

- Motherboard Buck Synchronization
- Backplane Buck Synchronization
- IRIG-B decoder (:entity:`irigb_decoder`) and generator
- IRIG-B tagging of Referenece clock counter and Frame counters
- External ARM processor SPI memory-map interface
- Externally configurable core configuration registers


Overview
========


Schematic
=========

.. figure:: ../images/SYSTEM/gpio.svg
    :width: 100%



Entity documentation
====================

.. parse:: hdl/system/gpio.vhd

.. autoentity:: gpio

Parameters
==========

- **PLATFORM_TYPE:** Target platform, defined as ``platform_type_enum`` in :ref:`chfpga-package`.
- **COOKIE:** 7-bit application firmware identifier read back in the STATUS register (default ``0x42``).
- **PROTOCOL_VERSION:** 16-bit protocol version reported to host software for compatibility checking.
- **NUMBER_OF_ADCS:** Number of ADC channels implemented in the firmware.
- **CHANNELIZERS_CLOCK_SOURCE:** ADC lane index from which the channelizer clocks are derived.
- **ADC_SAMPLES_PER_FRAME / ADC_SAMPLES_PER_WORD / ADC_BITS_PER_SAMPLE:** ADC data frame geometry parameters.
- **NUMBER_OF_ADC_BOARDS:** Number of FMC ADC mezzanine boards (default 1).
- **NUMBER_OF_CHANNELIZERS / NUMBER_OF_CHANNELIZERS_WITH_FFT:** F-engine channelizer counts.
- **FFT_TYPE / CT_TYPE / CT_LEVEL:** FFT and corner-turn engine type enumerations.
- **NUMBER_OF_CT_INPUTS / NUMBER_OF_CT_CB1_OUTPUTS / NUMBER_OF_GPU_LINKS:** Corner-turn and GPU link counts.
- **NUMBER_OF_CORRELATORS / NUMBER_OF_CHANNELIZERS_TO_CORRELATE:** X-engine correlator configuration.
- **NUMBER_OF_BUCK_SYNC_LINES:** Number of buck regulator SYNC output lines (default 16).
- **BUCK_SYNC_ENABLE:** Default state of the buck sync outputs at startup (default ``TRUE``).
- **BUCK_CLK_DIVIDE_FACTOR:** Divider for the buck sync clock (``200 MHz / factor / 16`` gives the sync frequency).
- **MAC_ADDRESS_OUI_CODE:** 24-bit OUI prefix for the MAC address (default ``X"000A35"``).
- **NUMBER_OF_USER_SMA_SIGNALS:** Number of sources available in the user SMA output mux.
- **IMPLEMENT_LCD:** When ``TRUE``, instantiates LCD display control logic.
- **IMPLEMENT_SWITCHER_SYNC:** When ``TRUE``, instantiates buck regulator SYNC generation logic.
- **IMPLEMENT_FAN:** When ``TRUE``, instantiates fan tachymeter debounce and PWM control.
- **IMPLEMENT_ARM_SPI:** When ``TRUE``, instantiates the :entity:`arm_spi` slave interface.
- **SIM:** When ``TRUE``, enables simulation mode.

Interface
=========

BSB control interface
---------------------

- ``s/m_axis_bsb_t*``: BSB (Byte-Stream Bus) 8-bit command/reply stream interface.
- ``bsb_clk``/``bsb_rst``: BSB clock (125 MHz) and reset.

UDP networking configuration
-----------------------------

- ``local_mac_addr``/``local_base_ip_addr``/``local_base_ip_port``: Local FPGA UDP network identity, managed through the core registers via ARM-SPI or BSB.
- ``remote_mac_addr1``/``remote_ip_addr1``/``remote_ip_port1``: Remote address for UDP data channel 1.
- ``remote_ip_port0``: Destination port for UDP command reply channel 0.
- ``host_frame_read_rate``: Throttling parameter controlling the UDP output data rate.
- ``sfp_status_vector``/``sfp_config_vector``: SFP/SGMII bridge status and configuration.
- ``udp_tx_frame``/``udp_rx_frame``/``udp_tx_overflow``/``udp_rx_overflow``: UDP link health monitoring inputs.
- ``cmd_packet_counter``/``rply_packet_counter``: UDP packet counters for diagnostics.
- ``udp_stack_reset``/``ctrl_master_reset``: Software-triggered reset outputs.

ARM SPI interface
-----------------

- ``arm_spi_sck/miso/mosi/cs_n``: SPI bus to the ARM processor, used to access the core registers via :entity:`arm_spi`.

IceBoard I/O (bidirectional / tristate)
-----------------------------------------

- ``arm_irq_in/out/oe``/``flash_cs_in/out/oe``/``gpio_irq_in/out/oe``/``gpio_rst_in/out/oe``/``uart_rx_in/out/oe``/``uart_tx_in/out/oe``: Tristate I/O signals for IceBoard-specific QC testing.

Backplane and buck regulator
-----------------------------

- ``buck_sync``: Buck switching regulator SYNC outputs with individually programmable 16-phase offsets.
- ``bp_buck_sync``: Backplane buck SYNC (bidirectional open-drain).
- ``bp_gpio_int_in/out/oe``: Backplane open-drain interrupt line (connects every board in a crate).

ADC control
-----------

- ``adc_rst``: ADC board reset outputs, one per board.
- ``adc_cal_freeze``/``adc_cal_frozen``: RfSoC ADC calibration freeze control and frozen-status feedback.
- ``adc_cal_signal_detect``: RfSoC ADC calibration signal detect flags.
- ``adc_clear_or``/``adc_clear_ov``: Clear overrange/overvoltage sticky flags.
- ``adc_or``/``adc_ov``/``adc_cm_ov``/``adc_cm_uv``/``adc_ot1``/``adc_ot2``: ADC alarm status inputs.
- ``adc_pll_lock``: ADC mezzanine PLL lock status inputs.
- ``lcd_db``/``lcd_e``/``lcd_rs``/``lcd_rw``: LCD display interface (when ``IMPLEMENT_LCD = TRUE``).

IRIG-B
------

- ``irigb_mux_in``: 8-input vector of IRIG-B source signals fed to the :entity:`irigb_decoder`.
- ``irigb_before_target``: High when the current IRIG-B time is before the programmed target timestamp.
- ``irigb_pps``: Pulse-per-second output derived from the IRIG-B decoder.
- ``irigb_out``: IRIG-B encoded time output from the internal :entity:`irigb_encoder`.

User output mux and event counter
-----------------------------------

- ``user_mux_in``/``user_mux_out``/``user_mux_oe``: User-selectable signal output mux (4 outputs).
- ``user_bit``: Two user-programmable bits exposed through registers.
- ``event_ctr_clk``/``event_ctr_en``/``event_ctr_inc``/``event_ctr_reset``: Interface to the 48-bit frame event counter.
- ``pwm_clk``/``pwm_ctr_en``/``pwm_reset``/``pwm_out``: Programmable PWM generator interface.
- ``fan_pwm``: Fan PWM output (held at 100%).
- ``fan_tach``: Fan tachymeter input. Debounced internally.
- ``fan_tach_div2``: Divide-by-2 debounced fan signal for the frequency counter.

Clocks and control outputs
---------------------------

- ``clk200``/``clk200_reset``: 200 MHz system clock and its reset.
- ``clk10``: 10 MHz backplane reference clock.
- ``clk10_sel``: 10 MHz reference clock source selection output (CRS platform).
- ``sysmon_clk_enable``: enables the SYSMON clock buffer (control byte 3, bit 0, default 1). Set to 0 during data taking: the 62.5 MHz SYSMON clock couples into the RF-ADC inputs and appears as a 12.5 MHz comb at 3.2 GSPS (5 clock cycles = 256 samples). Set to 1 before reading the SYSMON or the device DNA.
- ``dna_clk``: Clock for the FPGA DNA_PORT primitive (max 97 MHz).
- ``pll_sync``: External PLL SYNC pulse output.
- ``chan_clk_sel``: Channelizer clock source selection output.
- ``user_reset``/``sysmon_user_reset``/``adcdaq_reset_async``/``chan_clk_reset_async``/``chan_reset_async``/``corr_reset_async``/``blinker_reset``/``ctrl_reset_pulse``: Software-initiated reset and control outputs.


Implementation details
======================

Principle of operations
-----------------------

The :entity:`gpio` entity is the central I/O control hub of the SYSTEM submodule. All software access is provided through a single BSB command/reply stream, handled by an internal ``bsb_regs`` instance that exposes 51 control bytes and 44 status bytes. Control byte fields are directly decoded into combinatorial signal assignments or feed sequential processes; status bytes assemble read-only firmware parameters and live monitoring signals.

Architecture
------------

Optional sub-entities are instantiated based on generics: :entity:`arm_spi` (when ``IMPLEMENT_ARM_SPI`` is ``TRUE``) bridges the external SPI bus to the :entity:`core_registers` 32-bit req/ack interface, which holds persistent networking and IRIG-B configuration accessible across resets. :entity:`irigb_decoder`, :entity:`irigb_encoder`, and :entity:`irigb_comparator` are unconditionally instantiated. The buck sync generator counts ``clk200`` cycles to produce ``NUMBER_OF_BUCK_SYNC_LINES`` SYNC pulses with individually programmable 4-bit phase offsets (one of 16 phases). The fan tachymeter debouncer waits for a 17-bit count of stable cycles before accepting a new state, then outputs a divide-by-2 signal for the frequency counter. The FPGA serial number is read from the ``DNA_PORT`` / ``DNA_PORTE2`` primitive by a 57-cycle shift-register process. The firmware timestamp is read from the ``USR_ACCESS`` / ``USR_ACCESSE2`` primitive and published in the BSB status bytes and in a core register.

Clocking
--------

Four clock domains are used. The BSB register interface and ARM-SPI adapter run on ``bsb_clk`` (125 MHz). The buck sync generator, fan debouncer, IRIG-B decoder, and all time-capture logic run on ``clk200`` (200 MHz). The 10 MHz reference clock free-running counter runs on ``clk10``. The event counter runs on ``event_ctr_clk`` (frame clock, typically derived from the ADC clock). Cross-domain trigger signals use ``xpm_cdc_single`` synchronizers; IRIG-B timestamp capture uses toggle-based level signalling to guarantee no event is missed regardless of the relative clock frequencies.


UDP Memory Map
==============

.. include-docs:: gpio
    :start-after: GPIO Module

ARM-SPI Memory Map
==================

.. .. include-docs:: gpio
..     :start-after: GPIO Module


Design Notes
============

Backplane Self-synchronizion and inter-board communication module
-----------------------------------------------------------------


We created an experimental module ``bp_buck_sync`` to allow the boards in a crate to:

- collaborate to generate a single clock  that could be used to synchronize the backplane buck without requiring a master board in a specific slot.
- communicate with each other


This module was not used in the field, and caused implementation to fail on ZCU111 platform, so we just remove it.


The self-sync was based on the clock-slowing principle of I2C, where any peripheral can hold the clock down to slow down the transactions, causing all the devices to operate at the speed of the slowest device on the bus.

Communication between boards was acheived by modulating the clock.