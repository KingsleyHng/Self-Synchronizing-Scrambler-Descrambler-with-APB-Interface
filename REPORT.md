# Self-Synchronizing Scrambler / Descrambler with APB Interface — Project Report

Detailed project report. For a quick overview and how-to-run, see [README.md](README.md).

A parametrized self-synchronizing scrambler and descrambler (the kind used on high-speed
serial links like PCIe/USB), wrapped as a software-configurable **AMBA APB** peripheral.
Taken from RTL through generic synthesis and a formal equivalence check of the netlist
against the RTL.

This is a personal learning project in SystemVerilog RTL design and the open-source
(Yosys) synthesis flow.

> **Status:** RTL done · self-checking regression in place (384/0) · SVA in place · generic
> synthesis + formal equivalence passing · real-PDK / timing not started yet.
> **Last updated:** 2026-08-01

---

## What it does

A self-synchronizing scrambler spreads the data stream so a serial link has enough
transitions for clock recovery. The receiver re-synchronizes on its own from the received
data, with no side-channel needed to share the LFSR state.

- **Scrambler (TX):** `out = data XOR state[TAP_A] XOR state[TAP_B]`, fed back into the LFSR
  (multiplicative / feedback topology).
- **Descrambler (RX):** structurally mirrored but purely feed-forward (the *received* bits are
  shifted in, not the output — so no feedback loop), plus a lock counter that asserts `locked`
  after `ceil(N/W)` valid words and gates the output until then.
- **APB wrapper:** four software-selectable modes (`bypass`, `scramble`, `descramble`,
  `loopback`) plus a small CSR block (mode, enable, seed, test period, status read-back).

Default config: `N = 58` (LFSR length), `W = 8` (parallel width), taps at 39 and 58.

## Architecture

```
scrambler_apb          Top: AMBA APB slave adapter (zero-wait-state, stateless)
└── scrambler_top      Wrapper: mode mux + CSR register file + test counter
    ├── scrambler_core   TX core: 58-bit LFSR with feedback
    └── descrambler_core RX core: mirrored, feed-forward + lock detection
```

The wrapper is a thin shell: no scrambling math, only wiring, mode selection, pulse shaping,
and status aggregation. All four modules share one parameter set.

The APB adapter is purely combinational. `psel`/`penable` already encode the bus phase
(SETUP = `psel & !penable`, ACCESS = `psel & penable`), so a slave that never inserts wait
states has nothing left to remember — see *Design notes*.

## Repository layout

```
RTL/        SystemVerilog sources (4 modules) + tb/ testbenches
syn/        Yosys synthesis + formal equivalence flow, and reports/
Doc/        synthesis report, architecture doc, equivalence-check guide
```

## Results (generic synthesis, Yosys)

| Metric | Value |
|---|---|
| RTL modules | 4 |
| Cells (generic gates) | 1429 |
| Flip-flops | 241 |
| Longest logic depth (LTP) | 16 levels |
| Formal equivalence (netlist vs RTL) | 944 / 944 proven, 0 unproven |
| Inferred latches | 0 |
| `check -assert` problems | 0 |

> Note: this is **technology-independent** synthesis — no ASIC standard-cell library or FPGA
> device yet, so these are complexity indicators, not real area/timing/power. The 16-level path
> is the test counter, which maps to a ripple chain only because generic mapping has no
> dedicated carry primitive. Full write-up in
> [`Doc/Yosys_Synthesis_Report.md`](Doc/Yosys_Synthesis_Report.md).

### The critical path is the counter, not the datapath

The longest topological path runs from `test_counter[1]` to `test_counter[14]` — its carry
chain. The scramble path itself is only **2 XOR levels**, by construction: the tap constraint
`TAP_A > W` guarantees no intra-window recursion, so widening the parallel datapath does not
deepen it.

That makes `TEST.PERIOD`'s width the one real f<sub>max</sub> lever in this design, which is
why it was narrowed from 31 to 16 bits. A real technology has dedicated carry logic so 16 is
not an STA number, but the *relative* finding — the test counter is far deeper than the
datapath it exists to test — holds regardless of technology.

## Recent progress

### 2026-08-01 — area/depth pass, and what the regression was not covering

Four changes, each one measured. Every step followed the same loop: add the test first, change
the RTL, then re-run synthesis + formal equivalence + lint.

| Step | Cells | FFs | Depth | Equivalence |
|---|---|---|---|---|
| Starting point | 1673 | 274 | 32 | 1011 proven |
| `test_counter` → 31 bits | 1635 | 273 | 31 | 1010 proven |
| `TEST.PERIOD` + counter → 16 bits | 1480 | 243 | 16 | 948 proven |
| APB adapter FSM removed | 1426 | 241 | 16 | 944 proven |
| `csr_hi_word()` parametrized | 1429 | 241 | 16 | 944 proven |

The flip-flops removed reconcile exactly: 30 = `test_period` (15) + `test_counter` (15), 2 = the
APB adapter's state register. The final +3 cells is mapping noise, not a logic change — the old
and new high-word formulations were checked equivalent over 4 corner cases, 58 walking-ones and
20 000 random vectors, zero mismatches.

**`TEST.PERIOD` narrowed to 16 bits** *(the one externally visible spec change)*. `PERIOD` and
the internal counter must be the same width, and that counter's carry chain is the deepest logic
in the design. At 100 MHz, 16 bits still spans 10 ns … 655 µs — the register exists to give a
scope a repeatable trigger cadence, and the 21 seconds that 31 bits allowed was a setting nobody
would ever program. `TEST[31:17]` is now reserved (write-ignored, read-as-zero).

**The APB FSM was dead logic.** Its `cur_state == SETUP` qualifier on the write strobe was
tautological: APB guarantees `penable` only rises the cycle after `psel & !penable`, and every
transition out of that condition landed in `SETUP`. Synthesis could not prove it away — the
proof needs the protocol assumption, and synthesis does not read assumes — so two flops sat in
the netlist doing nothing. Worse, the state names lagged the bus by a cycle: the state called
`SETUP` was asserted while the bus was in ACCESS, which had already caused confusion once.

**What exposed it:** `COV_BACK2BACK_C` had matched **0 times**. Checking the waveform, all 114
transfers held `psel` high for exactly 2 cycles — every test dropped `psel` between transfers,
so the FSM's `ACCESS → SETUP` arc, its only reason to exist, had never once been executed. A
back-to-back burst test was added first (it now hits that cover 3 times), then the FSM came out.

> **The lesson worth keeping:** a green regression says the paths you exercised are correct, not
> that you exercised the important ones. A cover that never matches is the cheapest available
> signal that some logic is unreachable — worth reading every run, not just when hunting a bug.

Two other silent failure modes found and fixed along the way:

- **`TEST.PERIOD = 0` latched `force_rst` high permanently**, holding both cores in reset. Every
  CSR read back exactly as written and no status bit reported it; the only symptom was a
  `dout_valid` that never arrived. The counter and the pulse are now gated on the *same*
  expression so they cannot drift apart.
- **`N > 64` silently dropped seed bits.** The N-bit seed/state split across LO/HI CSR pairs only
  works for `32 < N <= 64`; at `N = 70` bits `[69:64]` became unreadable with no tool warning.
  Now checked at elaboration.

### Earlier

- **Shift logic refactor** — the LFSR state update was rewritten from a `for` loop inside the
  clocked block into a combinational next-state (`state_next` via bit-slice + reversal) with the
  sequential block doing only `state <= state_next`. This removed a tool-dependent "ghost
  register" artifact (loop variables being inferred as 128 bits of flops before being optimized
  away) and makes the design more portable across synthesizers.
- **Clean release layout** — sources, testbenches, synthesis flow and reports organized into a
  self-contained repository.

## How to run

Toolchain is the linux-x64 `oss-cad-suite` (Yosys), run via WSL2 / Linux (the binaries are ELF,
not Windows executables). The synthesis path can be overridden with `OSS_CAD_ROOT=...`.

```bash
cd syn
./run_synth.sh                 # generic synthesis  -> reports/ + netlist/
./run_synth.sh equiv_check.ys  # formal equivalence -> "Equivalence successfully proven!"
```

## Verification

- Self-checking APB regression (`RTL/tb/tb_scrambler_apb_regression.sv`): **384 checks, 0
  failures** across 14 sub-tests. Every CSR write goes through a real APB SETUP→ACCESS handshake
  rather than poking the wrapper's CSR ports directly, so a failure localizes to "the APB bridge
  broke something that direct CSR access did not".
- **32 SVA properties** (24 assert + 8 cover/assume) across the three RTL layers, checked for
  non-vacuity.
- Gate-level netlist independently cross-checked against the RTL by formal equivalence.

| Sub-test | What it pins down |
|---|---|
| bypass / scramble / descramble / loopback | four modes against an independently coded golden model |
| non-zero-seed reject | zero seed refused, state provably unchanged |
| forced-reset period (TX / RX) | `force_rst` fires every `PERIOD+1` cycles, state forced to all-ones |
| `PERIOD = 0` boundary | timer disabled, datapath still running (4 checks, incl. a control case) |
| `TEST` reserved bits | reserved bits read 0 **and** cannot alter the pulse cadence (6 checks) |
| APB back-to-back | one single-cycle strobe per transfer, `pready` never drops (6 checks) |
| back-pressure | state, lock counter and `dout_valid` all frozen while disabled |
| `BIT_ORDER` mirror | differential against a `BIT_ORDER=1` companion instance |
| all-zero alarm | sticky, clear rejected while the fault persists (9 checks) |
| parity (SEU) alarm | fault injected by `force`/`release`, full detect→clear chain |

Two of these are worth singling out, because the obvious version of the test would have missed
the bug that matters:

- **`BIT_ORDER`** is applied as a *mirrored pair* — reverse in, reverse out, in both cores — so
  any loopback or scramble-then-descramble test passes even when the reversal is completely
  wrong, because the two mistakes cancel. Instead of re-implementing the reversal in a golden
  model (which would only prove the testbench agrees with itself), a `BIT_ORDER=1` companion
  instance is fed `rev(din)` and must satisfy the exact identity `dout_bo1 == rev(dout)`. That
  depends on nothing but mirror symmetry, so it stays valid whatever the polynomial is.
- **`TEST` reserved bits**: checking read-back alone would pass even if someone widened
  `test_period` without widening `test_counter` — the register would read back perfectly while
  the timer silently stopped firing. So the same `PERIOD` is programmed with the reserved bits
  all-ones and all-zeros, and the *pulse cadence* must be identical.

## Design notes

- **Reset to all-ones, not all-zeros** — all-ones is a legal non-zero seed; combined with a
  zero-seed reject on `seed_load`, the LFSR is kept out of the all-zero lock-up state that
  naive LFSR scramblers can fall into.
- **Seed-load guarding** — `seed_load` is blocked while data is actively flowing through the
  scrambler, so a mid-stream seed write can't silently corrupt the TX state and desync the RX.
- **`force_rst` sourcing** — driven by either a test-period rollover or a mode change, but never
  by seed-load / error-clear (which have lower priority and would be wiped).
- **CSR register semantics** — three behaviors: RW storage bits, W1P one-shot pulses
  (read back as 0), and W1C sticky status.
- **Stateless APB adapter** — `psel`/`penable` fully encode the bus phase, so a zero-wait-state
  slave needs no FSM. Behaviour on a protocol-legal bus is identical cycle for cycle; it differs
  only if a master violates APB by raising `penable` without a preceding SETUP, which is
  undefined for a slave either way.
- **`synth -nofsm` retained** — there is no longer an FSM to encode, but the flag is kept so
  Yosys does not re-encode any future state logic behind the equivalence check's back; it also
  keeps internal-point coverage at full.
- **`N` is bounded on both sides (`32 < N <= 64`)** — the seed/state high word must be non-empty
  and must still fit one 32-bit CSR. The two ends fail differently, which is worth knowing:
  `N > 64` drops bits *silently*, so it needs the explicit elaboration check; `N <= 32` produces
  a reversed part-select, which is a compile-time error and fires before any run-time `$fatal`
  can. Both are loud, but only the upper bound relies on the check.
- **Width literals derived, not hand-computed** — the three CSR high-word zero-extensions were
  once written `{6'b0, x[N-1:32]}`, where the `6` was worked out for `N = 58`. It happened to
  stay correct for every legal `N` (the assignment's own width adjustment rescued it), but it
  read as if derived from `N` when it was not. Now a single `csr_hi_word()` function. Note it is
  deliberately *not* written as `{{(64-N){1'b0}}, ...}`: at `N = 64` that would be a zero-width
  concatenation, which is illegal SystemVerilog.

## Roadmap

- [ ] Coverage + CI (GitHub Actions: lint → simulate → synthesize) — *in progress*
- [ ] Formal property checks (no-deadlock, scramble/descramble invertibility, sync convergence)
- [ ] Real-PDK flow (sky130 / FPGA) for genuine area and timing
- [ ] Constrained-random verification with a coverage report

## License

Released under the [MIT License](LICENSE).
