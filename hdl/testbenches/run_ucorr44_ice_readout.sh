#!/usr/bin/env bash
# Compile and run the ICE corr16 UCORR44 readout testbench with xsim (Vivado 2022.2).
#
# Usage:
#   hdl/testbenches/run_ucorr44_ice_readout.sh [-a] [-d build_dir] [GENERIC=value ...]
#
#   -a   keep XPM SystemVerilog assertions (out-of-range warnings). Off by default:
#        they fire on every bank-1 write (~35k lines per frame) and swamp long runs.
#   GENERIC=value  testbench generics, e.g. STIM=2 N_INTEG=4096 NO_ACCUM=1 CORR_ID=0
#                  SEND_PERIOD=1 N_READOUTS=4 RUN_FRAMES=0 NCHAN=16
#                  NCHAN=16 is the ICE corr16 core (~1 frame/s, i.e. hours per run);
#                  NCHAN=4 is a reduced model with the same control/address logic, ~15x faster.
#
# Example (regression, a few minutes):
#   hdl/testbenches/run_ucorr44_ice_readout.sh NCHAN=4 STIM=2 N_INTEG=2048 N_READOUTS=3
#
# The build directory defaults to <repo>/temp/ucorr44_ice_sim (temp/ is git-ignored); use
# separate directories (-d) for runs executed in parallel.
# Results: <build_dir>/<tag>_{summary,packets,captures,word0,trace}.txt and xsim_<snapshot>.log.
# Exit status is nonzero unless the summary ends with "RESULT: PASS".
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
VIVADO_SETTINGS=${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}
ASSERTS=0
BUILD=""
while getopts "ad:" opt; do
    case $opt in
        a) ASSERTS=1 ;;
        d) BUILD=$OPTARG ;;
        *) exit 2 ;;
    esac
done
shift $((OPTIND - 1))

UCMAC=$REPO/hdl/corr/UCMAC44_ARRAY.vhd
BUILD=${BUILD:-$REPO/temp/ucorr44_ice_sim}
GEN=()
TAG=""
for g in "$@"; do
    GEN+=(-generic_top "$g")
    TAG="${TAG}_${g}"
done
SNAP=snap${TAG:-_default}
[ "$ASSERTS" = 1 ] && SNAP=${SNAP}_assert
TB=$REPO/hdl/testbenches/ucorr44_ice_readout_testbench.vhd

mkdir -p "$BUILD"
cd "$BUILD"
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS" >/dev/null

if [ ! -f xsim.dir/work/.compiled ] || [ "$UCMAC" -nt xsim.dir/work/.compiled ] ||
   [ "$TB" -nt xsim.dir/work/.compiled ] || [ "$REPO/hdl/corr/UCORR44.vhd" -nt xsim.dir/work/.compiled ]; then
    xvhdl -2008 --work work \
        "$REPO/hdl/chfpga_package.vhd" \
        "$UCMAC" \
        "$REPO/hdl/corr/UCORR44.vhd" \
        "$TB" > xvhdl.log
    touch xsim.dir/work/.compiled
fi
EXTRA=()
[ "$ASSERTS" = 1 ] || EXTRA=(--ignore_assertions)
xelab -debug ${XELAB_DEBUG:-off} -O3 --timescale 1ns/1ps --relax -mt 8 "${EXTRA[@]}" "${GEN[@]}" \
    -L xpm -L unisim work.ucorr44_ice_readout_testbench -s "$SNAP" > "xelab_$SNAP.log"
xsim "$SNAP" -R --onfinish quit --log "xsim_$SNAP.log"
grep -q 'RESULT: PASS' "xsim_$SNAP.log"
