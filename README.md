# Self-Synchronizing Scrambler / Descrambler with APB Interface

A parametrized self-synchronizing scrambler and descrambler (the kind used on high-speed
serial links like PCIe/USB), wrapped as a software-configurable **AMBA APB** peripheral.
Taken from RTL through generic synthesis and a formal equivalence check of the netlist
against the RTL.

This is a personal learning project in SystemVerilog RTL design and the open-source
(Yosys) synthesis flow.

> **Status:** RTL done · self-checking regression in place · generic synthesis + formal
> equivalence passing · real-PDK / timing not started yet.

---

## What it does

A self-synchronizing scrambler spreads the data stream so a serial link has enough
transitions for clock recovery. The receiver re-synchronizes on its own from the received
data, with no side-channel needed to share the LFSR state.

- **Scrambler (TX):** `out = data XOR state[TAP_A] XOR state[TAP_B]`, fed back into the LFSR.
- **Descrambler (RX):** mirrored but purely feed-forward (no feedback loop), plus a lock
  counter that gates the output until it has synchronized.
- **APB wrapper:** four modes (`bypass`, `scramble`, `descramble`, `loopback`) plus a small
  CSR block (mode, enable, seed, test period, status read-back).

Default config: `N = 58` (LFSR length), `W = 8` (parallel width), taps at 39 and 58.

## Architecture

```
scrambler_apb          Top: AMBA APB slave adapter (FSM: IDLE / SETUP / ACCESS)
└── scrambler_top      Wrapper: mode mux + CSR register file + test counter
    ├── scrambler_core   TX core: 58-bit LFSR with feedback
    └── descrambler_core RX core: mirrored, feed-forward + lock detection
```

## Repository layout

```
RTL/        SystemVerilog sources (4 modules) + tb/ testbenches
syn/        Yosys synthesis + formal equivalence flow, and reports/
Doc/        synthesis report, architecture doc, equivalence-check guide
```

## Results (generic synthesis, Yosys)

| Metric | Value |
|---|---|
| Cells (generic gates) | 1650 |
| Flip-flops | 274 |
| Formal equivalence (netlist vs RTL) | 1011 / 1011 proven |
| Inferred latches | 0 |

> Note: this is **technology-independent** synthesis — no ASIC standard-cell library or FPGA
> device yet, so these are complexity indicators, not real area/timing/power. Full write-up in
> [`Doc/Yosys_Synthesis_Report.md`](Doc/Yosys_Synthesis_Report.md).

## How to run

Toolchain is the linux-x64 `oss-cad-suite` (Yosys), run via WSL2 / Linux.

```bash
cd syn
./run_synth.sh                 # generic synthesis  -> reports/ + netlist/
./run_synth.sh equiv_check.ys  # formal equivalence -> "Equivalence successfully proven!"
```

## Verification

- Self-checking APB regression (`RTL/tb/tb_scrambler_apb_regression.sv`) drives the protocol,
  exercises the modes, and prints a PASS/FAIL summary.
- Unit and loopback benches for the cores and top level.
- Netlist cross-checked against the RTL by formal equivalence.

## Roadmap

- [ ] Coverage + CI (GitHub Actions: lint → simulate → synthesize) — *in progress*
- [ ] Formal property checks (no-deadlock, scramble/descramble invertibility, sync convergence)
- [ ] Real-PDK flow (sky130 / FPGA) for genuine area and timing
- [ ] Constrained-random verification with a coverage report

## Notes

A few design choices are documented in more detail in `Doc/`: reset to all-ones + zero-seed
reject to avoid the LFSR all-zero lock-up; `seed_load` guarding during active data flow; and
using `synth -nofsm` to keep the APB FSM in binary encoding.

## License

Released under the [MIT License](LICENSE).
