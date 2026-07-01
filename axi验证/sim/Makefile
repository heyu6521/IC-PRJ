# -----------------------------------------------------------------------------
# AXI4 RTL smoke test Makefile
# Default simulator: Synopsys VCS
# -----------------------------------------------------------------------------

VCS       ?= vcs
TOP       ?= axi4_basic_smoke_tb
SIMV      ?= simv
FILELIST  ?= filelist.f
WAVES     ?= 0

VCS_FLAGS ?= -full64 -sverilog -timescale=1ns/1ps
VCS_FLAGS += -debug_access+all
SIM_FLAGS ?=

ifeq ($(WAVES),1)
  VCS_FLAGS += +define+FSDB
endif

.PHONY: compile sim all clean

compile:
	$(VCS) $(VCS_FLAGS) -f $(FILELIST) -top $(TOP) -l compile.log -o $(SIMV)

sim:
	@if [ ! -x ./$(SIMV) ]; then $(MAKE) compile; fi
	./$(SIMV) $(SIM_FLAGS) -l sim.log

all: compile sim

clean:
	rm -rf $(SIMV) $(SIMV).daidir csrc DVEfiles ucli.key *.log *.vpd *.vcd *.fsdb novas.* verdiLog
