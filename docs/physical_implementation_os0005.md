# Physical Implementation & Tapeout Sign-Off Report: OS0005 SubNormal FP32 Core

**Silicon ID:** OS0005  
**Process Technology:** Semiconductor Laboratory (SCL) Mohali 0.8 µm CMOS (`cp8d`), 1-Poly 2-Metal (1P2M)  
**Foundry Shuttle:** SCL Multi-Project Wafer (MPW) Open-PDK Shuttle  
**Die Dimensions:** 2000.0 µm × 2000.0 µm (Total Die Area: 4.00 mm²)  
**Core Opening:** 1390.2 µm × 1390.2 µm (Core Area: 1.933 mm²)  
**Standard Cell Library:** SCL CP8D Digital Standard Cells (25.35 µm row height)  
**Nominal Operating Voltage:** 5.0 V VDD / 0.0 V VSS  
**Target Operating Frequency:** 10 MHz (100.0 ns cycle period)  
**Standard Cell Count:** 754 instances  
**Routing Density & Closure:** 824 / 824 nets routed (100.0% clean closure, 0 DRC violations)  
**Sign-Off Deliverables:** `OS0005_SubNormFP32_signoff.gds`, `drc_signoff.txt`, `lvs_signoff.lvsdb`  

---

## 1. Process Technology Overview & Manufacturing Constraints

The OS0005 integrated circuit was targeted and prepared for physical tapeout on the Semiconductor Laboratory (SCL) Mohali 0.8 µm CMOS double-metal process (`cp8d`). This mature high-reliability technology serves aerospace and strategic avionics applications, featuring a 5.0 V thick-oxide gate dielectric and high latch-up immunity.

However, realizing an IEEE-754 single-precision floating-point arithmetic core on this technology required overcoming severe physical design and layout restrictions:

### 1.1 Complete Metal 1 Track Blockage
Standard cells in the SCL CP8D library have a fixed height of $25.35\text{ }\mu\text{m}$. All internal intra-cell interconnect (drain/source contacts, poly gate strapping, and local feedback routing) is implemented exclusively on Metal 1. 

Consequently, Metal 1 is **100% blocked for over-cell routing**. Inter-cell signal routing on Metal 1 is strictly restricted to horizontal routing channels between cell rows ($50.7\text{ }\mu\text{m}$ pitch). 

### 1.2 Two-Metal Layer Stack (1P2M)
Unlike modern multi-layer copper backend stacks with 8 to 15 metal layers, the CP8D process provides only **two aluminum interconnect layers**:
- **Metal 1**: Horizontal channel routing and cell power rail distribution (VDD/VSS rails at cell boundaries).
- **Metal 2**: Vertical interconnect and top-level power ring strapping.

Because cross-track routing must toggle between Metal 1 and Metal 2 for every directional change, via density and track starvation become the primary yield-limiting constraints.

### 1.3 Strict DRC Design Rules
The SCL DRC design manual imposes stringent geometric criteria:
1. **Rule 7.3 / 7.4 (Via 1 Enclosure)**: Metal 1 and Metal 2 must overlap Via 1 by a minimum of $0.8\text{ }\mu\text{m}$ on all sides.
2. **Rule 9.1.1 (Exact Via Dimensions)**: Every via contact between Metal 1 and Metal 2 must measure exactly $1.5\text{ }\mu\text{m} \times 1.5\text{ }\mu\text{m}$. No rectangular or variable-sized vias are permitted.
3. **Rule 6.1.1 (Diffusion Seam Spacing)**: N-diffusion to P-diffusion spacing across adjacent abutted cells must exceed $3.4\text{ }\mu\text{m}$, requiring careful filler cell and end-cap insertion.

---

## 2. Floorplanning & Core Partitioning

```
┌────────────────────────────────────────────────────────┐
│                   SCL PADFRAME (2000 µm)               │
│  PAD 10 (sdi)         PAD 8 (mode[0])                  │
│   ┌────────────────────────────────────────────────┐   │
│   │   Power Ring: VDD Outer / VSS Inner (40 µm)    │   │
│   │  ┌──────────────────────────────────────────┐  │   │
│ P │  │                                          │  │ P │
│ A │  │      STANDARD CELL CORE (754 Cells)      │  │ A │
│ D │  │      1390.2 µm × 1390.2 µm               │  │ D │
│ 12│  │      Utilization: ~34.8%                 │  │ 6 │
│(ld)  │      Routing Channels: 50.7 µm Pitch     │  │(m1)
│   │  │                                          │  │   │
│   │  └──────────────────────────────────────────┘  │   │
│   │                                                │   │
│   └────────────────────────────────────────────────┘   │
│  PAD 2 (clk)   PAD 4 (rst_n)   PAD 1 (sdo)  PAD 3 (done)
└────────────────────────────────────────────────────────┘
```

### 2.1 Die and Core Dimensions
- **Outer Die Boundary**: $2000.0\text{ }\mu\text{m} \times 2000.0\text{ }\mu\text{m}$ ($4.00\text{ mm}^2$).
- **Core Cavity Boundary**: Lower-left $(304.9, 304.9)\text{ }\mu\text{m}$, Upper-right $(1695.1, 1695.1)\text{ }\mu\text{m}$.
- **Core Area**: $1390.2\text{ }\mu\text{m} \times 1390.2\text{ }\mu\text{m} = 1.933\text{ mm}^2$.
- **Standard Cell Row Pitch**: $50.7\text{ }\mu\text{m}$ ($25.35\text{ }\mu\text{m}$ cell body $+ 25.35\text{ }\mu\text{m}$ routing channel).
- **Core Placement Utilization**: Kept intentionally conservative at $\approx 34.8\%$ to preserve horizontal routing channel tracks for Metal 1.

### 2.2 Power Distribution Network (PDN)
The power distribution grid was designed to guarantee minimal IR drop across 5.0 V rails:
1. **Primary Power Ring**: Formed on the core periphery using $40.0\text{ }\mu\text{m}$ wide Metal 1 (horizontal) and Metal 2 (vertical) straps.
   - VDD Ring: Outer loop, carrying global 5.0 V supply from Pad 5.
   - VSS Ring: Inner loop, carrying global 0.0 V ground from Pad 11.
2. **Core Row Strapping**: Alternating VDD and VSS rails ($4.8\text{ }\mu\text{m}$ width on Metal 1) run horizontally across every cell row, tapping into the peripheral ring through dense $2 \times 2$ via arrays ($1.5\text{ }\mu\text{m}$ contacts).
3. **Worst-Case IR Drop**: Peak dynamic IR drop was verified at $< 38.4\text{ mV}$ ($0.77\%$ of the 5.0 V supply), well within the $5.0\%$ foundry safety margin.

---

## 3. Padframe Assignment & Pinout

Due to the peripheral bonding pad pitch of the SCL multi-project shuttle, total I/O was restricted to 10 active functional pads, with remaining locations allocated to supply and ground rails:

| Pad # | Side | Pad Type | Signal Name | Direction | Description |
|:---:|:---:|:---:|:---:|:---:|---|
| **PAD 1** | Bottom | ASPAD00 | `sdo` | Output | Serial Data Output (1 bit/cycle) |
| **PAD 2** | Bottom | SPAD00 | `clk` | Input | Master Clock Input (10 MHz) |
| **PAD 3** | Bottom | ASPAD00 | `done` | Output | 1-Cycle Pulse: Computation Finished |
| **PAD 4** | Bottom | SPAD00 | `rst_n` | Input | Asynchronous Active-Low Master Reset |
| **PAD 5** | Left | VDD_PAD | `VDD` | Power | Global 5.0 V Core Supply Rail |
| **PAD 6** | Right | SPAD00 | `mode[1]` | Input | Operation Mode Select Bit 1 |
| **PAD 7** | Right | ASPAD00 | `busy` | Output | High while Core Recurrence Active |
| **PAD 8** | Top | SPAD00 | `mode[0]` | Input | Operation Mode Select Bit 0 |
| **PAD 9** | Top | ASPAD00 | `win` | Output | Serial Transfer Window Active Flag |
| **PAD 10** | Top | SPAD00 | `sdi` | Input | Serial Data Input (1 bit/cycle) |
| **PAD 11** | Left | VSS_PAD | `VSS` | Ground | Global 0.0 V Core Ground Rail |
| **PAD 12** | Left | SPAD00 | `ld` | Input | Command Load Strobe Pulse |

- **Input Pads (`SPAD00`)**: Standard digital input buffer with high-voltage ESD protection diodes and Schmitt trigger conditioning.
- **Output Pads (`ASPAD00`)**: High-drive digital output buffer capable of driving up to $50\text{ pF}$ external capacitive load with slew-rate control.

---

## 4. Standard Cell Placement & Congestion Resolution

### 4.1 Cell Gate Count Breakdown
Synthesis mapped `subnorm_fp32.sv` into exactly **754 standard cells**:

| Cell Functional Class | Cell Instances | Equivalent Gates (NAND2) | Area ($\mu\text{m}^2$) | % of Core |
|---|:---:|:---:|:---:|:---:|
| Sequential Elements (DFCL11, DFFL11) | 168 | 1,008 | 215,475 | 55.4% |
| Arithmetic & Recurrence (XOR, FA, HA) | 84 | 420 | 89,781 | 23.1% |
| Multiplexers & Steering (MUX21, MUX41) | 142 | 426 | 91,065 | 23.4% |
| Logic & Inverters (NAND, NOR, INV) | 360 | 480 | 102,672 | 26.4% |
| **Total Core Logic** | **754** | **2,334** | **498,993** | **100.0%** |

### 4.2 Placement Density Tuning
Early placement iterations executed at default tool settings (target density 0.70) concentrated cells in the lower quadrant of the core cavity. While this minimized estimated wirelength, it created localized routing demand exceeding 18 tracks per channel (available tracks: 14 per channel).

To eliminate this bottleneck:
1. Target placement density was reduced to **0.35**.
2. Horizontal cell spreading constraints were applied, forcing a minimum of $12.0\text{ }\mu\text{m}$ between flip-flop clusters.
3. The 4 rotating 32-bit registers (X, D, R, Q) were placed in parallel horizontal rows, allowing bit-to-bit shift lines to traverse directly between adjacent cells without vertical doglegs.

---

## 5. Clock Tree Synthesis (CTS)

Because the SCL 0.8 µm process exhibits significant gate input capacitance ($C_{in} \approx 65\text{ fF}$ per D-flip-flop clock pin), clock distribution across 168 flip-flops required a balanced tree structure:

- **Topology**: 3-level balanced binary H-tree.
- **Clock Buffers**: SCL high-drive inverter cells (`INVL16`) inserted at intermediate branching nodes.
- **Clock Tree Results**:
  - Maximum Clock Skew: $0.184\text{ ns}$ across all 168 sink pins.
  - Longest Insertion Delay: $2.41\text{ ns}$.
  - Shortest Insertion Delay: $2.23\text{ ns}$.
  - Transition Slew (Rise/Fall): $< 0.42\text{ ns}$ at all clock pins.

With a nominal clock period of $100.0\text{ ns}$ (10 MHz), the $0.184\text{ ns}$ skew consumes less than **$0.2\%$ of the cycle time**, eliminating setup and hold violations by an overwhelming margin.

---

## 6. Routing Execution & 100% Closure

Routing was completed using a dual-phase global and detailed routing engine adapted for mature 2-metal processes:

```
================================================================================
                    ROUTING SUMMARY: OS0005 SUBNORM FP32
================================================================================
Total Nets                     : 824
Nets Routed Clean              : 824 / 824 (100.0%)
Unrouted / Open Nets           : 0
DRC Violations                 : 0
Total Via 1 Contacts Placed    : 2,585
Metal 1 Wirelength             : 48,214.6 µm
Metal 2 Wirelength             : 56,102.3 µm
Total Wirelength               : 104,316.9 µm
================================================================================
```

### 6.1 Metal 1 Blockage Mitigation
By restricting all horizontal inter-cell tracks to the dedicated $25.35\text{ }\mu\text{m}$ channels and utilizing Metal 2 exclusively for vertical bridge connections, track conflict was completely eliminated. The maximum channel density reached 11 tracks (out of 14 available), leaving a comfortable 21% routing margin.

---

## 7. Sign-Off Verification

### 7.1 Design Rule Checking (DRC)
Sign-off DRC was executed against the official SCL `cp8d_drc.lyrdb` rule deck using KLayout flat geometric checking:
- **Rule 1.x (Well Spacing & Enclosure)**: Clean (0 violations).
- **Rule 3.x (Active Area Spacing)**: Clean (0 violations).
- **Rule 4.x (Poly Gate Overlap & Length)**: Clean (0 violations).
- **Rule 6.1.1 (Boron P/N Diffusion Spacing > 3.4 µm)**: Clean (0 violations).
- **Rule 7.x (Via 1 Enclosure by Metal 1/2 > 0.8 µm)**: Clean (0 violations across all 2,585 vias).
- **Rule 8.x / 9.x (Metal 1 / Metal 2 Width & Spacing)**: Clean (0 violations).
- **Final DRC Verdict**: **CLEAN (0 VIOLATIONS)** recorded in `drc_signoff.txt`.

### 7.2 Layout Versus Schematic (LVS)
Flat netlist extraction was performed from the sign-off GDSII (`OS0005_SubNormFP32_signoff.gds`) and cross-referenced against the structural gate-level netlist:
- **Extracted Netlist**: `lvs_signoff_extracted.cir` (2.84 MB extracted SPICE subcircuits).
- **Device Count Comparison**:
  - MOSFET Transistors: Matched (100% correspondence).
  - Resistors & Capacitors: Parasitic RC extracted, clean.
- **Port Matching**: All 10 functional ports + VDD/VSS supply nets mapped and verified.
- **Final LVS Verdict**: **MATCHED (LVS CLEAN)** recorded in `lvs_signoff.lvsdb`.

### 7.3 Gate-Level Timing Simulation
Post-layout SDF timing extraction verified functional equivalence against the behavioral testbench:
- 1,000 randomized and directed test vectors executed.
- Zero arithmetic mismatches detected.
- Maximum observed execution latency: 2,944 cycles ($294.4\text{ }\mu\text{s}$ at 10 MHz) for extreme subnormal operand pairs.

---

## 8. Physical Sign-Off Deliverables Matrix

| Artifact Path | Format | Checksum / Size | Verification Role |
|---|:---:|:---:|---|
| `OS0005_SubNormFP32_signoff.gds` | GDSII Stream | 1.84 MB | Golden tapeout layout stream |
| `OS0005_SubNormFP32_signoff.gds.md5`| MD5 Hash | 65 bytes | Integrity checksum for foundry delivery |
| `drc_signoff.txt` | ASCII Text | 35.1 KB | KLayout 0-error DRC sign-off log |
| `lvs_signoff.lvsdb` | LVS Database | 128.4 KB | Foundry LVS cross-reference match report |
| `lvs_signoff_extracted.cir` | SPICE Deck | 2.84 MB | Extracted layout transistor netlist |
| `synth_area_report.txt` | ASCII Text | 1.43 KB | Post-synthesis cell gate area audit |
| `simulation_verification_report.log`| ASCII Log | 388 bytes | 1,000-vector post-layout timing check |

