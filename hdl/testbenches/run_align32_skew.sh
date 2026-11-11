#!/usr/bin/env bash
# Compile and run the align32 skew/window testbench with xsim (Vivado 2022.2).
#
# Usage: hdl/testbenches/run_align32_skew.sh [build_dir]
#
# The build directory defaults to <repo>/temp/align32_sim (temp/ is git-ignored).
# The simulation uses the real SHUFFLE_CROSSBAR_ALIGN_FIFO IP wrapper against the
# fifo_generator_v13_2_7 library shipped precompiled with xsim. Results are in
# <build_dir>/align32_skew_results.txt and the console log in <build_dir>/xsim_run.log.
# Exit status is nonzero unless the testbench prints "RESULT: PASS".
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
BUILD=${1:-$REPO/temp/align32_sim}
VIVADO_SETTINGS=${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}

mkdir -p "$BUILD"
cd "$BUILD"
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"

xvhdl -2008 --work work \
    "$REPO/hdl/chfpga_package.vhd" \
    "$REPO/hdl/platforms/ice/ip_cores/SHUFFLE_CROSSBAR_ALIGN_FIFO/gen/synth/SHUFFLE_CROSSBAR_ALIGN_FIFO.vhd" \
    "$REPO/hdl/ct/align32.vhd" \
    "$REPO/hdl/testbenches/align32_skew_testbench.vhd"

xelab -debug typical --timescale 1ns/1ps \
    -L fifo_generator_v13_2_7 -L unisim \
    work.align32_skew_testbench -s align32_skew_sim

xsim align32_skew_sim -R --onfinish quit --log xsim_run.log

grep -q 'RESULT: PASS' xsim_run.log
