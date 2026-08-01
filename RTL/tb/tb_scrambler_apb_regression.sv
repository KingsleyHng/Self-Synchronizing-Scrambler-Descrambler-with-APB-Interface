`timescale 1ns/1ps

`include "descrambler_core.sv"
`include "scrambler_core.sv"
`include "scrambler_top.sv"


// =============================================================================
//  tb_scrambler_apb_regression : full-mode regression driven ENTIRELY over the
//    real AMBA APB SETUP/ACCESS handshake.
//
//    tb_scrambler_top.sv's REGRESSION already exhaustively proves the seven
//    modes/mechanisms (BYPASS, SCRAMBLER, DESCRAMBLER, LOOPBACK,
//    NON_ZERO_SEED_READ, FORCE_RST_PERIOD_TEST, PARITY_ERR_TEST) are correct
//    against golden models, but it configures the DUT by poking
//    scrambler_top's native csr_wr/csr_addr/csr_wdata ports directly --
//    it never proves the APB bus itself can drive every one of those modes.
//
//    tb_scrambler_apb.sv, in turn, proves the APB SETUP/ACCESS protocol
//    translation is correct (write lands in the right register, read returns
//    the right data, no side effects) but only as a handful of targeted
//    protocol checks -- it doesn't run the full mode regression.
//
//    This file is the integration of the two: same DUT hierarchy as
//    tb_scrambler_apb.sv (scrambler_apb wrapping scrambler_top), same test
//    logic/golden models as tb_scrambler_top.sv, but EVERY CSR write --
//    mode select, seed load, TEST period, W1C clears, everything -- goes
//    through a genuine APB SETUP->ACCESS transaction. The only thing that
//    changed relative to tb_scrambler_top.sv is:
//      (a) write_csr()'s internals (APB handshake instead of raw port poke)
//      (b) hierarchical debug references now go through dut.scrambler_top_inst
//    Every task, golden model, and pass/fail check is otherwise identical,
//    so a failure here means "the APB bridge broke something that direct
//    CSR access did not" -- exactly the coverage gap this file exists to close.
// =============================================================================
module tb_scrambler_apb_regression();

    parameter int N = 58; // state register length
    parameter int W = 8;  // input/output width
    parameter int TAP_A = 39; // first feedback tap (must be > W)
    parameter int TAP_B = 58; // second feedback tap (must be <= N, > TAP_A)
    parameter int BIT_ORDER = 0; // 0 = LSB-first, 1 = MSB-first
    parameter int AW = 8; // APB address width
    // MODE selects which task the initial block dispatches to. Valid values:
    // BYPASS | SCRAMBLER | DESCRAMBLER | LOOPBACK | NON_ZERO_SEED_READ |
    // FORCE_RST_PERIOD_TEST | FORCE_RST_PERIOD_TEST_DES |
    // FORCE_RST_PERIOD_ZERO_TEST | TEST_RSVD_TEST | APB_B2B_TEST |
    // BIT_ORDER_TEST | BACKPRESSURE_TEST | ALLZERO_ERR_TEST |
    // PARITY_ERR_TEST | REGRESSION (runs all of the above)
    parameter MODE = "REGRESSION";

    // Number of valid words to fill the N-bit register = ceil(N / W).
    // Mirrors descrambler_core's LOCK_CYCLES; used to align expected data.
    localparam int LOCK_CYCLES = (N + W - 1) / W;

    logic clk; // clock
    logic rst_n; // async-assert, sync-release, active-low reset

    // ---- APB master-side signals (this testbench IS the APB master) --------
    logic              psel;
    logic              penable;
    logic              pwrite;
    logic [AW-1:0]     paddr;
    logic [31:0]       pwdata;
    logic              pready;
    logic [31:0]       prdata;
    logic              pslverr;

    logic [W-1:0] din; // source data; din[0] is the first bit in time
    logic din_valid; // input valid
    logic ext_en; // external enable; freezes state when low (back-pressure)
    logic [W-1:0] dout; // scrambled output (to the wire)
    logic dout_valid;

    scrambler_apb #(
        .N(N),
        .W(W),
        .TAP_A(TAP_A),
        .TAP_B(TAP_B),
        .BIT_ORDER(BIT_ORDER),
        .APB_ADDR_WIDTH(AW)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .pready(pready),
        .prdata(prdata),
        .pslverr(pslverr),
        .din(din),
        .din_valid(din_valid),
        .ext_en(ext_en),
        .dout(dout),
        .dout_valid(dout_valid)
    );

    // =========================================================================
    // BIT_ORDER=1 differential companion
    //
    //   BIT_ORDER cannot be exercised by the regression above: it is an
    //   elaboration-time parameter, and -- worse -- it is applied as a MIRRORED
    //   pair (reverse on the way in, reverse again on the way out) in BOTH
    //   cores. Any loopback or scramble-then-descramble test therefore passes
    //   even if the reversal is completely wrong, because the two mistakes
    //   cancel. Only the scrambler's dout, observed on its own, can catch it.
    //
    //   Rather than re-implement the reversal in a golden model (which would
    //   only prove the testbench agrees with itself), this exploits an exact
    //   algebraic identity. Writing rev() for the W-bit mirror and f() for the
    //   internal scramble step:
    //
    //     BIT_ORDER=0 :  dout0      = f(din)
    //     BIT_ORDER=1 :  din_core   = rev(din) ; dout1 = rev(f(din_core))
    //
    //   So if this instance is fed rev(din) while the main DUT is fed din, its
    //   din_core becomes rev(rev(din)) == din -- identical to the main DUT's.
    //   Both cores then see the very same internal bit stream, their LFSR
    //   states evolve in lockstep, and the outputs must satisfy
    //
    //     dout_bo1 == rev(dout)          <-- checked in BIT_ORDER_TEST()
    //
    //   for every single word. This depends on nothing but the mirror
    //   symmetry, so it stays valid no matter what the scramble polynomial is.
    //
    //   Everything except din is shared with the main DUT -- one APB write
    //   configures both, so they are guaranteed the same mode, seed and enables.
    // =========================================================================
    logic [W-1:0] din_rev;
    logic [W-1:0] dout_bo1;
    logic         dout_valid_bo1;

    always_comb begin
        for (int i = 0; i < W; i++) din_rev[i] = din[W-1-i];
    end

    scrambler_apb #(
        .N(N),
        .W(W),
        .TAP_A(TAP_A),
        .TAP_B(TAP_B),
        .BIT_ORDER(1),          // <-- the only difference from `dut`
        .APB_ADDR_WIDTH(AW)
    ) dut_bo1 (
        .clk(clk),
        .rst_n(rst_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .pready(),              // driven, unused: the main DUT covers the APB
        .prdata(),              // read path; this companion only needs writes
        .pslverr(),
        .din(din_rev),
        .din_valid(din_valid),
        .ext_en(ext_en),
        .dout(dout_bo1),
        .dout_valid(dout_valid_bo1)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz clock
    end

    task init();
        begin
            rst_n     = 0;
            psel      = 0;
            penable   = 0;
            pwrite    = 0;
            paddr     = 0;
            pwdata    = 0;
            din       = 0;
            din_valid = 0;
            ext_en    = 1;
            @(negedge clk);
            rst_n = 1;
        end
    endtask

    // Pass/fail accumulators shared by every task below.
    // NOTE: these MUST be declared ahead of write_csr() -- that task already
    // increments error_count, and a module-scope variable cannot be referenced
    // before its declaration.
    int error_count = 0;
    int pass_count  = 0;

    // =========================================================================
    // write_csr : same name/signature as tb_scrambler_top.sv's task, so every
    // call site below is untouched -- but the body now drives a real APB
    // SETUP -> ACCESS transaction (same BFM shape as tb_scrambler_apb.sv's
    // apb_write) instead of poking scrambler_top's csr_wr/csr_addr/csr_wdata
    // ports directly. pready is tied high inside the DUT (zero-wait-state),
    // so the transfer always completes on the rising edge ending ACCESS.
    // =========================================================================
    task write_csr(input [7:0] addr, input [31:0] data);
        begin
            if(addr == 8'h00) begin
                if(data[1:0] == 2'b00) begin
                    $display("Setting mode to BYPASS");
                end else if(data[1:0] == 2'b01) begin
                    $display("Setting mode to SCRAMBLE");
                end else if(data[1:0] == 2'b10) begin
                    $display("Setting mode to DESCRAMBLE");
                end else if(data[1:0] == 2'b11) begin
                    $display("Setting mode to LOOPBACK");
                end
            end

            if(addr == 8'h04)begin
                $display("Lower Byte Seed Value: %0b", data);
            end
            if(addr == 8'h08)begin
                $display("Higher Byte Seed Value: %0b", data);
            end

            if(addr == 8'h0c)begin
                if(data[0] == 1)begin
                    $display("Seed Load Signal asserted");
                end
                else begin
                    $display("Seed Load Signal deasserted");
                end
            end

            @(negedge clk);
            psel    = 1'b1;
            penable = 1'b0;
            pwrite  = 1'b1;
            paddr   = addr;
            pwdata  = data;
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            #1;
            if (pready !== 1'b1) begin
                $display("write_csr(addr=%0h): FAILED || pready not asserted during ACCESS", addr);
                error_count++;
            end
            @(negedge clk);
            psel    = 1'b0;
            penable = 1'b0;
            pwrite  = 1'b0;
        end
    endtask

    // =========================================================================
    // apb_read : not used by the mode tasks below (they use hierarchical
    // dut.scrambler_top_inst.csr_reg[] peeks for cycle-accurate checks --
    // see the header comment), but kept available for any ad-hoc read-back
    // debugging. The full read-path protocol coverage already lives in
    // tb_scrambler_apb.sv (CTRL readback, NONZERO_OK, STATE_SCR_LO, out-of-
    // range, no-read-side-effects) so it is not re-derived here.
    // =========================================================================
    task apb_read(input [AW-1:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            psel    = 1'b1;
            penable = 1'b0;
            pwrite  = 1'b0;
            paddr   = addr;
            @(negedge clk);
            penable = 1'b1;
            @(posedge clk);
            #1;
            data = prdata;
            @(negedge clk);
            psel    = 1'b0;
            penable = 1'b0;
        end
    endtask

    task send_data(input[7:0] data);
        @(negedge clk);
        din = data;
        din_valid = 1;
        @(negedge clk);
        din_valid = 0;
    endtask

    logic[7:0] randomized_data;
    // error_count / pass_count are declared above write_csr() -- see the note there.

    // =====================================================================
    // Golden reference model for SCRAMBLE mode
    //   Mirrors the documented recurrence (Doc Sec 5.2.1):
    //     s[n] = d[n] ^ s[n-TAP_A] ^ s[n-TAP_B]
    //   ref_state uses the same convention as scrambler_core's `state`:
    //   ref_state[0] = most recently produced output bit. This is an
    //   independently-coded model (own variables, own update code) so
    //   it can catch top-level bugs (seed wiring, bit order, mux) even
    //   though it shares the same documented equation as the DUT.
    // =====================================================================
    logic [N-1:0] ref_state;

    task automatic ref_load_seed(input logic [N-1:0] seed_val);
        ref_state = seed_val;
    endtask

    function automatic logic [W-1:0] ref_scramble_step(input logic [W-1:0] data_word);
        logic [W-1:0] din_core, sout, dout_word;
        logic [N-1:0] next_state;

        // input boundary bit-order reversal (mirrors scrambler_core)
        if (BIT_ORDER == 0) begin
            din_core = data_word;
        end else begin
            for (int i = 0; i < W; i++) din_core[i] = data_word[W-1-i];
        end

        // 2-level XOR tap logic (mirrors scrambler_core)
        for (int i = 0; i < W; i++) begin
            sout[i] = din_core[i] ^ ref_state[TAP_A-1-i] ^ ref_state[TAP_B-1-i];
        end

        // output boundary bit-order reversal
        if (BIT_ORDER == 0) begin
            dout_word = sout;
        end else begin
            for (int i = 0; i < W; i++) dout_word[i] = sout[W-1-i];
        end

        // state shift-in (mirrors scrambler_core)
        next_state = ref_state;
        for (int j = 0; j < W; j++) next_state[j] = sout[W-1-j];
        for (int k = W; k < N; k++) next_state[k] = ref_state[k-W];
        ref_state = next_state;

        return dout_word;
    endfunction

    // Sends one byte, computes the expected byte via the golden model,
    // and compares against the DUT's dout while din_valid is asserted.
    // scrambler_core's dout is purely combinational (zero latency), so
    // the comparison happens in the same cycle din is presented.
    task send_and_check_scramble(input logic [W-1:0] data);
        logic [W-1:0] expected;
        begin
            expected = ref_scramble_step(data);

            @(negedge clk);
            din       = data;
            din_valid = 1;
            @(posedge clk); // let the combinational dout settle before sampling
            #1;

            if (dout !== expected || dout_valid !== 1'b1) begin
                $display("SCRAMBLE MODE: FAILED || din: %0h || dout: %0h (expected %0h) || dout_valid: %0b",
                          data, dout, expected, dout_valid);
                error_count++;
            end else begin
                $display("SCRAMBLE MODE: PASSED || din: %0h || dout: %0h", data, dout);
                pass_count++;
            end
        end
    endtask

    class Packet;
        rand bit [31:0] data;

        constraint non_zero {
            data != 32'h00000000;
        }
    endclass

    Packet p = new();

    // Local check helper: one line per assertion, so the checks below stay
    // readable and every one of them lands in exactly one pass/fail bucket.
    task nzs_chk(input logic cond, input string msg);
        begin
            if (cond) begin
                $display("NON-ZERO SEED: PASSED || %s", msg);
                pass_count++;
            end else begin
                $display("NON-ZERO SEED: FAILED || %s", msg);
                error_count++;
            end
        end
    endtask

    // =====================================================================
    // NON_ZERO_SEED_READ : NONZERO_OK status bit + zero-seed load rejection
    //
    //   Two separate mechanisms are under test:
    //     (a) scrambler_top's NONZERO_OK status bit (0x0C bit1) tracks
    //         whether seed_reg is non-zero -- read back over real APB.
    //     (b) scrambler_core's internal_seed_load gate REJECTS a zero seed,
    //         so the LFSR can never be driven into the all-zero lock-up
    //         state by a seed load. This is the one that actually matters.
    //
    //   How (b) has to be checked: proving a zero seed was rejected requires
    //   showing the state register is UNCHANGED across the load attempt.
    //   Testing "state != 0" proves nothing at all -- the state is never zero
    //   in the first place, since both reset and force_rst drive it to
    //   all-ones. So the negative case snapshots the state, attempts the
    //   load, and demands the snapshot back bit-for-bit, plus a guard that
    //   the snapshot itself was non-zero (or the comparison would be
    //   vacuous). The positive case likewise requires the state to equal the
    //   EXACT seed written, not merely to be non-zero.
    //
    //   Run in all four MODEs: seed_load must work regardless of mode, since
    //   scrambler_core's seed_load branch does not depend on `en`.
    //
    //   din_valid is held low throughout -- partly because scrambler_top
    //   gates seed_load with !(scr_din_valid && en_scrambler), and partly so
    //   the state can only move when this test asks it to.
    // =====================================================================
    task NON_ZERO_SEED_READ();
        logic [31:0]  seed_lo_val, seed_hi_val, rdata;
        logic [N-1:0] expected_seed;
        logic [N-1:0] scr_state_before, des_state_before;
        int           err_at_entry, pass_at_entry;
        begin
            $display("START NON-ZERO SEED READ TEST");
            err_at_entry  = error_count;
            pass_at_entry = pass_count;

            din_valid = 1'b0;

            for (int m = 0; m < 4; m++) begin
                $display("--- NON-ZERO SEED: MODE %0d ---", m);

                // A mode change pulses force_rst (prev_mode != mode); let it
                // pass first, so a forced state can never be mistaken for a
                // seed load having moved the state.
                write_csr(8'h00, {30'd1, m[1:0]}); // MODE=m, EN=1
                repeat (3) @(posedge clk);

                // ---------- positive: a non-zero seed must load --------------
                p.randomize(); seed_lo_val = p.data;
                p.randomize(); seed_hi_val = p.data;

                // Mirror scrambler_top's CSR decode: seed_reg[31:0] <= SEED_LO,
                // seed_reg[N-1:32] <= SEED_HI[N-33:0].
                expected_seed[31:0]   = seed_lo_val;
                expected_seed[N-1:32] = seed_hi_val[N-33:0];

                des_state_before = dut.scrambler_top_inst.descrambler.state_o;

                write_csr(8'h04, seed_lo_val);
                write_csr(8'h08, seed_hi_val);

                apb_read(8'h0C, rdata);
                nzs_chk(rdata[1] === 1'b1,
                        $sformatf("mode %0d: NONZERO_OK reads 1 after a non-zero seed write", m));

                write_csr(8'h0c, 32'h00000001); // LOAD
                @(posedge clk); #1;             // settle past the NBA update

                nzs_chk(dut.scrambler_top_inst.scrambler.state_o === expected_seed,
                        $sformatf("mode %0d: scrambler state == the exact seed written (got %h, want %h)",
                                  m, dut.scrambler_top_inst.scrambler.state_o, expected_seed));

                // The seed is wired to the scrambler only; loading it must not
                // disturb the descrambler (which has no seed input at all).
                nzs_chk(dut.scrambler_top_inst.descrambler.state_o === des_state_before,
                        $sformatf("mode %0d: seed load left the descrambler state untouched", m));

                // ---------- negative: a zero seed must be REJECTED ------------
                scr_state_before = dut.scrambler_top_inst.scrambler.state_o;

                // Guard against a vacuous comparison: the state we are asking
                // the DUT to preserve must be distinguishable from zero.
                nzs_chk(scr_state_before !== '0,
                        $sformatf("mode %0d: pre-condition -- state is non-zero before the zero-seed attempt", m));

                write_csr(8'h04, 32'h00000000);
                write_csr(8'h08, 32'h00000000);

                apb_read(8'h0C, rdata);
                nzs_chk(rdata[1] === 1'b0,
                        $sformatf("mode %0d: NONZERO_OK reads 0 after a zero seed write", m));

                write_csr(8'h0c, 32'h00000001); // LOAD attempt -- must be ignored
                @(posedge clk); #1;

                nzs_chk(dut.scrambler_top_inst.scrambler.state_o === scr_state_before,
                        $sformatf("mode %0d: zero-seed LOAD rejected, state unchanged (got %h, want %h)",
                                  m, dut.scrambler_top_inst.scrambler.state_o, scr_state_before));
            end

            // Local verdict: compare against this task's OWN entry snapshot, so
            // a failure inherited from an earlier subtest cannot be reported
            // here as if this test had failed.
            if (error_count == err_at_entry) begin
                $display("NON-ZERO SEED READ TEST: PASSED || all %0d checks passed",
                          pass_count - pass_at_entry);
            end else begin
                $display("NON-ZERO SEED READ TEST: FAILED || %0d of %0d checks failed",
                          error_count - err_at_entry,
                          (error_count - err_at_entry) + (pass_count - pass_at_entry));
            end
        end
    endtask

    // =====================================================================
    // TEST register (0x10) verification: FORCE_RST_EN + PERIOD
    //   test_counter counts 0..PERIOD each clock while FORCE_RST_EN=1; on the
    //   cycle it reaches PERIOD, force_rst pulses for one cycle (forcing both
    //   cores' state to all-ones) and the counter wraps back to 0. So force_rst
    //   should fire exactly every (PERIOD+1) clock cycles.
    //
    //   Strategy: run SCRAMBLE mode with a NON-all-ones seed and continuous
    //   random data, so scrambler_core's state actively drifts away from
    //   all-ones between pulses. If force_rst is doing nothing, state would
    //   just keep drifting and never return to all-ones -- only a working
    //   FORCE_RST_EN/PERIOD path explains state snapping back on a fixed
    //   cadence. Then separately confirm FORCE_RST_EN=0 stops the pulsing.
    // =====================================================================
    task FORCE_RST_PERIOD_TEST();
        localparam int PERIOD     = 4;  // small period -> fast, easy-to-check test
        localparam int NUM_PULSES = 5;  // observe several pulses, not just one
        int cycles_since_pulse;
        int pulses_seen;
        logic pending_state_check;
        begin
            $display("START FORCE_RST / PERIOD TEST");

            // Actively-shifting mode + non-all-ones seed, so state visibly drifts
            // away from all-ones between pulses (see header comment for why).
            write_csr(8'h00, 32'h00000005); // MODE=SCRAMBLE, EN=1
            write_csr(8'h04, 32'hDEADBEEF);
            write_csr(8'h08, 32'h0AAAAAAA);
            write_csr(8'h0c, 32'h00000001); // seed load

            // Arm the periodic force_rst: FORCE_RST_EN=1 (bit0), PERIOD=PERIOD (bits[31:1]).
            write_csr(8'h10, {15'b0, PERIOD[15:0], 1'b1}); // PERIOD is TEST[16:1]

            din_valid = 1'b1; // keep streaming so state keeps moving between pulses

            cycles_since_pulse   = 0;
            pulses_seen          = 0;
            pending_state_check  = 1'b0;
            while (pulses_seen < NUM_PULSES) begin
                @(negedge clk);
                din = $urandom;
                @(posedge clk);
                #1; // let force_rst / state_o / test_counter settle past the NBA update

                if (pending_state_check) begin
                    if (dut.scrambler_top_inst.scrambler.state_o !== {N{1'b1}}) begin
                        $display("FORCE_RST/PERIOD TEST: FAILED || pulse #%0d: state not all-ones (%h)",
                                  pulses_seen, dut.scrambler_top_inst.scrambler.state_o);
                        error_count++;
                    end else begin
                        $display("FORCE_RST/PERIOD TEST: PASSED || pulse #%0d: state correctly forced to all-ones",
                                  pulses_seen);
                        pass_count++;
                    end
                    pending_state_check = 1'b0;
                end

                if (dut.scrambler_top_inst.force_rst) begin
                    pulses_seen++;
                    if (pulses_seen > 1 && cycles_since_pulse !== PERIOD) begin
                        $display("FORCE_RST/PERIOD TEST: FAILED || pulse spacing was %0d cycles, expected %0d",
                                  cycles_since_pulse, PERIOD);
                        error_count++;
                    end
                    cycles_since_pulse  = 0;
                    pending_state_check = 1'b1; // state will have been forced by the next edge
                end else begin
                    cycles_since_pulse++;
                end
            end

            // --- FORCE_RST_EN=0 must stop the periodic pulsing --------------------
            write_csr(8'h10, {15'b0, PERIOD[15:0], 1'b0}); // PERIOD is TEST[16:1]

            for (int i = 0; i < (PERIOD + 1) * 3; i++) begin
                @(negedge clk);
                din = $urandom;
                @(posedge clk);
                #1;
                if (dut.scrambler_top_inst.force_rst) begin
                    $display("FORCE_RST/PERIOD TEST: FAILED || force_rst pulsed while FORCE_RST_EN=0");
                    error_count++;
                end
            end
            $display("FORCE_RST/PERIOD TEST: PASSED || no spurious pulses while FORCE_RST_EN=0");
            pass_count++;

            din_valid = 1'b0;
        end
    endtask

    task FORCE_RST_PERIOD_TEST_DES();
        localparam int PERIOD     = 10;  // small period -> fast, easy-to-check test
        localparam int NUM_PULSES = 5;  // observe several pulses, not just one
        int cycles_since_pulse;
        int pulses_seen;
        logic pending_state_check;
        begin
            $display("START FORCE_RST / PERIOD TEST (DES)");

            // DESCRAMBLE mode: the descrambler is self-synchronizing (no seed),
            // its state drifts away from all-ones by shifting in each valid din,
            // so force_rst snapping it back to all-ones is visible between pulses.
            // (seed writes below are inert here -- kept for template parity; the
            //  scrambler is disabled in DESCRAMBLE mode so its seed is unused.)
            write_csr(8'h00, 32'h00000006); // MODE=DESCRAMBLE, EN=1
            write_csr(8'h04, 32'hDEADBEEF);
            write_csr(8'h08, 32'h0AAAAAAA);
         //   write_csr(8'h0c, 32'h00000001); // seed load

            // Arm the periodic force_rst: FORCE_RST_EN=1 (bit0), PERIOD=PERIOD (bits[31:1]).
            write_csr(8'h10, {15'b0, PERIOD[15:0], 1'b1}); // PERIOD is TEST[16:1]

            din_valid = 1'b1; // keep streaming so state keeps moving between pulses

            cycles_since_pulse   = 0;
            pulses_seen          = 0;
            pending_state_check  = 1'b0;
            while (pulses_seen < NUM_PULSES) begin
                @(negedge clk);
                din = $urandom;
                @(posedge clk);
                #1; // let force_rst / state_o / test_counter settle past the NBA update

                if (pending_state_check) begin
                    if (dut.scrambler_top_inst.descrambler.state_o !== {N{1'b1}}) begin
                        $display("FORCE_RST/PERIOD TEST DES: FAILED || pulse #%0d: state not all-ones (%h)",
                                  pulses_seen, dut.scrambler_top_inst.descrambler.state_o);
                        error_count++;
                    end else begin
                        $display("FORCE_RST/PERIOD TEST DES: PASSED || pulse #%0d: state correctly forced to all-ones",
                                  pulses_seen);
                        pass_count++;
                    end
                    pending_state_check = 1'b0;
                end

                if (dut.scrambler_top_inst.force_rst) begin
                    pulses_seen++;
                    if (pulses_seen > 1 && cycles_since_pulse !== PERIOD) begin
                        $display("FORCE_RST/PERIOD TEST: FAILED (DES) || pulse spacing was %0d cycles, expected %0d",
                                  cycles_since_pulse, PERIOD);
                        error_count++;
                    end
                    cycles_since_pulse  = 0;
                    pending_state_check = 1'b1; // state will have been forced by the next edge
                end else begin
                    cycles_since_pulse++;
                end
            end

            // --- FORCE_RST_EN=0 must stop the periodic pulsing --------------------
            write_csr(8'h10, {15'b0, PERIOD[15:0], 1'b0}); // PERIOD is TEST[16:1]

            for (int i = 0; i < (PERIOD + 1) * 3; i++) begin
                @(negedge clk);
                din = $urandom;
                @(posedge clk);
                #1;
                if (dut.scrambler_top_inst.force_rst) begin
                    $display("FORCE_RST/PERIOD TEST DES: FAILED || force_rst pulsed while FORCE_RST_EN=0");
                    error_count++;
                end
            end
            $display("FORCE_RST/PERIOD TEST DES: PASSED || no spurious pulses while FORCE_RST_EN=0");
            pass_count++;

            din_valid = 1'b0;
        end
    endtask

    // =====================================================================
    // TEST register (0x10) PERIOD=0 boundary
    //   scrambler_top's own declaration says "PERIOD should be at least 1,
    //   otherwise the test will be disabled" -- so arming FORCE_RST_EN=1 with
    //   PERIOD=0 must leave the datapath RUNNING, not wedge it.
    //
    //   Why this boundary is dangerous: test_counter resets to 0 and the pulse
    //   condition is (test_counter == test_period). With PERIOD=0 that is
    //   already true on the first cycle, the counter is reloaded with 0, and
    //   the condition stays true forever -- force_rst sits high permanently
    //   instead of pulsing, holding both cores in reset indefinitely. Nothing
    //   in the CSR map reports this: every register reads back exactly as
    //   written, and the only symptom is a dout_valid that never arrives.
    //   FORCE_RST_PERIOD_TEST / _DES only ever program PERIOD=4 and 10, so
    //   this boundary is otherwise completely uncovered.
    //
    //   Three independent symptoms are checked rather than just force_rst, so
    //   the test still means something if the pulse logic is later restructured:
    //     1. force_rst must not sit high across the observation window
    //     2. dout_valid must still arrive for the words being streamed
    //     3. the scrambler state must still drift (not be pinned to all-ones)
    //   Plus a control case (PERIOD=0 with FORCE_RST_EN=0) that must stay quiet
    //   either way -- if the control case ever fails too, the fault is in the
    //   enable path, not in the PERIOD=0 decode.
    // =====================================================================
    task FORCE_RST_PERIOD_ZERO_TEST();
        localparam int OBS_CYCLES = 20;
        int force_rst_high;
        int dout_valid_seen;
        int state_drifted;
        begin
            $display("START FORCE_RST / PERIOD=0 BOUNDARY TEST");

            // Same actively-shifting setup as FORCE_RST_PERIOD_TEST, so the
            // state has a reason to move if it is not being held in reset.
            write_csr(8'h00, 32'h00000005); // MODE=SCRAMBLE, EN=1
            write_csr(8'h04, 32'hDEADBEEF);
            write_csr(8'h08, 32'h0AAAAAAA);
            write_csr(8'h0c, 32'h00000001); // seed load

            // Arm with PERIOD=0: FORCE_RST_EN=1 (bit0), PERIOD=0 (bits[31:1]).
            write_csr(8'h10, 32'h00000001);

            // MODE was written several APB transactions ago, so prev_mode==mode
            // by now and the mode-change force_rst pulse has long since passed.
            // Every force_rst seen below is therefore the TEST timer's doing.
            force_rst_high  = 0;
            dout_valid_seen = 0;
            state_drifted   = 0;

            din_valid = 1'b1;
            for (int i = 0; i < OBS_CYCLES; i++) begin
                @(negedge clk);
                din = $urandom;
                @(posedge clk);
                #1; // let force_rst / state_o / dout_valid settle past the NBA update
                if (dut.scrambler_top_inst.force_rst) force_rst_high++;
                if (dout_valid)                       dout_valid_seen++;
                if (dut.scrambler_top_inst.scrambler.state_o !== {N{1'b1}}) state_drifted++;
            end
            din_valid = 1'b0;

            // 1. force_rst must never latch high
            if (force_rst_high != 0) begin
                $display("PERIOD=0 TEST: FAILED || force_rst asserted on %0d/%0d cycles -- PERIOD=0 must disable the timer, not hold the datapath in reset",
                          force_rst_high, OBS_CYCLES);
                error_count++;
            end else begin
                $display("PERIOD=0 TEST: PASSED || force_rst stayed low for all %0d cycles", OBS_CYCLES);
                pass_count++;
            end

            // 2. the datapath must still produce output
            if (dout_valid_seen == 0) begin
                $display("PERIOD=0 TEST: FAILED || dout_valid never asserted across %0d streamed words -- datapath is wedged",
                          OBS_CYCLES);
                error_count++;
            end else begin
                $display("PERIOD=0 TEST: PASSED || dout_valid asserted on %0d/%0d cycles",
                          dout_valid_seen, OBS_CYCLES);
                pass_count++;
            end

            // 3. state must still be shifting, not pinned at the force_rst value
            if (state_drifted == 0) begin
                $display("PERIOD=0 TEST: FAILED || scrambler state pinned to all-ones for the whole window -- held in reset");
                error_count++;
            end else begin
                $display("PERIOD=0 TEST: PASSED || scrambler state drifted off all-ones on %0d/%0d cycles",
                          state_drifted, OBS_CYCLES);
                pass_count++;
            end

            // --- Control case: PERIOD=0 with FORCE_RST_EN=0 must stay quiet ---
            // This one passes with or without the fix; it exists to localize a
            // failure to the PERIOD=0 decode rather than the enable path.
            write_csr(8'h10, 32'h00000000);

            force_rst_high = 0;
            din_valid      = 1'b1;
            for (int i = 0; i < OBS_CYCLES; i++) begin
                @(negedge clk);
                din = $urandom;
                @(posedge clk);
                #1;
                if (dut.scrambler_top_inst.force_rst) force_rst_high++;
            end
            din_valid = 1'b0;

            if (force_rst_high != 0) begin
                $display("PERIOD=0 TEST: FAILED || force_rst asserted on %0d/%0d cycles while FORCE_RST_EN=0",
                          force_rst_high, OBS_CYCLES);
                error_count++;
            end else begin
                $display("PERIOD=0 TEST: PASSED || PERIOD=0 with FORCE_RST_EN=0 stays quiet (control case)");
                pass_count++;
            end
        end
    endtask




















    task tp_chk(input logic cond, input string msg);
        begin
            if (cond) begin
                $display("TEST_RSVD: PASSED || %s", msg);
                pass_count++;
            end else begin
                $display("TEST_RSVD: FAILED || %s", msg);
                error_count++;
            end
        end
    endtask

    // Arm TEST with test_val, watch a FIXED number of cycles, report how many
    // force_rst pulses were seen and the gap between the first two.
    //
    // The window is bounded on purpose. FORCE_RST_PERIOD_TEST spins in
    // `while (pulses_seen < NUM_PULSES)`, which is fine when PERIOD is known
    // small -- but this task is deliberately fed values whose high bits are
    // set, and the whole point is that a REGRESSED design would decode them as
    // a huge PERIOD. Under `while` that regression hangs the simulation with no
    // message; with a fixed window it reports "0 pulses" and fails cleanly.
    task automatic tp_measure(input logic [31:0] test_val, input int obs_cycles,
                              output int pulses, output int first_gap);
        int since;
        begin
            write_csr(8'h10, test_val);

            pulses = 0; first_gap = -1; since = 0;
            din_valid = 1'b1;
            for (int i = 0; i < obs_cycles; i++) begin
                @(negedge clk);
                din = $urandom;
                @(posedge clk);
                #1; // let force_rst settle past the NBA update
                if (dut.scrambler_top_inst.force_rst) begin
                    pulses++;
                    if (pulses == 2) first_gap = since;
                    since = 0;
                end else begin
                    since++;
                end
            end
            din_valid = 1'b0;
            write_csr(8'h10, 32'h00000000); // disarm before returning
        end
    endtask

    // =====================================================================
    // TEST_RSVD_TEST : TEST[31:17] is reserved (RAZ/WI)
    //
    //   PERIOD used to occupy TEST[31:1]. 31 bits @100MHz is up to 21 s per
    //   force_rst pulse -- a setting nobody would ever program, since this
    //   register exists to give a scope a repeatable trigger cadence. Those
    //   unusable high bits were not free: test_counter must be as wide as
    //   test_period, and that counter's carry chain is the deepest logic in
    //   the design, so the high bits were setting fmax. PERIOD is now
    //   TEST[16:1] (16 bits, 10 ns .. 655 us per pulse) and TEST[31:17] is
    //   reserved.
    //
    //   Two independent things must hold, and testing only the first would
    //   miss the bug that matters:
    //     * readback -- the reserved bits must read back 0 no matter what was
    //       written (RAZ/WI), so software can tell the field is 16 bits wide;
    //     * TIMING -- writing garbage into the reserved bits must not change
    //       the pulse cadence at all. This is the real check. If someone
    //       widens test_period back out without widening test_counter (or
    //       vice versa), readback can still look perfectly correct while the
    //       timer silently stops firing.
    //
    //   The equivalence check at the end is what pins this down: the same
    //   PERIOD with the reserved bits all-ones and all-zeros must produce an
    //   identical pulse count AND an identical gap.
    // =====================================================================
    task TEST_RSVD_TEST();
        localparam logic [31:0] IMPL_MASK = 32'h0001_FFFF; // TEST[16:0] implemented
        localparam int PERIOD = 4;
        localparam int OBS    = 40; // ~8 pulses at PERIOD=4; bounded (see above)
        logic [31:0] rdata;
        logic [31:0] armed_hi, armed_lo;
        int pulses_hi, pulses_lo, gap_hi, gap_lo;
        begin
            $display("START TEST[31:17] RESERVED-BITS TEST");

            // ---- Part 1: reserved bits read back as 0 ----------------------
            // Both patterns deliberately have bit0 (FORCE_RST_EN) = 0, i.e. the
            // timer stays DISARMED for the whole readback part. This matters:
            // test_counter has no unconditional else branch -- it reloads only
            // on a match and counts only while armed, so disarming does NOT
            // return it to 0, it freezes wherever it was. Arming here with
            // PERIOD=0xFFFF would park the counter at whatever it reached
            // across these APB transactions, and the PERIOD=4 windows below
            // would then have to count all the way around the 16-bit wrap
            // before matching -- zero pulses inside their bounded window, for a
            // reason that has nothing to do with what this test is about.
            // Leaving it disarmed keeps the counter at the 0 that init() set.
            write_csr(8'h10, 32'hFFFFFFFE);
            apb_read(8'h10, rdata);
            tp_chk(rdata === (32'hFFFFFFFE & IMPL_MASK),
                   $sformatf("wrote FFFFFFFE, read %h, expected %h",
                             rdata, 32'hFFFFFFFE & IMPL_MASK));

            write_csr(8'h10, 32'hDEAD0008);
            apb_read(8'h10, rdata);
            tp_chk(rdata === (32'hDEAD0008 & IMPL_MASK),
                   $sformatf("wrote DEAD0008, read %h, expected %h",
                             rdata, 32'hDEAD0008 & IMPL_MASK));

            write_csr(8'h10, 32'h00000000); // disarm before the timing part

            // ---- Part 2/3: reserved bits must not affect the cadence -------
            // Same actively-shifting setup the other PERIOD tests use. MODE is
            // written well ahead of the measurement windows, so prev_mode==mode
            // by then and every force_rst counted is the TEST timer's doing.
            write_csr(8'h00, 32'h00000005); // MODE=SCRAMBLE, EN=1
            write_csr(8'h04, 32'hDEADBEEF);
            write_csr(8'h08, 32'h0AAAAAAA);
            write_csr(8'h0c, 32'h00000001); // seed load

            armed_lo = {15'h0000, PERIOD[15:0], 1'b1}; // reserved bits clear
            armed_hi = {15'h7FFF, PERIOD[15:0], 1'b1}; // reserved bits all set

            tp_measure(armed_hi, OBS, pulses_hi, gap_hi);
            tp_measure(armed_lo, OBS, pulses_lo, gap_lo);

            // A 31-bit PERIOD would decode armed_hi as ~0x7FFF0004 and fire
            // nothing in this window -- this is the check that catches it.
            tp_chk(pulses_hi >= 2,
                   $sformatf("PERIOD=%0d with TEST[31:17]=all-ones pulsed %0d times in %0d cycles (need >=2; 0 means the reserved bits were decoded as PERIOD)",
                             PERIOD, pulses_hi, OBS));

            tp_chk(gap_hi === PERIOD,
                   $sformatf("PERIOD=%0d with TEST[31:17]=all-ones gave gap %0d, expected %0d",
                             PERIOD, gap_hi, PERIOD));

            tp_chk((pulses_lo >= 2) && (gap_lo === PERIOD),
                   $sformatf("PERIOD=%0d with TEST[31:17]=0 gave %0d pulses, gap %0d, expected gap %0d (reference case)",
                             PERIOD, pulses_lo, gap_lo, PERIOD));

            // The equivalence criterion is the GAP: it is the actual cadence and is
            // independent of where in the count the window happened to open.
            // Pulse counts are allowed to differ by one, because the two
            // windows do not start at the same phase -- test_counter is not
            // reset between the calls (no else branch, see Part 1), so the
            // second window opens wherever the first one left off and can
            // catch one extra or one fewer pulse at the edges. Demanding exact
            // equality there would be a flaky check, not a stronger one.
            tp_chk((gap_hi === gap_lo) &&
                   ((pulses_hi - pulses_lo) inside {-1, 0, 1}),
                   $sformatf("reserved bits changed the cadence: all-ones gave %0d pulses/gap %0d, all-zeros gave %0d pulses/gap %0d",
                             pulses_hi, gap_hi, pulses_lo, gap_lo));
        end
    endtask


    task b2b_chk(input logic cond, input string msg);
        begin
            if (cond) begin
                $display("APB_B2B: PASSED || %s", msg);
                pass_count++;
            end else begin
                $display("APB_B2B: FAILED || %s", msg);
                error_count++;
            end
        end
    endtask

    // =====================================================================
    // APB_B2B_TEST : back-to-back APB transfers (psel never drops)
    //
    //   Every other task here configures the DUT through write_csr(), which
    //   ends each transfer by driving psel low -- so the bus always returns
    //   to IDLE between accesses. Measured on the 378-pass waveform: 114
    //   transfers, psel high for exactly 2 cycles every single time, and
    //   COV_BACK2BACK_C matched 0 times. The ACCESS->SETUP arc had never
    //   been exercised.
    //
    //   That arc is legal APB and is the only reason a zero-wait-state slave
    //   would need state at all, so leaving it untested is the real gap:
    //
    //     SETUP  ACCESS SETUP  ACCESS SETUP  ACCESS
    //     psel    1      1      1      1      1      1
    //     penable 0      1      0      1      0      1
    //             |<-- xfer 0 ->|<-- xfer 1 ->|<-- xfer 2 ->|
    //
    //   What must hold: exactly one csr_wr strobe per transfer, each exactly
    //   one cycle wide (never merging into a multi-cycle strobe across the
    //   boundary), every payload landing in its own register, and pready
    //   staying high throughout -- a zero-wait-state slave may not insert
    //   wait states just because the master kept psel asserted.
    //
    //   Note the checks are written against the BUS, not against cur_state:
    //   this test must stay valid whether or not the slave keeps an FSM.
    // =====================================================================
    task APB_B2B_TEST();
        localparam int B2B_N = 4;
        logic [7:0]  addrs [0:B2B_N-1];
        logic [31:0] datas [0:B2B_N-1];
        logic [31:0] rdata;
        int    wr_pulses, bad_width, pready_low;
        int    width, idx;
        logic  trace [0:2*B2B_N];   // csr_wr sampled once per posedge
        begin
            $display("START APB BACK-TO-BACK TEST");

            // Writing the same register twice in one burst (0x04 first and
            // last) checks the second write is not swallowed by the first.
            // 0x08 is SEED_HI: only bits [N-33:0] = [25:0] exist, so the
            // value is kept inside 26 bits to keep the readback exact.
            // 0x10 is armed with FORCE_RST_EN=0 so the burst cannot start the
            // periodic force_rst and disturb whatever runs next.
            addrs[0] = 8'h04; datas[0] = 32'h12345678;
            addrs[1] = 8'h08; datas[1] = 32'h02AAAAAA;
            addrs[2] = 8'h10; datas[2] = 32'h00000008;
            addrs[3] = 8'h04; datas[3] = 32'hCAFEBABE;

            pready_low = 0;
            idx        = 0;

            @(negedge clk);
            psel   = 1'b1;
            pwrite = 1'b1;
            for (int k = 0; k < B2B_N; k++) begin
                // --- SETUP phase: psel stays high from the previous ACCESS
                penable = 1'b0;
                paddr   = addrs[k];
                pwdata  = datas[k];
                @(posedge clk);
                #1;
                trace[idx] = dut.csr_wr; idx++;
                if (pready !== 1'b1) pready_low++;

                @(negedge clk);
                // --- ACCESS phase
                penable = 1'b1;
                @(posedge clk);
                #1;
                trace[idx] = dut.csr_wr; idx++;
                if (pready !== 1'b1) pready_low++;

                @(negedge clk);
            end
            psel    = 1'b0;
            penable = 1'b0;
            pwrite  = 1'b0;
            @(posedge clk);
            #1;
            trace[idx] = dut.csr_wr; idx++;

            // --- count strobes and widths from the trace -------------------
            wr_pulses = 0; bad_width = 0; width = 0;
            for (int i = 0; i < idx; i++) begin
                if (trace[i]) begin
                    width++;
                end else if (width != 0) begin
                    wr_pulses++;
                    if (width != 1) bad_width++;
                    width = 0;
                end
            end
            if (width != 0) begin
                wr_pulses++;
                if (width != 1) bad_width++;
            end

            b2b_chk(wr_pulses === B2B_N,
                    $sformatf("%0d csr_wr strobes across %0d back-to-back writes, expected %0d",
                              wr_pulses, B2B_N, B2B_N));

            b2b_chk(bad_width === 0,
                    $sformatf("%0d csr_wr strobe(s) were not exactly one cycle wide -- strobes must not merge across the ACCESS->SETUP boundary",
                              bad_width));

            b2b_chk(pready_low === 0,
                    $sformatf("pready dropped on %0d cycle(s) during the burst -- a zero-wait-state slave must not insert waits",
                              pready_low));

            // --- payloads must have landed in their own registers ----------
            apb_read(8'h04, rdata);
            b2b_chk(rdata === 32'hCAFEBABE,
                    $sformatf("SEED_LO read %h, expected CAFEBABE (the LAST of two writes to 0x04 in the burst)",
                              rdata));

            apb_read(8'h08, rdata);
            b2b_chk(rdata === 32'h02AAAAAA,
                    $sformatf("SEED_HI read %h, expected 02AAAAAA", rdata));

            apb_read(8'h10, rdata);
            b2b_chk(rdata === 32'h00000008,
                    $sformatf("TEST read %h, expected 00000008", rdata));
        end
    endtask


    task BYPASS();
        begin
            $display("START BYPASS MODE");
            write_csr(8'h00, 32'h00000004); // Set mode to BYPASS
            write_csr(8'h04, 32'hFFFFFFFE);
            write_csr(8'h08, 32'hFFFFFFFE);
            write_csr(8'h0c, 32'h00000001);

            for(int i = 0; i < 20; i++)begin
                randomized_data = $urandom;
                send_data(randomized_data);

                if(dout !== randomized_data)begin
                    $display("BYPASS MODE: FAILED || din: %0h || dout: %0h" , randomized_data, dout);
                    error_count++;
                end
                else begin
                    $display("BYPASS MODE: PASSED");
                    pass_count++;
                end
            end
        end
    endtask

    task SCRAMBLER();
        logic [31:0]  seed_lo_val;
        logic [31:0]  seed_hi_val;
        logic [N-1:0] expected_seed;
        begin
            $display("START SCRAMBLER MODE");

            seed_lo_val = 32'hFFFFFFFE;
            seed_hi_val = 32'hFFFFFFFE;

            write_csr(8'h00, 32'h00000005); // Set mode to SCRAMBLER, EN=1
            write_csr(8'h04, seed_lo_val);  // Lower Byte Seed
            write_csr(8'h08, seed_hi_val);  // Upper Byte Seed
            write_csr(8'h0c, 32'h00000001); // Seed Load

            expected_seed[31:0]   = seed_lo_val;
            expected_seed[N-1:32] = seed_hi_val[N-33:0];
            ref_load_seed(expected_seed);

            for(int i = 0; i < 20; i++) begin
                randomized_data = $urandom;
                send_and_check_scramble(randomized_data);
            end
        end
    endtask

    // =====================================================================
    // DESCRAMBLE mode verification (end-to-end self-sync test)
    //   Strategy: scramble random original data with the GOLDEN scrambler
    //   model (reusing ref_scramble_step), feed the scrambled stream to the
    //   descrambler DUT, and check that the recovered output equals the
    //   original data once the core has locked. This proves "scramble then
    //   descramble == original" AND self-synchronization (the descrambler is
    //   never told the scrambler's seed).
    // =====================================================================
    task DESCRAMBLER();
        // Total words to stream (must be > LOCK_CYCLES). Sized well above the
        // functional minimum on purpose: this stream is also the main source
        // of stimulus for scrambler_top's DESCRAMBLE_MODE_* assertions, and
        // every word here is scoreboard-checked against the golden model, so
        // a longer run buys real coverage rather than just simulation time.
        localparam int M = 100;
        logic [W-1:0] original  [0:M-1];
        logic [W-1:0] scrambled [0:M-1];
        logic [N-1:0] scr_seed;
        logic [W-1:0] expected;
        int   check_idx;
        int   watchdog;
        begin
            $display("START DESCRAMBLER MODE");

            write_csr(8'h00, 32'h00000006); // MODE=descramble(2), EN(bit2)=1

            scr_seed = {$urandom, $urandom};
            scr_seed[0] = 1'b1;                       // force non-zero (no lock-up)
            if (scr_seed == {N{1'b1}}) scr_seed[1] = 1'b0; // avoid == reset value
            ref_load_seed(scr_seed);

            for (int i = 0; i < M; i++) begin
                original[i]  = $urandom;
                scrambled[i] = ref_scramble_step(original[i]);
            end

            check_idx = 0;
            fork
                begin
                    for (int i = 0; i < M; i++) begin
                        @(negedge clk);
                        din       = scrambled[i];
                        din_valid = 1'b1;
                    end
                    @(negedge clk);
                    din_valid = 1'b0;
                    din       = '0;
                end
                begin
                    watchdog = 0;
                    while (check_idx < M - LOCK_CYCLES) begin
                        @(posedge clk);
                        #1;
                        if (dout_valid) begin
                            expected = original[LOCK_CYCLES + check_idx];
                            if (dout !== expected) begin
                                $display("DESCRAMBLE MODE: FAILED || idx: %0d || dout: %0h (expected %0h)",
                                          LOCK_CYCLES + check_idx, dout, expected);
                                error_count++;
                            end else begin
                                $display("DESCRAMBLE MODE: PASSED || idx: %0d || recovered: %0h",
                                          LOCK_CYCLES + check_idx, dout);
                                pass_count++;
                            end
                            check_idx++;
                        end
                        watchdog++;
                        if (watchdog > M + 100) begin
                            $display("DESCRAMBLE MODE: TIMEOUT waiting for dout_valid (got %0d/%0d)",
                                      check_idx, M - LOCK_CYCLES);
                            error_count++;
                            break;
                        end
                    end
                end
            join
        end
    endtask

    // =====================================================================
    // PARITY_ERR verification (STATUS bit2)
    //   Same fault-injection technique as tb_scrambler_top.sv (force/release
    //   on the WHOLE state vector; see that file's header comment for why),
    //   just retargeted one hierarchy level deeper through scrambler_apb's
    //   scrambler_top_inst. The W1C clear itself, though, now genuinely goes
    //   over APB via write_csr(8'h14, ...).
    // =====================================================================
    task PARITY_ERR_TEST();
        logic [N-1:0] flipped_state;
        begin
            $display("START PARITY_ERR TEST");

            // ---------- Part 1: scrambler_core ---------------------------------
            write_csr(8'h00, 32'h00000005); // MODE=SCRAMBLE, EN=1
            write_csr(8'h04, 32'hDEADBEEF);
            write_csr(8'h08, 32'h0AAAAAAA);
            write_csr(8'h0c, 32'h00000001); // seed load

            din_valid = 1'b0;
            @(negedge clk);

            if (dut.scrambler_top_inst.csr_reg[5][2] !== 1'b0) begin
                $display("PARITY_ERR TEST: FAILED || PARITY_ERR set before any fault was injected");
                error_count++;
            end else begin
                $display("PARITY_ERR TEST: PASSED || PARITY_ERR clear before fault injection");
                pass_count++;
            end

            flipped_state    = dut.scrambler_top_inst.scrambler.state;
            flipped_state[5] = ~flipped_state[5];
            force dut.scrambler_top_inst.scrambler.state = flipped_state;
            release dut.scrambler_top_inst.scrambler.state;

            @(posedge clk);
            #1;
            if (dut.scrambler_top_inst.parity_err_scr !== 1'b1 || dut.scrambler_top_inst.csr_reg[5][2] !== 1'b1) begin
                $display("PARITY_ERR TEST: FAILED || scrambler PARITY_ERR did not set after state corruption");
                error_count++;
            end else begin
                $display("PARITY_ERR TEST: PASSED || scrambler PARITY_ERR set after state corruption");
                pass_count++;
            end

            // Fault still present -> a clear pulse must be rejected.
            write_csr(8'h14, 32'h00000004); // PARITY_ERR clear pulse (bit2)
            @(posedge clk);
            #1;
            if (dut.scrambler_top_inst.csr_reg[5][2] !== 1'b1) begin
                $display("PARITY_ERR TEST: FAILED || PARITY_ERR cleared while fault still present");
                error_count++;
            end else begin
                $display("PARITY_ERR TEST: PASSED || PARITY_ERR correctly rejected clear while fault persists");
                pass_count++;
            end

            @(negedge clk);
            din_valid = 1'b1;
            din       = $urandom;
            @(negedge clk);
            din_valid = 1'b0;

            write_csr(8'h14, 32'h00000004); // PARITY_ERR clear pulse (bit2)
            @(posedge clk);
            #1;
            if (dut.scrambler_top_inst.csr_reg[5][2] !== 1'b0) begin
                $display("PARITY_ERR TEST: FAILED || PARITY_ERR did not clear once the fault was resolved");
                error_count++;
            end else begin
                $display("PARITY_ERR TEST: PASSED || PARITY_ERR cleared once the fault was resolved");
                pass_count++;
            end

            // ---------- Part 2: descrambler_core --------------------------------
            write_csr(8'h00, 32'h00000006); // MODE=DESCRAMBLE, EN=1

            din_valid = 1'b0;
            @(negedge clk); // let the mode-change force_rst pulse pass

            flipped_state    = dut.scrambler_top_inst.descrambler.state;
            flipped_state[9] = ~flipped_state[9];
            force dut.scrambler_top_inst.descrambler.state = flipped_state;
            release dut.scrambler_top_inst.descrambler.state;

            @(posedge clk);
            #1;
            if (dut.scrambler_top_inst.parity_err_des !== 1'b1 || dut.scrambler_top_inst.csr_reg[5][2] !== 1'b1) begin
                $display("PARITY_ERR TEST: FAILED || descrambler PARITY_ERR did not set after state corruption");
                error_count++;
            end else begin
                $display("PARITY_ERR TEST: PASSED || descrambler PARITY_ERR set after state corruption");
                pass_count++;
            end

            @(negedge clk);
            din_valid = 1'b1;
            din       = $urandom;
            @(negedge clk);
            din_valid = 1'b0;

            write_csr(8'h14, 32'h00000004); // PARITY_ERR clear pulse (bit2)
            @(posedge clk);
            #1;
            if (dut.scrambler_top_inst.csr_reg[5][2] !== 1'b0) begin
                $display("PARITY_ERR TEST: FAILED || PARITY_ERR did not clear once descrambler fault was resolved");
                error_count++;
            end else begin
                $display("PARITY_ERR TEST: PASSED || PARITY_ERR cleared once descrambler fault was resolved");
                pass_count++;
            end
        end
    endtask

    task LOOPBACK();
        // Total words to stream (must be > LOCK_CYCLES). Sized well above the
        // functional minimum on purpose: this is the only stimulus that drives
        // LOOPBACK_DOUT_EQUAL_DOUT, the end-to-end "scramble then descramble
        // == identity" assertion. It used to be fed incidentally by the old
        // NON_ZERO_SEED_READ's 240 unchecked words; now that those are gone,
        // the coverage has to come from here -- where every word is also
        // scoreboard-checked.
        localparam int M = 100;
        logic [W-1:0] original [0:M-1];
        logic [N-1:0] scr_seed;
        logic [W-1:0] expected;
        int   check_idx;
        int   watchdog;
        begin
            $display("START LOOPBACK MODE");

            write_csr(8'h00, 32'h00000007); // MODE=loopback(3), EN(bit2)=1

            scr_seed = {$urandom, $urandom};
            scr_seed[0] = 1'b1;                            // force non-zero
            if (scr_seed == {N{1'b1}}) scr_seed[1] = 1'b0;  // avoid == reset value

            write_csr(8'h04, scr_seed[31:0]);   // SEED_LO
            write_csr(8'h08, scr_seed[N-1:32]); // SEED_HI
            write_csr(8'h0c, 32'h00000001);     // trigger seed load

            for (int i = 0; i < M; i++) begin
                original[i] = $urandom;
            end

            check_idx = 0;
            fork
                begin
                    for (int i = 0; i < M; i++) begin
                        @(negedge clk);
                        din       = original[i];
                        din_valid = 1'b1;
                    end
                    @(negedge clk);
                    din_valid = 1'b0;
                    din       = '0;
                end
                begin
                    watchdog = 0;
                    while (check_idx < M - LOCK_CYCLES) begin
                        @(posedge clk);
                        #1;
                        if (dout_valid) begin
                            expected = original[LOCK_CYCLES + check_idx];
                            if (dout !== expected) begin
                                $display("LOOPBACK MODE: FAILED || idx: %0d || dout: %0h (expected %0h)",
                                          LOCK_CYCLES + check_idx, dout, expected);
                                error_count++;
                            end else begin
                                $display("LOOPBACK MODE: PASSED || idx: %0d || recovered: %0h",
                                          LOCK_CYCLES + check_idx, dout);
                                pass_count++;
                            end
                            check_idx++;
                        end
                        watchdog++;
                        if (watchdog > M + 100) begin
                            $display("LOOPBACK MODE: TIMEOUT waiting for dout_valid (got %0d/%0d)",
                                      check_idx, M - LOCK_CYCLES);
                            error_count++;
                            break;
                        end
                    end
                end
            join
        end
    endtask

    // =====================================================================
    // bo_stream : one BIT_ORDER differential pass in the mode given by
    //   ctrl_val. Streams random words into the main DUT (BIT_ORDER=0) while
    //   the companion instance gets the same words mirrored, then requires
    //   dout_bo1 == rev(dout) on every valid cycle. See the dut_bo1 header
    //   for why that identity must hold.
    //
    //   Only failures are printed -- a passing run prints one summary line
    //   instead of one line per word -- but pass_count still advances per
    //   word, so the pass/fail granularity stays at the individual comparison.
    // =====================================================================
    task bo_stream(input logic [31:0] ctrl_val, input string tag);
        localparam int M = 32;
        logic [W-1:0] dout_mirror;
        int checked, non_palindrome;
        begin
            write_csr(8'h00, ctrl_val);
            write_csr(8'h04, 32'hDEADBEEF);
            write_csr(8'h08, 32'h0AAAAAAA);
            write_csr(8'h0c, 32'h00000001); // one APB write reaches BOTH instances
            repeat (2) @(posedge clk);

            checked        = 0;
            non_palindrome = 0;
            for (int i = 0; i < M; i++) begin
                @(negedge clk);
                din       = $urandom;
                din_valid = 1'b1;
                @(posedge clk);
                #1;
                if (dout_valid !== dout_valid_bo1) begin
                    $display("BIT_ORDER TEST: FAILED || %s word %0d: dout_valid diverged (%0b vs %0b) -- BIT_ORDER must not affect timing",
                              tag, i, dout_valid, dout_valid_bo1);
                    error_count++;
                end
                else if (dout_valid) begin
                    for (int b = 0; b < W; b++) dout_mirror[b] = dout[W-1-b];
                    if (dout !== dout_mirror) non_palindrome++;

                    if (dout_bo1 !== dout_mirror) begin
                        $display("BIT_ORDER TEST: FAILED || %s word %0d: dout_bo1=%h, expected rev(dout)=%h (dout=%h din=%h)",
                                  tag, i, dout_bo1, dout_mirror, dout, din);
                        error_count++;
                    end else begin
                        pass_count++;
                    end
                    checked++;
                end
            end
            din_valid = 1'b0;

            // Guard 1: the pass must actually have observed output.
            if (checked == 0) begin
                $display("BIT_ORDER TEST: FAILED || %s: no valid output words observed at all", tag);
                error_count++;
            end else begin
                $display("BIT_ORDER TEST: PASSED || %s: %0d words compared, all exact mirrors", tag, checked);
                pass_count++;
            end

            // Guard 2: rev(x) == x holds for any palindromic byte, so a run
            // that happened to produce only palindromes would pass even with
            // the mirror logic missing entirely. Demand asymmetric samples.
            if (non_palindrome == 0) begin
                $display("BIT_ORDER TEST: FAILED || %s: every observed word was a palindrome -- comparison had no discriminating power", tag);
                error_count++;
            end else begin
                $display("BIT_ORDER TEST: PASSED || %s: %0d/%0d words non-palindromic (comparison is discriminating)",
                          tag, non_palindrome, checked);
                pass_count++;
            end
        end
    endtask

    // =====================================================================
    // BIT_ORDER_TEST : proves the BIT_ORDER=1 mirror is applied correctly on
    //   BOTH boundaries of BOTH cores.
    //
    //   Run in SCRAMBLE and DESCRAMBLE separately, never in LOOPBACK: in
    //   loopback the scrambler's output mirror and the descrambler's input
    //   mirror cancel, which is exactly the blind spot this test exists to
    //   cover. Each pass also checks that the two instances' LFSR states
    //   stayed bit-identical -- that is the precondition the whole identity
    //   rests on, and checking it directly turns a silent mismatch into a
    //   pinpointed one (state diverged => the INPUT mirror is wrong; state
    //   agrees but dout does not => the OUTPUT mirror is wrong).
    // =====================================================================
    task BIT_ORDER_TEST();
        int err_at_entry, pass_at_entry;
        begin
            $display("START BIT_ORDER TEST");
            err_at_entry  = error_count;
            pass_at_entry = pass_count;

            // ---------- scrambler side ----------
            bo_stream(32'h00000005, "SCRAMBLE"); // MODE=SCRAMBLE, EN=1

            if (dut.scrambler_top_inst.scrambler.state_o !==
                dut_bo1.scrambler_top_inst.scrambler.state_o) begin
                $display("BIT_ORDER TEST: FAILED || scrambler LFSR states diverged (%h vs %h) -- the INPUT mirror is wrong",
                          dut.scrambler_top_inst.scrambler.state_o,
                          dut_bo1.scrambler_top_inst.scrambler.state_o);
                error_count++;
            end else begin
                $display("BIT_ORDER TEST: PASSED || scrambler LFSR states identical across BIT_ORDER (input mirror correct)");
                pass_count++;
            end

            // ---------- descrambler side ----------
            // Changing MODE pulses force_rst, re-arming both companions from a
            // clean all-ones state, so no explicit init() is needed here.
            bo_stream(32'h00000006, "DESCRAMBLE"); // MODE=DESCRAMBLE, EN=1

            if (dut.scrambler_top_inst.descrambler.state_o !==
                dut_bo1.scrambler_top_inst.descrambler.state_o) begin
                $display("BIT_ORDER TEST: FAILED || descrambler LFSR states diverged (%h vs %h) -- the INPUT mirror is wrong",
                          dut.scrambler_top_inst.descrambler.state_o,
                          dut_bo1.scrambler_top_inst.descrambler.state_o);
                error_count++;
            end else begin
                $display("BIT_ORDER TEST: PASSED || descrambler LFSR states identical across BIT_ORDER (input mirror correct)");
                pass_count++;
            end

            if (error_count == err_at_entry) begin
                $display("BIT_ORDER TEST: PASSED || all %0d checks passed", pass_count - pass_at_entry);
            end else begin
                $display("BIT_ORDER TEST: FAILED || %0d of %0d checks failed",
                          error_count - err_at_entry,
                          (error_count - err_at_entry) + (pass_count - pass_at_entry));
            end
        end
    endtask

    // =====================================================================
    // bp_hold_window : with `en` ALREADY de-asserted on entry, hammer the
    //   datapath and require that absolutely nothing moves.
    //
    //   The stimulus matters as much as the checks: din keeps changing and
    //   din_valid stays HIGH for the whole window. A freeze test that drops
    //   din_valid would pass even if `en` were ignored entirely, since
    //   nothing would advance anyway. Holding valid high is what makes `en`
    //   the only thing standing between the stimulus and the state.
    //
    //   descrambler.lock_counter is watched alongside the two state
    //   registers because it is gated by `en` independently (descrambler_core
    //   line ~194). If it kept counting while frozen, the core would claim
    //   `locked` before it had actually received N bits -- a failure mode the
    //   scrambler has no equivalent of.
    // =====================================================================
    task bp_hold_window(input string tag, input int hold_cycles);
        logic [N-1:0] scr_frozen, des_frozen;
        logic [31:0]  lock_frozen;
        logic [W-1:0] din_first;
        int scr_drift, des_drift, lock_drift, leaked, din_changes;
        begin
            @(negedge clk);
            scr_frozen  = dut.scrambler_top_inst.scrambler.state_o;
            des_frozen  = dut.scrambler_top_inst.descrambler.state_o;
            lock_frozen = dut.scrambler_top_inst.descrambler.lock_counter;

            scr_drift = 0; des_drift = 0; lock_drift = 0;
            leaked    = 0; din_changes = 0;
            din_first = din;

            for (int i = 0; i < hold_cycles; i++) begin
                din       = $urandom;  // keep changing the data...
                din_valid = 1'b1;      // ...and keep asserting valid
                if (din !== din_first) din_changes++;
                @(posedge clk);
                #1;
                if (dut.scrambler_top_inst.scrambler.state_o        !== scr_frozen)  scr_drift++;
                if (dut.scrambler_top_inst.descrambler.state_o      !== des_frozen)  des_drift++;
                if (dut.scrambler_top_inst.descrambler.lock_counter !== lock_frozen) lock_drift++;
                if (dout_valid !== 1'b0) leaked++;
                @(negedge clk);
            end
            din_valid = 1'b0;

            if (scr_drift != 0) begin
                $display("BACKPRESSURE: FAILED || %s: scrambler state moved on %0d/%0d frozen cycles",
                          tag, scr_drift, hold_cycles);
                error_count++;
            end else begin
                $display("BACKPRESSURE: PASSED || %s: scrambler state frozen for all %0d cycles", tag, hold_cycles);
                pass_count++;
            end

            if (des_drift != 0) begin
                $display("BACKPRESSURE: FAILED || %s: descrambler state moved on %0d/%0d frozen cycles",
                          tag, des_drift, hold_cycles);
                error_count++;
            end else begin
                $display("BACKPRESSURE: PASSED || %s: descrambler state frozen for all %0d cycles", tag, hold_cycles);
                pass_count++;
            end

            if (lock_drift != 0) begin
                $display("BACKPRESSURE: FAILED || %s: descrambler lock_counter advanced on %0d/%0d frozen cycles -- could lock early",
                          tag, lock_drift, hold_cycles);
                error_count++;
            end else begin
                $display("BACKPRESSURE: PASSED || %s: descrambler lock_counter frozen for all %0d cycles", tag, hold_cycles);
                pass_count++;
            end

            if (leaked != 0) begin
                $display("BACKPRESSURE: FAILED || %s: dout_valid asserted on %0d/%0d cycles while en=0",
                          tag, leaked, hold_cycles);
                error_count++;
            end else begin
                $display("BACKPRESSURE: PASSED || %s: no output produced while en=0", tag);
                pass_count++;
            end

            // Guard: if din never actually changed, the freeze proved nothing.
            if (din_changes == 0) begin
                $display("BACKPRESSURE: FAILED || %s: stimulus never varied -- the freeze check had no discriminating power", tag);
                error_count++;
            end else begin
                $display("BACKPRESSURE: PASSED || %s: %0d/%0d cycles carried changing din under valid (stimulus is discriminating)",
                          tag, din_changes, hold_cycles);
                pass_count++;
            end
        end
    endtask

    // =====================================================================
    // BACKPRESSURE_TEST : `en` (= ext_en && ctrl_en) must FREEZE the datapath,
    //   not drop data.
    //
    //   Both AND legs are exercised separately -- ext_en is a port, ctrl_en is
    //   CTRL[2] written over APB -- because either one alone being ignored
    //   would still leave the other working, and a test that only drives one
    //   would never notice.
    //
    //   The strongest check here is NOT the freeze itself but the RESUME: the
    //   golden model (ref_scramble_step) is advanced once per accepted word
    //   and never during the frozen window, so if the DUT quietly advanced its
    //   LFSR even one step while en=0, every post-resume word would mismatch.
    //   That is what makes this a back-pressure test rather than a "does the
    //   enable pin do something" test.
    //
    //   Part 3 repeats the freeze in DESCRAMBLE mode, where lock_counter is
    //   live and can be caught advancing while frozen.
    // =====================================================================
    task BACKPRESSURE_TEST();
        localparam int PRE  = 6;   // words accepted before the freeze
        localparam int HOLD = 8;   // frozen cycles
        localparam int POST = 6;   // words accepted after resuming
        logic [31:0]  seed_lo_val, seed_hi_val;
        logic [N-1:0] seed58;
        int err_at_entry, pass_at_entry;
        begin
            $display("START BACKPRESSURE TEST");
            err_at_entry  = error_count;
            pass_at_entry = pass_count;

            seed_lo_val = 32'hDEADBEEF;
            seed_hi_val = 32'h0AAAAAAA;

            ext_en    = 1'b1;
            din_valid = 1'b0;

            write_csr(8'h00, 32'h00000005); // MODE=SCRAMBLE, EN=1
            write_csr(8'h04, seed_lo_val);
            write_csr(8'h08, seed_hi_val);
            write_csr(8'h0c, 32'h00000001); // seed load

            // Align the golden model to the same seed the DUT just loaded.
            seed58[31:0]   = seed_lo_val;
            seed58[N-1:32] = seed_hi_val[N-33:0];
            ref_load_seed(seed58);

            // ---------- Part 1: ext_en (the port) ------------------------
            for (int i = 0; i < PRE; i++) send_and_check_scramble($urandom);

            din_valid = 1'b0;               // stop offering data BEFORE toggling
            @(negedge clk);                 // en, so the transition itself cannot
            ext_en = 1'b0;                  // race an in-flight word

            bp_hold_window("ext_en", HOLD);

            ext_en = 1'b1;                  // resume (still on a negedge, din_valid=0)
            for (int i = 0; i < POST; i++) send_and_check_scramble($urandom);

            // ---------- Part 2: ctrl_en (CTRL[2], over APB) --------------
            din_valid = 1'b0;
            @(negedge clk);
            write_csr(8'h00, 32'h00000001); // MODE=SCRAMBLE unchanged, EN=0
            repeat (2) @(posedge clk);

            bp_hold_window("ctrl_en", HOLD);

            write_csr(8'h00, 32'h00000005); // EN=1 again
            repeat (2) @(posedge clk);
            for (int i = 0; i < POST; i++) send_and_check_scramble($urandom);

            // ---------- Part 3: DESCRAMBLE mode, lock_counter live -------
            // Mode change pulses force_rst, so lock_counter restarts from 0;
            // stream enough words to get it counting (but stop short of the
            // point where it would matter), then freeze and watch it.
            din_valid = 1'b0;
            @(negedge clk);
            write_csr(8'h00, 32'h00000006); // MODE=DESCRAMBLE, EN=1
            repeat (2) @(posedge clk);

            for (int i = 0; i < 4; i++) begin  // < LOCK_CYCLES, so it is mid-count
                @(negedge clk);
                din       = $urandom;
                din_valid = 1'b1;
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            din_valid = 1'b0;
            ext_en    = 1'b0;

            bp_hold_window("descramble/ext_en", HOLD);

            ext_en = 1'b1;

            if (error_count == err_at_entry) begin
                $display("BACKPRESSURE TEST: PASSED || all %0d checks passed", pass_count - pass_at_entry);
            end else begin
                $display("BACKPRESSURE TEST: FAILED || %0d of %0d checks failed",
                          error_count - err_at_entry,
                          (error_count - err_at_entry) + (pass_count - pass_at_entry));
            end
        end
    endtask

    task az_chk(input logic cond, input string msg);
        begin
            if (cond) begin
                $display("ALLZERO_ERR: PASSED || %s", msg);
                pass_count++;
            end else begin
                $display("ALLZERO_ERR: FAILED || %s", msg);
                error_count++;
            end
        end
    endtask

    // =====================================================================
    // ALLZERO_ERR_TEST : STATUS.ALLZERO_ERR (0x14 bit1) sticky alarm + W1C
    //
    //   This alarm guards against the LFSR sitting in the all-zero lock-up
    //   state. In this design that state is UNREACHABLE by any legal path:
    //   reset and force_rst both drive all-ones, and a zero seed is rejected
    //   by internal_seed_load (proven separately by NON_ZERO_SEED_READ). So
    //   the detector can only be reached by corrupting `state` directly --
    //   same force/release technique PARITY_ERR_TEST uses, modelling an SEU.
    //
    //   What is actually worth testing is the W1C priority chain in
    //   scrambler_core (reset > detect > clear > hold):
    //     * while state is STILL zero, a clear pulse must be REJECTED --
    //       detection outranks clearing, so software cannot dismiss an alarm
    //       for a fault that is still present;
    //     * the flag is STICKY -- once the state recovers, the alarm stays
    //       raised until software explicitly clears it, so a transient fault
    //       cannot go unnoticed;
    //     * only then does the clear take effect.
    //
    //   Part 2 additionally confirms the self-synchronous scrambler ESCAPES
    //   the all-zero state on its own: with state==0 the tap XORs contribute
    //   nothing, so scrambler_out == din_core and any non-zero input word
    //   shifts the state back to non-zero. That is why this alarm is purely
    //   defensive here (unlike an additive scrambler, which really can lock
    //   up) -- and if anyone ever changes the feedback structure in a way
    //   that introduces a genuine lock-up, this check is what will catch it.
    // =====================================================================
    task ALLZERO_ERR_TEST();
        logic [31:0]  rdata;
        logic [N-1:0] zero_state;
        int err_at_entry, pass_at_entry;
        begin
            $display("START ALLZERO_ERR TEST");
            err_at_entry  = error_count;
            pass_at_entry = pass_count;

            zero_state = '0;

            write_csr(8'h00, 32'h00000005); // MODE=SCRAMBLE, EN=1
            write_csr(8'h04, 32'hDEADBEEF);
            write_csr(8'h08, 32'h0AAAAAAA);
            write_csr(8'h0c, 32'h00000001); // seed load -> state is non-zero

            din_valid = 1'b0;               // keep the state still: only the
            @(negedge clk);                 // injection may move it

            // Pre-condition: nothing raised yet, and the state really is
            // non-zero -- otherwise "injecting zero" would be a no-op.
            apb_read(8'h14, rdata);
            az_chk(rdata[1] === 1'b0, "clear before any fault is injected");
            az_chk(dut.scrambler_top_inst.scrambler.state_o !== '0,
                   "pre-condition: state is non-zero before injection");

            // ---------- inject the all-zero state ------------------------
            // force must target the WHOLE vector (a bit-select through two
            // levels of hierarchy is what hangs this toolchain -- see
            // PARITY_ERR_TEST). force+release leaves the value in place until
            // the next procedural assignment, and with din_valid low the
            // always_ff never assigns, so the state stays at zero.
            force dut.scrambler_top_inst.scrambler.state = zero_state;
            release dut.scrambler_top_inst.scrambler.state;
            #1; // state_o is a continuous assign off `state`; the forced value
                // needs a delta to propagate. Reading state_o at zero delay
                // here returns the PREVIOUS value and fails spuriously.

            az_chk(dut.scrambler_top_inst.scrambler.state_o === '0,
                   "injection took effect: state is now all-zero");

            @(posedge clk); #1;

            apb_read(8'h14, rdata);
            az_chk(rdata[1] === 1'b1, "ALLZERO_ERR set after the state went all-zero");

            // ---------- clear must be REJECTED while the fault persists ----
            write_csr(8'h14, 32'h00000002); // W1C pulse on bit1
            @(posedge clk); #1;
            apb_read(8'h14, rdata);
            az_chk(rdata[1] === 1'b1,
                   "clear correctly rejected while the state is still all-zero");

            // ---------- resolve the fault, alarm must stay sticky ---------
            write_csr(8'h0c, 32'h00000001); // reload the (still non-zero) seed
            @(posedge clk); #1;

            az_chk(dut.scrambler_top_inst.scrambler.state_o !== '0,
                   "state recovered to non-zero via seed load");
            apb_read(8'h14, rdata);
            az_chk(rdata[1] === 1'b1,
                   "sticky: alarm stays raised after the fault is gone (no self-clear)");

            // ---------- now the clear must take effect --------------------
            write_csr(8'h14, 32'h00000002);
            @(posedge clk); #1;
            apb_read(8'h14, rdata);
            az_chk(rdata[1] === 1'b0,
                   "clear accepted once the state is non-zero again");

            // ---------- Part 2: self-escape from the all-zero state -------
            force dut.scrambler_top_inst.scrambler.state = zero_state;
            release dut.scrambler_top_inst.scrambler.state;

            @(negedge clk);
            din       = 8'hA5;              // any non-zero word will do
            din_valid = 1'b1;
            @(posedge clk); #1;
            din_valid = 1'b0;

            az_chk(dut.scrambler_top_inst.scrambler.state_o !== '0,
                   "self-synchronous scrambler escapes all-zero after one non-zero word");

            if (error_count == err_at_entry) begin
                $display("ALLZERO_ERR TEST: PASSED || all %0d checks passed", pass_count - pass_at_entry);
            end else begin
                $display("ALLZERO_ERR TEST: FAILED || %0d of %0d checks failed",
                          error_count - err_at_entry,
                          (error_count - err_at_entry) + (pass_count - pass_at_entry));
            end
        end
    endtask

    // =====================================================================
    // REGRESSION: run every mode task back-to-back, entirely over APB.
    //   Same isolation discipline as tb_scrambler_top.sv's REGRESSION: every
    //   subtest gets a full init() + settle first, so a failure is always
    //   attributable to that subtest and not to residual state left behind
    //   by whichever subtest happened to run before it.
    // =====================================================================
    task REGRESSION();
        int err_before, pass_before;
        begin
            $display("=================== APB-DRIVEN REGRESSION START ===================");

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            BYPASS();
            $display("--- BYPASS subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            SCRAMBLER();
            $display("--- SCRAMBLER subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            DESCRAMBLER();
            $display("--- DESCRAMBLER subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            LOOPBACK();
            $display("--- LOOPBACK subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            NON_ZERO_SEED_READ();
            $display("--- NON_ZERO_SEED_READ subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            FORCE_RST_PERIOD_TEST();
            $display("--- FORCE_RST_PERIOD_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            FORCE_RST_PERIOD_TEST_DES();
            $display("--- FORCE_RST_PERIOD_TEST_DES subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            FORCE_RST_PERIOD_ZERO_TEST();
            $display("--- FORCE_RST_PERIOD_ZERO_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            TEST_RSVD_TEST();
            $display("--- TEST_RSVD_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            APB_B2B_TEST();
            $display("--- APB_B2B_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            BIT_ORDER_TEST();
            $display("--- BIT_ORDER_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            BACKPRESSURE_TEST();
            $display("--- BACKPRESSURE_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            ALLZERO_ERR_TEST();
            $display("--- ALLZERO_ERR_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            err_before = error_count; pass_before = pass_count;
            init(); repeat (10) @(posedge clk);
            PARITY_ERR_TEST();
            $display("--- PARITY_ERR_TEST subtotal: pass=%0d fail=%0d ---",
                      pass_count - pass_before, error_count - err_before);

            $display("=================== APB-DRIVEN REGRESSION END ===================");
        end
    endtask

    initial begin
        $dumpfile("tb_scrambler_apb_regression.vcd");
        $dumpvars(0, tb_scrambler_apb_regression);
        $display("");
        $display("=================== APB-Bridged Simulation Start ===================");
        $display("");
        init();
        repeat (10) @(posedge clk);

        if(MODE == "BYPASS")begin
            BYPASS();
        end
        else if(MODE == "SCRAMBLER") begin
            SCRAMBLER();
        end
        else if(MODE == "DESCRAMBLER") begin
            DESCRAMBLER();
        end
        else if(MODE == "LOOPBACK")begin
            LOOPBACK();
        end
        else if(MODE == "NON_ZERO_SEED_READ")begin
            NON_ZERO_SEED_READ();
        end
        else if(MODE == "FORCE_RST_PERIOD_TEST")begin
            FORCE_RST_PERIOD_TEST();
        end
        else if(MODE == "FORCE_RST_PERIOD_TEST_DES")begin
            FORCE_RST_PERIOD_TEST_DES();
        end
        else if(MODE == "FORCE_RST_PERIOD_ZERO_TEST")begin
            FORCE_RST_PERIOD_ZERO_TEST();
        end
        else if(MODE == "TEST_RSVD_TEST")begin
            TEST_RSVD_TEST();
        end
        else if(MODE == "APB_B2B_TEST")begin
            APB_B2B_TEST();
        end
        else if(MODE == "BIT_ORDER_TEST")begin
            BIT_ORDER_TEST();
        end
        else if(MODE == "BACKPRESSURE_TEST")begin
            BACKPRESSURE_TEST();
        end
        else if(MODE == "ALLZERO_ERR_TEST")begin
            ALLZERO_ERR_TEST();
        end
        else if(MODE == "PARITY_ERR_TEST")begin
            PARITY_ERR_TEST();
        end
        else if(MODE == "REGRESSION")begin
            REGRESSION();
        end
        else begin
            $display("ERROR: Invalid MODE parameter value: %s", MODE);
            $finish;
        end

        if(error_count == 0)begin
            $display("APB-BRIDGED SIMULATION PASSED || PASS_COUNT: %0d || FAIL_COUNT: %0d ||", pass_count, error_count);
        end
        else begin
            $display("APB-BRIDGED SIMULATION FAILED || PASS_COUNT: %0d || FAIL_COUNT: %0d ||", pass_count, error_count);
        end

        repeat (10) @(posedge clk);
        $display("=================== APB-Bridged Simulation End ===================");
        $finish;
    end

endmodule
