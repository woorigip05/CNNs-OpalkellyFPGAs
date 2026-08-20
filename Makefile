# Makefile -- repo root. Delegates to every testbench under tb/.

TB_DIRS := $(sort $(dir $(wildcard tb/*/Makefile)))

.PHONY: test clean list

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