# Self-Synchronizing Scrambler / Descrambler with APB Interface — Project Report

Detailed project report. For a quick overview and how-to-run, see [README.md](README.md).

A parametrized self-synchronizing scrambler and descrambler (the kind used on high-speed
serial links like PCIe/USB), wrapped as a software-configurable **AMBA APB** peripheral.
Taken from RTL through generic synthesis and a formal equivalence check of the netlist
against the RTL.

This is a personal learning project in SystemVerilog RTL design and the open-source
(Yosys) synthesis flow.

> **Status:** RTL done · self-checking regression in place · generic synthesis + formal
> equivalence passing · real-PDK / timing not started yet.
> **Last updated:** 2026-07-15

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
scrambler_apb          Top: AMBA APB slave adapter (FSM: IDLE / SETUP / ACCESS)
└── scrambler_top      Wrapper: mode mux + CSR register file + test counter
    ├── scrambler_core   TX core: 58-bit LFSR with feedback
    └── descrambler_core RX core: mirrored, feed-forward + lock detection
```

The wrapper is a thin shell: no scrambling math, only wiring, mode selection, pulse shaping,
and status aggregation. All four modules share one parameter set.

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
| Cells (generic gates) | 1650 |
| Flip-flops | 274 |
| Longest logic depth (LTP) | 32 levels |
| Formal equivalence (netlist vs RTL) | 1011 / 1011 proven, 0 unproven |
| Inferred latches | 0 |
| `check -assert` problems | 0 |

> Note: this is **technology-independent** synthesis — no ASIC standard-cell library or FPGA
> device yet, so these are complexity indicators, not real area/timing/power. The 32-level path
> is a 32-bit test counter that maps to a ripple chain only because generic mapping has no
> dedicated carry primitive. Full write-up in
> [`Doc/Yosys_Synthesis_Report.md`](Doc/Yosys_Synthesis_Report.md).

## Recent progress

- **Shift logic refactor** — the LFSR state update was rewritten from a `for` loop inside the
  clocked block into a combinational next-state (`state_next` via bit-slice + reversal) with the
  sequential block doing only `state <= state_next`. This removed a tool-dependent "ghost
  register" artifact (loop variables being inferred as 128 bits of flops before being optimized
  away) and makes the design more portable across synthesizers. Re-verified: formal equivalence
  still 1011/1011, flip-flop count unchanged at 274, cell count 1627 → 1650 (normal gate-mapping
  variation).
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

- Self-checking APB regression (`RTL/tb/tb_scrambler_apb_regression.sv`) drives the APB protocol,
  exercises the modes, and prints a PASS/FAIL summary with a non-zero exit on failure.
- Unit and loopback benches for the cores and the top level.
- Gate-level netlist independently cross-checked against the RTL by formal equivalence.

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
- **`synth -nofsm` on purpose** — keeps the 3-state APB FSM in binary encoding instead of Yosys's
  default one-hot re-encoding: one fewer flop, and the formal equivalence check stays at full
  internal-point coverage.

## Roadmap

- [ ] Coverage + CI (GitHub Actions: lint → simulate → synthesize) — *in progress*
- [ ] Formal property checks (no-deadlock, scramble/descramble invertibility, sync convergence)
- [ ] Real-PDK flow (sky130 / FPGA) for genuine area and timing
- [ ] Constrained-random verification with a coverage report

## License

Released under the [MIT License](LICENSE).
