#*****************************************************************************************
# Vivado (TM) v2022.2 (64-bit)
#
# Defines a number of filesets to be used to create projects
#
#
#*****************************************************************************************


# directives
set no_lc "1"


# List of files used in this project

# Set the repo directory to access files outside of the project dir
# We assume we are two levels down from the repo root, e.g. repo_dir/xilinx_projects/my_project_name/.
set repo_dir [file normalize "../../"]


# set ip_dir "${repo_dir}/_Cores/"
set hdl_dir "${repo_dir}/hdl/"
# set const_dir "${repo_dir}/constraints/"
set bd_name ""

set hdl_base_files [list  \
 "chfpga_package.vhd" \
 "chfpga.vhd" \
 "utils/generic_fifo.vhd" \
 "utils/axis_merge.vhd" \
 "bsb/axis_sync_fifo.vhd" \
 "bsb/bsb_sync_fifo.vhd" \
 "bsb/bsb_router.vhd" \
 "bsb/bsb_regs.vhd" \
 "bsb/bsb_async_fifo.vhd" \
 "bsb/bsb_master.vhd" \
 "system/irigb_package.vhd" \
 "system/core_registers.vhd" \
 "system/irigb_decoder.vhd" \
 "system/irigb_comparator.vhd" \
 "system/irigb_encoder.vhd" \
 "system/system.vhd" \
 "system/gpio.vhd" \
 "system/freq_ctr.vhd" \
 "system/refclk.vhd" \
 "system/sysmon.vhd" \
 "system/blinker.vhd" \
 "system/clocks.vhd" \
 "chan/chan.vhd" \
 "chan/chan_array.vhd" \
 "chan/lfsr.vhd" \
 "chan/funcgen.vhd" \
 "chan/fft_delay.vhd" \
 "chan/fft.vhd" \
 "chan/scaler_mul.vhd" \
 "chan/scaler.vhd" \
 "chan/chan_fifo.vhd" \
 ]



# IP cores paths are relative to hdl/platforms/<platform_name>/ip_cores
set fft_type_chime "FFT2/FFT2.xci"
set fft_type_hirax "hirax_bit_growth_0/hirax_bit_growth_0.xci"
set fft_type_hirax_3dsp "hirax_bitgrowth_3dsp_24bit_jun8_0/hirax_bitgrowth_3dsp_24bit_jun8_0.xci"
set fft_type_chord "pfb_fft_bitgrowth_0/pfb_fft_bitgrowth_0.xci"

#*****************************************************************************************
# ICE Platform
#*****************************************************************************************

set ice_platform_dir "${hdl_dir}/platforms/ice"
set ice_target_part "xc7k420tffg901-2"

set ice_ct_ooc_ip_files $fft_type_hirax_3dsp
set ice_corr16_ooc_ip_files $fft_type_hirax_3dsp

# SCALER_CMUL/SCALER_CMUL.xci to be added if using complex gains

set ice_base_ip_files [list \
  "gmii_to_sgmii_bridge/gmii_to_sgmii_bridge.xci"\
]

set ice_ct_ip_files [concat $ice_base_ip_files [list \
  "SHUFFLE_BIN_SEL_FLAGS_FIFO4/SHUFFLE_BIN_SEL_FLAGS_FIFO4.xci" \
  "SHUFFLE_BIN_SEL_DATA_FIFO_EMBED/SHUFFLE_BIN_SEL_DATA_FIFO_EMBED.xci" \
  "SHUFFLE_BIN_SEL_DATA_FIFO_BRAM/SHUFFLE_BIN_SEL_DATA_FIFO_BRAM.xci" \
  "SHUFFLE_BIN_SEL_FLAGS_FIFO6/SHUFFLE_BIN_SEL_FLAGS_FIFO6.xci" \
  "SHUFFLE_BIN_SEL_MASK_RAM/SHUFFLE_BIN_SEL_MASK_RAM.xci" \
  "SHUFFLE_CROSSBAR_ALIGN_FIFO/SHUFFLE_CROSSBAR_ALIGN_FIFO.xci" \
  "XGLINK_RX_DATA_FIFO/XGLINK_RX_DATA_FIFO.xci" \
  "XGLINK_TX_DATA_FIFO/XGLINK_TX_DATA_FIFO.xci" \
  "CHDIST_FRAME_FIFO/CHDIST_FRAME_FIFO.xci" \
  "CHDIST_SCALER_FLAGS_FIFO/CHDIST_SCALER_FLAGS_FIFO.xci" \
  "CHDIST_DATA_EMBED_FIFO/CHDIST_DATA_EMBED_FIFO.xci" \
  "MASK_RAM/MASK_RAM.xci" \
  "XG_UDP_MAC_TX_HEADER_FIFO/XGMII_UDP_MAC_TX_HEADER_FIFO.xci" \
  "XG_UDP_MAC_TX_DATA_FIFO/XGMII_UDP_MAC_TX_DATA_FIFO.xci" \
 ]]

set ice_corr16_ip_files $ice_base_ip_files

#  "KC705/CORR44_DATA_FIFO/CORR44_DATA_FIFO.xci" \



set ice_hdl_base_files [concat $hdl_base_files [list \
  "platforms/ice/chfpga_ice.vhd" \
  \
  "system/spi.vhd" \
  "system/i2c.vhd" \
  "system/arm_spi.vhd" \
  \
  "chan/prober.vhd" \
  "chan/adcdaq.vhd" \
  \
  "ct/bct_engine.vhd"\
  \
  "data_links/1G_UDP_MAC/udp_mac_crc32.vhd" \
  "data_links/1G_UDP_MAC/udp_mac_tx.vhd" \
  "data_links/1G_UDP_MAC/udp_mac_rx.vhd" \
  "data_links/1G_UDP_MAC/udp_mac_gmii_to_sgmii.vhd" \
  "data_links/1G_UDP_MAC/udp_mac.vhd" \
  ]]


set ice_ct_hdl_files [concat $ice_hdl_base_files [list \
  "ct/align32.vhd"\
  "ct/chan_bin_sel.vhd"\
  "ct/chan_crossbar.vhd"\
  "ct/remap.vhd"\
  "ct/shuffle_bin_sel.vhd"\
  "ct/shuffle_crossbar.vhd"\
  \
  "data_links/XGLINK/xglink_bypass.vhd"\
  "data_links/XGLINK/xglink_crc32_32.vhd"\
  "data_links/XGLINK/xglink_tx.vhd"\
  "data_links/XGLINK/xglink_rx.vhd"\
  "data_links/XGLINK/xglink_gtx.vhd"\
  "data_links/XGLINK/xglink_rx_startup_fsm.vhd"\
  "data_links/XGLINK/xglink_tx_startup_fsm.vhd"\
  "data_links/XGLINK/xglink_scrambler.vhd"\
  "data_links/XGLINK/xglink_block_sync.vhd"\
  "data_links/XGLINK/xglink_descrambler.vhd"\
  "data_links/XGLINK/xglink_core.vhd"\
  "data_links/XGLINK/xglink_array.vhd"\
  "data_links/XGLINK/xglink_sync_block.vhd"\
  \
  "data_links/10GE_UDP_MAC/xge_udp_mac_tx.vhd" \
  "data_links/10GE_UDP_MAC/xge_array.vhd" \
  ]]


set ice_corr16_hdl_files [concat $ice_hdl_base_files [list \
  "corr/UCMAC44_ARRAY.vhd"\
  "corr/UCORR44.vhd"\
  "corr/UCORR44_ARRAY.vhd"\
  ]]


#corr/CMAC44.vhd
#corr/CORR44.vhd
#corr/CORR44_ARRAY.vhd



#*****************************************************************************************
# KC705 Platform
#*****************************************************************************************

set kc705_platform_dir "${hdl_dir}/platforms/kc705"
set kc705_target_part "xc7k325tffg900-2"

set kc705_corr8_ooc_ip_files $fft_type_hirax_3dsp
# Paths relative to ${kc705_platform_dir}/ip_cores (includes hirax_bit_growth_3dsp copied from IceBoard tree)
set kc705_corr8_ip_files {}

set kc705_hdl_base_files [concat $hdl_base_files [list \
  "platforms/kc705/chfpga_kc705.vhd" \
  \
  "system/spi.vhd" \
  "system/i2c.vhd" \
  "system/arm_spi.vhd" \
  \
  "chan/prober.vhd" \
  "chan/adcdaq.vhd" \
  \
  "ct/bct_engine.vhd"\
  \
  "data_links/1G_UDP_MAC/udp_mac_crc32.vhd" \
  "data_links/1G_UDP_MAC/udp_mac_tx.vhd" \
  "data_links/1G_UDP_MAC/udp_mac_rx.vhd" \
  "data_links/1G_UDP_MAC/udp_mac.vhd" \
  ]]

set kc705_corr8_hdl_files [concat $kc705_hdl_base_files [list \
  "corr/UCMAC44_ARRAY.vhd"\
  "corr/UCORR44.vhd"\
  "corr/UCORR44_ARRAY.vhd"\
  ]]


#*****************************************************************************************
# CRS Platform
#*****************************************************************************************

set crs_platform_dir "${hdl_dir}/platforms/crs"
set crs_target_part "xczu47dr-ffvg1517-1-i"
set crs_bd_name "zynq_tcpipe_crs"

set crs_ooc_ip_files $fft_type_chord

set crs_corr8_ip_files []

# For corr32, 64, which need the GTYs for corner turning (paths relative to ${crs_platform_dir}/ip_cores)
set crs_corr_ip_files [list \
 "GTY/gtwizard_ultrascale_0.xci" \
 ]

set crs_ct_ip_files [list \
 "cmac_usplus_1/cmac_usplus_1.xci" \
]



set crs_hdl_base_files [concat $hdl_base_files [list \
 "platforms/crs/chfpga_crs.vhd" \
 "chan/ucap.vhd" \
 "ct/uct_engine.vhd" \
 ]]


set crs_corr_hdl_files [concat $crs_hdl_base_files [list \
 "ct/align64_fifo.vhd" \
 "ct/align64.vhd" \
 "data_links/XXVGLINK/xxvglink_data_fifo.vhd" \
 "data_links/XXVGLINK/xxvglink_bypass.vhd" \
 "data_links/XXVGLINK/crc32_64.vhd" \
 "data_links/XXVGLINK/xxvglink_tx.vhd" \
 "data_links/XXVGLINK/xxvglink_rx.vhd" \
 "data_links/XXVGLINK/xxvglink_scrambler.vhd" \
 "data_links/XXVGLINK/xxvglink_block_sync.vhd" \
 "data_links/XXVGLINK/xxvglink_descrambler.vhd" \
 "data_links/XXVGLINK/xxvglink_core.vhd" \
 "data_links/XXVGLINK/xxvglink_array.vhd" \
 "corr/UCMAC44_ARRAY.vhd" \
 "corr/UCORR44.vhd" \
 "corr/UCORR44_ARRAY.vhd" \
 ]]

set crs_ct_hdl_files [concat $crs_hdl_base_files [list \
  "ct/upack.vhd" \
  "data_links/100GE_UDP_MAC/rawpack.vhd" \
  "data_links/100GE_UDP_MAC/cge.vhd"\
  ]]


#*****************************************************************************************
# ZCU111 Platform
#*****************************************************************************************

set zcu111_platform_dir "${hdl_dir}/platforms/zcu111"
set zcu111_target_part "xczu28dr-ffvg1517-2-e"
set zcu111_bd_name "zynq_tcpipe_zcu111"

# Same CHORD PFB/FFT as CRS (out-of-context synthesis); see fft_type_chord
set zcu111_ooc_ip_files $fft_type_chord

set zcu111_ct_ip_files [list \
  "cmac_usplus_1/cmac_usplus_1.xci" \
 ]

set zcu111_hdl_base_files [concat $hdl_base_files [list \
  "platforms/zcu111/chfpga_zcu111.vhd" \
  "chan/ucap.vhd" \
  "ct/uct_engine.vhd" \
 ]]

set zcu111_ct_hdl_files [concat $zcu111_hdl_base_files [list \
  "ct/upack.vhd" \
  "data_links/100GE_UDP_MAC/rawpack.vhd" \
  "data_links/100GE_UDP_MAC/cge.vhd" \
 ]]


