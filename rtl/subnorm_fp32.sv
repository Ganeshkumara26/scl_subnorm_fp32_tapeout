// SubNorm FP32 - serial IEEE-754 binary32 divide / sqrt (RNE, full gradual underflow), shared serial recurrence.
// 4 x 32-bit registers rotate right every cycle (free-running). All arithmetic is LSB-first through one 1-bit subtractor.
// Protocol: pulse ld with mode (0 FDIV, 1 FSQRT); when win=1 shift in A then B (32 bits each, LSB first, bit0 in first cycle after win rises);
// wait done; pulse ld with mode 3 and read X (result) then D over a 64-cycle window (LSB first).
module subnorm_fp32 (
    input  logic clk, rst_n,
    input  logic ld, sdi,
    input  logic [1:0] mode,
    output logic sdo, done, win, busy
);
    typedef enum logic [3:0] {S_IDLE, S_LDX, S_LDD, S_DEC, S_PREA, S_PREB, S_SQ1, S_SQ2, S_ITER, S_NORM, S_DEN, S_RND, S_PACK, S_RD1, S_RD2} st_t;
    st_t st;
    logic [31:0] X, D, R, Q;
    logic [4:0]  c;
    logic signed [9:0] E;
    logic sq, pend, done_r, sp, cp, pass_s, bor, ge, nzacc, nzr, dst, rc, cy, hq, q27, ovfq, sqodd;
    logic dq1, dq2, rd1, rd2, dx1, dx2, r_dly, d_dly, fa, fb;
    logic a_ez, a_eF, a_fz, b_ez, b_eF, b_fz, sa, sb, sgn;
    logic [1:0] kind, pmode;
    logic [5:0] k, iters;

    assign sdo  = (st == S_RD2) ? D[0] : X[0];
    assign done = done_r;
    assign busy = (st != S_IDLE) | pend;
    wire inwin  = (st == S_LDX) | (st == S_LDD) | (st == S_RD1) | (st == S_RD2);
    assign win  = inwin | ((st == S_IDLE) & (c == 5'd31) & (pend | ld));

    // ---- decode taps (valid at c==23 in S_DEC: exponent fields are at positions [7:0]) ----
    wire a_ez_n = (X[7:0] == 8'd0), a_eF_n = (X[7:0] == 8'hFF);
    wire b_ez_n = (D[7:0] == 8'd0), b_eF_n = (D[7:0] == 8'hFF);
    wire signed [9:0] ea_eff = a_ez_n ? 10'sd1 : $signed({2'b00, X[7:0]});
    wire signed [9:0] eb_eff = b_ez_n ? 10'sd1 : $signed({2'b00, D[7:0]});
    wire a_fz_n = ~fa, b_fz_n = ~fb;

    // ---- special-case decision (evaluated at c==31 of S_DEC) ----
    wire a_nan = a_eF & ~a_fz, b_nan = b_eF & ~b_fz, a_inf = a_eF & a_fz, b_inf = b_eF & b_fz;
    wire a_zero = a_ez & a_fz, b_zero = b_ez & b_fz;
    wire sa_n = X[0], sb_n = D[0];                         // sign bits are at the head at c==31
    logic spec; logic [1:0] spec_kind; logic spec_sgn;
    always_comb begin
        spec = 1'b0; spec_kind = 2'd1; spec_sgn = 1'b0;
        if (sq) begin
            if (a_nan | (sa_n & ~a_zero)) spec = 1'b1;
            else if (a_zero) begin spec = 1'b1; spec_kind = 2'd3; spec_sgn = sa_n; end
            else if (a_inf)  begin spec = 1'b1; spec_kind = 2'd2; end
        end else begin
            if (a_nan | b_nan | (a_inf & b_inf) | (a_zero & b_zero)) spec = 1'b1;
            else if (a_inf | b_zero) begin spec = 1'b1; spec_kind = 2'd2; spec_sgn = sa_n ^ sb_n; end
            else if (a_zero | b_inf) begin spec = 1'b1; spec_kind = 2'd3; spec_sgn = sa_n ^ sb_n; end
        end
    end

    // ---- serial recurrence (same as verified engine) ----
    wire m   = R[0];
    wire tq  = (c == 5'd0) ? 1'b1 : (c == 5'd1) ? 1'b0 : dq2;
    wire s   = sq ? tq : D[0];
    wire bin = (c == 5'd0) ? 1'b0 : bor;
    wire diff= m ^ s ^ bin;
    wire bout= (~m & s) | (~(m ^ s) & bin);
    wire w   = ge ? diff : m;

    // ---- per-state "condition at pass start" (c==0) ----
    logic cond_now; logic cap_now;
    wire e_lt1 = E[9] | (E == 10'sd0);
    wire e_cap = (E < -10'sd26);
    always_comb begin
        case (st)
            S_PREA: cond_now = ~R[23];
            S_PREB: cond_now = ~D[23];
            S_NORM: cond_now = ~Q[26];
            S_DEN:  cond_now = e_lt1;
            default: cond_now = 1'b0;
        endcase
    end
    wire sp_now = (c == 5'd0) ? cond_now : sp;
    wire cp_now = (c == 5'd0) ? e_cap    : cp;
    wire sqodd_now = (c == 5'd0) ? ~E[0] : sqodd;
    wire hq_now  = (c == 5'd0) ? (Q[26] | Q[27]) : hq;
    wire ovf_now = (c == 5'd0) ? ((E >= 10'sd255) | (Q[27] & (E == 10'sd254))) : ovfq;
    wire hid_a = ~a_ez_n, hid_b = ~b_ez_n;

    // ---- tails ----
    logic x_t, d_t, r_t, q_t;
    wire [4:0] sqdl = sqodd_now ? 5'd10 : 5'd9;
    wire isinf = (kind == 2'd2) | ((kind == 2'd0) & hq_now & ovf_now);
    logic pack_bit;
    wire frac_ok = (kind == 2'd0) & ~(hq_now & ovf_now);
    always_comb begin
        if (c < 5'd22)       pack_bit = frac_ok ? Q[3] : 1'b0;
        else if (c == 5'd22) pack_bit = (kind == 2'd1) ? 1'b1 : (frac_ok ? Q[3] : 1'b0);
        else if (c < 5'd31)  pack_bit = ((kind == 2'd1) | isinf) ? 1'b1 : (kind == 2'd3) ? 1'b0 : (hq_now ? E[c - 5'd23] : 1'b0);
        else                 pack_bit = (kind == 2'd1) ? 1'b0 : sgn;
    end

    always_comb begin
        x_t = X[0]; d_t = D[0]; r_t = R[0]; q_t = Q[0];
        case (st)
            S_LDX: x_t = sdi;
            S_LDD: d_t = sdi;
            S_DEC: begin
                r_t = (c < 5'd23) ? X[0] : (c == 5'd23) ? hid_a : 1'b0;
                d_t = (c < 5'd23) ? D[0] : (c == 5'd23) ? hid_b : 1'b0;
                q_t = 1'b0;
            end
            S_PREA: begin if (sp_now) r_t = (c == 5'd0) ? 1'b0 : r_dly; q_t = 1'b0; end
            S_PREB: begin if (sp_now) d_t = (c == 5'd0) ? 1'b0 : d_dly; q_t = 1'b0; end
            S_SQ1:  begin x_t = (c < sqdl) ? 1'b0 : (sqodd_now ? R[22] : R[23]); q_t = 1'b0; end
            S_SQ2:  begin r_t = (c == 5'd0) ? (sqodd ? R[22] : 1'b1) : (c == 5'd1) ? sqodd : 1'b0; q_t = 1'b0; end
            S_ITER: begin
                if (pass_s) begin
                    if (sq) r_t = (c < 5'd2) ? X[30] : rd2; else r_t = (c < 5'd1) ? 1'b0 : rd1;
                    q_t = (c == 5'd0) ? ge : dq1;
                    if (sq) x_t = (c < 5'd2) ? 1'b0 : dx2;
                end
            end
            S_NORM: if (sp_now) q_t = (c == 5'd0) ? 1'b0 : dq1;
            S_DEN:  if (sp_now) q_t = cp_now ? 1'b0 : ((c == 5'd31) ? 1'b0 : Q[1]);
            S_RND:  if (c >= 5'd3) q_t = Q[0] ^ ((c == 5'd3) ? rc : cy);
            S_PACK: x_t = pack_bit;
            default: ;
        endcase
    end

    // ---- exponent adder ----
    logic e_we, e_ci, e_shr; logic signed [9:0] e_a, e_b;
    always_comb begin
        e_we = 1'b0; e_a = E; e_b = 10'sd0; e_ci = 1'b0; e_shr = 1'b0;
        case (st)
            S_DEC: begin
                if (c == 5'd23) begin e_we = 1'b1; e_a = ea_eff; e_b = sq ? 10'sd0 : ~eb_eff; e_ci = ~sq; end
                else if (c == 5'd24 && !sq) begin e_we = 1'b1; e_b = 10'sd127; end
            end
            S_PREA: if (c == 5'd0 && !R[23]) begin e_we = 1'b1; e_b = -10'sd1; end
            S_PREB: if (c == 5'd0 && !D[23]) begin e_we = 1'b1; e_b = 10'sd1; end
            S_SQ1:  if (c == 5'd0) begin e_we = 1'b1; e_b = 10'sd126; e_ci = E[0]; e_shr = 1'b1; end
            S_NORM: if (c == 5'd0 && !Q[26] && !sq) begin e_we = 1'b1; e_b = -10'sd1; end
            S_DEN:  if (c == 5'd0 && e_lt1) begin e_we = 1'b1; if (e_cap) e_a = 10'sd0; e_b = 10'sd1; end
            S_PACK: if (c == 5'd0 && Q[27]) begin e_we = 1'b1; e_b = 10'sd1; end
            default: ;
        endcase
    end
    wire signed [10:0] esum = $signed({e_a[9], e_a}) + $signed({e_b[9], e_b}) + $signed({10'd0, e_ci});

    // ---- control (async reset) ----
    wire last = (c == 5'd31);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin c <= 5'd0; st <= S_IDLE; pend <= 1'b0; done_r <= 1'b0; pmode <= 2'd0; end
        else begin
            c <= c + 5'd1;
            if (st == S_IDLE) begin
                if (ld) begin pend <= 1'b1; pmode <= mode; end
                if (last && (pend | ld)) begin
                    pend <= 1'b0;
                    if ((ld ? mode : pmode) == 2'd3) st <= S_RD1;
                    else begin st <= S_LDX; done_r <= 1'b0; end
                end
            end else if (last) begin
                case (st)
                    S_LDX:  st <= S_LDD;
                    S_LDD:  st <= S_DEC;
                    S_DEC:  st <= spec ? S_PACK : S_PREA;
                    S_PREA: if (!sp_now) st <= sq ? S_SQ1 : S_PREB;
                    S_PREB: if (!sp_now) st <= S_ITER;
                    S_SQ1:  st <= S_SQ2;
                    S_SQ2:  st <= S_ITER;
                    S_ITER: if (pass_s && k == iters - 6'd1) st <= S_NORM;
                    S_NORM: st <= S_DEN;
                    S_DEN:  if (!sp_now) st <= S_RND;
                    S_RND:  st <= S_PACK;
                    S_PACK: begin st <= S_IDLE; done_r <= 1'b1; end
                    S_RD1:  st <= S_RD2;
                    S_RD2:  st <= S_IDLE;
                    default: st <= S_IDLE;
                endcase
            end
        end
    end

    // ---- datapath (no reset) ----
    always_ff @(posedge clk) begin
        X <= {x_t, X[31:1]}; D <= {d_t, D[31:1]}; R <= {r_t, R[31:1]}; Q <= {q_t, Q[31:1]};
        dq1 <= Q[0]; dq2 <= dq1; rd1 <= w; rd2 <= rd1; dx1 <= X[0]; dx2 <= dx1; r_dly <= R[0]; d_dly <= D[0];
        bor <= bout;
        if (st == S_ITER && !pass_s && last) ge <= ~bout;
        if (c == 5'd0) nzacc <= w; else nzacc <= nzacc | w;
        if (e_we) E <= e_shr ? esum[10:1] : esum[9:0];
        sp <= sp_now; cp <= cp_now; hq <= hq_now; ovfq <= ovf_now;
        if (st == S_SQ1) sqodd <= sqodd_now;
        if (st == S_IDLE && last) sq <= (ld ? mode : pmode) == 2'd1;
        // decode flags
        if (st == S_DEC) begin
            if (c == 5'd0) begin fa <= X[0]; fb <= D[0]; end
            else if (c < 5'd23) begin fa <= fa | X[0]; fb <= fb | D[0]; end
            if (c == 5'd23) begin a_ez <= a_ez_n; a_eF <= a_eF_n; a_fz <= a_fz_n; b_ez <= b_ez_n; b_eF <= b_eF_n; b_fz <= b_fz_n; end
            if (last) begin sa <= sa_n; sb <= sb_n; kind <= spec ? spec_kind : 2'd0;
                sgn <= spec ? spec_sgn : (sq ? 1'b0 : (sa_n ^ sb_n)); dst <= 1'b0; end
        end
        // ITER sequencing
        if (st == S_PREA || st == S_PREB || st == S_SQ2 || st == S_DEC) begin pass_s <= 1'b0; k <= 6'd0; iters <= sq ? 6'd26 : 6'd27; end
        else if (st == S_ITER && last) begin if (pass_s) begin pass_s <= 1'b0; k <= k + 6'd1; end else pass_s <= 1'b1; end
        // NORM / DEN / RND captures
        if (st == S_NORM && c == 5'd0) nzr <= nzacc;
        if (st == S_DEN && c == 5'd0 && e_lt1) dst <= dst | (e_cap ? 1'b1 : Q[0]);
        if (st == S_RND) begin
            if (c == 5'd0) rc <= Q[2] & (Q[1] | Q[0] | nzr | dst | Q[3]);
            if (c >= 5'd3) cy <= Q[0] & ((c == 5'd3) ? rc : cy);
        end
    end
endmodule
