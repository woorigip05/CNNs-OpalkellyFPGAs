# tb/adder/Makefile -- toolchain smoke test (ABACUS-13)

RTL_DIR := $(CURDIR)/../../rtl

VERILOG_SOURCES += $(RTL_DIR)/adder.sv

# cocotb 2.0 names. In 1.x these were TOPLEVEL and MODULE; the old spellings
# still work but warn, and will be removed.
COCOTB_TOPLEVEL     := adder
COCOTB_TEST_MODULES := test_adder

include ../common.mk