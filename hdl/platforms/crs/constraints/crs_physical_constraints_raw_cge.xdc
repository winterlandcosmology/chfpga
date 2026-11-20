############################################################################
##
##   CRS Rev1.0 Physical constraints - 100G link with the raw ADC streamer only
##   (DATA_LINK_TYPE = RAW_CGE), for configurations that also hold a correlator
##
############################################################################


# -- QSFP Connector for 100G Ethernet (CGE)
# -- GTY QSFP28 ports - Bank 128
# Note: The pin assignments here overrides the pins assigned in the CMAC IP
set_property PACKAGE_PIN Y35 [get_ports {qsfp_txp[0]}]
set_property PACKAGE_PIN V35 [get_ports {qsfp_txp[1]}]
set_property PACKAGE_PIN T35 [get_ports {qsfp_txp[2]}]
set_property PACKAGE_PIN R33 [get_ports {qsfp_txp[3]}]

# GTY reference clock, 156.25 MHz from fixed PLL, Bank 129
# Note: clock period is defined by the CMAC IP and does not need to be defined below.
set_property PACKAGE_PIN W33 [get_ports clk156_p]


########################################
# Floorplanning constraints
########################################

# 100G Ethernet. Same area as in the -ct configuration, next to the CMAC block and the QSFP
# transceivers. This area overlaps the left columns of the correlator pblock (CORR): CORR keeps
# the correlator inside its area but does not keep other logic out, so the two share those columns.
create_pblock CGE
add_cells_to_pblock [get_pblocks CGE] [get_cells -quiet [list chfpga0/DATA_LINK_GEN.data_link_sel_gen.raw_cge_case.cge0]]
resize_pblock [get_pblocks CGE] -add {SLICE_X0Y240:SLICE_X12Y299}
resize_pblock [get_pblocks CGE] -add {RAMB18_X0Y96:RAMB18_X0Y119}
resize_pblock [get_pblocks CGE] -add {RAMB36_X0Y48:RAMB36_X0Y59}
