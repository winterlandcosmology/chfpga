#!/usr/bin/env bash
# Compile and run the ICE corr16 UCORR44_ARRAY testbench with xsim (Vivado 2022.2).
#
# Usage:
#   hdl/testbenches/run_ucorr44_ice_array.sh [-e] [-d build_dir] [GENERIC=value ...]
#
#   -e   elaboration report only: elaborate with debug info and print the generics of the
#        array, the cores, the UCMAC44_ARRAYs and one xpm_memory instance (xsim get_value)
#   GENERIC=value  testbench generics: NCHAN (16 = ICE), STIM, N_INTEG, N_READOUTS,
#                  TREADY_PERIOD, RUN_FRAMES (-1 = elaboration report only)
#
# Example: hdl/testbenches/run_ucorr44_ice_array.sh NCHAN=4 N_INTEG=4096 STIM=2 TREADY_PERIOD=28
#   (TREADY_PERIOD=28 makes the reduced model's output roughly as slow as the bench's)
# Build directory defaults to <repo>/temp/ucorr44_ice_array (temp/ is git-ignored).
# Results: <build_dir>/a<NCHAN>_s<STIM>_n<N>_tp<TP>_{summary,packets}.txt, xsim_<snapshot>.log
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
VIVADO_SETTINGS=${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}
ELAB=0
BUILD=""
while getopts "ed:" opt; do
    case $opt in
        e) ELAB=1 ;;
        d) BUILD=$OPTARG ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))
UCMAC=$REPO/hdl/corr/UCMAC44_ARRAY.vhd
BUILD=${BUILD:-$REPO/temp/ucorr44_ice_array}
GEN=()
TAG=""
for g in "$@"; do
    GEN+=(-generic_top "$g")
    TAG="${TAG}_${g}"
done
SNAP=snap${TAG:-_default}

mkdir -p "$BUILD"
cd "$BUILD"
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS" >/dev/null
xvhdl -2008 --work work \
    "$REPO/hdl/chfpga_package.vhd" \
    "$REPO/hdl/utils/generic_fifo.vhd" \
    "$REPO/hdl/bsb/bsb_regs.vhd" \
    "$UCMAC" \
    "$REPO/hdl/corr/UCORR44.vhd" \
    "$REPO/hdl/corr/UCORR44_ARRAY.vhd" \
    "$REPO/hdl/testbenches/ucorr44_ice_array_testbench.vhd" > xvhdl.log
xvlog --work work "$XILINX_VIVADO/data/verilog/src/glbl.v" > xvlog.log # xpm_cdc needs glbl
if [ "$ELAB" = 1 ]; then
    cat > elab_report.tcl <<'TCL'
run 10 ns
set T /ucorr44_ice_array_testbench/dut
proc show {label path {radix unsigned}} {
    if {[catch {set v [get_value -radix $radix $path]} err]} { set v "<$err>" }
    puts "ELABREPORT $label = $v"
}
foreach o {NCHAN NCORR NBINS_PER_CORR BIN_DECIMATION_FACTOR INPUT_WIDTH READOUT_BINS N_BITS_PER_BIN SOFT_NINTEG NCHAN_PER_CLK NCLK_PER_BIN URAM_MAX} {
    show "UCORR44_ARRAY.$o" "$T/$o"
}
foreach c {0 1} {
    set C "$T/\\corr_gen($c)\\/corr0"
    foreach o {NCHAN NCHAN_PER_CLK NBINS NDECIM NCORR CORR_NUMBER URAM_MAX READOUT_BIN P NCLK_PER_BIN NCLK NCMAC NCOL_PER_CLK} {
        show "UCORR44($c).$o" "$C/$o"
    }
    foreach o {NCMAC NPROD AUTOCORR_STRIDE CORR_NUMBER NCORR URAM_MAX READOUT_BIN BYTES_PER_PRODUCT} {
        show "UCMAC44_ARRAY($c).$o" "$C/corr0/$o"
    }
}
# xsim exposes no scopes below the generate here; the XPM configuration is reported by the
# XPM_MEMORY DRC messages printed at elaboration (grepped below).
quit
TCL
    xelab -debug typical --timescale 1ns/1ps --relax -mt 8 --ignore_assertions -generic_top RUN_FRAMES=-1 \
        -L xpm -L unisim work.ucorr44_ice_array_testbench work.glbl -s snap_elab > xelab_snap_elab.log
    timeout 900 xsim snap_elab -tclbatch elab_report.tcl --log xsim_snap_elab.log > /dev/null
    grep '^ELABREPORT' xsim_snap_elab.log | sed 's/^ELABREPORT //'
    echo "XPM_MEMORY DRC messages (one pair per xpm_memory_sdpram instance): $(grep -c 'XPM_MEMORY 30-1[69]' xsim_snap_elab.log)"
    grep -m2 'XPM_MEMORY 30-1[69]' xsim_snap_elab.log
    exit 0
fi
xelab -debug off -O3 --timescale 1ns/1ps --relax -mt 8 --ignore_assertions "${GEN[@]}" \
    -L xpm -L unisim work.ucorr44_ice_array_testbench work.glbl -s "$SNAP" > "xelab_$SNAP.log"
xsim "$SNAP" -R --onfinish quit --log "xsim_$SNAP.log"
