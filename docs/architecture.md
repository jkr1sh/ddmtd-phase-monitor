# DDMTD Phase Monitor — Architecture Specification

**Status:** Proposed v1.0 architecture; implementation details marked **OPEN** must be resolved before RTL freeze.  
**Target:** Synthesizable Verilog-2005; functional simulation → Artix-7 (Basys 3) → SKY130 standard-cell implementation.  
**Scope:** Compact, two-channel digital DMTD phase monitor; not a White Rabbit SoftPLL or a calibrated picosecond instrument.

## 1. Objective and operating point

Measure the circular phase difference between two nominally equal-frequency clocks by sampling both with a slightly offset clock, estimating each sampled beat transition, subtracting corrected timestamps, and averaging successive differential measurements.

| Item | v1.0 choice |
|---|---|
| Processing / sampling clock | `clk` = 10.000 MHz |
| Input clocks | `clk_a`, `clk_b` = 9.990 MHz nominal |
| Nominal beat frequency | `abs(10.000 - 9.990) MHz` = 10 kHz |
| Nominal beat duration | 100 us = 1000 sampling cycles |
| Shared timebase | 10-bit counter, values 0..999 (MOD 1000) |
| Sampling | Matched 3-FF pipelines, non-inverting |
| Transition estimation | CERN-inspired streaming bit-median (BVM) FSM, each channel |
| Threshold | `in[5:2]`, 4 bits; 0 maps to 1; valid effective values 1..15 |
| Pairing | Sequential fresh-tag pairing, with beat-scale health checks and recovery |
| Differential phase | `(tag_a - tag_b) mod 1000` |
| Temporal unwrap | Nearest-neighbor increments, nominal range [-500,499] |
| Averaging | Nonoverlapping 16 accepted pairs (power-of-two shift) |
| Output | 10-bit modulo phase + valid + UART + diagnostic flags |
| UART | Two 8N1 bytes, low byte first; 87 clk cycles/bit (~114943 baud) |

The beat count is **derived**: `N = f_sample / abs(f_sample - f_input) = 1000`. The 3-FF depth, 4-bit threshold field, 16-tag average, and watchdog margin are **engineering selections**, not universal DMTD constants.

### Time scale and sign

A one-sample shift of the slowly moving sampled transition corresponds to approximately

`delta = abs(1/f_input - 1/f_sample) = 100.1001 ps`

when expressing the input-clock time displacement. The 100 ps approximation corresponds to an alternative sampling-clock coordinate convention. The phase sign must be established by an end-to-end delay sweep: this specification defines **positive count** as `(tag_a - tag_b) mod 1000`, not necessarily positive physical B delay until verified. The instrument reports **phase modulo one input period**, not accumulated cycle count or calibrated absolute time.

## 2. Signal-flow architecture

The two nominally 9.99 MHz input clocks are independently sampled by matched three-flip-flop pipelines clocked at 10 MHz. Each sampled binary waveform is processed by its own streaming BVM state machine, producing a corrected transition timestamp and a valid strobe. Both BVM estimators use the same free-running modulo-1000 counter as their timestamp reference.

The sequential pairing controller receives both streams, holds fresh timestamps, and produces a pair only when its association policy is satisfied. Per-channel beat-period watchdogs monitor event cadence. Faults invalidate pending measurements and trigger automatic reacquisition.

For each accepted pair, the arithmetic pipeline computes the modular difference of the two timestamps, unwraps successive circular phase measurements using nearest-neighbor increments, and accumulates sixteen locally continuous samples. The averaged value is reduced modulo 1000 and registered for the output interface. A valid pulse marks each new result; the UART sends the same result as two bytes. Diagnostic outputs indicate faults and tracking status.

All measurement and output logic is clocked by `clk`. The two input clocks are **asynchronous inputs**, not separate processing clock domains in this core. FPGA clock generation and board-level clock quality are outside the core and must be characterized separately.

## 3. External interface

Maintain the compact 14-bit pad-oriented interface for continuity with the existing design:

```verilog
module ddmtd (
    input  wire        clk,       // 10 MHz sampling clock
    input  wire        rst,       // active-high reset
    input  wire [13:0] in,
    output wire [13:0] out
);
```

| Port | Meaning |
|---|---|
| `in[0]` | asynchronous input clock A |
| `in[1]` | asynchronous input clock B |
| `in[5:2]` | common BVM qualification threshold |
| `in[13:6]` | reserved / unused |
| `out[9:0]` | most recent 16-pair averaged phase, 0..999 |
| `out[10]` | one-`clk`-cycle average-valid pulse |
| `out[11]` | UART TX, idle high |
| `out[12]` | sticky pairing/watchdog fault (clear on reset; optional later explicit clear) |
| `out[13]` | association tracking status |

**OPEN — configuration changes:** v1.0 can require the threshold to be set before releasing reset and held constant while operating. This is simpler and more deterministic than supporting live updates; document this as the interface contract. If live updates are required later, latch/coordinate changes across both BVM channels and reacquire.

## 4. Shared modulo-1000 counter

One synchronous 10-bit free-running counter increments each sampling-clock edge:

```verilog
if (free_cntr == 10'd999)
    free_cntr <= 10'd0;
else
    free_cntr <= free_cntr + 10'd1;
```

It is a **shared circular time coordinate**, not a beat-locked counter. Any BVM correction or phase subtraction must wrap modulo **1000**, never via natural 10-bit overflow (1024). Counter reset defines an arbitrary time origin; differential measurements cancel common fixed offsets when both channels behave symmetrically.

## 5. Sampling front end

Each input uses a matched, non-inverting, three-register chain:

```verilog
(* ASYNC_REG = "TRUE" *) reg [2:0] sync_a;
(* ASYNC_REG = "TRUE" *) reg [2:0] sync_b;

// on each posedge clk:
sync_a <= {sync_a[1:0], in[0]};
sync_b <= {sync_b[1:0], in[1]};
```

The pipeline reduces the probability of metastability propagating into the estimator; it does **not** remove sampling reversals or guarantee picosecond accuracy. Matched fixed latency should cancel in differential timestamps. For FPGA implementation, inspect the inferred registers, synchronizer placement, and stage-to-stage timing; avoid false-path constraints that remove checks between synchronizer stages. Reset-release and startup masking must be verified. Three stages are a conservative choice, not an analytically proven optimum.

**Reference distinction:** CERN's non-oversampled `dmtd_sampler.vhd` includes additional registered logic and an inversion in its standard path. Our 3-FF, non-inverting sampler is a deliberate simplification, so the selected physical input edge and output sign convention must be verified.

## 6. Streaming BVM transition estimators

One independent FSM per channel, inspired by CERN's `dmtd_with_deglitcher.vhd`:

| State | Behavior |
|---|---|
| `WAIT_STABLE_0` | Count a consecutive low run; arm only after reaching threshold. |
| `WAIT_EDGE` | On first high sample, save current modulo counter as candidate timestamp. |
| `GOT_EDGE` | Increment candidate modulo 1000 for each subsequent zero; count consecutive highs; publish corrected tag after qualifying stable high. |

Estimator idea:

`tag_bvm = (first_high_counter + number_of_subsequent_zero_samples_until_qualification) mod 1000`

This is **not** equivalent to zero counting over an arbitrary fixed 1000-sample window. The FSM's low-arming and high-termination conditions define its observation region. It uses stability qualification **and** bit-median correction; replacing the old persistence-only first-edge tag is the substantive change.

The threshold is programmable through `in[5:2]` (effective 1..15), common to both channels. Start testing at 4 and sweep 1, 2, 4, 8, and 15.

**OPEN — cycle-exact semantics:** Define whether a threshold of H means exactly H consecutive sampled levels; specify count initialization, comparison timing, output-valid pulse timing, and how a zero on the tag-publication cycle is handled. Write a standalone BVM reference model and test all off-by-one cases, including correction across 999→0. An additional design guard may be needed for pathological transition sequences that never reach stable high.

**OPEN — estimator completion latency:** Tags are *reported* after qualification but refer to an earlier corrected transition position. The pairing watchdog must use actual event/report timing appropriately, not confuse them.

## 7. Sequential tag pairing and health monitoring

Each channel produces `{tag[9:0], valid}`. Pairing stores at most one fresh tag from each channel:

```verilog
reg [9:0] held_a, held_b;
reg pending_a, pending_b;
```

Under nominal operation, the next fresh A tag and next fresh B tag form one differential measurement, irrespective of which arrives first. **No 500-cycle inter-channel timeout** is imposed. This avoids rejecting valid phase positions that lie more than half a beat apart in arrival time.

Logical control states:

- `ACQUIRE`: discard stale pending state and establish a new association baseline.
- `TRACK`: accept sequential fresh tags; produce one `pair_valid` pulse per completed pair.
- `RECOVER`: latch a fault, invalidate pending/unwrap/average history, then reacquire.

Per-channel watchdogs measure intervals between successive valid BVM tag strobes. The nominal interval is 1000 `clk` cycles; **1500 cycles is a provisional maximum-gap threshold** for initial tests, not a validated specification. Detect duplicate/unpaired events and absent/late channel activity. On fault, set sticky `pair_error`, deassert tracking, flush partial pair and averaging history, and return to acquisition. Do not reset the free-running counter or both BVM FSMs unless the fault requires it.

**OPEN — critical: startup beat identity.** Sequential A1/B1 association is not guaranteed to be the same physical beat at arbitrary reset release. For a steady periodic signal, pairing adjacent beats may still give the correct *circular* phase; for steps, offsets, or missed tags, it can cause transient or persistent ambiguity. Define the acquisition anchor, permissible transient behavior, and any deliberate one-beat warm-up.

**OPEN — watchdog / recovery policy.** A 1500-cycle per-channel maximum-gap watchdog alone does not detect all dropped tags, false extra tags, or wrong beat associations. Specify minimum plausible inter-tag gap, treatment of simultaneous strobes, priority when a new tag and timeout coincide, fault clear behavior, and how many consecutive good intervals are required before asserting `tracking_locked`. Reacquisition restores normal operation under assumptions; it is **not an absolute proof of correct beat identity**.

**OPEN — frequency tolerance and slew:** Derive permissible deviations in the two input frequencies and maximum step/slew from the beat timing, BVM threshold, and pairing policy. A step that occurs between channel transitions may legitimately produce a mixed-epoch pair; define whether it is flagged, tolerated for one sample, or excluded from error scoring.

## 8. Modular differential phase

On `pair_valid`, calculate:

`raw_phase = (held_a - held_b) mod 1000`, in 0..999.

Perform subtraction in an explicitly widened signed representation, then add/subtract 1000 as required. Do not use truncation of a 10-bit subtraction, because that implements MOD 1024. This block is independent of temporal unwrapping and has its own self-checking corner-case tests.

## 9. Temporal unwrapping and local averaging

Consecutive raw differential phases `z[n]` are circular. Compute the shortest nearest-neighbor increment:

```text
d = z[n] - z[n-1]
if d < -500: delta = d + 1000
else if d >= 500: delta = d - 1000
else: delta = d
```

This maps increments to `[-500,499]`; exactly 500 counts is ambiguous and assigned the negative direction by convention. Correct tracking requires the *true* intermeasurement phase change to be less than half a beat, with margin for noise.

For each nonoverlapping 16-pair window, construct a **locally continuous** sequence around the first raw phase of that window and average those 16 values. Retain previous raw phase as necessary for continuity diagnostics, but do not allow an unbounded signed trajectory to accumulate indefinitely. A bounded local representation avoids eventual overflow and makes arithmetic widths derivable.

`mean = sum(local_unwrapped_phase[0..15]) / 16`

A right shift by four implements division by 16 for signed fixed-point integers, but `>>> 4` rounds negative values toward minus infinity. Choose and document the desired rounding convention; do not assume nearest-integer rounding.

After averaging, normalize the signed mean modulo 1000 to the output range 0..999. **Unwrapping** is for a mathematically meaningful average across 999→0; **final modulo** is for reporting a bounded circular phase. The output is not a continuously accumulated phase trajectory.

**OPEN — arithmetic microarchitecture:** Freeze whether each window is anchored at its first sample or relative to the prior window; derive exact worst-case sum and register widths; define reset/first-sample behavior and signed rounding. Test windows crossing both 999→0 and 0→999, and recovery mid-window. A single `+1000`/`-1000` normalization is valid only after the internal mean range is proven to permit it; otherwise use a bounded multi-step normalization.

## 10. Output register and UART

At every completed 16-pair window:

- Register `out[9:0]` to the normalized mean phase.
- Pulse `out[10]` for one `clk` cycle.
- Enqueue the same 10-bit result for UART transmission.
- Retain the last valid output between updates; `tracking_locked` indicates whether it is current/meaningful.

UART format: two 8N1 frames, low eight bits first, then upper two bits in the low bits of the second byte (upper six bits zero). At 10 MHz, 87 cycles/bit gives `10 MHz / 87 ≈ 114942.5 baud` (~-0.22% relative to 115200).

**OPEN — UART buffering:** Define whether a new result arriving while busy is queued, overwrites a pending latest-value slot, or asserts an overflow fault. Nominal averages arrive about every 1.6 ms, while two UART frames require about 174 us, so a one-entry pending buffer is adequate nominally, but its exceptional behavior must be explicit.

## 11. Verification strategy

Start with `rtl/ddmtd.v`, `tb/`, and a `Makefile`; generate simulator products under ignored `build/` or `sim/results/` directories. All testbenches are self-checking, use independent reference calculations, and exit nonzero on failure.

| Testbench | Required checks |
|---|---|
| `tb_bvm.v` | Clean transitions; isolated high; multiple reversals; threshold sweep; modulo correction; no duplicate tags; exact strobe latency. |
| `tb_pairing.v` | A-first/B-first; 0..999 circular separations; simultaneous strobes; startup; missing/extra events; watchdog faults; reacquisition. |
| `tb_phase_math.v` | Widened signed subtraction; MOD 1000; both wrap directions; half-beat ambiguity; 16-sample averaging; negative rounding. |
| `tb_ddmtd.v` | End-to-end nominal transfer curve and tag cadence; 10 MHz / 9.99 MHz clocks. |
| `tb_dynamic.v` | Phase steps, ramps, boundary crossings, output latency, UART reconstruction. |
| `tb_jitter.v` | Deterministic sampled reversals and controlled timing disturbances; threshold-dependent BVM behavior. |

Log timestamped stimulus truth, raw A/B tags, tag-valid strobes, paired tags, raw modular phase, unwrapped/window phase, average, fault/tracking status, and decoded UART output. Explicitly mark transient samples spanning a stimulus change; do not automatically score them against the post-step instantaneous truth.

**Pass criterion:** No unexplained assertion failures in the specified operating region, reproducible logs, and clearly documented limitations. Functional simulation alone does not validate analog timing accuracy or metastability MTBF.

## 12. FPGA phase (later)

Target Digilent Basys 3 (Artix-7). The board's native oscillator is 100 MHz; provide a documented, appropriately constrained 10 MHz sampling clock and independently controlled 9.99 MHz input clocks. A derived FPGA clock is suitable for **functional demonstration** but may not be an independent, low-jitter timing reference for precision characterization.

Collect Vivado synthesis/implementation utilization, device placement screenshots, setup/hold timing summaries, the worst critical path (startpoint, endpoint, cell/net delays, slack), synchronizer placement, and timing exceptions. Also capture board photographs and phase-transfer/step-response/repeatability/frequency-offset results with stated instrument limitations.

**OPEN — board stimulus:** Decide the actual clock-source arrangement, I/O electrical standards and pins, constraints, and whether the 10 MHz sampling clock is internally generated or externally supplied. Do not claim physical 100 ps accuracy from a 100 MHz-derived digital stimulus alone.

## 13. ASIC phase (later)

Target SKY130 synthesis via Yosys, then LibreLane/OpenROAD for floorplanning, placement, routing, and timing analysis (OpenSTA). Save configuration files, tool versions, cell area, mapped cell count, timing constraints, critical paths, utilization, and selected layout screenshots. Re-run functional tests against a post-synthesis netlist where practical.

**OPEN — ASIC implementation:** Define the clock/reset/pad constraints, synthesis library corner, timing assumptions, and how the asynchronous input synchronizer will be implemented and evaluated in the target library. FPGA-specific attributes are not a substitute for ASIC CDC and physical implementation checks.

## 14. Provenance and scope

The streaming bit-median concept and three-state stable-low/first-edge/stable-high mechanism are adapted conceptually from CERN White Rabbit's `dmtd_with_deglitcher.vhd` (Tomasz Wlostowski; CERN-OHL-W-2.0+ notice in supplied source). The 3-FF non-inverting sampling front end, MOD-1000 timebase, sequential pairing/watchdogs, averaging, and UART constitute this project's particular architecture and are **not** claimed to be identical to CERN's full implementation. If source code is translated or adapted, preserve applicable copyright/license notices and verify repository licensing obligations.

No SoftPLL, PPS alignment, adaptive beat-frequency estimator, oversampling, continuous phase-noise estimator, or extra glitch telemetry is planned for v1.0.

## 15. Open-issue checklist before RTL freeze

**Must resolve before integrated implementation:**

- [ ] **BVM:** exact sample-count/threshold/strobe semantics; correction and modulo wrap; pathological no-termination behavior.
- [ ] **Pairing:** acquisition baseline, event ordering, simultaneous arrivals, missing/extra tags, recovery and tracking qualification.
- [ ] **Watchdog:** derive upper/lower interval limits and BVM latency margin; distinguish a missing beat from valid phase separation.
- [ ] **Arithmetic:** local unwrap anchoring, widths, overflow bounds, signed rounding, and final modulo normalization.
- [ ] **Clock/phase convention:** measured sign and count-to-time scale established by a controlled phase sweep.

**Can resolve during integration/characterization:**

- [ ] Threshold-change policy (recommend hold constant outside reset).
- [ ] UART busy/pending/overflow policy.
- [ ] Basys 3 clock source, constraints, and board test setup.
- [ ] SKY130 constraints, corner, CDC implementation, and physical reports.
- [ ] Parameter justification: characterize threshold values and 16-sample noise/latency tradeoff; use device data for synchronizer MTBF claims.

**Architecture acceptance:** All major blocks are selected. The above items are *behavioral contracts* and verification details, not invitations to expand the project into a new research program.
