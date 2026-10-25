# DDMTD Phase Monitor — Verification and Characterization Plan

**Status:** Planned; starts at Sprint 6 after Sprint 5 UART directed tests and reported six-testbench regression pass.  
**Companion:** `architecture.md` is the normative RTL architecture and interface contract. This document defines experiments, verification evidence, data capture, and freeze gates.  
**Scope:** Verilog-2005 / Icarus functional simulation first; Artix-7 and SKY130 validation later. Simulation does not establish picosecond physical accuracy.

## 1. Baseline and objectives

Current baseline: streaming BVM, 3-FF sampling, MOD-1000 timestamps, pairing/watchdogs, 16-pair phase averaging, and two-byte 8N1 UART implemented. The existing directed tests passed according to the supplied run logs. Sprint 4 static integration covered 0, 20 and 95 ns delay cases; Sprint 5 UART directed test reported 13 checks and zero errors.

The characterization effort must measure the response of the **entire system**, establish the sign and count-to-time relationship experimentally, distinguish transient windows from steady-state results, and verify serial output against the correct historical average. Preserve raw data and deterministic test parameters so plots are reproducible.

## 2. Verification principles

1. Each testbench has a defined stimulus, independent expected behavior, assertions, timeout, and nonzero failure exit (`$fatal`). A plot is not a pass criterion.
2. Record stimulus truth from the generated clock-edge schedule, **not** from DUT timestamps. Derive the expected sign from a controlled phase sweep before locking numerical acceptance bands.
3. Keep simulation time, sampling-cycle index, stimulus epoch, and event ordering explicit. Avoid race-dependent sampling; capture registered outputs after nonblocking updates.
4. Averages can span stimulus changes. Mark mixed-epoch windows and assess protocol/arithmetic correctness separately from steady-state phase error.
5. Compare circular phases using a MOD-1000 circular residual; do not subtract raw 0..999 values near wrap without normalization.
6. UART results can lag averages. Use a reference queue / pending-slot model matching the latest-value overwrite policy, never compare a received word to the current `avg_phase` blindly.
7. Run deterministic corner tests and seeded statistical tests separately. Log seed, configuration, simulator version, RTL revision, and thresholds.
8. Keep the DUT synthesizable; simulation-only logging and instrumentation stay in `tb/` and `scripts/`.

## 3. Proposed repository layout

```text
tb/
  tb_bvm.v  tb_sampler.v  tb_pairing.v  tb_phase_math.v
  tb_ddmtd.v  tb_uart.v
  tb_phase_sweep.v  tb_dynamic.v  tb_jitter.v
  tb_faults.v  tb_uart_integration.v
  common/
    ddmtd_monitor.v
    uart_decoder.v
scripts/
  analyze.py
  plot_phase_sweep.py
  plot_dynamic.py
  plot_jitter.py
build/
  results/<test_name>/<run_id>/
    metadata.txt
    stimulus.csv  tags.csv  pairs.csv
    averages.csv  uart.csv  faults.csv
    summary.txt
```

The common monitor should be a separately compiled Verilog-2005 module with explicit input ports for observable events; any hierarchical access to internal DUT state should be isolated in the testbench adapter and documented. The UART decoder must reconstruct actual serial frames independently of the transmitter RTL.

## 4. Shared logging contract — Sprint 6

Use one common timestamp unit (recommended `time_ps`, integer picoseconds) plus `cycle` where applicable. Every CSV has a header and a `test_id`; write rows **on events**, not on every sample clock, to avoid huge files. Include `stimulus_epoch` where meaningful.

| File | Minimum fields |
|---|---|
| `stimulus.csv` | `test_id,time_ps,stimulus_epoch,event,phase_delay_ps,clk_a_hz,clk_b_hz,jitter_seed` |
| `tags.csv` | `test_id,time_ps,cycle,channel,tag,threshold,stimulus_epoch` |
| `pairs.csv` | `test_id,time_ps,cycle,tag_a,tag_b,raw_phase,tracking_locked,stimulus_epoch` |
| `averages.csv` | `test_id,time_ps,cycle,average_index,phase_count,expected_count,circular_error,mixed_epoch,tracking_locked` |
| `uart.csv` | `test_id,time_ps,frame_index,byte_index,data_hex,start_ok,stop_ok,word_phase,expected_word,match` |
| `faults.csv` | `test_id,time_ps,cycle,event,tracking_locked,pair_error,recovery_cycles` |

If a field is unknown/not applicable, use a documented blank convention; do not fabricate expected values. Store metadata separately: git revision, `iverilog -V`, parameters, time precision, seed, test duration, and test outcome. Add `$dumpfile`/`$dumpvars` for bounded diagnostic runs rather than dumping enormous VCDs by default.

**Sprint 6 acceptance:** monitor produces valid event logs on the existing `tb_ddmtd` stimulus; independent UART decoder passes a known byte sequence; CSVs parse; metadata is complete; a smoke plot is generated; assertions still determine pass/fail.

## 5. Sprint 7 — Static phase transfer (`tb_phase_sweep.v`)

- Sweep relative input delay across one nominal input period, with dense samples near zero/wrap and around half-period.
- Keep nominal 10 MHz sample clock and 9.99 MHz inputs; settle through acquisition and at least one complete 16-pair window per point. Collect multiple stable averages per point.
- Log generated edge timing, observed BVM tags, pair cadence, average counts, and UART output.
- Establish the actual transfer sign, phase origin, quantization, count-to-time slope, repeatability, and discontinuities.
- Use circular residuals and plot measured-versus-applied phase, error versus delay, and histograms. Acceptance tolerances are **TBD from justified simulation/reference-model behavior**, not invented now.

**Boundary cases:** 0/999 count wrap, phase near half-cycle, reset at different input phases, and threshold values 1, 2, 4, 8, 15.

## 6. Sprint 8 — Dynamic behavior (`tb_dynamic.v`)

- Apply phase steps of both signs, including modulo crossings, and ramps with increasing rates. Change delays through an edge-scheduling method that does not unintentionally add/drop cycles without logging that event.
- Track stimulus epochs, window membership, time to first valid post-step result, time to stable result, tracking loss/recovery, and output update cadence.
- Distinguish mixed-epoch averages from fully post-step averages. Do not score mixed windows against instantaneous post-step truth.
- Sweep ramp slope until nearest-neighbor unwrap ambiguity or pairing/watchdog failure; document the **observed** supported slew range and its dependence on threshold and noise.
- Plot applied phase and measured phase versus time, circular residuals, lock/fault timelines, and latency distributions.

**Acceptance:** no unexplained framing/arithmetic/protocol failures in specified scenarios; define supported slew only after results are observed.

## 7. Sprint 9 — Robustness (`tb_jitter.v`, `tb_faults.v`)

### Jitter / BVM

- Inject reproducible, seeded edge-time perturbations; specify distribution, amplitude, and whether noise is independent or common-mode.
- Sweep BVM threshold and compare output dispersion, bias, event cadence, missed-tag rates, and tracking continuity.
- Report repeatability statistics over sufficiently many windows; keep simulation-only results distinct from physical jitter/MTBF claims.

### Pairing / watchdog / reset

- Directed checks at exact 500/1500-cycle inter-tag boundaries and one cycle outside each bound.
- Duplicate A/B pending events, missing/late events, reset with pending association, reset during averaging, and reacquisition.
- Verify sticky fault, suppression of invalid averages, history flushing, recovery timing, and eventual resumed operation.
- Where practical, use pairing-unit injection to control exact tag strobes; do not expect full clock stimulus to deterministically create every internal corner case.

### Frequency-offset tolerance

- Sweep beat interval around nominal and map observed lock/fault boundaries. State assumptions and exclude unsupported input conditions from nominal accuracy claims.

## 8. End-to-end UART (`tb_uart_integration.v`)

- Decode `out[11]` as 8N1 with 87 sampling-clock cycles per bit. Verify idle-high, start/stop bits, LSB-first ordering, two-byte word assembly, and reserved upper six bits zero.
- Match every transmitted 10-bit word to its corresponding historical `avg_valid` value using a queue that models the transmitter's single latest-value pending slot.
- Force busy-time updates and overwrites in a targeted UART-unit scenario; check reset mid-frame and the recovery to idle.
- Log frame-start times, decoded bytes, assembled words, expected values, and errors. Add UART-frame annotations to waveform views.

## 9. Sprint 10 — Regression and RTL freeze

- Run existing six directed testbenches plus characterization suites, preserving seed/configuration and producing machine-readable summaries.
- Require zero unexplained assertion failures; document coverage, numerical tolerance derivations, unsupported regimes, and known ambiguities.
- Confirm UART/average correlation, output-pin mapping, reset behavior, no unknowns after specified initialization, and no unintended RTL modifications.
- Freeze a tagged RTL revision only after tests and code review; save results/plots and update `architecture.md` status.
- Physical follow-on: Artix-7 synthesis/placement/timing and controlled board measurement, then SKY130 synthesis/STA/place-route. Neither is covered by a simulation-only freeze.

## 10. Makefile handoff

Keep `make regression` as the fast directed suite initially. Add a separate `make characterize` target when new testbenches and shared monitor sources exist. Compile common modules explicitly (e.g., `tb/common/*.v`), create per-run result directories, and avoid rerunning long statistical tests during every edit. Never print `PASS` solely because a simulation exited if its assertions do not use nonzero failure status.

## 11. Outstanding decisions

- Exact phase sweep spacing, dwell time, numerical tolerances, and reference model.
- Simulation clock-edge generator that supports controlled phase steps/ramps without unlogged edge discontinuities.
- UART frame timing conventions and simultaneous pending-slot update ordering in the reference scoreboard.
- Jitter distributions and run lengths; acceptable confidence intervals.
- Whether the v1.0 BVM threshold must remain fixed between resets (recommended for initial characterization).
- Board-level stimulus generation, pin constraints, and calibration methods.

**Start here:** Sprint 6 — common monitor, independent UART decoder, CSV output, and one short end-to-end smoke run. Do not start with millions of cycles until logging and scoreboards are validated.
