# Makefile -- repo root. Delegates to every testbench under tb/, plus
# remote Vivado synthesis (see synth/README.md) and the XSIM signoff smoke
# test (see sim/xsim/).

TB_DIRS := $(sort $(dir $(wildcard tb/*/Makefile)))
SYNTH := ./scripts/remote_synth.sh

.PHONY: test clean list synth synth-pe synth-array synth-attach synth-pull sim-xsim

## Run every cocotb testbench. Fails on the first failing one.
test:
	@for d in $(TB_DIRS); do \
		echo "=== $$d ==="; \
		$(MAKE) --no-print-directory -C $$d test || exit 1; \
	done

clean:
	@for d in $(TB_DIRS); do $(MAKE) --no-print-directory -C $$d clean; done

list:
	@for d in $(TB_DIRS); do echo $$d; done

synth:
	$(SYNTH) --top abacus_top --mode full
synth-pe:
	$(SYNTH) --top pe_mac --mode ooc --clk 4.0
synth-array:
	$(SYNTH) --top systolic_array --mode ooc --clk 4.0
synth-attach:
	$(SYNTH) --attach
synth-pull:
	$(SYNTH) --pull

## XSIM batch-mode smoke test, on the same server as synthesis (ABACUS-15).
sim-xsim:
	./scripts/remote_xsim.sh