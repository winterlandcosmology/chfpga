#!/bin/bash
# Full-rate simulation of capture bus -> rawpack -> cge -> behavioural 100G MAC model, followed by
# a check of every frame the MAC model sent (check_frames.py).
# Needs the Vivado environment (source setenv.sh from the repository root) and python3.
#
# Usage: ./run_chain.sh [GENERIC=value ...]     e.g. ./run_chain.sh SINGLE=1 RUN_TIME_US=2000
# Generics of the MAC model are set with LINE_RATE=<bits/s> (default 100e9).
set -e
here=$(cd "$(dirname "$0")" && pwd)
hdl=$here/../../../hdl
mkdir -p "$here/work" && cd "$here/work"
generics=()
for g in "$@"; do generics+=(-generic_top "$g"); done
rm -f cmac_frames.txt
xvlog -nolog "$XILINX_VIVADO/data/verilog/src/glbl.v" > /dev/null
xvhdl -2008 -nolog "$hdl/chfpga_package.vhd" "$hdl/bsb/bsb_regs.vhd" "$hdl/bsb/bsb_async_fifo.vhd" \
	"$hdl/data_links/100GE_UDP_MAC/rawpack.vhd" "$hdl/testbenches/cmac_usplus_1_sim_model.vhd" "$hdl/data_links/100GE_UDP_MAC/cge.vhd" \
	"$hdl/testbenches/tb_package.vhd" "$hdl/testbenches/rawpack_cge_testbench.vhd" | grep -E 'ERROR|WARNING' || true
xelab -nolog -L xpm -L unisim work.rawpack_cge_testbench work.glbl -s rawpack_cge_tb "${generics[@]}" | grep -E 'ERROR' || true
# SLEEP_CHECK and EMPTY_CHECK are start-up messages of the XPM FIFO simulation models while in reset
xsim rawpack_cge_tb -nolog -R | grep -E 'DONE|Failure|Error|ERROR|overflow|underflow' | grep -vE 'SLEEP_CHECK|EMPTY_CHECK' || true
python3 "$here/check_frames.py" cmac_frames.txt --min-packets 10
