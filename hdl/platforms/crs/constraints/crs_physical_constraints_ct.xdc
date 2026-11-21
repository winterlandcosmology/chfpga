############################################################################
##
##   CRS Rev1.0 Physical constraints - "-ct" config-specific
##
############################################################################


# -- QSFP Connector for 100G Ethernet (CGE)
# -- GTY QSFP28 ports - Bank 128
# Note: The pin assignments here overrides the pins assigned in the CMAC IP
set_property PACKAGE_PIN Y35 [get_ports {qsfp_txp[0]}]
set_property PACKAGE_PIN V35 [get_ports {qsfp_txp[1]}]
set_property PACKAGE_PIN T35 [get_ports {qsfp_txp[2]}]
set_property PACKAGE_PIN R33 [get_ports {qsfp_txp[3]}]

# -- Second 100G Ethernet link (CGE1): SFP28 cages 1 to 4, for a QSFP28 to 4x SFP28 breakout cable
# -- GTY Bank 129. These lines must stay after the QSFP lines: the first CMAC IP is generated for
# -- these transceivers, and the QSFP pins above move it to bank 128.
set_property PACKAGE_PIN P35 [get_ports {sfp_txp[0]}]
set_property PACKAGE_PIN N33 [get_ports {sfp_txp[1]}]
set_property PACKAGE_PIN L33 [get_ports {sfp_txp[2]}]
set_property PACKAGE_PIN J33 [get_ports {sfp_txp[3]}]
# The reference clock of CGE1 is bp_shuffle_refclk[0] (156.25 MHz, MGTREFCLK0 of bank 131, pin P31),
# which is defined in the common constraint files.

# -----
# 100G interface
# -----

# GTY reference clock, 156.25 MHz from fixed PLL, Bank 129
# This is config-specific
set_property PACKAGE_PIN W33 [get_ports clk156_p]
#set_property PACKAGE_PIN W33 [get_ports clk156_p]
# Note: clock period is defined by the CMAC IP and does not need to be defined below.
#create_clock -name CLK156 -period 6.4 [get_ports {clk156_p}]


########################################
########################################
# Floorplanning constraints
########################################
########################################



create_pblock CGE
add_cells_to_pblock [get_pblocks CGE] [get_cells -quiet [list chfpga0/DATA_LINK_GEN.data_link_sel_gen.upack_cge_case.cge0]]
resize_pblock [get_pblocks CGE] -add {SLICE_X0Y240:SLICE_X12Y299}
resize_pblock [get_pblocks CGE] -add {DSP48E2_X0Y96:DSP48E2_X0Y119}
resize_pblock [get_pblocks CGE] -add {PCIE4CE4_X0Y0:PCIE4CE4_X0Y0}
resize_pblock [get_pblocks CGE] -add {RAMB18_X0Y96:RAMB18_X0Y119}
resize_pblock [get_pblocks CGE] -add {RAMB36_X0Y48:RAMB36_X0Y59}


# Second 100G link. Its transceivers (bank 129) are at rows Y300 to Y359, and its hard MAC
# (CMACE4_X0Y1) is at rows Y360 to Y419.
create_pblock CGE1
add_cells_to_pblock [get_pblocks CGE1] [get_cells -quiet [list chfpga0/DATA_LINK_GEN.data_link_sel_gen.upack_cge_case.cge1_gen.cge1]]
resize_pblock [get_pblocks CGE1] -add {SLICE_X0Y300:SLICE_X12Y359}
resize_pblock [get_pblocks CGE1] -add {RAMB18_X0Y120:RAMB18_X0Y143}
resize_pblock [get_pblocks CGE1] -add {RAMB36_X0Y60:RAMB36_X0Y71}


create_pblock UPACK
add_cells_to_pblock [get_pblocks UPACK] [get_cells -quiet [list chfpga0/DATA_LINK_GEN.data_link_sel_gen.upack_cge_case.upack0]]
resize_pblock [get_pblocks UPACK] -add {SLICE_X15Y180:SLICE_X19Y419 SLICE_X13Y220:SLICE_X14Y249}
resize_pblock [get_pblocks UPACK] -add {RAMB18_X1Y88:RAMB18_X1Y99}
resize_pblock [get_pblocks UPACK] -add {RAMB36_X1Y44:RAMB36_X1Y49}
set_property EXCLUDE_PLACEMENT 1 [get_pblocks UPACK]
set_property IS_SOFT FALSE [get_pblocks UPACK]



create_pblock CORN
add_cells_to_pblock [get_pblocks CORN] [get_cells -quiet [list chfpga0/ct_gen.ct_case.uct_case.ct0]]
resize_pblock [get_pblocks CORN] -add {SLICE_X6Y360:SLICE_X11Y419 SLICE_X0Y330:SLICE_X5Y419}
resize_pblock [get_pblocks CORN] -add {BUFG_GT_X0Y144:BUFG_GT_X0Y191}
resize_pblock [get_pblocks CORN] -add {BUFG_GT_SYNC_X0Y90:BUFG_GT_SYNC_X0Y119}
resize_pblock [get_pblocks CORN] -add {DSP48E2_X0Y144:DSP48E2_X0Y167}
resize_pblock [get_pblocks CORN] -add {RAMB18_X0Y144:RAMB18_X0Y167}
resize_pblock [get_pblocks CORN] -add {RAMB36_X0Y72:RAMB36_X0Y83}
set_property IS_SOFT FALSE [get_pblocks CORN]





