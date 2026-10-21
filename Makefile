IVERILOG := iverilog
VVP      := vvp

TOP      ?= tb_bvm
RTL      := rtl/ddmtd.v
TB       := tb/$(TOP).v
SIM      := build/$(TOP).vvp

.PHONY: all sim clean

all: sim

$(SIM): $(RTL) $(TB)
	mkdir -p build
	$(IVERILOG) -g2005 -Wall -s $(TOP) -o $@ $(RTL) $(TB)

sim: $(SIM)
	$(VVP) $(SIM)

clean:
	rm -rf build