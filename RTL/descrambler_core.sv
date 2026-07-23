`default_nettype none
`define SVA

module descrambler_core #(
    parameter int N         = 58,  // LFSR length
    parameter int W         = 8,   // parallel data width
    parameter int TAP_A     = 39,  // first  feedback tap (must be > W)
    parameter int TAP_B     = 58,  // second feedback tap (must be <= N, > TAP_A)
    parameter int BIT_ORDER = 0    // 0 = LSB-first, 1 = MSB-first
) (
    input  wire             clk,        // clock
    input  wire             rst_n,      // async-assert, sync-release, active-low reset
    input  wire             en,         // enable; freezes state when low (back-pressure)
    input  wire             force_rst,  // test only: force state to all-ones, re-arm sync
    input  wire [W-1:0]     din,        // received (scrambled) data; din[0] first in time
    input  wire             din_valid,  // input valid
    input  wire             parity_clr, // single-cycle pulse: clear parity_err 
    output logic            parity_err,  // sticky parity error alarm (W1C)
    output logic [W-1:0]    dout,       // recovered data (registered, gated by locked)
    output logic            dout_valid, // output valid (high only after lock)
    output logic            locked,     // sync indicator: high after N valid bits received
    output logic [N-1:0]    state_o     // current state (debug / DFT observation)
);

  // --------------------------------------------------------------------------
  // Internal signals
  // --------------------------------------------------------------------------
  logic [N-1:0] state;            // LFSR state register (state[0] = newest received bit)
  logic [W-1:0] din_core;         // input after optional bit-order reversal
  logic [W-1:0] descrambler_out;  // recovered output in internal time order
  logic         valid_comb;       // combinational output-valid qualifier
  logic state_parity; // parity bits for state update

  // Number of valid clocks needed to fill the N-bit register = ceil(N / W).
  localparam int LOCK_CYCLES = (N + W - 1) / W;
  logic [$clog2(LOCK_CYCLES+1):0] lock_counter;

  // --------------------------------------------------------------------------
  // Parameter legality checks (elaboration-time)
  // --------------------------------------------------------------------------
  initial begin
    // TAP_A > W guarantees no intra-window recursion and a non-negative index
    if (TAP_A <= W) begin
      $fatal(1, "descrambler_core: TAP_A must be greater than W | TAP_A=%0d, W=%0d", TAP_A, W);
    end
    // TAP_B <= N : the largest index read is state[TAP_B-1], must be <= N-1
    if (TAP_B > N) begin
      $fatal(1, "descrambler_core: TAP_B must be less than or equal to N | TAP_B=%0d, N=%0d", TAP_B, N);
    end
    // TAP_A < TAP_B : A is the smaller tap, B the larger (distinct, ordered)
    if (TAP_A >= TAP_B) begin
      $fatal(1, "descrambler_core: TAP_A must be less than TAP_B | TAP_A=%0d, TAP_B=%0d", TAP_A, TAP_B);
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
  // Recovery logic (combinational, 2-level XOR, pure feed-forward)
  //   descrambler_out[i] = din_core[i] ^ state[TAP_A-1-i] ^ state[TAP_B-1-i]
  // --------------------------------------------------------------------------
  genvar gi;
  generate
    for (gi = 0; gi < W; gi++) begin : gen_dout
      assign descrambler_out[gi] = din_core[gi] ^ state[TAP_A-1-gi] ^ state[TAP_B-1-gi];
    end
  endgenerate

  logic [W-1:0] dout_tmp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dout_tmp       <= '0;
      dout_valid <= 1'b0;
    end
    else if(force_rst)begin
      dout_tmp <= '0;
      dout_valid <= 1'b0;
    end
    else if (locked && valid_comb) begin
      dout_tmp       <= descrambler_out;
      dout_valid <= valid_comb;
    end
    else begin
      dout_tmp       <= '0;
      dout_valid <= 1'b0;
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
  // State register update (pure feed-forward)
  //   Priority: reset > force_rst > shift > hold.
  //   Unlike the scrambler, the W newly RECEIVED input bits (din_core) are
  //   shifted in -- not the output -- so there is no feedback loop.
  //     state[j] <= din_core[W-1-j]   for j in [0, W)
  //     state[k] <= state[k-W]        for k in [W, N)
  // --------------------------------------------------------------------------

  logic[W-1:0] state_next;
  logic state_parity_next;

  assign state_parity_next = ^{state[N-W-1:0] ,state_next};

  genvar j;
  generate
    for (j = 0; j < W; j++) begin
      assign state_next[j] = din_core[W-1-j];
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= {N{1'b1}};
      state_parity <= ^{N{1'b1}}; // all-ones parity for next cycle
    end
    else if (force_rst) begin
      state <= {N{1'b1}};
      state_parity <= ^{N{1'b1}};
    end
    else if (en && din_valid) begin
    /*  for (int j = 0; j < W; j++) begin
        state[j] <= din_core[W-1-j];
      end
      for (int k = W; k < N; k++) begin
        state[k] <= state[k-W];
      end
    */
      state <= {state[N-W-1:0] , state_next};
    //  state_parity <= ^din_core ^ (^state[N-W-1:0]); // update parity for next cycle
      state_parity <= state_parity_next;
    end
  end

  // --------------------------------------------------------------------------
  // Lock tracking
  //   Counts valid clocks; after LOCK_CYCLES = ceil(N/W) valid clocks the
  //   register is filled with genuine received data and the core is
  //   synchronized. 'locked' is sticky until reset / force_rst.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      locked       <= 1'b0;
      lock_counter <= '0;
    end
    else if (force_rst) begin
      locked       <= 1'b0;
      lock_counter <= '0;
    end
    else if (en && din_valid) begin
      if (lock_counter == LOCK_CYCLES - 1) begin
        locked <= 1'b1;
      end
      if (!locked) lock_counter <= lock_counter + 1'b1;
    end
  end

  // --------------------------------------------------------------------------
  // Output stage : registered and gated by 'locked'
  //   Before lock the recovered data is not trustworthy, so it is suppressed
  //   (dout = 0, dout_valid = 0). After lock the recovered word and its valid
  //   are registered out, adding one cycle of latency.
  // --------------------------------------------------------------------------
  assign valid_comb = din_valid && en;



  // --------------------------------------------------------------------------
  // Observation output
  // --------------------------------------------------------------------------
  assign state_o = state;

//SVA

`ifdef SVA

property FORCED_RST_DOUT_VALID_DES;
  @(posedge clk) disable iff(!rst_n)
    (force_rst) |=> !dout_valid;
endproperty

FORCED_RST_DOUT_VALID_DES_A: assert property(FORCED_RST_DOUT_VALID_DES)
  else $error("FORCED_RST_DOUT_VALID_DES: stale word leaked after force_rst | dout_valid=%0b dout=0x%0h", $sampled(dout_valid), $sampled(dout));

property FORCED_RST_WHILE_CAPTURING_DES;
  @(posedge clk) disable iff(!rst_n)
    (force_rst && locked && valid_comb);
endproperty

FORCED_RST_WHILE_CAPTURING_DES_C: cover property (FORCED_RST_WHILE_CAPTURING_DES);

`endif



endmodule

`default_nettype wire
