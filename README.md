# RISC-V (RV32I) Out-of-Order CPU with TAGE-SC-L Branch Predictor

A superscalar-capable out-of-order RISC-V core implemented from RTL to GDSII, featuring a
three-tier **TAGE-SC-L** branch predictor (TAGE + Loop Predictor + Statistical Corrector).

The project covers the complete digital design flow: RTL design → functional verification →
logic synthesis → gate-level simulation → full place-and-route → timing closure → DRC-clean
GDSII export.

---

## Key Results

| | Result |
|---|---|
| **Branch accuracy** | **96.5%**|
| **MPKI** | **11.9** (vs. 281.8 with no predictor) — **95.8% reduction** |
| **Active IPC** | **0.492** (vs. 0.358) — **+37.4%** |
| **Predictor cost** | **+10.4% area / +9.9% power / 0 MHz frequency penalty** |
| **Efficiency** | **+24.5% IPC/mm², +25.0% IPC/mW** |
| **Operating frequency** | **91 MHz** (11 ns, WNS +74 ps) |
| **Die area** | **0.454 mm²** (675.45 × 672.60 µm) |
| **Total power** | **68.84 mW** @ 1.1 V |
| **DRC violations** | **0** |
| **Functional verification** | **75/75 checks PASS** across 14 directed tests |

**Technology:** gscl45nm (45 nm PDK)

**Tools:** Cadence NCSim, Synopsys Design Compiler, Synopsys PrimeTime, Cadence Innovus 25.1

<img width="1146" height="1125" alt="image" src="https://github.com/user-attachments/assets/58032f68-d79d-4e75-a9bb-fbfecd58e390" />

---

## Table of Contents

1. [Microarchitecture](#1-microarchitecture)
2. [TAGE-SC-L Branch Predictor](#2-tage-sc-l-branch-predictor)
3. [Branch Prediction Results](#3-branch-prediction-results)
4. [PPA Trade-off Analysis](#4-ppa-trade-off-analysis)
5. [Physical Design](#5-physical-design)
6. [Timing Closure](#6-timing-closure)
7. [Verification](#7-verification)
8. [Repository Structure](#8-repository-structure)

---

## 1. Microarchitecture

Classic Tomasulo-style out-of-order execution with a reorder buffer for precise exceptions
and branch recovery.

<img width="1366" height="675" alt="image" src="https://github.com/user-attachments/assets/8ffd7cbe-3af8-42a1-9ee2-2a0b5b3b2666" />


### Parameters

| Structure | Configuration |
|---|---|
| Reorder Buffer (ROB) | 16 entries |
| Reservation Station (RS) | 8 entries |
| Load-Store Queue (LSQ) | 8 entries, with store-to-load forwarding |
| Physical Register File | 64 registers (6-bit physical tags) |
| Architectural registers | 32 (RV32I) |
| Rename | RAT + Free-List, ARAT-based recovery on mispredict |
| Memory interface | Chip-level ports (external instruction/data memory) |

### Verified ISA Subset

| Class | Instructions |
|---|---|
| R-type | `ADD` `SUB` `AND` `OR` `XOR` `SLL` `SRL` `SRA` `SLT` `SLTU` |
| I-type | `ADDI` `ANDI` `SLTI` `SLTIU` |
| Branch | `BEQ` `BNE` `BLT` `BGE` `BLTU` `BGEU` |
| Jump | `JAL` `JALR` |
| Upper-imm | `LUI` `AUIPC` |
| Memory | `LW` `SW` |

---

## 2. TAGE-SC-L Branch Predictor

Three cooperating predictors, following Seznec's TAGE-SC-L design. Each component targets a
different class of branch behaviour, and they are combined by a confidence-gated override
policy.

### 2.1 TAGE — Geometric History Length Tables

| Table | Entries | History length | Tag width | Counter |
|---|---|---|---|---|
| **T0** (bimodal) | 128 | — (PC only) | none | 2-bit unsigned |
| **T1** | 32 | 4 | 8-bit | 3-bit signed |
| **T2** | 32 | 16 | 10-bit | 3-bit signed |
| **T3** | 32 | 64 | 12-bit | 3-bit signed |

- **Provider selection** — the longest-history table whose tag matches supplies the
  prediction; the next-longest match becomes the *alternate* prediction, used to drive
  useful-bit updates.
- **Folded XOR indexing** — the 64-bit global history register is compressed to a 5-bit
  index and a 10/12-bit tag by segmenting and XOR-folding, so every history bit influences
  the lookup in a single cycle of pure XOR logic.
- **Independent index/tag hashing** — indices and tags fold different slices, so an index
  collision does not imply a tag collision. Tag widths scale with history length
  (8/10/12-bit for h = 4/16/64) because longer histories compress into the same 5-bit index
  space and therefore alias more.
- **Useful-bit replacement** — `u` measures how often an entry beat its alternate, not how
  often it was correct. Only `u == 0` entries may be reallocated, and an 8-bit aging counter
  halves all useful bits every 256 updates so stale entries are eventually reclaimed.

### 2.2 Loop Predictor (LP)

8 entries · 10-bit tag · 10-bit current/committed iteration counters · 2-bit confidence.

TAGE saturates on a long-running loop and therefore mispredicts every loop exit. The LP
counts iterations and predicts `taken` while `cur_iter < conf_iter`. It only overrides TAGE
after the same trip count has been observed twice (confidence ≥ 2), which prevents it from
interfering with irregular branches.

### 2.3 Statistical Corrector (SC)

Three 16-entry tables of 6-bit signed counters, indexed by three independent views:

| Table | Index | Captures |
|---|---|---|
| `sc_ghist` | `PC ^ GHR[3:0]` | correlation with recent branch outcomes |
| `sc_path` | `PC ^ PHR[3:0]` | correlation with the control-flow path taken |
| `sc_bias` | `PC` | the branch's intrinsic bias |

The three counters are sign-extended and summed — a hardware perceptron. SC overrides TAGE
only when **all three** conditions hold: TAGE's provider counter is weak, `|score| ≥ 8`, and
the two predictions disagree. Updates are error-driven (counters move only when the final
prediction was wrong), which keeps switching activity low.

### 2.4 Override Priority

```
if      (LP confidence ≥ 2)                        → use LP
else if (TAGE weak && SC strong && they disagree)  → use SC
else                                                → use TAGE
```

---

## 3. Branch Prediction Results

Three predictor configurations were built and run through the identical 14-test regression:

- **No BPU** — no branch predictor; fetch advances `PC + 4` unconditionally and relies on
  the ROB to flush and redirect. Since the regression is loop-dominated (~81% of branches
  taken), this is correct only on the ~19% that fall through.
- **TAGE** — 4-table geometric-history TAGE
- **TAGE-SC-L** — TAGE + Loop Predictor + Statistical Corrector

### 3.1 Aggregate Results

| Metric | No BPU | TAGE | **TAGE-SC-L** | No BPU → SC-L |
|---|---|---|---|---|
| Branch accuracy | 18.6% | 94.7% | **96.5%** | **+77.9 pp** |
| MPKI | 281.8 | 18.1 | **11.9** | **−95.8%** |
| Mispredicts | 2,011 | 158 | **104** | **−94.8%** |
| Active IPC | 0.358 | 0.489 | **0.492** | **+37.4%** |
| Instructions retired | 7,134 | 8,684 | **8,684** | +21.7% |
| Active cycles | 19,873 | 17,723 | **17,615** | −11.4% |


### 3.2 Per-Test Breakdown

**Test 10 — 100-iteration loop** (99 T + 1 NT, tests warm-up behaviour)

| | No BPU | TAGE | TAGE-SC-L |
|---|---|---|---|
| Result | 1 P / 1 **F** | 2 P / 0 F | 2 P / 0 F |
| Accuracy | 0.8% | 98.0% | **98.0%** |
| MPKI | 390.7 | 7.6 | **7.6** |
| Mispredicts | 118 | 4 | **4** |
| IPC | 0.201 | 0.350 | **0.350** |

**Test 11 — Alternating pattern, period 2** (T, NT, T, NT …)

| | No BPU | TAGE | TAGE-SC-L |
|---|---|---|---|
| Result | 1 P / 3 **F** | 4 P / 0 F | 4 P / 0 F |
| Accuracy | 20.6% | 89.3% | **98.1%** |
| MPKI | 312.1 | 41.3 | **7.1** |
| Mispredicts | 407 | 64 | **11** |
| IPC | 0.260 | 0.339 | **0.347** |
| LP overrides | — | — | **293** |

**Test 12 — 4-cycle pattern, period 4** (NT NT NT T)

| | No BPU | TAGE | TAGE-SC-L |
|---|---|---|---|
| Result | 1 P / 3 **F** | 4 P / 0 F | 4 P / 0 F |
| Accuracy | 27.8% | 92.4% | 91.9% |
| MPKI | 299.3 | 31.1 | 33.5 |
| Mispredicts | 397 | 53 | 57 |
| LP / SC overrides | — | — | LP 64 / SC 5 |

**Test 13 — 16-cycle pattern, period 16** (exercises T2, h = 16)

| | No BPU | TAGE | TAGE-SC-L |
|---|---|---|---|
| Accuracy | 32.3% | 95.9% | **95.9%** |
| MPKI | 298.8 | 17.8 | **17.8** |
| Mispredicts | 318 | 19 | **19** |
| IPC | 0.399 | 0.515 | **0.515** |
| Provider mix | — | T0 213 / T1 180 / **T2 66** / T3 11 | same |

**Test 15 — Nested loop, 30 × 16** (the Loop Predictor's design target)

| | No BPU | TAGE | TAGE-SC-L |
|---|---|---|---|
| Result | 2 P / 3 **F** | 5 P / 0 F | 5 P / 0 F |
| Accuracy | **5.9%** | 98.6% | **99.1%** |
| MPKI | 299.9 | 4.3 | **2.7** |
| Mispredicts | 757 | 14 | **9** |
| IPC | 0.505 | 0.765 | **0.767** |
| LP overrides | — | — | **912** (89.4% of branches) |

> Mispredicts on this test fall **757 → 9 (−98.8%)** from the unpredicted baseline to
> TAGE-SC-L, and a further **−35.7%** from TAGE to TAGE-SC-L. The LP supplies the
> prediction for 89.4% of all branches here, exactly as designed.

### 3.3 Provider Distribution

Which TAGE table supplied the final prediction, aggregated over all tests:

| Provider | Count | Share |
|---|---|---|
| T0 (bimodal) | 1,586 | 52.7% |
| T1 (h = 4) | 1,076 | 35.7% |
| T2 (h = 16) | 249 | 8.3% |
| T3 (h = 64) | 99 | 3.3% |

Component overrides of the TAGE prediction:

| Component | Overrides | Share of branches |
|---|---|---|
| Loop Predictor | 1,269 | 42.2% |
| Statistical Corrector | 5 | 0.2% |

The distribution matches the design intent: the bimodal table handles statically-biased
branches, T1 covers short repeating patterns, and the higher-order tables are reserved for
the genuinely long-history cases. The regression is loop-dominated, so the LP is the
principal contributor among the SC-L extensions.

---

## 4. PPA Trade-off Analysis

All three predictor configurations were synthesised with Design Compiler under identical
constraints (6.5 ns clock target, gscl45nm, typical corner). **All three met timing with
zero slack violation**, which makes the deltas below a clean measurement of what the
predictor costs.

### 4.1 Synthesis PPA

| Metric | No BPU | TAGE | **TAGE-SC-L** | No BPU → SC-L |
|---|---|---|---|---|
| Total cell area (µm²) | 923,041.8 | 989,472.6 | **1,018,864.4** | **+10.38%** |
| Combinational | 524,099.2 | 562,612.3 | 582,133.8 | +11.07% |
| Sequential | 398,942.6 | 426,860.3 | 436,730.6 | +9.47% |
| Sequential cells | 38,640 | 41,344 | **42,300** | +9.47% |
| Combinational cells | 222,369 | 238,750 | 247,446 | +11.28% |
| Total power (mW) | 147.75 | 158.48 | **162.42** | **+9.93%** |
| Dynamic | 141.42 | 151.71 | 155.46 | +9.93% |
| Leakage | 6.29 | 6.74 | 6.92 | +10.08% |
| **Setup slack** | **MET** | **MET** | **MET** | **no penalty** |

Incremental cost of each stage:

| | No BPU → TAGE | TAGE → TAGE-SC-L |
|---|---|---|
| Area | +7.20% | **+2.97%** |
| Power | +7.26% | **+2.48%** |
| Flip-flops | +2,704 | **+956** |

### 4.2 The Predictor Is Not on the Critical Path

All three configurations report an **identical critical path** and an identical 6.42 ns
arrival time:

```
No BPU     rob/head_reg[2] → arat → rename_stage/u_free_list/FIFO_reg[29][5]   6.42 ns  MET
TAGE       rob/head_reg[1] → arat → rename_stage/u_free_list/FIFO_reg[16][5]   6.42 ns  MET
TAGE-SC-L  rob/head_reg[0] → arat → rename_stage/u_free_list/FIFO_reg[21][5]   6.42 ns  MET
```

The bottleneck is the **rename recovery path** (ROB retire → ARAT recovery mux → free-list
allocation), not the predictor. Adding a full TAGE-SC-L predictor to a core that previously
had none therefore costs **zero frequency**.

### 4.3 Efficiency

Because the frequency is unchanged, the IPC gain translates directly into throughput:

| Metric | No BPU | TAGE-SC-L | Δ |
|---|---|---|---|
| Active IPC | 0.358 | 0.492 | +37.4% |
| Area | 0.9230 mm² | 1.0189 mm² | +10.4% |
| Power | 147.75 mW | 162.42 mW | +9.9% |
| **IPC per mm²** | 0.3879 | 0.4829 | **+24.5%** |
| **IPC per mW** | 0.002423 | 0.003029 | **+25.0%** |

A 37.4% performance gain for roughly 10% area and power is a net **~25% improvement in
performance density** — the predictor pays for itself several times over.

### 4.4 Where the SC-L Flip-Flops Go

The measured cost of adding the Loop Predictor and Statistical Corrector to TAGE is
**+956 flip-flops**. Accounting for it from the RTL:

| Source | Bits |
|---|---|
| Loop Predictor table (8 entries × 33 bit) | 264 |
| SC tables (3 × 16 entries × 6-bit signed) | 288 |
| Path History Register | 16 |
| Widened `bpu_meta_t` stored in the ROB (27 bit × 16 entries) | 432 |
| **Predicted total** | **1,000** |
| **Measured** | **956** (−4.4%, absorbed by synthesis optimisation) |

Note that a substantial fraction of the predictor's cost is **not** in the predictor itself:
the 85-bit `bpu_meta_t` prediction metadata is carried alongside every in-flight instruction
through decode, rename, the reservation station and the ROB, so that the correct table
entries can be updated at retire.

---

## 5. Physical Design

Full place-and-route in Cadence Innovus 25.1, from netlist to DRC-clean layout.

### 5.1 Flow

```
Design Import (Verilog netlist + LEF + MMMC)
  → Floorplan (1:1 aspect ratio, 70% target utilisation, 20 µm core margin)
  → Power Planning (UPF power intent → ring → stripes)
  → Placement (place_design with pre-place optimisation)
  → Pre-CTS Optimisation
  → Clock Tree Synthesis (CLKBUF1/2/3 + INVX1/2/4/8, useful skew enabled)
  → Post-CTS Optimisation
  → Routing (NanoRoute, timing-driven, metal1–metal10, 40 iterations)
  → ECO Routing
  → DRC Signoff → GDSII
```

### 5.2 Final Chip

| Parameter | Value |
|---|---|
| Die size | 675.45 × 672.60 µm = **0.4543 mm²** |
| Core size | 635.08 × 632.32 µm = **0.4016 mm²** |
| Core utilisation | **71.42%** |
| Placed instances | **95,753** |
| Standard-cell area | **286,797 µm²** |
| Flip-flops | **9,548** |
| Metal layers | metal1 – metal10 |
| Total wire length | **1,215,327 µm** |
| Vias | **723,667** |
| Routing overflow | **0.00% H / 0.00% V** |
| **DRC violations** | **0** |

<img width="1002" height="999" alt="image" src="https://github.com/user-attachments/assets/ff1652bc-1731-4160-8d13-9793df5a462e" />
<img width="1146" height="1125" alt="image" src="https://github.com/user-attachments/assets/8352cd2a-dc2e-4f6b-8ede-2766b434c32f" />
<img width="731" height="221" alt="image" src="https://github.com/user-attachments/assets/c97843da-59e3-49f0-96d5-6537e9d3ea23" />

### 5.3 Power Distribution Network

Defined via an **IEEE 1801 (UPF)** power intent file declaring a single power domain
(`PD_TOP`) with `VDD`/`VSS` supply nets, then physically implemented as:

| Element | Layer | Width | Spacing | Pitch |
|---|---|---|---|---|
| Core ring (top/bottom) | metal3 (H) | 3 µm | 2 µm | — |
| Core ring (left/right) | metal2 (V) | 3 µm | 2 µm | — |
| Power stripes | metal3 (V) | 2 µm | 2 µm | 40 µm set-to-set |

Layers follow the library's preferred routing directions, so the horizontal rings and
vertical stripes intersect orthogonally and stitch into a grid through vias. **91,818
cell power pins** were connected to the global supply nets.

### 5.4 Clock Tree Synthesis

| Parameter | Value |
|---|---|
| Clock sinks | 9,548 |
| Buffer cells | CLKBUF1 / CLKBUF2 / CLKBUF3 |
| Inverter cells | INVX1 / INVX2 / INVX4 / INVX8 |
| Useful skew applied | 212 endpoints advanced by 300 ps |

### 5.5 Area Breakdown by Module

| Module | Instances | Area (µm²) | Share |
|---|---|---|---|
| `rename_stage` | 33,601 | 75,379.4 | **26.28%** |
| `free_list` | 31,719 | 69,732.8 | 24.31% |
| `rat` | 1,862 | 5,605.8 | 1.95% |
| **`bpu`** (TAGE-SC-L) | 15,992 | 53,565.9 | **18.68%** |
| `prf` | 15,395 | 49,740.6 | 17.34% |
| `rob` | 13,465 | 47,002.3 | 16.39% |
| `rs` | 7,006 | 26,362.0 | 9.19% |
| `lsq` | 6,624 | 22,845.1 | 7.97% |
| `alu` | 1,658 | 5,094.7 | 1.78% |
| `arat` | 1,085 | 3,969.8 | 1.38% |
| `fetch` | 261 | 1,109.4 | 0.39% |
| `decode` | 277 | 941.9 | 0.33% |
| **Total** | **95,753** | **286,797.2** | 100% |

The free-list dominates the floorplan at 24.31% of core area — and it is also the endpoint
of the critical path. Area and timing pressure point at the same structure, which identifies
rename recovery as the single highest-value target for further optimisation.

### 5.6 Power Analysis

Post-route power at 90.91 MHz, 1.1 V, 0.2 default switching activity:

| Component | Power (mW) | Share |
|---|---|---|
| Internal | 43.51 | 63.20% |
| Switching | 23.39 | 33.98% |
| Leakage | 1.94 | 2.82% |
| **Total** | **68.84** | 100% |

| Group | Power (mW) | Share |
|---|---|---|
| Combinational | 41.40 | 60.14% |
| Sequential | 27.44 | 39.86% |

Total switched capacitance **801 pF**; power density **151.5 mW/mm²**.

---

## 6. Timing Closure

### 6.1 Closure Progression

| Stage | Clock | WNS |
|---|---|---|
| Synthesis | 6.5 ns | MET |
| Post-placement + opt | 6.5 ns | −1.577 ns |
| Post-CTS | 6.5 ns | −2.592 ns |
| Post-route | 9.0 ns | −4.499 ns |
| Post-route | 15.0 ns | +3.957 ns |
| Post-route | 12.0 ns | +1.074 ns |
| **Post-route (final)** | **11.0 ns** | **+0.074 ns** |

### 6.2 Finding the Maximum Frequency

Rather than shipping the first period that closed, the clock constraint was swept by binary
search against the *same routed netlist* — changing only the SDC, since the netlist and
parasitics are independent of the target period. This recovered the true frequency ceiling:

| Clock | Frequency | WNS |
|---|---|---|
| 15 ns | 66.7 MHz | +3.957 ns |
| 12 ns | 83.3 MHz | +1.074 ns |
| **11 ns** | **90.9 MHz** | **+0.074 ns** |
| 9 ns | 111.1 MHz | −4.499 ns |

The design closes at **11 ns / 91 MHz** — **36.4% faster** than the first conservative
period that met timing, at zero additional design effort.

### 6.3 The Limiting Path

```
rob/head_reg[0]                        (ROB head pointer)
  → arat (recovery mux)                (architectural RAT recovery)
    → rename_stage/u_free_list/FIFO_reg (physical register reclamation)
```

This is the **rename recovery path**: on retire, the ROB head releases a physical register,
the ARAT updates the architectural mapping, and the free-list reclaims the tag — all
combinationally within one cycle, spanning three modules. It is the critical path in every
configuration built, and is independent of the branch predictor. The standard industrial
remedy is to pipeline rename recovery across two cycles, trading one cycle of recovery
latency for a substantially shorter combinational path.

---

## 7. Verification

### 7.1 RTL Simulation — 75/75 checks PASS

14 directed tests, 75 assertion checks, verified against architectural register file and
data memory contents.

| # | Test | Focus | Checks |
|---|---|---|---|
| 1 | Basic ALU | All R-type and I-type ALU operations | 10 |
| 2 | Fibonacci | 10-iteration loop, repeated mispredict recovery | 4 |
| 3 | Signed branches | `BEQ` / `BNE` / `BLT` / `BGE`, taken and not-taken | 8 |
| 4 | Unsigned compare | `SLTU` / `SLTIU` / `BLTU` / `BGEU` | 9 |
| 5 | Jumps | `JAL` / `JALR` / `AUIPC` with link registers | 10 |
| 6 | Load | `LW` from pre-loaded data memory | 2 |
| 7 | Store | `SW` to data memory | 3 |
| 8 | Store-to-load forwarding | LSQ forwards an in-flight store to a later load | 4 |
| 9 | Multi-store forwarding | Load must receive the *latest* matching store | 6 |
| 10 | BPU stress | 100-iteration loop, predictor warm-up | 2 |
| 11 | BPU pattern | Alternating, period 2 | 4 |
| 12 | BPU pattern | 4-cycle, period 4 | 4 |
| 13 | BPU pattern | 16-cycle, period 16 (exercises T2, h = 16) | 4 |
| 15 | Nested loop | 30 × 16 nested loop (Loop Predictor showcase) | 5 |
| | | **Total** | **75** |

The testbench instruments the DUT every cycle to collect per-test and aggregate
microarchitectural statistics: retired instructions, active cycles, branch count, mispredict
count, TAGE provider distribution, and Loop Predictor / Statistical Corrector override
counts.

### 7.2 Gate-Level Simulation

The post-synthesis netlist was simulated with SDF back-annotation on Cadence NCSim, using
the gscl45nm Verilog cell models.

| Check | Result |
|---|---|
| Netlist elaboration | 9,548 flip-flops + standard cells resolved |
| Reset behaviour | All state initialised correctly |
| X-propagation on chip outputs | **0 over 2,000 cycles** |
| Program counter | Advanced normally throughout execution |

---

## 8. Repository Structure

```
.
├── src/
│   ├── riscv_pkg.sv        Shared types: inst_pkt_t, bpu_meta_t, rob_entry_t …
│   ├── Top.sv              Top level
│   ├── fetch.sv            Fetch + next-PC logic
│   ├── bpu.sv              TAGE-SC-L branch predictor
│   ├── decode.sv           Instruction decode
│   ├── rename_stage.sv     Rename (RAT + free-list)
│   ├── rat.sv              Speculative register alias table
│   ├── arat.sv             Architectural register alias table (mispredict recovery)
│   ├── free_list.sv        Physical register free list
│   ├── rs.sv               Reservation station
│   ├── alu.sv              Execution unit
│   ├── lsq.sv              Load-store queue with store-to-load forwarding
│   ├── rob.sv              Reorder buffer
│   ├── prf.sv              Physical register file
│   ├── imem.sv             Instruction memory model (simulation only)
│   ├── dmem.sv             Data memory model (simulation only)
│   ├── code.txt            Instruction memory image
│   ├── tb_Top.sv           RTL regression testbench — 14 tests / 75 checks
│   ├── run.do              Batch simulation script
│   └── run_gui.do          Simulation script with waveform viewer
└── .gitignore
```

### Branches

| Branch | Memory architecture |
|---|---|
| `master` | Memory instantiated inside the top module |
| `mem_out-v3` | Memory external to the chip, accessed through top-level ports — the configuration used for physical design |

---

## References

- A. Seznec and P. Michaud, *A case for (partially) TAgged GEometric history length branch
  prediction*, Journal of Instruction-Level Parallelism, 2006.
- A. Seznec, *TAGE-SC-L branch predictors*, 4th JILP Championship Branch Prediction, 2014.
- D. Jiménez and C. Lin, *Dynamic branch prediction with perceptrons*, HPCA 2001.
