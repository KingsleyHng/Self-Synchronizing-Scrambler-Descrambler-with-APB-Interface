`default_nettype none
// NOTE: do NOT `define SVA here. Pass it on the command line instead
// (VCS: +define+SVA -- already in the EDA Playground run.sh). Defining it
// inside the RTL forces the SVA block on for EVERY consumer, and Yosys does
// not parse `property`, so synthesis dies with
//   "syntax error, unexpected TOK_PROPERTY".

module scrambler_top #(
    parameter int N = 58, // state register length
    parameter int W = 8,  // input/output width
    parameter int TAP_A = 39, // first feedback tap (must be > W)
    parameter int TAP_B = 58, // second feedback tap (must be <= N, > TAP_A)
    parameter int BIT_ORDER = 0 // 0 = LSB-first, 1 = MSB-first
)(
    input wire clk, // clock
    input wire rst_n, // async-assert, sync-release, active-low reset
    input wire csr_wr, // CSR write strobe
    input wire [7:0] csr_addr, // CSR address
    input wire [31:0] csr_wdata, // CSR write data
    output logic [31:0] csr_rdata, // CSR read data

    input wire [W-1:0] din, // source data; din[0] is the first bit in time
    input wire din_valid, // input valid
    input wire ext_en, // external enable; freezes state when low (back-pressure)
    output logic [W-1:0] dout, // scrambled output (to the wire)
    output logic dout_valid
);

typedef enum logic [1:0]{
    MODE_BYPASS,
    MODE_SCRAMBLE,
    MODE_DESCRAMBLE,
    MODE_LOOPBACK
} mode_e;

logic [1:0]  mode;        // CTRL[1:0]
logic        ctrl_en;     // CTRL[2]
logic [N-1:0] seed_reg;   // {SEED_HI, SEED_LO} concatenated into N bits (at N=58, SEED_HI uses only [25:0])
// TEST[16:1]. PERIOD must be at least 1; 0 disables the periodic force_rst
// (see test_active below). TEST[31:17] is RESERVED: writes are ignored and
// reads return 0.
//
// Why 16 bits and not 32: this register only exists so a bench can force a
// known, repeatable reset cadence -- typically to line a scope trigger up with
// the start of a scrambler run. 16 bits @100MHz already spans 10 ns .. 655 us
// per pulse, which is far more than any such capture needs. The 31-bit version
// reached 21 s per pulse, a setting nobody would ever program, and it cost real
// silicon: the counter's carry chain (see test_counter) is the deepest logic in
// this design, so those unusable high bits were directly setting fmax.
logic [15:0] test_period;
logic        test_en;     // TEST[0]


logic en_scrambler, en_descrambler;
logic [N-1:0] scrambler_state, descrambler_state;   
logic descrambler_locked;
logic allzero_err;
logic force_rst, err_clr;
logic seed_load;

logic [W-1:0] scr_dout, des_dout;
logic scr_din_valid, des_din_valid;
logic [W-1:0] des_din;
logic scr_dout_valid, des_dout_valid;



 initial begin
    // TAP_A > W guarantees no intra-window recursion and a non-negative index
    if (TAP_A <= W) begin
      $fatal(1, "scrambler_top: TAP_A must be greater than W | TAP_A=%0d, W=%0d", TAP_A, W);
    end
    // TAP_B <= N : the largest index read is state[TAP_B-1], must be <= N-1
    if (TAP_B > N) begin
      $fatal(1, "scrambler_top: TAP_B must be less than or equal to N | TAP_B=%0d, N=%0d", TAP_B, N);
    end
    // TAP_A < TAP_B : A is the smaller tap, B the larger (distinct, ordered)
    if (TAP_A >= TAP_B) begin
      $fatal(1, "scrambler_top: TAP_A must be less than TAP_B | TAP_A=%0d, TAP_B=%0d", TAP_A, TAP_B);
    end
    // ---- CSR high/low split constraints on N -------------------------------
    // seed and state are N bits but the CSR bus is 32, so both are split across
    // a LO register (bits [31:0]) and a HI register (bits [N-1:32]). The split
    // is only valid for 32 < N <= 64. The two ends fail very differently:
    //
    //   N > 64  : the high word exceeds 32 bits and the surplus is dropped
    //             SILENTLY. Measured at N=70: seed bits [69:64] can never be
    //             read back and no tool says a word about it. This is the case
    //             the check below actually earns its keep on.
    //
    //   N <= 32 : csr_wdata[N-33:0] becomes a reversed/negative part-select
    //             (at N=32 it is [-1:0]). That is a COMPILE-time error, so it
    //             fires before this run-time $fatal ever gets the chance --
    //             verified: at N=32 the tool reports "part select [-1:0] is
    //             reversed" and never reaches elaboration. The check is kept
    //             anyway (harmless, and clearer on any tool that folds it at
    //             elaboration time), but do not rely on it for this end. The
    //             failure is at least loud rather than silent.
    if (N <= 32) begin
      $fatal(1, "scrambler_top: N must be greater than 32 -- the CSR seed/state split needs a non-empty high word | N=%0d", N);
    end
    if (N > 64) begin
      $fatal(1, "scrambler_top: N must be at most 64 -- the high word [N-1:32] must fit in one 32-bit CSR | N=%0d, high word is %0d bits", N, N-32);
    end
  end

logic parity_clr_comb;
logic parity_err_scr, parity_err_des;

logic parity_err;

assign parity_err = parity_err_scr || parity_err_des;

scrambler_core #(.N(N), .W(W), .TAP_A(TAP_A), .TAP_B(TAP_B), .BIT_ORDER(BIT_ORDER)) scrambler (
    .clk(clk), .rst_n(rst_n), .en(en_scrambler),
    .seed(seed_reg), .seed_load(seed_load), .force_rst(force_rst), .err_clr(err_clr), .parity_clr(parity_clr_comb), .parity_err(parity_err_scr),
    .din(din), .din_valid(scr_din_valid),
    .dout(scr_dout), .dout_valid(scr_dout_valid),
    .state_o(scrambler_state), .allzero_err(allzero_err)
);

descrambler_core #(.N(N), .W(W), .TAP_A(TAP_A), .TAP_B(TAP_B), .BIT_ORDER(BIT_ORDER)) descrambler (
    .clk(clk), .rst_n(rst_n), .en(en_descrambler),
    .force_rst(force_rst), .parity_clr(parity_clr_comb), .parity_err(parity_err_des),
    .din(des_din), .din_valid(des_din_valid),
    .dout(des_dout), .dout_valid(des_dout_valid),
    .locked(descrambler_locked), .state_o(descrambler_state)
);

logic en;
assign en = ext_en && ctrl_en;

always_comb begin
    case(mode)
        MODE_BYPASS:
            begin
                en_scrambler = 1'b0;
                en_descrambler = 1'b0;
                scr_din_valid = 1'b0;
                des_din_valid = 1'b0;
                des_din = '0;
                dout = din;
                dout_valid = din_valid && en;
            end

        MODE_SCRAMBLE:
            begin
                en_scrambler = en;
                en_descrambler = 1'b0;
                scr_din_valid = din_valid;
                des_din_valid = 1'b0;
                des_din = '0;
                dout = scr_dout;
                dout_valid = scr_dout_valid;
            end

        MODE_DESCRAMBLE:
            begin
                en_scrambler = 1'b0;
                en_descrambler = en;
                scr_din_valid = 1'b0;
                des_din_valid = din_valid;
                des_din = din;
                dout = des_dout;
                dout_valid = des_dout_valid;
            end
        
        MODE_LOOPBACK:
            begin
                en_scrambler = en;
                en_descrambler = en;
                scr_din_valid = din_valid;
                des_din_valid = scr_dout_valid;
                des_din = scr_dout;
                dout = des_dout;
                dout_valid = des_dout_valid;
            end
        
        default:
            begin
                en_scrambler = 1'b0;
                en_descrambler = 1'b0;
                scr_din_valid = 1'b0;
                des_din_valid = 1'b0;
                des_din = '0;
                dout = '0;
                dout_valid = 1'b0;
            end
    endcase
    
end

logic [1:0] prev_mode;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prev_mode <= MODE_BYPASS;
    end
    else begin
        prev_mode <= mode;
    end
end

//CSR interface
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mode <= MODE_BYPASS;
        ctrl_en <= 1'b0;
        seed_reg <= {N{1'b1}};
        test_period <= '0;
        test_en <= 1'b0; 
    end 
    else begin
        if(csr_wr)begin
            case(csr_addr) 
                8'h00:begin
                    mode <= csr_wdata[1:0];
                    ctrl_en <= csr_wdata[2];
                end
                8'h04:begin
                    seed_reg[31:0] <= csr_wdata;
                end
                8'h08:begin
                    seed_reg[N-1:32] <= csr_wdata[N-33:0];
                end
                8'h10:begin
                    test_period <= csr_wdata[16:1]; // [31:17] reserved, ignored
                    test_en <= csr_wdata[0];
                end
            endcase
        end
    end
end

logic seed_load_comb, err_clr_comb;
assign seed_load_comb = csr_wr && (csr_addr == 8'h0C) && (csr_wdata[0] == 1'b1);
assign err_clr_comb = csr_wr && (csr_addr == 8'h14) && (csr_wdata[1] == 1'b1);
assign parity_clr_comb = csr_wr && (csr_addr == 8'h14) && (csr_wdata[2] == 1'b1);

assign seed_load = seed_load_comb && !(scr_din_valid && en_scrambler);
assign err_clr = err_clr_comb;

logic non_zero_ok;
assign non_zero_ok = (seed_reg != '0);

// Zero-extend the high word [N-1:32] of an N-bit value into a 32-bit CSR.
//
// Replaces three copies of `{6'b0, x[N-1:32]}`. That 6 was hand-computed for
// N=58 (58-32=26 significant bits, 32-26=6 pad bits) and read as if it were
// derived from N, which it was not. It did in fact stay correct for every
// legal N -- the assignment's own width adjustment rescued it, zero-extending
// below N=58 and truncating only surplus pad bits above -- but that is a
// coincidence, not an invariant, and it is not what the code appears to say.
//
// Deliberately NOT written as {{(64-N){1'b0}}, v[N-1:32]}: at N=64 the pad
// would be a zero-width concatenation, which is illegal SystemVerilog. The
// explicit zero-fill plus a part-select assignment is valid across the whole
// 32 < N <= 64 range -- checked by elaborating at N=58 and at the N=64
// boundary, both of which pass.
function automatic logic [31:0] csr_hi_word(input logic [N-1:0] v);
    csr_hi_word = '0;
    csr_hi_word[N-33:0] = v[N-1:32];
endfunction

logic[31:0] csr_reg[0:9];


    always_comb begin
        csr_reg[0] = {29'b0, ctrl_en, mode};
        csr_reg[1] = seed_reg[31:0];
        csr_reg[2] = csr_hi_word(seed_reg);
        csr_reg[3] = {30'b0, non_zero_ok, 1'b0};
        csr_reg[4] = {15'b0, test_period, test_en}; // [31:17] reserved, read 0
        csr_reg[5] = {29'b0, parity_err, allzero_err, descrambler_locked};
        csr_reg[6] = scrambler_state[31:0];
        csr_reg[7] = csr_hi_word(scrambler_state);
        csr_reg[8] = descrambler_state[31:0];
        csr_reg[9] = csr_hi_word(descrambler_state);
    end


always_comb begin
    case(csr_addr)
        8'h00:begin
            csr_rdata = csr_reg[0];
        end
        8'h04:begin
            csr_rdata = csr_reg[1];
        end
        8'h08:begin
            csr_rdata = csr_reg[2];
        end
        8'h0C:begin
            csr_rdata = csr_reg[3];
        end
        8'h10:begin
            csr_rdata = csr_reg[4];
        end
        8'h14:begin
            csr_rdata = csr_reg[5];
        end
        8'h18:begin
            csr_rdata = csr_reg[6];
        end
        8'h1C:begin
            csr_rdata = csr_reg[7];
        end
        8'h20:begin
            csr_rdata = csr_reg[8];
        end
        8'h24:begin
            csr_rdata = csr_reg[9];
        end
        default:begin
            csr_rdata = '0;
        end
    endcase
end

// PERIOD == 0 means "periodic force_rst disabled" (see the TEST[16:1] comment
// above), NOT "pulse every cycle". Without this guard test_counter reloads to
// 0, immediately re-matches PERIOD=0 on the very next cycle, and never leaves
// 0 -- so force_rst would sit HIGH permanently instead of pulsing, holding
// both cores in reset forever. That failure is silent: every CSR still reads
// back exactly as written and no status bit reports it; the only symptom is a
// dout_valid that never arrives. Gate the counter and the pulse on the SAME
// condition so the two can never drift apart.
logic test_active;
assign test_active = test_en && (test_period != '0);

// Width MUST match test_period (TEST[16:1], 16 bits) exactly. Any extra bit is
// dead weight: the counter is only ever compared against test_period, so a
// wider counter just zero-extends test_period and the extra bits can never be 1
// at a match -- they would be flops stuck at 0, sitting in the middle of the
// increment's carry chain. That chain is the deepest logic in the whole design
// (the scramble path itself is only two XOR levels), so it sets fmax, and every
// bit removed from it shortens the critical path.
logic [15:0] test_counter;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        test_counter <= '0;
    end
    else if(test_active && (test_counter == test_period)) begin
        test_counter <= '0;
    end
    else if(test_active) begin
        test_counter <= test_counter + 1'b1;

    end

end


assign force_rst = (test_active && (test_counter == test_period)) || (prev_mode != mode);


//SVA
`ifdef SVA
property BYPASS_MODE_EN;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_BYPASS) |-> (!en_scrambler && !en_descrambler);
endproperty

BYPASS_MODE_EN_A: assert property(BYPASS_MODE_EN);

property BYPASS_MODE_VALID;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_BYPASS) |-> (!scr_din_valid && !des_din_valid && (dout_valid == (din_valid && en)));
endproperty

BYPASS_MODE_VALID_A: assert property(BYPASS_MODE_VALID);

property BYPASS_MODE_DOUT;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_BYPASS) |-> (dout == din);
endproperty

BYPASS_MODE_DOUT_A: assert property(BYPASS_MODE_DOUT);


property SCRAMBLE_MODE_EN;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_SCRAMBLE) |-> (en_scrambler == en) && !en_descrambler;
endproperty

SCRAMBLE_MODE_EN_A: assert property(SCRAMBLE_MODE_EN);

property SCRAMBLE_MODE_VALID;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_SCRAMBLE) |-> (scr_din_valid == din_valid) && (des_din_valid == 1'b0) && (dout_valid == scr_dout_valid);
endproperty

SCRAMBLE_MODE_VALID_A: assert property(SCRAMBLE_MODE_VALID);

property SCRAMBLE_MODE_DATA;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_SCRAMBLE) |->  (dout == scr_dout);
endproperty

SCRAMBLE_MODE_DATA_A: assert property(SCRAMBLE_MODE_DATA);


property DESCRAMBLE_MODE_EN;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_DESCRAMBLE) |-> (!en_scrambler) && (en_descrambler == en);
endproperty

DESCRAMBLE_MODE_EN_A: assert property(DESCRAMBLE_MODE_EN);

property DESCRAMBLE_MODE_VALID;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_DESCRAMBLE) |-> (!scr_din_valid) && (des_din_valid == din_valid) && (dout_valid == des_dout_valid);
endproperty

DESCRAMBLE_MODE_VALID_A: assert property(DESCRAMBLE_MODE_VALID);

property DESCRAMBLE_MODE_DATA;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_DESCRAMBLE) |->  (des_din == din) && (dout == des_dout);
endproperty

DESCRAMBLE_MODE_DATA_A: assert property(DESCRAMBLE_MODE_DATA);



property LOOPBACK_MODE_EN;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_LOOPBACK) |-> (en_scrambler == en) && (en_descrambler == en);
endproperty

LOOPBACK_MODE_EN_A: assert property(LOOPBACK_MODE_EN);

property LOOPBACK_MODE_VALID;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_LOOPBACK) |-> (scr_din_valid == din_valid) && (des_din_valid == scr_dout_valid) && (dout_valid == des_dout_valid);
endproperty

LOOPBACK_MODE_VALID_A: assert property(LOOPBACK_MODE_VALID);

property LOOPBACK_MODE_DATA;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_LOOPBACK) |->  (des_din == scr_dout) && (dout == des_dout);
endproperty

LOOPBACK_MODE_DATA_A: assert property(LOOPBACK_MODE_DATA);


property LOOPBACK_DOUT_EQUAL_DOUT;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_LOOPBACK && dout_valid
         && !force_rst && !$past(force_rst,1) && !$past(force_rst,2))
        |-> (dout == $past(din,2));
endproperty

LOOPBACK_DOUT_EQUAL_DOUT_A: assert property(LOOPBACK_DOUT_EQUAL_DOUT)
  else $error("LOOPBACK_DOUT_EQUAL_DOUT: loopback failed to restore | dout=0x%0h expected(din-2)=0x%0h", $sampled(dout), $past(din,2));


property LOOPBACK_DOUT_SEEN;
    @(posedge clk) disable iff(!rst_n)
        (mode == MODE_LOOPBACK && dout_valid);
endproperty

LOOPBACK_DOUT_SEEN_C: cover property(LOOPBACK_DOUT_SEEN);

// TEST.PERIOD == 0 must DISABLE the periodic force_rst, not latch it high.
// (prev_mode == mode excludes the unrelated mode-change force_rst pulse.)
property TEST_PERIOD_ZERO_DISABLES_TIMER;
    @(posedge clk) disable iff(!rst_n)
        (test_en && (test_period == '0) && (prev_mode == mode)) |-> !force_rst;
endproperty

TEST_PERIOD_ZERO_DISABLES_TIMER_A: assert property(TEST_PERIOD_ZERO_DISABLES_TIMER)
  else $error("TEST_PERIOD_ZERO_DISABLES_TIMER: PERIOD=0 latched force_rst high instead of disabling the timer | force_rst=%0b test_counter=%0d", $sampled(force_rst),
 $sampled(test_counter));

// Guards the assertion above against passing vacuously: the PERIOD=0-armed
// scenario must actually be stimulated for that assert to mean anything.
property TEST_PERIOD_ZERO_ARMED;
    @(posedge clk) disable iff(!rst_n)
        (test_en && (test_period == '0));
endproperty

TEST_PERIOD_ZERO_ARMED_C: cover property(TEST_PERIOD_ZERO_ARMED);

`endif


endmodule

`default_nettype wire