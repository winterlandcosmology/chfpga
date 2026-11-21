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
upstream=1  # default of the UPSTREAM generic
for g in "$@"; do generics+=(-generic_top "$g"); [[ $g == UPSTREAM=* ]] && upstream=${g#*=}; done
rm -f cmac_frames.txt cmac_frames_1.txt
# The second link uses the second MAC IP: its simulation model is the same model with another name and another output file
sed -e 's/cmac_usplus_1/cmac_usplus_2/g' -e 's/cmac_frames.txt/cmac_frames_1.txt/' "$hdl/testbenches/cmac_usplus_1_sim_model.vhd" > cmac_usplus_2_sim_model.vhd
rm -rf xsim.dir/rawpack_cge_tb  # never run an old snapshot when the compilation fails
xvlog -nolog "$XILINX_VIVADO/data/verilog/src/glbl.v" > /dev/null
xvhdl -2008 -nolog "$hdl/chfpga_package.vhd" "$hdl/bsb/bsb_regs.vhd" "$hdl/bsb/bsb_async_fifo.vhd" \
	"$hdl/data_links/100GE_UDP_MAC/rawpack.vhd" "$hdl/testbenches/cmac_usplus_1_sim_model.vhd" cmac_usplus_2_sim_model.vhd "$hdl/data_links/100GE_UDP_MAC/cge.vhd" \
	"$hdl/testbenches/tb_package.vhd" "$hdl/testbenches/rawpack_cge_testbench.vhd" > compile.log 2>&1 \
	|| { grep ERROR compile.log; echo "Failure: compilation error"; exit 1; }
xelab -nolog -L xpm -L unisim work.rawpack_cge_testbench work.glbl -s rawpack_cge_tb "${generics[@]}" > elaborate.log 2>&1 \
	|| { grep ERROR elaborate.log; echo "Failure: elaboration error"; exit 1; }
# SLEEP_CHECK and EMPTY_CHECK are start-up messages of the XPM FIFO simulation models while in reset
xsim rawpack_cge_tb -nolog -R | grep -E 'DONE|Failure|Error|ERROR|overflow|underflow' | grep -vE 'SLEEP_CHECK|EMPTY_CHECK' || true
files=(cmac_frames.txt)
[ -s cmac_frames_1.txt ] && files+=(cmac_frames_1.txt)
[ -s cmac_frames.txt ] || files=(cmac_frames_1.txt)
python3 "$here/check_frames.py" "${files[@]}" --min-packets 10 --upstream "$upstream"
