`default_nettype none



module scrambler_core #(
    parameter int N         = 58,  // LFSR length
    parameter int W         = 8,   // parallel data width
    parameter int TAP_A     = 39,  // first  feedback tap (must be > W)
    parameter int TAP_B     = 58,  // second feedback tap (must be <= N, > TAP_A)
    parameter int BIT_ORDER = 0    // 0 = LSB-first, 1 = MSB-first
) (
    input  wire             clk,         // clock
    input  wire             rst_n,       // async-assert, sync-release, active-low reset
    input  wire             en,          // enable; freezes state when low (back-pressure)
    input  wire [N-1:0]     seed,        // seed value to load (must be non-zero)
    input  wire             seed_load,   // single-cycle pulse: load seed into state
    input  wire             force_rst,   // test only: force state to all-ones (repeatable wave)
    input  wire [W-1:0]     din,         // source data; din[0] is the first bit in time
    input  wire             din_valid,   // input valid
    input  wire             err_clr,     // single-cycle pulse: clear allzero_err (W1C path)
    input  wire             parity_clr,   // single-cycle pulse: clear parity_err (W1C path)
    output logic [W-1:0]    dout,        // scrambled output (to the wire)
    output logic            dout_valid,  // output valid
    output logic [N-1:0]    state_o,     // current state (debug / DFT observation)
    output logic            parity_err,  // sticky parity error alarm (W1C)
    output logic            allzero_err  // sticky all-zero state alarm (LFSR lock-up)
);

  // --------------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------------
  logic [N-1:0] state;              // LFSR state register (state[0] = newest output)
  logic [W-1:0] din_core;           // input after optional bit-order reversal
  logic [W-1:0] scrambler_out;      // scrambled output in internal time order
  logic         internal_seed_load; // qualified seed load (blocked when seed == 0)
    logic state_parity; // parity bits for state update

  // --------------------------------------------------------------------------
  // Parameter legality checks (elaboration-time)
  //   These constraints are implied by the index expressions below; an illegal
  //   instantiation must fail loudly here rather than silently build bad logic.
  // --------------------------------------------------------------------------
  initial begin
    // TAP_A > W guarantees no intra-window recursion and a non-negative index
    if (TAP_A <= W) begin
      $fatal(1, "scrambler_core: TAP_A must be greater than W | TAP_A=%0d, W=%0d", TAP_A, W);
    end
    // TAP_B <= N : the largest index read is state[TAP_B-1], must be <= N-1
    if (TAP_B > N) begin
      $fatal(1, "scrambler_core: TAP_B must be less than or equal to N | TAP_B=%0d, N=%0d", TAP_B, N);
    end
    // TAP_A < TAP_B : A is the smaller tap, B the larger (distinct, ordered)
    if (TAP_A >= TAP_B) begin
      $fatal(1, "scrambler_core: TAP_A must be less than TAP_B | TAP_A=%0d, TAP_B=%0d", TAP_A, TAP_B);
    end
  end

  // --------------------------------------------------------------------------
  // Input boundary: optional bit-order reversal
  //   BIT_ORDER == 0 : pass through (external LSB-first matches internal order)
  //   BIT_ORDER == 1 : mirror, so the externally-first bit (din[W-1]) maps to
  //                    the internally-first position din_core[0]
  // --------------------------------------------------------------------------
  always_comb begin
    if (BIT_ORDER == 0) begin
      din_core = din;
    end
    else begin
      for (int i = 0; i < W; i++) begin
        din_core[i] = din[W-1-i];
      end
    end
  end

  // --------------------------------------------------------------------------
  // Output logic (combinational, 2-level XOR)
  //   scrambler_out[i] = din_core[i] ^ state[TAP_A-1-i] ^ state[TAP_B-1-i]
  //   For defaults (TAP_A=39, TAP_B=58):
  //     scrambler_out[0] taps state[38] and state[57]
  //     scrambler_out[7] taps state[31] and state[50]
  // --------------------------------------------------------------------------
  genvar gi;
  generate
    for (gi = 0; gi < W; gi++) begin : gen_dout
      assign scrambler_out[gi] = din_core[gi] ^ state[TAP_A-1-gi] ^ state[TAP_B-1-gi];
    end
  endgenerate

  logic [W-1:0] dout_tmp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dout_tmp <= '0;
      dout_valid <= 1'b0;
    end

    else if(force_rst)begin
      dout_tmp <= '0;
      dout_valid <= 1'b0;
    end

    else if (en && din_valid) begin
      dout_tmp <= scrambler_out;
      dout_valid <= 1'b1;
    end
    else begin
      dout_tmp      <= '0;
      dout_valid <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // Output boundary: optional bit-order reversal (mirror of the input side;
  // the reversal rule MUST match the input side exactly)
  // --------------------------------------------------------------------------

  always_comb begin
    if (BIT_ORDER == 0) begin
      dout = dout_tmp;
    end
    else begin
      for (int i = 0; i < W; i++) begin
        dout[i] = dout_tmp[W-1-i];
      end
    end
  end

  

  // --------------------------------------------------------------------------
  // Seed-load qualification: a zero seed is rejected so the LFSR can never be
  // driven into the all-zero lock-up state by a seed load.
  // --------------------------------------------------------------------------
  always_comb begin
    if (seed == '0) begin
      internal_seed_load = 1'b0;
    end
    else begin
      internal_seed_load = seed_load;
    end
  end

  // --------------------------------------------------------------------------
  // allzero_err : sticky all-zero alarm with W1C-style clear.
  //   Priority: reset > detect (state==0) > clear (err_clr) > hold.
  //   Detection is intentionally above clear: while the fault persists the
  //   alarm cannot be cleared; only once state is non-zero does err_clr take
  //   effect. The software-visible W1C register lives in scrambler_top's CSR.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      allzero_err <= 1'b0;
    end
    else if (state == '0) begin
      allzero_err <= 1'b1;
    end
    else if (err_clr) begin
      allzero_err <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // Parity error detection and clearing
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      parity_err <= 1'b0;
    end
    else if (^state != state_parity) begin
      parity_err <= 1'b1;
    end
    else if (parity_clr) begin
      parity_err <= 1'b0;
    end
  end

  // --------------------------------------------------------------------------
  // State register update
  //   Priority: reset > force_rst > seed_load > shift > hold.
  //   Shift-in mapping (independent of BIT_ORDER): the W new outputs are
  //   written into the low W flops in reverse, and the old state shifts up by
  //   W. state[0] always holds the newest output.
  //     state[j] <= scrambler_out[W-1-j]   for j in [0, W)
  //     state[k] <= state[k-W]             for k in [W, N)
  // --------------------------------------------------------------------------

  logic[W-1:0] state_next_lower_nibble;
  genvar j;
  generate
    for(j = 0; j < W; j++)begin
      assign state_next_lower_nibble[j] = scrambler_out[W-1-j];
    end
  endgenerate

  logic[N-W-1:0] state_next_upper_nibble;
  assign state_next_upper_nibble = state[N-W-1:0];
  

  logic state_parity_next;
  assign state_parity_next = ^{state_next_upper_nibble , state_next_lower_nibble };


  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= {N{1'b1}};
      state_parity <= ^{N{1'b1}}; // all-ones parity for next cycle
    end
    else if (force_rst) begin
      state <= {N{1'b1}};
      state_parity <= ^{N{1'b1}};
    end
    else if (internal_seed_load) begin
      state <= seed;
      state_parity <= ^seed; // compute parity of seed for next cycle
    end
    else if (en && din_valid) begin
    /*  for (int j = 0; j < W; j++) begin
        state[j] <= scrambler_out[W-1-j];
      end
      for (int k = W; k < N; k++) begin
        state[k] <= state[k-W];
      end
    */
      state <= {state_next_upper_nibble , state_next_lower_nibble };

    //  state_parity <= ^scrambler_out ^ (^state[N-W-1:0]); // update parity for next cycle
      state_parity <= state_parity_next;
    end
  end

  // --------------------------------------------------------------------------
  // Observation / status outputs
  // --------------------------------------------------------------------------
  assign state_o    = state;


//SVA
`ifdef SVA
property FORCED_RST_DOUT_VALID_SCR;
  @(posedge clk) disable iff(!rst_n)
    (force_rst) |=> !dout_valid;
endproperty

FORCED_RST_DOUT_VALID_SCR_A: assert property (FORCED_RST_DOUT_VALID_SCR)
  else $error("FORCED_RST_DOUT_VALID_SCR: stale word leaked after force_rst | dout_valid=%0b dout=0x%0h", $sampled(dout_valid), $sampled(dout));


property FORCED_RST_WHILE_CAPTURING_SCR;
  @(posedge clk) disable iff(!rst_n)
    force_rst && en && din_valid;
endproperty

FORCED_RST_WHILE_CAPTURING_SCR_C: cover property (FORCED_RST_WHILE_CAPTURING_SCR);

`endif



endmodule

`default_nettype wire
