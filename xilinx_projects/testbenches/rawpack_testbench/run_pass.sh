#!/bin/bash
# Compiles and runs the pass-through test of rawpack (rawpack_pass_testbench) with the Vivado simulator.
# Needs the Vivado environment (source setenv.sh from the repository root).
# Prints "RAWPACK PASS-THROUGH TEST PASSED" on success. Work files go in ./work/pass (not versioned).
set -e
here=$(cd "$(dirname "$0")" && pwd)
hdl=$here/../../../hdl
mkdir -p "$here/work/pass" && cd "$here/work/pass"
rm -rf xsim.dir/rawpack_pass_tb  # never run an old snapshot when the compilation fails
xvlog -nolog "$XILINX_VIVADO/data/verilog/src/glbl.v" > /dev/null
xvhdl -2008 -nolog "$hdl/chfpga_package.vhd" "$hdl/bsb/bsb_regs.vhd" "$hdl/bsb/bsb_async_fifo.vhd" \
	"$hdl/data_links/100GE_UDP_MAC/rawpack.vhd" "$hdl/testbenches/rawpack_pass_testbench.vhd" > compile.log 2>&1 \
	|| { grep ERROR compile.log; echo "Failure: compilation error"; exit 1; }
xelab -nolog -L xpm -L unisim work.rawpack_pass_testbench work.glbl -s rawpack_pass_tb > elaborate.log 2>&1 \
	|| { grep ERROR elaborate.log; echo "Failure: elaboration error"; exit 1; }
xsim rawpack_pass_tb -nolog -R | grep -E 'PASSED|Failure|Error|ERROR'
