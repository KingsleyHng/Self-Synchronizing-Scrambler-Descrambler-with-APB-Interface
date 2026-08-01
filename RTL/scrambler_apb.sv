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

logic[7:0] csr_addr;
logic csr_wr;
logic[31:0] csr_wdata;
logic[31:0] csr_rdata;


initial begin
  if(APB_ADDR_WIDTH < 8)begin
    $fatal(1, "APB_ADDR_WIDTH should larger than 8");
  end
end

// ---------------------------------------------------------------------------
// Zero-wait-state APB slave: no state needed.
//
// psel/penable already encode the phase completely -- SETUP is (psel &&
// !penable), ACCESS is (psel && penable) -- so a slave that never stalls has
// nothing left to remember. This used to be a 3-state FSM whose state names
// lagged the bus by one cycle (its "SETUP" state was asserted while the bus
// was in ACCESS), and csr_wr was qualified with `cur_state == SETUP` on top of
// penable. That extra term was tautological: APB guarantees penable is only
// ever raised the cycle after (psel && !penable) -- see the
// APB_INPUT_SETUP_TO_ACCESS_M assume below -- and every transition out of
// (psel && !penable) landed in that state. Synthesis could not prove it away,
// because the proof needs the assume and synthesis does not read assumes, so
// the two flops sat in the netlist doing nothing.
//
// Behaviour on a protocol-legal bus is unchanged, csr_wr included, cycle for
// cycle. It differs only if a master violates APB by raising penable without a
// preceding SETUP cycle -- undefined behaviour for a slave either way, but
// worth knowing: this version responds immediately, the FSM stalled a cycle.
// ---------------------------------------------------------------------------
assign pslverr = 1'b0;

assign csr_wr = psel && penable && pwrite;
// Only the low 8 bits are decoded (CSR map is 4-byte aligned, 0x00..0x24).
// Slicing explicitly so a wider paddr cannot silently alias onto a real
// register -- see ADDR_IN_RANGE_A below.
assign csr_addr = paddr[7:0];
// Not gated. scrambler_top samples csr_wdata only under csr_wr, so zeroing it
// between transfers bought nothing and cost 32 AND gates -- and it was gated
// on a condition that did not quite match csr_wr's (it omitted pwrite), which
// is exactly the kind of near-duplicate expression that rots out of sync.
assign csr_wdata = pwdata;
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

`ifdef SVA
//SVA
property PREADY_ALWAYS_1;
  @(posedge clk) disable iff(!rst_n)
  pready == 1;
endproperty
  
PREADY_ASSERTION_A: assert property(PREADY_ALWAYS_1);


property APB_CSR_WR;
  @(posedge clk) disable iff(!rst_n)
    (csr_wr) |=> (!csr_wr);
endproperty

APB_CSR_WR_A: assert property(APB_CSR_WR);

// Replaces the old APB_SETUP_BEFORE_ACCESS / APB_STATE_NO_FORTH_STATE pair,
// which asserted things about cur_state. With the FSM gone there is no state
// to constrain; what actually matters is that the slave commits a write only
// in ACCESS. This is the property the `cur_state == SETUP` term used to
// provide, stated directly against the bus.
property NO_WRITE_IN_SETUP;
  @(posedge clk) disable iff(!rst_n)
    (psel && !penable) |-> !csr_wr;
endproperty

NO_WRITE_IN_SETUP_A: assert property(NO_WRITE_IN_SETUP);


// Likewise: no write may be committed while the slave is not selected at all.
property NO_WRITE_UNSELECTED;
  @(posedge clk) disable iff(!rst_n)
    (!psel) |-> !csr_wr;
endproperty

NO_WRITE_UNSELECTED_A: assert property(NO_WRITE_UNSELECTED);

property APB_INPUT_SETUP_TO_ACCESS;
  @(posedge clk) disable iff(!rst_n)
    (psel && !penable) |=> (psel && penable);
endproperty

APB_INPUT_SETUP_TO_ACCESS_M: assume property(APB_INPUT_SETUP_TO_ACCESS);

property APB_INPUT_PSEL_PENABLE;
  @(posedge clk) disable iff(!rst_n)
    (penable == 1) |-> (psel == 1);
endproperty

APB_INPUT_PSEL_PENABLE_M: assume property(APB_INPUT_PSEL_PENABLE);

property APB_ADDR_DATA_STABLE;
  @(posedge clk) disable iff(!rst_n)
    (psel && !penable) |=> $stable(paddr) && $stable(pwrite) && ($stable(pwdata) || !pwrite);
endproperty

APB_ADDR_DATA_STABLE_M: assume property(APB_ADDR_DATA_STABLE);

property CSR_WR_PAYLOAD_MATCH;
  @(posedge clk) disable iff(!rst_n)
    csr_wr |-> (csr_addr == paddr[7:0]) && (csr_wdata == pwdata);
endproperty
CSR_WR_PAYLOAD_MATCH_A: assert property(CSR_WR_PAYLOAD_MATCH);

property COV_WRITE_XFER;
  @(posedge clk) disable iff(!rst_n)
    (psel && !penable && pwrite) ##1 (psel && penable && pwrite);
endproperty

COV_WRITE_XFER_C: cover property(COV_WRITE_XFER);

property COV_READ_XFER;
  @(posedge clk) disable iff(!rst_n)
    (psel && !penable && !pwrite) ##1 (psel && penable && !pwrite);
endproperty

COV_READ_XFER_C: cover property(COV_READ_XFER);

// Back-to-back transfers: an ACCESS immediately followed by the next SETUP,
// with psel never dropping. Restated against the bus now that cur_state is
// gone. This used to match 0 times -- every test drove psel low between
// transfers -- so it was a vacuous cover; APB_B2B_TEST in
// tb_scrambler_apb_regression.sv now drives the burst that hits it.
property COV_BACK2BACK;
  @(posedge clk) disable iff(!rst_n)
    (psel && penable) ##1 (psel && !penable);
endproperty

COV_BACK2BACK_C: cover property(COV_BACK2BACK);

property PRDATA_KNOWN;
  @(posedge clk) disable iff(!rst_n)
    (psel && penable && !pwrite) |-> !$isunknown(prdata);
endproperty

PRDATA_KNOWN_A: assert property(PRDATA_KNOWN);

// csr_addr takes paddr[7:0] only. With the default APB_ADDR_WIDTH==8 that is
// the whole bus and this generate block produces nothing. If someone widens
// paddr, catch an out-of-range access here rather than let it alias silently
// onto a real register (0x0110 decoding as TEST at 0x10, say).
generate if (APB_ADDR_WIDTH > 8) begin : g_addr_range
  property ADDR_IN_RANGE;
    @(posedge clk) disable iff(!rst_n)
      psel |-> (paddr[APB_ADDR_WIDTH-1:8] == '0);
  endproperty

  ADDR_IN_RANGE_A: assert property(ADDR_IN_RANGE)
    else $error("ADDR_IN_RANGE: paddr=%h is above the decoded 0x00..0xFF window and would alias onto 0x%02h",
                $sampled(paddr), $sampled(paddr[7:0]));
end endgenerate

`endif




endmodule


`default_nettype wire

