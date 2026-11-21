#!/bin/bash
# Compiles and runs the self-checking rawpack testbench with the Vivado simulator (xsim).
# Needs the Vivado environment (source setenv.sh from the repository root).
#
# Usage: ./run.sh [GENERIC=value ...]     e.g. ./run.sh SINGLE=1 GAP_PERIOD=5 BLOCKS_PER_PACKET=90
# Prints "RAWPACK TEST PASSED" on success. Work files go in ./work (not versioned).
set -e
here=$(cd "$(dirname "$0")" && pwd)
hdl=$here/../../../hdl
mkdir -p "$here/work" && cd "$here/work"
generics=()
for g in "$@"; do generics+=(-generic_top "$g"); done
rm -rf xsim.dir/rawpack_tb  # never run an old snapshot when the compilation fails
xvlog -nolog "$XILINX_VIVADO/data/verilog/src/glbl.v" > /dev/null
xvhdl -2008 -nolog "$hdl/chfpga_package.vhd" "$hdl/bsb/bsb_regs.vhd" "$hdl/bsb/bsb_async_fifo.vhd" \
	"$hdl/data_links/100GE_UDP_MAC/rawpack.vhd" "$hdl/testbenches/tb_package.vhd" "$hdl/testbenches/rawpack_testbench.vhd" > compile.log 2>&1 \
	|| { grep ERROR compile.log; echo "Failure: compilation error"; exit 1; }
xelab -nolog -L xpm -L unisim work.rawpack_testbench work.glbl -s rawpack_tb "${generics[@]}" > elaborate.log 2>&1 \
	|| { grep ERROR elaborate.log; echo "Failure: elaboration error"; exit 1; }
xsim rawpack_tb -nolog -R | grep -E 'PASSED|Failure|Error|ERROR|header word'
