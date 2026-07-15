`default_nettype none

module scrambler_apb #(
    parameter int N              = 58, // state register length (see scrambler_top)
    parameter int W              = 8,  // input/output width
    parameter int TAP_A          = 39, // first  feedback tap (must be > W)
    parameter int TAP_B          = 58, // second feedback tap (must be <= N, > TAP_A)
    parameter int BIT_ORDER      = 0,  // 0 = LSB-first, 1 = MSB-first
    parameter int APB_ADDR_WIDTH = 8   // width of paddr
) (
    input  wire                      clk,      // = PCLK
    input  wire                      rst_n,    // = PRESETn (active-low, per AMBA APB spec)

    // ---- APB slave interface (AMBA APB, zero-wait-state) -------------------
    input  wire                      psel,
    input  wire                      penable,
    input  wire                      pwrite,
    input  wire [APB_ADDR_WIDTH-1:0] paddr,
    input  wire [31:0]               pwdata,
    output logic                     pready,
    output logic [31:0]              prdata,
    output logic                     pslverr,

    // ---- Data path (unchanged pass-through to scrambler_top) --------------
    input  wire  [W-1:0]             din,       // source data; din[0] first in time
    input  wire                      din_valid, // input valid
    input  wire                      ext_en,    // external enable / back-pressure
    output logic [W-1:0]             dout,      // scrambled/descrambled output
    output logic                     dout_valid
);

typedef enum logic [1:0]{
  IDLE,
  SETUP,
  ACCESS
} state;

state cur_state, next_state;

logic[7:0] csr_addr;
logic csr_wr;
logic[31:0] csr_wdata;
logic[31:0] csr_rdata;


initial begin
  if(APB_ADDR_WIDTH < 8)begin
    $fatal(1, "APB_ADDR_WIDTH should larger than 8");
  end
end

assign pslverr = 0;

assign csr_wr = (cur_state == SETUP) && penable && pwrite;
assign csr_addr = paddr;
assign csr_wdata = (cur_state == SETUP && penable) ? pwdata : 'b0;
assign prdata = csr_rdata;

scrambler_top #(
  .N(N),
  .W(W),
  .TAP_A(TAP_A),
  .TAP_B(TAP_B),
  .BIT_ORDER(BIT_ORDER)
) scrambler_top_inst(
    .clk(clk),      // clock
    .rst_n(rst_n),    // async-assert, sync-release, active-low reset
    .csr_wr(csr_wr),   // CSR write strobe
    .csr_addr(csr_addr), // CSR address
    .csr_wdata(csr_wdata),// CSR write data
    .csr_rdata(csr_rdata),// CSR read data

    .din(din),      // source data; din[0] is the first bit in time
    .din_valid(din_valid),// input valid
    .ext_en(ext_en), // external enable; freezes state when low (back-pressure)
    .dout(dout), // scrambled output (to the wire)
    .dout_valid(dout_valid)
);

assign pready = 1'b1;

always_comb begin
    next_state = cur_state;
  case(cur_state)
    IDLE  : next_state = (psel && !penable)? SETUP : IDLE;
    SETUP : next_state = ACCESS;
    ACCESS: next_state = pready ? ((psel) ? SETUP : IDLE) : ACCESS;
  endcase
end

always_ff@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
    cur_state <= IDLE;
  end
  else begin
    cur_state <= next_state;
  end
end



endmodule

`default_nettype wire
