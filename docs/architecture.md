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

**Implementation status — Sprint 1:** The streaming BVM estimator has passed eight directed unit checks with zero reported errors. The tests cover clean transitions, multiple sampled reversals, modulo-1000 timestamp correction, threshold-one behavior, interrupted high qualification, and duplicate-tag suppression.

The implemented threshold convention requires H consecutive samples for qualification. The candidate timestamp is captured on the first high sample and incremented modulo 1000 for each subsequent zero until stable-high qualification completes.

**Remaining verification:** Complete the programmable-threshold sweep, check exact publication latency, and investigate pathological sampled sequences that never achieve stable-high qualification. These are verification limitations, not unresolved architectural decisions.

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

### Tracking acquisition and reacquisition criteria

The pairing controller shall enter `TRACK` only after observing **two consecutive healthy inter-tag intervals on each channel**.

A healthy interval is defined as the elapsed number of sampling-clock cycles between successive valid BVM tags, falling within the configured beat-period tolerance.

- During `ACQUIRE`, monitor the inter-tag intervals of channels A and B independently.
- Maintain a 2-bit saturating healthy-interval counter per channel.
- Increment the corresponding counter for each valid inter-tag interval; reset it if the interval violates the permitted range.
- Assert `tracking_locked` only when both channels have recorded at least two consecutive healthy intervals and a fresh A/B association has been established.
- Suppress `pair_valid` until tracking is established.
- On a pairing or watchdog fault, enter `RECOVER`, clear pending tags and healthy-interval counters, invalidate averaging/unwrapping history, and return to `ACQUIRE`.

This is a conservative acquisition policy selected for v1.0, not a requirement inherited from CERN's DDMTD implementation.

**Limitation:** Healthy inter-tag intervals establish nominal event cadence, but do not independently prove correct beat identity or detect every possible missing-event association error.

Per-channel watchdogs measure intervals between successive valid BVM tag strobes. The nominal interval is 1000 `clk` cycles; **1500 cycles is a provisional maximum-gap threshold** for initial tests, not a validated specification. Detect duplicate/unpaired events and absent/late channel activity. On fault, set sticky `pair_error`, deassert tracking, flush partial pair and averaging history, and return to acquisition. Do not reset the free-running counter or both BVM FSMs unless the fault requires it.

**Known limitation: startup beat identity.** Sequential A1/B1 association is not guaranteed to be the same physical beat at arbitrary reset release. For a steady periodic signal, pairing adjacent beats may still give the correct *circular* phase; for steps, offsets, or missed tags, it can cause transient or persistent ambiguity. Define the acquisition anchor, permissible transient behavior, and any deliberate one-beat warm-up.

**Implementation status — Sprint 2:** The sequential pairing controller has passed nine directed functional checks with zero reported errors, covering acquisition, baseline suppression, simultaneous pairing, A-first/B-first ordering, early/late event detection, and automatic reacquisition.

The provisional healthy inter-tag interval is 500–1500 sampling-clock cycles, inclusive. Two consecutive healthy intervals per channel are required before baseline association and tracking.

The implementation uses registered outputs and a single-process synchronous FSM. Watchdog timing is based on BVM tag-publication strobes.

Boundary tests at exactly 500 and 1500 cycles, duplicate pending events, and reset during a pending association remain to be verified before declaring exhaustive directed coverage.

**Known limitation:** Healthy event cadence does not guarantee correct beat identity after arbitrary missing or extra events.

**OPEN — frequency tolerance and slew:** Derive permissible deviations in the two input frequencies and maximum step/slew from the beat timing, BVM threshold, and pairing policy. A step that occurs between channel transitions may legitimately produce a mixed-epoch pair; define whether it is flagged, tolerated for one sample, or excluded from error scoring.

## 8. Modular differential phase

On `pair_valid`, calculate:

`raw_phase = (held_a - held_b) mod 1000`, in 0..999.

Perform subtraction in an explicitly widened signed representation, then add/subtract 1000 as required. Do not use truncation of a 10-bit subtraction, because that implements MOD 1024. This block is independent of temporal unwrapping and has its own self-checking corner-case tests.

## 9. Temporal Phase Unwrapping and Local Averaging

### 9.1 Objective

The phase-processing block receives valid pairs of BVM-corrected timestamps and produces a 16-sample averaged differential phase measurement.

Each accepted pair generates one raw modular phase:

\[
z_n=(t_{A,n}-t_{B,n})\bmod1000
\]

The phase processor performs nearest-neighbor temporal unwrapping to maintain local phase continuity across the modulo boundary before averaging.

The output is reduced modulo 1000 to represent relative phase within one nominal input-clock period.

The core does not maintain a persistent phase-cycle counter or an unbounded accumulated phase trajectory.

### 9.2 Nearest-Neighbor Delta Unwrapping

For consecutive raw phase measurements:

\[
d_n=z_n-z_{n-1}
\]

The corrected phase increment is:

\[
\Delta_n=
\begin{cases}
d_n+1000,&d_n<-500\\
d_n-1000,&d_n\ge500\\
d_n,&\text{otherwise}
\end{cases}
\]

The resulting increments lie within `[-500,499]`.

An exactly 500-count difference is ambiguous. The implementation resolves this tie in the negative direction.

Correct unwrapping assumes that the actual phase change between consecutive accepted measurements is less than half a beat, with sufficient margin for measurement noise.

### 9.3 Window-Local Phase Reconstruction

Each averaging window contains 16 accepted differential phase measurements.

The first measurement establishes the window reference:

\[
B=z_0
\]

The register `window_base` stores this value.

The cumulative local offset is:

\[
O_0=0,\qquad O_n=O_{n-1}+\Delta_n
\]

The locally unwrapped phase is reconstructed as:

\[
\Phi_n=B+O_n
\]

The offset is relative to the first measurement of the current window, not the current raw phase.

Therefore, the implementation must use `window_base + next_offset`, not `raw_phase + next_offset`.

At each new averaging window, `window_base` and the local offset are reinitialized. No accumulated phase-cycle history is retained across windows.

### 9.4 Register Widths

| Quantity | Width | Range or justification |
|---|---|---|
| Input timestamps | 10-bit unsigned | 0–999 |
| Signed timestamp difference | 12-bit signed | −999 to +999 |
| Raw modular phase | 10-bit unsigned | 0–999 |
| Previous raw phase | 10-bit unsigned | 0–999 |
| Nearest-neighbor delta | 12-bit signed | −500 to +499 |
| Local offset | 14-bit signed | −7500 to +7485 |
| Local phase sample | 15-bit signed | Conservative range −7500 to +8484 |
| Accumulator | 20-bit signed | Conservative sum bound −120000 to +135744 |
| Sample counter | 4-bit unsigned | 0–15 |
| Averaged output | 10-bit unsigned | 0–999 |

The widths are selected to avoid signed overflow under the specified maximum nearest-neighbor increment and 16-sample window length.

### 9.5 Sixteen-Sample Boxcar Averaging

The processor accumulates sixteen locally unwrapped phase measurements:

\[
S=\sum_{n=0}^{15}\Phi_n
\]

The signed mean is:

\[
\bar\Phi=\left\lfloor\frac{S}{16}\right\rfloor
\]

Because the window length is a power of two, division is implemented using arithmetic right shift by four:

```verilog
mean = next_sum >>> 4;
```

For negative sums, arithmetic right shift rounds toward negative infinity. This is the defined v1.0 rounding convention.

The final averaged result is normalized modulo 1000:

\[
\text{avg\_phase}=\bar\Phi\bmod1000
\]

with the output restricted to 0–999.

The final modulo operation changes the numerical representation of the average; it does not reverse the benefit of unwrapping before averaging.

### 9.6 Timing and Output Behavior

The arithmetic block updates its accumulator only when `pair_valid` is asserted.

At the nominal 10 kHz beat rate, accepted differential measurements arrive approximately every 100 µs.

Sixteen accepted pairs therefore produce one averaged output approximately every 1.6 ms under continuous tracking.

The interval between the first and sixteenth accepted measurements is approximately 1.5 ms.

On the sixteenth accepted pair:

- The final sample is included in the accumulated sum.
- The signed mean is calculated.
- The result is normalized modulo 1000.
- `avg_phase` is updated.
- `avg_valid` is asserted for one sampling-clock cycle.

The next accepted pair begins a new nonoverlapping averaging window.

### 9.7 Reset and Recovery

External reset clears all phase-processing registers.

A `pair_reinit` pulse from the pairing controller invalidates the current averaging window and resets its local arithmetic state.

Any incomplete averaging window is discarded.

The next accepted pair establishes a new `window_base`.

The last published phase value must not be interpreted as a current valid measurement while tracking is lost.

### 9.8 Phase-Cycle Ambiguity

The v1.0 core reports the averaged differential phase modulo 1000.

Phase values differing by integer multiples of 1000 counts are indistinguishable at the output.

The core does not maintain a persistent phase-cycle counter or report unbounded accumulated phase drift.

Long-term phase drift may be reconstructed offline from successive averaged measurements only if phase evolution is sufficiently slow, measurement continuity is maintained, and cycle slips do not introduce ambiguity.

This is an accepted architectural limitation, not an omitted v1.0 feature.

### 9.9 Verification Status — Sprint 3

The corrected phase arithmetic RTL passed the directed `tb_phase_math.v` simulation with:

- 291 checks.
- 8 averaged outputs.
- 0 reported errors.

The tests exercised constant differential phase, forward and reverse modulo crossings, negative local means, the half-beat ambiguity convention, large positive steps, recovery during an incomplete averaging window, and idle gaps.

These results establish correctness for the exercised deterministic cases. They do not constitute exhaustive formal verification or end-to-end timing characterization.

### 9.10 Full Pipeline Integration — Sprint 4

The sampling, BVM, sequential pairing, and phase-processing modules have been integrated under the `ddmtd` top-level module.

The integrated datapath operates in the 10 MHz sampling-clock domain and accepts two nominally 9.99 MHz input clocks.

The `tb_ddmtd.v` testbench verifies the complete measurement pipeline using three fixed relative input-clock delays: 0 ns, 20 ns, and 95 ns.

**Observed simulation results:**

| Input delay | Accepted pairs | Averaged outputs | Result |
|---|---:|---:|---|
| 0 ns | 116 | 7 | PASS |
| 20 ns | 116 | 7 | PASS |
| 95 ns | 116 | 7 | PASS |

The testbench reported zero errors.

These results demonstrate correct integrated operation for the tested static phase offsets and the testbench's acceptance tolerances.

Dynamic phase tracking, phase-slew limits, jitter behavior, frequency-offset tolerance, and physical timing accuracy have not yet been characterized.

UART transmission remains outside the Sprint 4 implementation.

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

|    Testbench    |  Status |                            Coverage                           |
|:---------------:|:-------:|:-------------------------------------------------------------:|
| tb_bvm.v        | PASS    | 8 directed checks                                             |
| tb_sampler.v    | PASS    | 3-FF sampling, MOD-1000 counter, BVM integration              |
| tb_pairing.v    | PASS    | 9 directed checks                                             |
| tb_phase_math.v | PASS    | Modular subtraction, nearest-neighbor unwrapping, 16-sample averaging, signed arithmetic, recovery |
| tb_ddmtd.v      | Planned | End-to-end nominal phase transfer                             |
| tb_dynamic.v    | Planned | Steps, ramps, slew, UART                                      |
| tb_jitter.v     | Planned | Jitter and BVM threshold characterization                     |

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

## 15. Open-Issue Checklist Before RTL Freeze

### Completed Implementation Milestones

- [x] **BVM:** Implement streaming bit-median correction and programmable qualification.
- [x] **Sampling:** Integrate matched 3-FF pipelines and shared MOD-1000 counter.
- [x] **Pairing:** Implement sequential association, two-interval acquisition, baseline suppression, and automatic recovery.
- [x] **Watchdog:** Implement provisional 500–1500-cycle inter-tag monitoring and sticky fault indication.
- [x] **Phase arithmetic:** Implement MOD-1000 differential subtraction, nearest-neighbor delta unwrapping, window-local reconstruction, and 16-sample signed averaging.
- [x] **Arithmetic verification:** Pass 291 directed checks with zero reported errors.
- [x] **Full pipeline integration:** Connect sampling, BVM, pairing, and phase processing under the `ddmtd` top-level module.
- [x] **Static integration verification:** Pass 0 ns, 20 ns, and 95 ns relative-phase test cases with 116 accepted pairs and 7 averaged outputs per case; zero reported errors.

### Remaining RTL Implementation

- [ ] **UART:** Implement two-byte 8N1 transmission at approximately 115200 baud.
- [ ] **UART verification:** Verify byte ordering, framing, baud timing, and decoded phase values.
- [ ] **Output integration:** Connect UART transmission to `avg_valid` and verify the complete 14-bit interface.

### Remaining Functional Verification

- [ ] **BVM verification:** Complete threshold sweep, publication-latency checks, and pathological transition tests.
- [ ] **Pairing boundary verification:** Test exact watchdog boundaries, duplicate pending tags, and reset during an incomplete association.
- [ ] **Phase-transfer characterization:** Verify phase sign, count-to-time conversion, and transfer behavior over the full modulo-1000 range.
- [ ] **Dynamic characterization:** Test phase steps, ramps, wrap crossings, response latency, and supported phase-slew limits.
- [ ] **Jitter characterization:** Evaluate BVM threshold sensitivity, repeatability, and averaging trade-offs.
- [ ] **Frequency-offset tolerance:** Determine the supported beat-frequency range and watchdog limitations.
- [ ] **Full regression:** Run all self-checking testbenches against the final RTL with zero unexplained failures.

### Implementation and Physical Validation

- [ ] **Artix-7 FPGA:** Synthesize, place, route, and verify timing in Vivado; perform board-level characterization.
- [ ] **SKY130 ASIC:** Complete synthesis, static timing analysis, and physical implementation; collect area, utilization, and critical-path reports.

### Architecture Acceptance

The primary DDMTD measurement datapath is implemented and has passed directed unit and static integration tests.

The remaining RTL development is limited to UART transmission and output integration. Functional characterization and outstanding boundary tests must be completed before declaring the digital core verified.

The design deliberately excludes persistent phase-cycle tracking, adaptive beat-frequency estimation, SoftPLL functionality, and additional telemetry features.