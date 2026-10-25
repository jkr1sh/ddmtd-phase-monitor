IVERILOG := iverilog
VVP      := vvp
PYTHON   ?= python3

TOP      ?= tb_bvm
RTL      := rtl/ddmtd.v
TB       := tb/$(TOP).v
SIM      := build/$(TOP).vvp
COMMON   := $(wildcard tb/common/*.v)
TESTS    := tb_bvm tb_sampler tb_pairing tb_phase_math tb_ddmtd tb_uart
LOGDIR   := results/tb_ddmtd

.PHONY: all sim regression characterize plots clean
all: sim

$(SIM): $(RTL) $(TB) $(COMMON)
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -s $(TOP) -o $@ $(RTL) $(TB) $(COMMON)

sim: $(SIM)
	$(VVP) $(SIM)

regression:
	@set -e; \
	for tb in $(TESTS); do \
		echo "=== Running $$tb ==="; \
		$(MAKE) --no-print-directory sim TOP=$$tb; \
	done
	@echo "PASS: All regression tests"

characterize:
	mkdir -p build $(LOGDIR)
	$(IVERILOG) -g2005 -Wall -D DDMTD_LOGGING \
		-s tb_ddmtd -o build/tb_ddmtd_log.vvp \
		$(RTL) tb/tb_ddmtd.v $(COMMON)
	$(VVP) build/tb_ddmtd_log.vvp +LOGDIR=$(LOGDIR)
	$(PYTHON) scripts/plot_results.py $(LOGDIR)

plots:
	$(PYTHON) scripts/plot_results.py $(LOGDIR)

clean:
	rm -rf build
