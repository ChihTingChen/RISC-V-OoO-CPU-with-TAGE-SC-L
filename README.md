# RISC-V RV32I Out-of-Order CPU with TAGE-SC-L Branch Predictor

An out-of-order RV32I core with a TAGE-SC-L branch predictor (TAGE, loop predictor and
statistical corrector), written in SystemVerilog. The design was taken through synthesis,
scan insertion, place and route and signoff on the ASAP7 7 nm predictive PDK.

## Summary

| | |
|---|---|
| Branch accuracy | 96.5% |
| MPKI | 11.9 (281.8 without a predictor) |
| IPC | 0.492 (0.358 without a predictor) |
| Clock | 111 MHz (9 ns), signed off at the SS corner |
| Die area | 0.0100 mm² |
| Power | 2.17 mW (TT, 0.7 V) |
| Scan | 8 chains, 9,046 scan flops |
| DRC | 0 violations |
| Equivalence | RTL, scan netlist and post-route netlist all pass LEC |
| RTL regression | 75 of 75 checks pass |

Library: ASAP7 asap7sc7p5t_28 (RVT, LVT, SLVT)

Tools: Cadence Genus 25.1, Innovus 25.1, Conformal LEC 25.2, ModelSim

<img src="docs/asap7/asap7_final_layout.png" width="640" alt="Final routed layout">

## Contents

1. [Microarchitecture](#1-microarchitecture)
2. [Branch Predictor](#2-branch-predictor)
3. [Branch Prediction Results](#3-branch-prediction-results)
4. [Physical Design](#4-physical-design)
5. [Timing](#5-timing)
6. [Verification](#6-verification)
7. [Design for Test](#7-design-for-test)
8. [Repository Structure](#8-repository-structure)

## 1. Microarchitecture

Tomasulo-style out-of-order execution with a reorder buffer for in-order retirement and
branch recovery.

<img width="792" height="632" alt="Microarchitecture" src="https://github.com/user-attachments/assets/a1e602c7-71a9-4502-ba97-53257674d8ee" />

| Structure | Configuration |
|---|---|
| Reorder buffer | 16 entries |
| Reservation station | 8 entries |
| Load-store queue | 8 entries, store-to-load forwarding |
| Physical register file | 64 registers |
| Architectural registers | 32 |
| Rename | RAT and free list, ARAT-based recovery on mispredict |
| Memory | External instruction and data memory through chip ports |

Supported instructions:

| Class | Instructions |
|---|---|
| R-type | ADD SUB AND OR XOR SLL SRL SRA SLT SLTU |
| I-type | ADDI ANDI SLTI SLTIU |
| Branch | BEQ BNE BLT BGE BLTU BGEU |
| Jump | JAL JALR |
| Upper immediate | LUI AUIPC |
| Memory | LW SW |

## 2. Branch Predictor

The predictor follows Seznec's TAGE-SC-L. TAGE gives the base prediction, and the loop
predictor and statistical corrector can override it.

### TAGE

| Table | Entries | History length | Tag | Counter |
|---|---|---|---|---|
| T0 (bimodal) | 128 | PC only | none | 2-bit |
| T1 | 32 | 4 | 8-bit | 3-bit signed |
| T2 | 32 | 16 | 10-bit | 3-bit signed |
| T3 | 32 | 64 | 12-bit | 3-bit signed |

- The longest-history table with a tag match provides the prediction. The next match is the
  alternate prediction and is used to update the useful bits.
- The 64-bit global history is XOR-folded into a 5-bit index and a 10 or 12-bit tag. Index
  and tag use different folds so an index collision is not also a tag collision.
- Only entries with useful bit 0 can be replaced. An aging counter halves the useful bits
  every 256 updates.

### Loop predictor

8 entries with a 10-bit tag, 10-bit iteration counters and a 2-bit confidence counter. It
counts loop iterations and predicts the exit, which TAGE always misses on long loops. It only
overrides TAGE after the same trip count has been seen twice.

### Statistical corrector

Three 16-entry tables of 6-bit signed counters:

| Table | Index | Captures |
|---|---|---|
| sc_ghist | PC ^ GHR[3:0] | correlation with recent outcomes |
| sc_path | PC ^ PHR[3:0] | correlation with the path taken |
| sc_bias | PC | bias of the branch |

The three counters are added together. The corrector overrides TAGE only when TAGE's
counter is weak, the sum is at least 8 in magnitude, and the two predictions disagree.

### Selection

```
if      (loop predictor confidence >= 2)               use loop predictor
else if (TAGE weak && SC strong && they disagree)      use SC
else                                                   use TAGE
```

## 3. Branch Prediction Results

The same 14-test regression was run with no predictor (always PC + 4), with TAGE only, and
with TAGE-SC-L.

| Metric | No predictor | TAGE | TAGE-SC-L |
|---|---|---|---|
| Branch accuracy | 18.6% | 94.7% | 96.5% |
| MPKI | 281.8 | 18.1 | 11.9 |
| Mispredicts | 2,011 | 158 | 104 |
| IPC | 0.358 | 0.489 | 0.492 |
| Instructions retired | 7,134 | 8,684 | 8,684 |
| Cycles | 19,873 | 17,723 | 17,615 |

Branch-focused tests:

| Test | Pattern | Accuracy (none / TAGE / SC-L) | Mispredicts (none / TAGE / SC-L) |
|---|---|---|---|
| 10 | 100-iteration loop | 0.8% / 98.0% / 98.0% | 118 / 4 / 4 |
| 11 | Alternating, period 2 | 20.6% / 89.3% / 98.1% | 407 / 64 / 11 |
| 12 | Period 4 | 27.8% / 92.4% / 91.9% | 397 / 53 / 57 |
| 13 | Period 16 | 32.3% / 95.9% / 95.9% | 318 / 19 / 19 |
| 15 | Nested loop, 30 × 16 | 5.9% / 98.6% / 99.1% | 757 / 14 / 9 |

Which table provided the prediction, over all tests:

| Provider | Count | Share |
|---|---|---|
| T0 | 1,586 | 52.7% |
| T1 | 1,076 | 35.7% |
| T2 | 249 | 8.3% |
| T3 | 99 | 3.3% |

The loop predictor overrode TAGE on 1,269 branches (42.2%) and the statistical corrector on
5 (0.2%). The regression is loop-heavy, so most of the gain over TAGE comes from the loop
predictor.

## 4. Physical Design

ASAP7 provides a 4x-scaled LEF (lengths ×4, areas ×16). Sizes below are converted back to
real 7 nm dimensions unless marked 4x.

Flow:

1. Genus synthesis with scan insertion (TT, RVT)
2. Innovus import with three corners: SS 0.63 V 100 °C, TT 0.7 V 25 °C, FF 0.77 V 0 °C
3. Floorplan at 80% utilization, routing tracks, pins, well taps
4. Power grid
5. Placement with scan reordering, tie cells, pre-CTS optimization
6. Clock tree synthesis and post-CTS optimization
7. Routing and post-route optimization
8. Decap and filler cells, DRC and connectivity checks, signoff timing and power

### Floorplan and pins

The core is 80% utilized. Pins are grouped by function: instruction memory on the left,
data memory reads on the right, data memory writes on the bottom, and clock, reset and scan
ports on the top. Pins are placed on M4 and M5 at 4.608 µm (4x), a multiple of the 0.192 µm
track pitch. All 212 pins are legal.

### Power grid

| Part | Layer | Width (4x) |
|---|---|---|
| Ring, top and bottom | M6 | 2.176 µm |
| Ring, left and right | M5 | 2.4 µm |
| Rails | M1 and M2 | 0.072 µm |
| Straps | M3 | 0.936 µm, 31.68 µm pitch |
| Straps | M4 | 0.864 µm, 61.44 µm pitch |
| Straps | M5 / M6 | 0.864 / 1.152 µm |

ASAP7 only allows widths from a width table, rectangular shapes, and wires centered on
tracks. The first version of the grid had over 1,000 DRC violations. Fixing the widths,
keeping M2 to M4 inside the core, and setting the via stacking per layer brought it to 0.

<img src="docs/asap7/asap7_pdn.png" width="560" alt="Power grid">

### Clock tree

| | |
|---|---|
| Sinks | 9,046 |
| Buffers inserted | 216 (RVT BUFx4 to BUFx12f) |
| Trunk routing | Double spacing on M4 and M5 |
| Insertion delay (SS) | 178.5 to 210.6 ps |
| Skew | 32.1 ps |

### Routing

| Run | DRC violations |
|---|---|
| First route | 84,815 |
| With via-in-pin | 94,521 |
| After the tech LEF fix | 7 |
| After filler cells | 101 |
| Rerun with the corrected flow | 0 |

Most of the early violations (43,628) were via enclosure errors on V3 and V5. Those vias are
rectangular, and the ASAP7 tech LEF only had end-of-line enclosure rules, which Innovus does
not apply to rectangular cuts. Adding END/SIDE enclosure rules to a copy of the tech LEF
fixed them. The remaining off-grid errors came from creating the routing tracks after the
pins and power grid were placed. Moving that step right after the floorplan removed them.

<img src="docs/asap7/asap7_route_detail.png" width="640" alt="Routing detail">

### Final design

| | |
|---|---|
| Die | 100.4 × 99.9 µm (0.0100 mm²) |
| Cell area | 7,539 µm² |
| Instances | 46,335 (not counting filler, decap and tap cells) |
| Flip-flops | 9,046 |
| Metal layers | M1 to M7 |
| Wire length | 250.5 mm |
| Vias | 534,119 |
| DRC | 0 |
| Opens | 0 |

Area by module:

| Module | Instances | Area (µm²) | Share |
|---|---|---|---|
| bpu | 9,665 | 1,681.5 | 22.3% |
| prf | 7,957 | 1,510.1 | 20.0% |
| rob | 5,966 | 1,213.0 | 16.1% |
| rename_stage (free_list + rat) | 10,135 | 1,063.2 | 14.1% |
| rs | 4,653 | 895.2 | 11.9% |
| lsq | 4,758 | 761.7 | 10.1% |
| alu | 1,455 | 167.0 | 2.2% |
| arat | 685 | 118.0 | 1.6% |
| fetch | 262 | 35.7 | 0.5% |
| decode | 232 | 27.3 | 0.4% |
| top level | 567 | 66.1 | 0.9% |

### Power

Static analysis at 111 MHz, TT corner, input activity 0.2.

| | mW | Share |
|---|---|---|
| Internal | 0.987 | 45.5% |
| Switching | 1.085 | 50.1% |
| Leakage | 0.095 | 4.4% |
| Total | 2.167 | |

By group: combinational 0.938 mW, sequential 0.860 mW, clock tree 0.369 mW.

## 5. Timing

Signoff conditions:

- Setup at SS and TT, hold at FF and TT
- Functional mode (scan_en = 0) and scan shift mode (scan_en = 1)
- On-chip variation derate of ±5% with CPPR
- Crosstalk-aware delay from post-route parasitics
- Clock uncertainty 50 ps for setup and 10 ps for hold

| Stage | Setup WNS | Hold WNS |
|---|---|---|
| Before placement | −3.747 ns | |
| After placement | −4.955 ns | |
| Pre-CTS optimization | +0.005 ns | |
| After CTS | −0.135 ns | −0.007 ns |
| Post-CTS optimization | +0.016 ns | 1 path at −0.000 ns |
| After routing | +0.091 ns | |
| Post-route optimization | +0.096 ns | 1 path at −0.000 ns |
| Signoff | +0.096 ns | 0.000 ns, no violations |

The last hold violation was in scan shift mode, where one flop's output drives the next
flop's scan input directly. A buffer was added on that pin by hand.

The worst setup path is the rename recovery path:

```
rob/head_reg[2]  ->  arat  ->  rename_stage/u_free_list/FIFO_reg[10][3]
arrival 8,810 ps at SS, slack +96 ps
```

When an instruction retires, the ROB head frees a physical register, the ARAT is updated,
and the free list compacts its queue, all in one cycle. This path sets the 9 ns clock.
Splitting rename recovery over two cycles would be the next step for frequency.

## 6. Verification

### RTL simulation

14 directed tests with 75 checks against the register file and data memory. All pass.

| # | Test | Checks |
|---|---|---|
| 1 | Basic ALU | 10 |
| 2 | Fibonacci loop | 4 |
| 3 | Signed branches | 8 |
| 4 | Unsigned compare and branches | 9 |
| 5 | JAL, JALR, AUIPC | 10 |
| 6 | Load | 2 |
| 7 | Store | 3 |
| 8 | Store-to-load forwarding | 4 |
| 9 | Forwarding from the latest store | 6 |
| 10 | 100-iteration loop | 2 |
| 11 | Alternating branch | 4 |
| 12 | Period-4 branch | 4 |
| 13 | Period-16 branch | 4 |
| 15 | Nested loop | 5 |
| | Total | 75 |

The testbench also counts retired instructions, cycles, mispredicts, the TAGE provider and
the loop predictor and corrector overrides.

### Equivalence checking

| Check | Result |
|---|---|
| RTL vs synthesized scan netlist (9,175 points, scan_en = 0) | Pass |
| Scan netlist vs post-route netlist (9,175 points, scan outputs excluded) | Pass |

Both runs have no non-equivalent or aborted points. Scan outputs are excluded in the second
check because scan reordering changes which flop drives each scan output.

## 7. Design for Test

ASAP7's only flip-flop with asynchronous reset has no scan version, and its scan flops have
no reset. Two changes were needed before scan insertion:

1. Reset was changed from asynchronous to synchronous in the nine `always_ff` blocks. Only
   the sensitivity list changed. The regression still passes 75 of 75 with identical logs.
2. The ASAP7 libraries do not include `test_cell` descriptions for the scan flops, so Genus
   could not use them. A copy of the libraries with `test_cell` added (SI, SE and an inverted
   scan output) fixed this.

| | |
|---|---|
| Scan style | Mux-D, one scan enable |
| Chains | 8, with 1,130 or 1,131 flops each |
| Scan flops | 9,046 (all flops) |
| DFT rule violations | 0 |
| Area change | 1.8% smaller than the non-scan netlist |

The scan chains are reordered after placement, which cut the scan wiring by about 72%. The
shift mode is included in timing signoff.

Not done: ATPG and fault coverage, Calibre DRC/LVS (no deck for ASAP7), antenna checks (no
antenna data in the LEF), and IR drop.

## 8. Repository Structure

```
src/
  riscv_pkg.sv       shared types
  Top.sv             top level
  fetch.sv           fetch and next PC
  bpu.sv             TAGE-SC-L predictor
  decode.sv          decode
  rename_stage.sv    rename (RAT and free list)
  rat.sv             speculative register alias table
  arat.sv            architectural register alias table
  free_list.sv       physical register free list
  rs.sv              reservation station
  alu.sv             execution unit
  lsq.sv             load-store queue
  rob.sv             reorder buffer
  prf.sv             physical register file
  imem.sv            instruction memory model (simulation only)
  dmem.sv            data memory model (simulation only)
  code.txt           instruction memory image
  tb_Top.sv          regression testbench
  run.do             batch simulation script
  run_gui.do         simulation with waveforms
docs/asap7/          layout screenshots
```

| Branch | Contents |
|---|---|
| master | Memory inside the top module |
| mem_out-v3 | Memory outside the chip through top-level ports, asynchronous reset |
| sync-reset | mem_out-v3 with synchronous reset, used for the ASAP7 implementation |

| Tag | Contents |
|---|---|
| v1.1-portfolio | Portfolio version |
| v3.1-async-reset | mem_out-v3 before the synchronous reset change |

## References

- A. Seznec and P. Michaud, A case for (partially) TAgged GEometric history length branch
  prediction, Journal of Instruction-Level Parallelism, 2006.
- A. Seznec, TAGE-SC-L branch predictors, 4th JILP Championship Branch Prediction, 2014.
- D. Jiménez and C. Lin, Dynamic branch prediction with perceptrons, HPCA 2001.
