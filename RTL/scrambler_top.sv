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
logic [N-1:0] seed_reg;   // {SEED_HI, SEED_LO} 拼出 N bit(N=58 时 SEED_HI 只用 [25:0])
logic [30:0] test_period; // TEST[31:1] // PERIOD should be at least 1, otherwise the test will be disabled
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
                    test_period <= csr_wdata[31:1];
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

logic[31:0] csr_reg[0:9];


    always_comb begin
        csr_reg[0] = {29'b0, ctrl_en, mode};
        csr_reg[1] = seed_reg[31:0];
        csr_reg[2] = {6'b0, seed_reg[N-1:32]};
        csr_reg[3] = {30'b0, non_zero_ok, 1'b0};
        csr_reg[4] = {test_period, test_en};
        csr_reg[5] = {29'b0, parity_err, allzero_err, descrambler_locked};
        csr_reg[6] = scrambler_state[31:0];
        csr_reg[7] = {6'b0, scrambler_state[N-1:32]};
        csr_reg[8] = descrambler_state[31:0];
        csr_reg[9] = {6'b0, descrambler_state[N-1:32]};
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

// PERIOD == 0 means "periodic force_rst disabled" (see the TEST[31:1] comment
// above), NOT "pulse every cycle". Without this guard test_counter reloads to
// 0, immediately re-matches PERIOD=0 on the very next cycle, and never leaves
// 0 -- so force_rst would sit HIGH permanently instead of pulsing, holding
// both cores in reset forever. That failure is silent: every CSR still reads
// back exactly as written and no status bit reports it; the only symptom is a
// dout_valid that never arrives. Gate the counter and the pulse on the SAME
// condition so the two can never drift apart.
logic test_active;
assign test_active = test_en && (test_period != '0);

logic [31:0] test_counter;
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