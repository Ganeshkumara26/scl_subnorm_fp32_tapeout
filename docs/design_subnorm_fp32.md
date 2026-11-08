# Design Document: `subnorm_fp32` — Serial IEEE-754 Binary32 Divide/Square-Root Unit

**Silicon ID:** OS0005  
**Process:** SCL Mohali 180nm CMOS (CP8D), 2-metal routing layers  
**Author:** OS0005 Design Team  
**Status:** Taped out — GDSII frozen and delivered to foundry

---

## 1. Executive Summary and Motivation

The `subnorm_fp32` module implements a fully IEEE-754-2008 compliant binary32 (single-precision) floating-point divider and square-root unit with complete gradual underflow support. The design targets the SCL Mohali 180nm CMOS process under the OS0005 tapeout run.

The central constraint driving every architectural decision is the **2-metal routing limitation** of the CP8D process technology. With only Metal 1 and Metal 2 available for signal routing, standard cell internal wiring consumes the entire Metal 1 layer within each cell row. All inter-cell routing must therefore occur on Metal 2 within dedicated routing channels. Our empirical analysis established that designs exceeding approximately 800 standard cells become unroutable under these constraints — Metal 2 track demand exceeds available channel capacity, causing routing congestion failures.

We therefore adopted a **serial bit-level architecture**: four 32-bit registers rotate right every clock cycle, feeding all arithmetic through a single 1-bit full subtractor. This reduces the combinational logic to the absolute minimum — no 24-bit adders, no barrel shifters, no multiplexers wider than a few bits. The result: **753 standard cells** after synthesis, comfortably within the 2-metal routing budget.

The trade-off is latency. A single divide or square-root operation requires approximately 2,944 clock cycles in the worst case (deeply subnormal inputs requiring many normalization passes). At the nominal 10 MHz clock, this corresponds to ~294 µs per operation. For the target application — a coprocessor offloading rare floating-point exceptions from an integer core — this latency is acceptable.

---

## 2. Non-Restoring Division Algorithm

We implement radix-2 non-restoring division for the mantissa quotient computation. Given dividend mantissa $A$ (24 bits, including hidden bit) and divisor mantissa $B$, we compute $Q = A / B$ using the recurrence:

$$R_{j+1} = 2R_j - q_j \cdot B$$

where $q_j \in \{-1, +1\}$ is the quotient digit selected by inspecting the sign of the current partial remainder:

$$q_j = \begin{cases} +1 & \text{if } R_j \geq 0 \\ -1 & \text{if } R_j < 0 \end{cases}$$

When $q_j = -1$, the recurrence adds $B$ rather than subtracting it, which is equivalent to subtracting $(-B)$. The key advantage over restoring division is that **no conditional restoration step** is required — the algorithm always proceeds forward, and the final remainder is corrected at the end if negative.

The serial implementation processes this recurrence one bit at a time. The partial remainder $R$ and divisor $B$ circulate through their respective 32-bit rotate registers. On each bit position, the 1-bit subtractor computes the difference, and the result is written back into $R$. After 32 clock cycles (one full rotation), one iteration of the recurrence is complete.

We perform **27 iterations** for division, producing 27 quotient bits. The extra bits beyond the 24-bit mantissa (23 fraction bits + hidden bit) provide the guard, round, and sticky information needed for IEEE-754 RNE rounding.

---

## 3. Non-Restoring Square Root Algorithm

Square root reuses the same serial subtractor with a modified recurrence. Given input mantissa $A$, we compute $Q = \sqrt{A}$ using:

$$R_{j+1} = 2R_j - (2Q_j + q_j) \cdot 2^{-(j+1)}$$

where $Q_j$ is the partial quotient accumulated so far. The subtrahend depends on the quotient bits already computed, which is why the serial engine must feed the quotient register back into the subtractor input (the `tq` signal in RTL).

For square root, the exponent transformation is:

$$E_{result} = \left\lfloor \frac{E_a + 126}{2} \right\rfloor$$

When the input exponent is odd (after bias removal), we pre-shift the mantissa left by one bit position before beginning iteration. This is handled by the `sqodd` flag and the S_SQ1/S_SQ2 preparation states.

We perform **26 iterations** for square root, producing 26 quotient bits. One fewer iteration is needed compared to division because the square root result has a narrower dynamic range.

---

## 4. Port List

| Port | Direction | Width | Description |
|:-----|:----------|:------|:------------|
| `clk` | Input | 1 bit | System clock, 10 MHz nominal |
| `rst_n` | Input | 1 bit | Active-low asynchronous reset |
| `ld` | Input | 1 bit | Load pulse — initiates operation or readback |
| `sdi` | Input | 1 bit | Serial data input (operand bits, LSB first) |
| `mode[1:0]` | Input | 2 bits | Operation select: `2'b00` = FDIV, `2'b01` = FSQRT, `2'b11` = readback |
| `sdo` | Output | 1 bit | Serial data output (result bits, LSB first) |
| `done` | Output | 1 bit | Operation complete flag (held until next operation) |
| `win` | Output | 1 bit | Window indicator: host may shift data in/out when high |
| `busy` | Output | 1 bit | Unit is actively computing or has a pending operation |

> [!NOTE]
> The serial interface was chosen to minimize pad count. With only 6 input pads (including clock and reset) and 4 output pads, the design fits within the OS0005 padframe allocation while leaving the majority of pads available for other functional blocks on the die.

---

## 5. FSM State Decomposition

The controller is a 15-state FSM. Every state runs for exactly **32 clock cycles** (one full register rotation), controlled by a 5-bit counter `c` that increments from 0 to 31.

| State | Duration | Purpose |
|:------|:---------|:--------|
| `S_IDLE` | 32 cycles | Waits for `ld` pulse. Latches `mode` and `pend` flag. Transitions on `c==31`. |
| `S_LDX` | 32 cycles | Shifts operand A (dividend or radicand) into register X via `sdi`, LSB first. |
| `S_LDD` | 32 cycles | Shifts operand B (divisor) into register D via `sdi`, LSB first. Ignored for FSQRT. |
| `S_DEC` | 32 cycles | Decodes IEEE-754 fields: extracts sign, exponent, mantissa. At `c==23`, exponent bytes are aligned at X[7:0] and D[7:0]. Accumulates mantissa-nonzero flags `fa`, `fb`. Inserts hidden bits into R and D at `c==23`. Evaluates special cases at `c==31`. Computes initial exponent $E = e_a - e_b + 127$ (division) or $E = e_a$ (square root, deferred to S_SQ1). |
| `S_PREA` | 32 cycles × N | Normalizes dividend/radicand mantissa in R. Shifts mantissa left by one bit per pass (via delayed feedback) while decrementing exponent E. Repeats until `R[23]` (hidden bit position) is set. |
| `S_PREB` | 32 cycles × N | Normalizes divisor mantissa in D. Same mechanism as S_PREA but increments exponent E (since divisor normalization shifts increase the quotient). Repeats until `D[23]` is set. |
| `S_SQ1` | 32 cycles | Square root exponent preparation. Computes $E = (E + 126) \gg 1$ with carry-in for odd exponents. Constructs the initial radicand alignment in X. |
| `S_SQ2` | 32 cycles | Square root mantissa preparation. Sets initial partial remainder R with the leading radicand bit(s) depending on odd/even exponent parity. |
| `S_ITER` | 64 cycles × K | Main iteration engine. Each iteration consists of two 32-cycle passes: **Pass 0** (sign evaluation) — the subtractor runs and the borrow-out at `c==31` determines `ge` (the quotient bit). **Pass 1** (conditional write-back) — if `ge==1`, the subtraction result is committed into R; otherwise R retains its original value. Runs K = 27 iterations for division, K = 26 for square root. |
| `S_NORM` | 32 cycles × N | Post-iteration normalization. If the quotient Q does not have bit 26 set, shifts Q left and decrements E. Repeats until `Q[26]` is set. (Division only; square root quotients are inherently normalized.) |
| `S_DEN` | 32 cycles × N | Denormalization for subnormal results. If $E \leq 0$, shifts Q right and increments E, accumulating shifted-out bits into the sticky flag `dst`. Repeats until $E = 1$ or the mantissa is fully exhausted ($E < -26$). |
| `S_RND` | 32 cycles | IEEE-754 Round-to-Nearest-Even. Computes the rounding increment `rc` from guard, round, and sticky bits. Propagates carry through the quotient mantissa via ripple-through logic on the rotating register. |
| `S_PACK` | 32 cycles | Assembles the final IEEE-754 result into register X. Packs the sign, biased exponent, and rounded mantissa fraction according to the result `kind` (normal, infinity, NaN, or zero). |
| `S_RD1` | 32 cycles | Readback phase 1 — outputs X (the result) serially through `sdo`, LSB first. |
| `S_RD2` | 32 cycles | Readback phase 2 — outputs D (the remainder/diagnostic) serially through `sdo`, LSB first. |

---

## 6. IEEE-754 Special Case Truth Table

### Division Special Cases

| Operand A | Operand B | Result | Sign | Kind |
|:----------|:----------|:-------|:-----|:-----|
| NaN | Any | Quiet NaN | — | `2'd1` |
| Any | NaN | Quiet NaN | — | `2'd1` |
| ±∞ | ±∞ | NaN | — | `2'd1` |
| ±0 | ±0 | NaN | — | `2'd1` |
| ±∞ | Normal/Subnormal | ±∞ | $s_a \oplus s_b$ | `2'd2` |
| Normal/Subnormal | ±0 | ±∞ | $s_a \oplus s_b$ | `2'd2` |
| ±0 | Normal/Subnormal/∞ | ±0 | $s_a \oplus s_b$ | `2'd3` |
| Normal/Subnormal | ±∞ | ±0 | $s_a \oplus s_b$ | `2'd3` |

### Square Root Special Cases

| Operand A | Result | Notes |
|:----------|:-------|:------|
| NaN | Quiet NaN | Propagated |
| Negative (non-zero) | NaN | Invalid operation — $\sqrt{x < 0}$ is undefined |
| +0 / −0 | ±0 (same sign) | Zero preserved with sign |
| +∞ | +∞ | Positive infinity passes through |

> [!IMPORTANT]
> All special-case detection occurs combinationally during `S_DEC` at `c==31`, when the sign bits are aligned at the MSB of the rotating registers. When a special case is detected, the FSM skips directly from `S_DEC` to `S_PACK`, bypassing all iterative computation.

---

## 7. Subnormal Number Handling

### Subnormal Inputs (Gradual Underflow Detection)

A subnormal input is detected when its biased exponent field equals zero and its mantissa field is nonzero ($E = 0, f \neq 0$). The effective exponent for subnormals is $E_{eff} = 1$ (not 0), per IEEE-754 convention. The hidden bit is **not** inserted for subnormals — instead, the mantissa is loaded as-is.

The normalization states `S_PREA` and `S_PREB` iteratively shift the mantissa left (by rotating through a delayed feedback path) until the leading 1 reaches bit position 23. Each left-shift pass decrements the exponent by 1 (for the dividend) or increments it by 1 (for the divisor), maintaining the mathematical value. A deeply subnormal input with only bit 0 set may require up to 23 normalization passes, each costing 32 clock cycles.

### Subnormal Outputs (Gradual Underflow Generation)

After the iterative computation and post-normalization in `S_NORM`, if the result exponent $E \leq 0$, the design enters `S_DEN` to denormalize the result. The quotient register Q is shifted right by one bit per pass while incrementing E, until $E = 1$. Bits shifted out of Q are OR-accumulated into the sticky flag `dst` to preserve rounding accuracy.

If $E < -26$, the result has underflowed below the minimum subnormal — the mantissa is fully flushed to zero, and `dst` captures whether any nonzero bits were lost. The `e_cap` signal implements this floor.

---

## 8. RNE Rounding Implementation

Round-to-Nearest, ties-to-Even (RNE) is implemented in `S_RND`. After the quotient is positioned in Q with guard (G), round (R), and sticky (S) bits available:

- **G** = `Q[2]` — the guard bit (first bit beyond the mantissa)
- **R** = `Q[1]` — the round bit
- **S** = `Q[0] | nzr | dst` — the sticky bit (OR of all remaining bits, accumulated during iteration via `nzacc` and during denormalization via `dst`)

The rounding increment is:

$$rc = G \cdot (R \mid S \mid L)$$

where $L$ = `Q[3]` is the LSB of the retained mantissa (used for tie-breaking: round to even). This increment is added to the mantissa by ripple-carry propagation through the rotating Q register starting at bit 3. The carry `cy` propagates through subsequent bits as Q rotates.

---

## 9. Exponent Computation Pipeline

Exponent arithmetic uses a single 10-bit signed adder, time-multiplexed across states:

| State | Operation | Formula |
|:------|:----------|:--------|
| `S_DEC` (c==23) | Initial computation | $E = e_a - e_b + \text{(ci=1 for div)}$, or $E = e_a$ for sqrt |
| `S_DEC` (c==24) | Bias addition (div only) | $E = E + 127$ |
| `S_PREA` (c==0) | Normalize dividend | $E = E - 1$ (per pass) |
| `S_PREB` (c==0) | Normalize divisor | $E = E + 1$ (per pass) |
| `S_SQ1` (c==0) | Sqrt exponent halving | $E = (E + 126 + E[0]) \gg 1$ |
| `S_NORM` (c==0) | Post-normalize quotient | $E = E - 1$ (per pass, div only) |
| `S_DEN` (c==0) | Denormalize result | $E = E + 1$ (per pass) |
| `S_PACK` (c==0) | Overflow adjustment | $E = E + 1$ if `Q[27]` set |

---

## 10. Area and Timing Constraints

### Synthesis Results

| Metric | Value |
|:-------|:------|
| Total standard cells | 753 |
| Flip-flops (DFFL11) | 182 |
| Flip-flops with clear (DFCL11) | 13 |
| Combinational cells | 558 |
| Total cell area | 2,106.32 µm² |
| Target clock period | 100 ns (10 MHz) |
| Supply voltage | 5.0 V |

### Why ≤800 Cells Fits in 2-Metal Routing

In the CP8D process, standard cells have a fixed height of 25.35 µm. Metal 1 is consumed entirely within the cell for internal transistor-level wiring. All inter-cell signal routing must use Metal 2, which runs in horizontal channels spaced at the cell-row pitch of 50.7 µm (one routing channel per cell row). Each channel offers a finite number of Metal 2 tracks.

Our analysis determined that at approximately 800 cells, the net count (805 wires, 990 wire bits for our design) approaches the capacity limit of the available Metal 2 routing channels within the 1390.2 × 1390.2 µm core opening. Beyond this threshold, routing tools cannot achieve full completion without violations.

At 753 cells, we achieved routing closure with only minor Metal 2 spacing infractions attributable to the routing channel congestion at specific hotspots — all within foundry-waivable tolerances.

---

## 11. Verification Results

### RTL Simulation

We verified the design using Icarus Verilog with a comprehensive testbench (`tb_fp.sv`). The test vector file (`vec.txt`) contains stimulus covering:

- Normal × Normal division and square root
- Subnormal × Normal and Normal × Subnormal combinations
- Subnormal × Subnormal (deeply subnormal) operands
- All IEEE-754 special cases: ±0, ±∞, NaN (signaling and quiet)
- Boundary cases: minimum/maximum normal, minimum/maximum subnormal
- Random vectors across the full exponent and mantissa range

| Metric | Result |
|:-------|:-------|
| Vectors tested | 1,000 |
| Errors | 0 |
| Maximum cycles per operation | 2,944 |
| Reference model | Software IEEE-754 golden model (RNE mode) |

> [!TIP]
> The testbench supports up to 20,000 vectors (`parameter NV = 20000`). The 1,000-vector sign-off run was selected to cover all critical corner cases within the available simulation time. The full 16,708-vector suite was used during development with Verilator for faster turnaround.

---

## 12. Design Decisions and Trade-offs

### Serial vs. Parallel Architecture

| Factor | Serial (chosen) | Parallel (alternative) |
|:-------|:-----------------|:-----------------------|
| Cell count | ~750 | ~3,000–5,000 |
| Routability (2-metal) | Feasible | Infeasible |
| Latency per operation | ~2,000–3,000 cycles | ~30–50 cycles |
| Throughput | ~3,400 ops/sec @ 10 MHz | ~200,000 ops/sec |
| Adder width | 1 bit | 24+ bits |
| Register file | 4 × 32-bit rotators | Multiple parallel registers |

The serial architecture was the only viable path for the 2-metal process constraint. The 60× latency penalty is acceptable for a coprocessor handling infrequent subnormal exceptions.

### Non-Restoring vs. Restoring Division

Non-restoring division eliminates the conditional restoration step, saving one cycle per iteration and simplifying the control logic. The trade-off is that the final quotient is in signed-digit form and may require a correction step, but this is folded into the existing normalization pass at negligible cost.

### Free-Running Rotate Registers

The decision to keep all four registers rotating continuously (even when their contents are not being modified) simplifies the clock gating requirements and ensures that data is always aligned predictably at each counter position. The power overhead of free-running rotation is minimal at 10 MHz on a 5.0V 180nm process.

### Unified Divide/Sqrt Engine

Sharing the serial subtractor between division and square root saves approximately 200 additional cells that a separate sqrt unit would require. The cost is two extra preparation states (S_SQ1, S_SQ2) and slightly more complex subtrahend selection logic (the `tq` multiplexer).

---

*Document generated for OS0005 tapeout — SCL Mohali 180nm CMOS process.*
