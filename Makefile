IVERILOG := iverilog
VVP      := vvp

TOP      ?= tb_bvm
RTL      := rtl/ddmtd.v
TB       := tb/$(TOP).v
SIM      := build/$(TOP).vvp

TESTS    := tb_bvm tb_sampler tb_pairing tb_phase_math tb_ddmtd tb_uart

.PHONY: all sim regression clean

all: sim

$(SIM): $(RTL) $(TB)
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -s $(TOP) -o $@ $(RTL) $(TB)

sim: $(SIM)
	$(VVP) $(SIM)

regression:
	@set -e; \
	for tb in $(TESTS); do \
		echo "=== Running $$tb ==="; \
		$(MAKE) sim TOP=$$tb; \
	done
	@echo "PASS: All regression tests"

clean:
	rm -rf build