``corr8`` configuration (*chfpga_crs_corr8_config.vhd*)
=======================================================

8-channel F-Engine, UCT corner-turn (single-board), and 8-input :math:`N^2` correlator. The 100G QSFP link carries the raw ADC streamer only.

Configuration parameters
-------------------------

- :ref:`CONFIG_CHAN_IMPLEMENT_FFT <config_chan_implement_fft>` — TRUE; F-Engine with FFT
- :ref:`CONFIG_CHAN_FFT_TYPE <config_chan_fft_type>` — CHORD; 14-bit, 16384 samples, 32+32 output
- :ref:`CONFIG_CHAN_CAPTURE_TYPE <config_chan_capture_type>` — UCAP; URAM-based centralized capture
- :ref:`CONFIG_CHAN_NUMBER_OF_CAPTURE_SOURCES <config_chan_number_of_capture_sources>` — 2
- :ref:`CONFIG_CHAN_SCALER_USE_COMPLEX_GAINS <config_chan_scaler_use_complex_gains>` — FALSE
- :ref:`CONFIG_NUMBER_OF_CHANNELIZERS_WITH_FFT <config_number_of_channelizers_with_fft>` — 8
- :ref:`CONFIG_CT_TYPE <config_ct_type>` — UCT; CHORD-like format
- :ref:`CONFIG_CT_LEVEL <config_ct_level>` — 1; single-board, no backplane
- :ref:`CONFIG_CT_CLK_SOURCE <config_ct_clk_source>` — ADC_CLK; 400 MHz processing clock
- :ref:`CONFIG_CT_LANE_TO_LINK_MAP <config_ct_lane_to_link_map>` — (0 => -1); bypass lane
- :ref:`CONFIG_CORR_TYPE <config_corr_type>` — UCORR44; 8-input correlator
- :ref:`CONFIG_CORR_READOUT_BINS <config_corr_readout_bins>` — (0, 1, 2, 3); bins for readout
- :ref:`CONFIG_DATA_LINK_TYPE <config_data_link_type>` — RAW_CGE; 100G link with the raw ADC streamer (``rawpack``), no ``upack``

Package definition
------------------

.. parse:: hdl/platforms/crs/chfpga_crs_corr8_config.vhd

Implementation details
======================

Principle of operations
-----------------------

This package defines compile-time constants for a self-contained, single-board CRS 8-input correlator. It enables 8 CHORD-format F-Engine channelizers with URAM-based centralized capture, a single-board UCT corner-turn (``CT_LEVEL = 1``) with a bypass lane and no backplane data exchange, and an 8-input UCORR44 correlator that reads out four spectral bins locally. The corner-turned data is not offloaded in real time. The 100G QSFP link (``DATA_LINK_TYPE = RAW_CGE``) carries only the raw ADC streamer: ``rawpack`` and ``cge`` without ``upack``, so the link needs no UltraRAM and the correlator keeps its 64 blocks. The 100G logic is placed with ``crs_physical_constraints_raw_cge.xdc``; its area overlaps the left columns of the correlator area, which is not changed.
