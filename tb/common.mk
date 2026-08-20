# tb/common.mk -- shared cocotb + Verilator settings.
#
# Each tb/<dut>/Makefile sets RTL_DIR, VERILOG_SOURCES, COCOTB_TOPLEVEL and
# COCOTB_TEST_MODULES, then includes this file LAST. Order matters: cocotb's
# Makefile.sim consumes those variables at include time.

SIM           ?= verilator
TOPLEVEL_LANG ?= verilog

COCOTB_HDL_TIMEUNIT      ?= 1ns
COCOTB_HDL_TIMEPRECISION ?= 1ps

# Waveforms. WAVES=1 does NOT work for Verilator -- the trace flags have to
# reach verilate itself. Produces dump.fst in the directory make ran in.
# Run `make clean` after changing these or the stale build gets reused.
EXTRA_ARGS += --trace --trace-fst --trace-structs

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: test waves

test: sim

waves: dump.fst
	@command -v surfer >/dev/null 2>&1 && surfer dump.fst || gtkwave dump.fst