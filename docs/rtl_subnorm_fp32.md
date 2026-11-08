# RTL Development & Architectural Reference: `subnorm_fp32.sv`

**Silicon Formal ID:** OS0005  
**Target Process:** Semiconductor Laboratory (SCL) Mohali 0.8 µm CMOS (`cp8d`), 2-Metal Routing  
**Standard Cell Utilization:** 754 cells (Synthesis Area Budget: <800 cells)  
**Nominal Core Voltage / Operating Frequency:** 5.0 V / 10 MHz  
**Source RTL:** [`subnorm_fp32.sv`](file:///D:/Desktop/4-2%20project/git_staging/scl_subnorm_fp32_tapeout/rtl/subnorm_fp32.sv)  
**Architectural Specification:** [`80_scl_subnorm_fp32.md`](file:///D:/Desktop/4-2%20project/design_docs/80_scl_subnorm_fp32.md)  

---

## 1. Micro-Architectural Motivation: The SCL 0.8 µm 2-Metal Routing Barrier

The computational core of OS0005 is designed to perform IEEE-754 single-precision (binary32) floating-point division and square root with complete gradual underflow (subnormal support) and Round-to-Nearest, Ties-to-Even (RNE) compliance. In high-integrity robotics, state estimation algorithms (such as the TIDE EKF) and stochastic trajectory optimizers (such as H-MPPI) require division for Kalman innovation covariance inversion $(H P H^T + R)^{-1}$, temperature normalization $\eta^{-1} = 1 / \sum w_k$, and square root for Mahalanobis gating.

Fabrication on the SCL Mohali 0.8 µm CP8D 2-metal standard cell platform imposed non-negotiable physical constraints:

1. **Complete Metal 1 Blockage**: Standard cell internal interconnect completely consumes Metal 1 across the full cell height of 25.35 µm. Metal 1 routing is strictly prohibited over cell rows, leaving only horizontal routing channels between cell rows (50.7 µm pitch).
2. **Single Free Routing Layer**: Metal 2 is the sole layer available for vertical interconnect.
3. **Severe DRC Rules**:
   - Contact Via 1 must be exactly $1.5\ \mu\text{m} \times 1.5\ \mu\text{m}$ (Rule 9.1.1).
   - Metal 1 and Metal 2 enclosure of Via 1 must be $\ge 0.8\ \mu\text{m}$ on all sides (Rules 7.3 and 7.4).
   - Cell seam diffusion spacing across abutting boundaries must exceed $3.4\ \mu\text{m}$ (Rule 6.1.1).
4. **Core Routability Ceiling**: Within the $1390.2\ \mu\text{m} \times 1390.2\ \mu\text{m}$ core area (inside the $2000\ \mu\text{m} \times 2000\ \mu\text{m}$ padframe), routing channel density creates exponential track congestion beyond ~800 standard cells.

A conventional parallel array divider (e.g., 24-stage array or SRT-2 with parallel barrel shifters, leading-zero counters, and wide multiplexers) demands $>3,200$ cells, rendering physical place-and-route mathematically impossible in a 2-metal process. To guarantee 100% routability, the micro-architecture was fundamentally reconceptualized as a **pure bit-serial datapath** centered around four free-running rotating shift registers and a single 1-bit full subtractor. This radical reduction achieved tapeout closure at exactly **754 standard cells**.

---

## 2. Register Organization & Cell Selection Strategy

The datapath is organized around four 32-bit registers ($X$, $D$, $R$, $Q$):
- **$X$ (Operand A / Radicand / Packed Result)**: Receives serial input $A$, supplies dividend/radicand bits, and accumulates the packed IEEE-754 result.
- **$D$ (Operand B / Divisor / Diagnostic Remainder)**: Receives serial input $B$, supplies divisor bits during division iterations, and outputs the final remainder residue.
- **$R$ (Partial Remainder)**: Holds the evolving remainder during radix-2 non-restoring recurrence.
- **$Q$ (Quotient / Root Accumulator)**: Accumulates quotient/square-root bits serially, undergoes normalizations, and executes serial RNE rounding.

```
       +----------------------------------------------------+
       |                                                    |
       v                                                    |
  +--------+    +-------------+-------------+-------------+ |
  | tail   |--->| MSB [31]    |   ...       |  LSB [0]    |-+---> Serial Tap
  | Mux    |    +-------------+-------------+-------------+
  +--------+             Free-Running Shift (>> 1)
```

### Eliminating Load/Shift Control Logic
In standard cell ASICs, multiplexed D-flip-flops with synchronous load enables (`DFFRE` or `DFFEn`) require extra transfer gates or feedback muxes per bit, increasing cell area and routing nets. In `subnorm_fp32.sv`, the four registers rotate right **unconditionally on every clock cycle**:

```systemverilog
always_ff @(posedge clk) begin
    X <= {x_t, X[31:1]};
    D <= {d_t, D[31:1]};
    R <= {r_t, R[31:1]};
    Q <= {q_t, Q[31:1]};
    // ...
end
```

Rather than gating clocks or routing parallel shift-enable networks across 128 register stages, all datapath operations are realized strictly by modulating the 1-bit tail multiplexers (`x_t`, `d_t`, `r_t`, `q_t`) at the register heads.

### Asynchronous Reset vs. Non-Reset Standard Cells
To minimize routing congestion and power consumption:
- The entire 128-bit rotating register bank ($X, D, R, Q$) and all intermediate pipeline flops (`dq1, dq2, rd1, rd2, dx1, dx2, r_dly, d_dly`) omit asynchronous reset lines, mapping directly to minimal-footprint standard cell D-flip-flops (`DFFL11`).
- Only the 5-bit cadence counter `c`, the 4-bit state vector `st`, and handshake registers (`pend`, `done_r`, `pmode`) connect to the active-low asynchronous reset `rst_n` using clearable flops (`DFCL11`).
- This strategic partitioning eliminated more than 140 reset pins and their associated horizontal M1 routing tracks from the standard cell rows.

---

## 3. Mathematical Recurrence & Serial Subtractor Datapath

### Radix-2 Non-Restoring Division Recurrence
Let $M_A$ be the dividend mantissa ($1 \le M_A < 2$) and $M_B$ the divisor mantissa ($1 \le M_B < 2$). With partial remainder $R_0 = M_A$, the step recurrence for quotient bit $q_i \in \{0, 1\}$ over $i = 1 \dots 27$ is:

$$R_i = \begin{cases} 2 R_{i-1} - M_B & \text{if } 2 R_{i-1} \ge M_B \implies q_i = 1 \\ 2 R_{i-1} & \text{if } 2 R_{i-1} < M_B \implies q_i = 0 \end{cases}$$

Rather than implementing a restoring multiplexer or signed radix-2 restoration with negative remainders, the RTL employs a **two-pass 32-cycle execution cycle** per quotient bit:
1. **Compare Pass (`pass_s == 0`)**: Trial subtraction of divisor $M_B$ from current remainder $R_{i-1}$.
2. **Shift/Commit Pass (`pass_s == 1`)**: Conditional selection between difference $(2 R_{i-1} - M_B)$ and restored remainder $2 R_{i-1}$.

### Hardware Subtractor Implementation
The entire arithmetic datapath uses a single 1-bit full subtractor:

```systemverilog
wire m    = R[0];
wire tq   = (c == 5'd0) ? 1'b1 : (c == 5'd1) ? 1'b0 : dq2;
wire s    = sq ? tq : D[0];
wire bin  = (c == 5'd0) ? 1'b0 : bor;
wire diff = m ^ s ^ bin;
wire bout = (~m & s) | (~(m ^ s) & bin);
wire w    = ge ? diff : m;
```

Borrow propagation occurs sequentially across 32 clock cycles:
- At cycle $c = 0$, `bin` is initialized to $0$.
- For cycles $c = 1 \dots 31$, the borrow bit `bor <= bout` ripples sequentially from LSB to MSB.
- At cycle $c = 31$ of `pass_s == 0`, the trial borrow output resolves the condition $R \ge S$:
  ```systemverilog
  if (st == S_ITER && !pass_s && last) ge <= ~bout;
  ```
- During the subsequent shift pass (`pass_s == 1`), `w` selects `diff` if `ge == 1` ($R \ge S$) or retains `m` ($R[0]$) if `ge == 0` ($R < S$).

```
        R[0] (m) -----+---------------+
                      |               |
        Subtrahend ---+-->[ 1-bit ]   |
            (s)       |   [ Sub   ]-->+--> Mux (ge) ---> w ---> rd1 -> r_t (R-tail)
        Borrow In ----+   [       ]   |        |
           (bin)              |       +--------+
                              v
                         bout -> bor
```

### Serial Shift-Left Multiplication ($2 R_{i-1}$)
In an LSB-first serial rotating datapath, shifting a binary vector left by one position corresponds to delaying the serial stream by exactly 1 clock cycle:
```systemverilog
S_ITER: begin
    if (pass_s) begin
        if (sq) r_t = (c < 5'd2) ? X[30] : rd2;
        else    r_t = (c < 5'd1) ? 1'b0  : rd1;
        q_t = (c == 5'd0) ? ge : dq1;
        // ...
    end
end
```
During division, `rd1 <= w`. Inserting $0$ at cycle $c = 0$ (`c < 1 ? 0 : rd1`) and streaming `rd1` for cycles $1 \dots 31$ exactly multiplies the partial remainder by 2 in the rotating frame!

---

## 4. Shared Recurrence for Square Root via Dynamic Subtrahend Synthesis

Square root evaluation $\sqrt{A}$ uses the identical 1-bit subtractor core. For radicand $A \in [1, 4)$, the partial root recurrence satisfies:

$$R_i = 4 R_{i-1} - (4 Q_{i-1} + 1)$$

Where $Q_{i-1}$ is the accumulated root mantissa. This demands two architectural transformations of the datapath:
1. **Remainder Scale Factor $4 \times$**: The remainder must shift left by two bit positions per root bit iteration. The RTL feeds `rd2` (where `rd2 <= rd1 <= w`, a 2-cycle pipeline delay) into `r_t`. The lower two bits ($c < 2$) are fed directly from the radicand register: `r_t = (c < 2) ? X[30] : rd2`.
2. **Dynamic Subtrahend $(4 Q_{i-1} + 1)$**: The subtrahend bits cannot come from register $D$. Instead, they are synthesized on-the-fly from the circulating quotient register $Q$:
   ```systemverilog
   wire tq = (c == 5'd0) ? 1'b1 : (c == 5'd1) ? 1'b0 : dq2;
   ```

Because multiplication by 4 in serial LSB-first binary represents a left-shift of 2 bits:
- Cycle $c = 0$: Subtrahend bit is constant $1$ (representing $+1$).
- Cycle $c = 1$: Subtrahend bit is constant $0$ (representing the $2^1$ position of $4 Q$).
- Cycles $c = 2 \dots 31$: Subtrahend bits are quotient bits delayed by 2 cycles (`dq2 <= dq1 <= Q[0]`).

This dynamic synthesis achieves complete functional sharing between division and square root without adding a second subtractor or a parallel trial root generator, saving approximately 220 standard cells.

---

## 5. Free-Running Temporal Multiplexing & Tap Mechanics

Because the 32-bit registers rotate unconditionally, a bit originally at index $k$ at $c = 0$ shifts to position $(k - c) \pmod{32}$ at cycle $c$. Rather than using wide 8-bit or 32-bit multiplexers, fields are extracted dynamically when they naturally rotate past fixed bit positions.

```
Cycle c = 0:   [Sign: 31] [Exponent: 30:23] [Mantissa: 22:0]
                                                  |
Cycle c = 23:  Rotated 23 times >>                v
               [22:0 Mantissa shifted out] [Sign: 8] [Exponent: 7:0]
                                                          |
                                                          +---> ea_eff, eb_eff tapped at [7:0]
Cycle c = 31:  Rotated 31 times >>
               [Sign arrives at Bit 0] ------------------------> sa_n = X[0], sb_n = D[0]
```

### Exponent Tapping at $c = 23$
During `S_DEC`, at cycle $c = 23$, exactly 23 right shifts have occurred. The 8-bit exponent fields $E[30:23]$ of operands $A$ and $B$ have rotated precisely into `X[7:0]` and `D[7:0]`:
```systemverilog
// Evaluated at c == 23 of S_DEC:
wire a_ez_n = (X[7:0] == 8'd0);
wire a_eF_n = (X[7:0] == 8'hFF);
wire b_ez_n = (D[7:0] == 8'd0);
wire b_eF_n = (D[7:0] == 8'hFF);
wire signed [9:0] ea_eff = a_ez_n ? 10'sd1 : $signed({2'b00, X[7:0]});
wire signed [9:0] eb_eff = b_ez_n ? 10'sd1 : $signed({2'b00, D[7:0]});
```
Notice the IEEE-754 subnormal exponent definition: if the raw exponent field is zero (`a_ez_n`), the effective exponent is biased at $1$ ($E_{eff} = 1$), matching IEEE-754 specifications.

Simultaneously, during cycles $c < 23$, the mantissa bits $M[22:0]$ flow through `X[0]` and `D[0]` into registers $R$ and $D$. At cycle $c = 23$, the hidden integer bit is injected:
```systemverilog
r_t = (c < 5'd23) ? X[0] : (c == 5'd23) ? hid_a : 1'b0;
d_t = (c < 5'd23) ? D[0] : (c == 5'd23) ? hid_b : 1'b0;
```
where `hid_a = ~a_ez_n` (1 for normal numbers, 0 for subnormals).

### Sign Extraction at $c = 31$
At cycle $c = 31$, exactly 31 shifts have occurred. The sign bits $S_A = A[31]$ and $S_B = B[31]$ arrive at `X[0]` and `D[0]`:
```systemverilog
wire sa_n = X[0], sb_n = D[0];
```
This zero-multiplexer tapping architecture eliminates 64 transmission gates from the input crossbar.

---

## 6. The 15-State Finite State Machine Cadence

The FSM comprises 15 states, synchronized to the free-running 5-bit cycle counter $c \in [0, 31]$. All state transitions occur exclusively on the cadence boundary `last = (c == 5'd31)`:

```
  +--------+      +--------+      +--------+      +--------+
  | S_IDLE |--->--| S_LDX  |--->--| S_LDD  |--->--| S_DEC  |
  +--------+      +--------+      +--------+      +----+---+
      |                                                |
      | (mode 3)           (special case)              v (normal)
      v                  +-----------------------------+
  +--------+             |                             |
  | S_RD1  |             v                             v
  +---+----+         +--------+                   +----------+
      |              | S_PACK |                   | S_PREA   | <----+
      v              +---+----+                   +----+-----+      | (subnorm A)
  +--------+             |                             | (!sp_now)  +-----+
  | S_RD2  |             v                             v
  +---+----+          (done)                      +----------+ (div)
      |                                      +--->| S_PREB   | <----+
      +-----------------> S_IDLE             |    +----+-----+      | (subnorm B)
                                      (sqrt) |         | (!sp_now)  +-----+
                                 +-----------+         v
                                 |                +----------+
                             +---+----+           |  S_ITER  | (27 / 26 iters)
                             | S_SQ1  |           +----+-----+
                             +---+----+                | (k == iters-1)
                                 |                     v
                             +---+----+           +----------+
                             | S_SQ2  |           |  S_NORM  |
                             +---+----+           +----+-----+
                                 |                     |
                                 +-------------------->+
                                                       |
                                                       v
                                                  +----------+
                                            +---->|  S_DEN   | <----+
                                  (!sp_now) |     +----+-----+      | (E <= 0)
                                            |          | (!sp_now)  +-----+
                                            |          v
                                            |     +----------+
                                            +-----|  S_RND   |
                                                  +----+-----+
                                                       |
                                                       v
                                                  +----------+
                                                  |  S_PACK  |
                                                  +----------+
```

| State | Purpose | Cycles | Next State Criteria |
|---|---|---|---|
| `S_IDLE` | Latch `ld`, await cadence boundary $c=31$ | $1 \dots 32$ | $\to$ `S_RD1` (`mode==3`) or `S_LDX` |
| `S_LDX` | Shift in 32 bits of operand $A$ via `sdi` | 32 | $\to$ `S_LDD` |
| `S_LDD` | Shift in 32 bits of operand $B$ via `sdi` | 32 | $\to$ `S_DEC` |
| `S_DEC` | Exponent subtraction/addition, hidden bit insert | 32 | $\to$ `S_PACK` (special case) or `S_PREA` |
| `S_PREA` | Iterative normalization of subnormal dividend | $32 \times N_A$ | Left-shift $R$, decrement $E$; exit when $R[23]=1$ |
| `S_PREB` | Iterative normalization of subnormal divisor | $32 \times N_B$ | Left-shift $D$, increment $E$; exit when $D[23]=1$ |
| `S_SQ1` | Radicand alignment, $\lfloor(E_A + 126)/2\rfloor$ exponent calc | 32 | $\to$ `S_SQ2` |
| `S_SQ2` | Remainder initialization for square root | 32 | $\to$ `S_ITER` |
| `S_ITER` | 27 (div) or 26 (sqrt) 2-pass recurrence cycles | $1728 / 1664$ | Sub-pass $0$: compare; Sub-pass $1$: commit |
| `S_NORM` | Post-normalization of quotient MSB | 32 | If $Q[26]=0$: left-shift $Q$, decrement $E$ |
| `S_DEN` | Iterative denormalization for subnormal results | $32 \times N_D$ | Right-shift $Q$, increment $E$; exit when $E > 0$ |
| `S_RND` | Serial Round-to-Nearest Ties-to-Even evaluation | 32 | Evaluate GRS, ripple carry through $Q[3 \dots 31]$ |
| `S_PACK` | Pack sign, exponent, and mantissa into register $X$ | 32 | $\to$ `S_IDLE`, pulse `done = 1` |
| `S_RD1` | Serial output of 32-bit packed result via `sdo` | 32 | $\to$ `S_RD2` |
| `S_RD2` | Serial output of 32-bit diagnostic remainder via `sdo`| 32 | $\to$ `S_IDLE` |

---

## 7. Gradual Underflow Architecture: Iterative Normalization & Denormalization

Many embedded floating-point units implement Flush-to-Zero (FTZ) to avoid the area overhead of parallel leading-zero counters and barrel shifters. In Kalman filter covariance propagation, FTZ induces artificial singular matrices when eigenvalues cross $1.175 \times 10^{-38}$. `subnorm_fp32.sv` avoids this failure mode with hardware-level **full gradual underflow**.

### Input Subnormal Pre-Normalization (`S_PREA` & `S_PREB`)
When an input has $E_{raw} = 0$ and $M \ne 0$, its hidden bit is $0$.
In `S_PREA`, at cycle $c = 0$, the condition `cond_now = ~R[23]` detects whether the leading 1 has reached the hidden bit position:
- If `sp_now` is active, register $R$ is shifted left by 1 bit over the 32-cycle pass:
  ```systemverilog
  if (sp_now) r_t = (c == 5'd0) ? 1'b0 : r_dly;
  ```
- The 10-bit signed exponent adder decrements $E$ by 1:
  ```systemverilog
  S_PREA: if (c == 5'd0 && !R[23]) begin e_we = 1'b1; e_b = -10'sd1; end
  ```
- The FSM remains in `S_PREA` until $R[23] = 1$. The identical mechanism normalizes divisor $B$ in `S_PREB`, incrementing $E$ by 1 per left-shift.

### Output Denormalization Loop (`S_DEN`)
If the quotient exponent satisfies $E \le 0$ (`e_lt1 = E[9] | (E == 10'sd0)`), the result falls into the subnormal representation range.
In `S_DEN`:
1. **Right-Shift Mechanism in Rotating Registers**: Register $Q$ normally rotates right. To achieve an effective right-shift of the mantissa relative to the frame over 32 cycles, the tail multiplexer selects `Q[1]` rather than `Q[0]`:
   ```systemverilog
   S_DEN: if (sp_now) q_t = cp_now ? 1'b0 : ((c == 5'd31) ? 1'b0 : Q[1]);
   ```
2. **Sticky Bit Accumulator (`dst`)**: Any bit shifted out past the LSB must be permanently retained for IEEE-754 rounding:
   ```systemverilog
   if (st == S_DEN && c == 5'd0 && e_lt1) dst <= dst | (e_cap ? 1'b1 : Q[0]);
   ```
3. **Catastrophic Underflow Saturation (`e_cap`)**: If $E < -26$, all 24 significand bits shift off into the sticky bit. The hardware asserts `cp_now = e_cap`, forces `dst <= 1'b1`, clears $Q$ to zero, and terminates denormalization without wasting 26 extra 32-cycle rotations.

---

## 8. Serial Round-to-Nearest, Ties-to-Even (RNE) Architecture

Parallel FPUs use wide incrementers or compound adders to perform rounding. In `subnorm_fp32.sv`, RNE rounding is executed **serially** within state `S_RND`.

### Guard, Round, Sticky (GRS) Mapping
At completion of `S_ITER` and `S_DEN`, the quotient register $Q$ aligns the bits as follows:
- **LSB**: $Q[3]$ — bit 0 of the 24-bit significand.
- **Guard Bit ($G$)**: $Q[2]$ — first bit below the significand ($2^{-1}$ ULP).
- **Round Bit ($R$)**: $Q[1]$ — second bit below the significand ($2^{-2}$ ULP).
- **Sticky Bit ($S$)**: Formed by the logical OR of three distinct residue sources:
  $$S = Q[0] \vee nzr \vee dst$$
  where $nzr$ is the accumulated non-zero remainder residue from all recurrence iterations, and $dst$ is the denormalization shift-out accumulator.

### Serial Carry Injection
At cycle $c = 0$ of `S_RND`, the round-up decision is computed:

$$\text{round\_up} = G \wedge (R \vee S \vee \text{LSB})$$

```systemverilog
if (st == S_RND) begin
    if (c == 5'd0) rc <= Q[2] & (Q[1] | Q[0] | nzr | dst | Q[3]);
    if (c >= 5'd3) cy <= Q[0] & ((c == 5'd3) ? rc : cy);
end
```

During cycles $c = 3 \dots 31$:
- At $c = 3$, $Q[0]$ presents the significand LSB ($Q[3]$ in original frame). The round carry `rc` is added:
  ```systemverilog
  S_RND: if (c >= 5'd3) q_t = Q[0] ^ ((c == 5'd3) ? rc : cy);
  ```
- For cycles $c = 4 \dots 31$, the carry `cy` ripples serially through the rotating register bits.
- If rounding causes a mantissa overflow ($1.111\dots1 + 1 = 10.000\dots0$), bit $Q[27]$ becomes 1. This condition is detected in `S_PACK`:
  ```systemverilog
  S_PACK: if (c == 5'd0 && Q[27]) begin e_we = 1'b1; e_b = 10'sd1; end
  ```
  The exponent is automatically incremented by 1, and the packing logic aligns the fraction field accordingly.

---

## 9. 10-Bit Signed Exponent Datapath

Exponent calculations are handled by a shared 10-bit signed adder:
```systemverilog
wire signed [10:0] esum = $signed({e_a[9], e_a}) + $signed({e_b[9], e_b}) + $signed({10'd0, e_ci});
```

The operands `e_a`, `e_b`, and `e_ci` are time-multiplexed across FSM states:
- **Division Decode (`S_DEC`)**:
  - Cycle $c = 23$: $E = E_A - E_B$ via two's complement: `e_a = ea_eff`, `e_b = ~eb_eff`, `e_ci = 1`.
  - Cycle $c = 24$: Add single-precision bias $+127$: `e_b = 10'sd127`.
- **Square Root Decode (`S_SQ1`)**:
  - Evaluates biased exponent: $\lfloor (E_A + 126) / 2 \rfloor$.
  - Executed in a single cycle using arithmetic right-shift: `e_a = E`, `e_b = 10'sd126`, `e_ci = E[0]`, `e_shr = 1'b1`.
- **Pre/Post Normalizations**: Increments or decrements $E$ by $\pm 1$ as bits shift.

---

## 10. Verification Anomalies, Edge Cases & Silicon Fixes

During rigorous verification with Verilator against 17,708 directed and pseudorandom test vectors (`tb_fp.sv`), several subtle edge cases were encountered and resolved.

### Bug 1: Radicand Alignment for Odd Exponents in Square Root
- **Discrepancy**: The mathematical identity for square root is:
  $$\sqrt{M \cdot 2^E} = \begin{cases} \sqrt{M} \cdot 2^{E/2} & E \text{ even} \\ \sqrt{2M} \cdot 2^{(E-1)/2} & E \text{ odd} \end{cases}$$
  Initially, odd-exponent radicands were shifted incorrectly, resulting in an exact $\sqrt{2} \approx 1.4142$ factor error in the significand.
- **Engineering Fix**: The signal `sqodd_now = (c == 0) ? ~E[0] : sqodd` was introduced. In `S_SQ1`, if the exponent is odd, the radicand is tapped from $R[22]$ rather than $R[23]$:
  ```systemverilog
  S_SQ1: begin x_t = (c < sqdl) ? 1'b0 : (sqodd_now ? R[22] : R[23]); q_t = 1'b0; end
  ```
  where `sqdl = sqodd_now ? 5'd10 : 5'd9`. This guarantees the radicand strictly enters the range $[1, 4)$ before the first iteration.

### Bug 2: Sticky Bit Loss during Catastrophic Subnormal Underflow
- **Discrepancy**: In `S_DEN`, when $E < -26$, all 24 bits of the significand must shift out. In initial simulations, if the final bit shifted out at the loop termination happened to be $0$ while earlier discarded bits were $1$, `dst` failed to latch the earlier $1$, causing RNE to round down rather than up.
- **Engineering Fix**: Added `e_cap = (E < -10'sd26)`. When `e_cap` asserts, `dst` is unconditionally forced to $1$:
  ```systemverilog
  if (st == S_DEN && c == 5'd0 && e_lt1) dst <= dst | (e_cap ? 1'b1 : Q[0]);
  ```

### Bug 3: Borrow Propagation on Exact Remainder Tie ($R == S$)
- **Discrepancy**: When $R_i = S$, subtraction yields zero with no borrow (`bout = 0`). The quotient bit must resolve to $1$. In early testbench runs, a 1-cycle pipeline race condition on `bor` caused `bout` to be evaluated before the borrow had cleared from the previous pass, causing exact power-of-two divisions ($1.0 / 1.0$) to produce $0.1111\dots$ instead of $1.0$.
- **Engineering Fix**: Implemented synchronous cycle reset on borrow input:
  ```systemverilog
  wire bin = (c == 5'd0) ? 1'b0 : bor;
  ```
  This guarantees that every subtraction pass begins with an uncorrupted zero borrow.

---

## 11. Pinout Minimization & Silicon Area Summary

The 10-pad serial interface was explicitly architected to avoid padframe routing blockage on the SCL 0.8 µm chip perimeter:

| Pin Name | Direction | Pad Type | Description |
|---|---|---|---|
| `clk` | Input | Digital Pad | 10 MHz nominal system clock |
| `rst_n` | Input | Digital Pad | Active-low asynchronous reset |
| `ld` | Input | Digital Pad | Command initiate pulse |
| `sdi` | Input | Digital Pad | Serial data input (1 bit/cycle) |
| `mode[1:0]`| Input | Digital Pad (×2) | `0`: FDIV, `1`: FSQRT, `3`: READ_RESULT |
| `sdo` | Output | Digital Pad | Serial data output (1 bit/cycle) |
| `done` | Output | Digital Pad | 1-cycle completion pulse |
| `win` | Output | Digital Pad | Serial transfer active window |
| `busy` | Output | Digital Pad | Core computation active indicator |

### Silicon Implementation Metrics
- **Cell Count**: 754 standard cells
- **Routability**: 100% routed closure with zero DRC violations on 2-metal SCL CP8D
- **Timing Closure**: Nominal clock period 100 ns (10 MHz). Critical path is the 1-bit subtractor and tail mux ($<9.2\ \text{ns}$), yielding $>90\ \text{ns}$ positive slack.
- **Area Budget**: Cell density $< 0.35$ within the $1390.2\ \mu\text{m} \times 1390.2\ \mu\text{m}$ core area, providing complete immunity to Metal 1 routing channel saturation.
