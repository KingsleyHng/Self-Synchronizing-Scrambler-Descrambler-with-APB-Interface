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
scrambler_apb          Top: AMBA APB slave adapter (zero-wait-state, stateless)
└── scrambler_top      Wrapper: mode mux + CSR register file + test counter
    ├── scrambler_core   TX core: 58-bit LFSR with feedback
    └── descrambler_core RX core: mirrored, feed-forward + lock detection
```

The APB adapter holds no state: `psel`/`penable` already encode the bus phase completely
(SETUP = `psel & !penable`, ACCESS = `psel & penable`), so a slave that never stalls has
nothing to remember. Back-to-back transfers are supported.

## Repository layout

```
RTL/        SystemVerilog sources (4 modules) + tb/ testbenches
syn/        Yosys synthesis + formal equivalence flow, and reports/
Doc/        synthesis report, architecture doc, equivalence-check guide
```

## Results (generic synthesis, Yosys)

| Metric | Value |
|---|---|
| Cells (generic gates) | 1429 |
| Flip-flops | 241 |
| Longest logic depth | 16 levels |
| Formal equivalence (netlist vs RTL) | 944 / 944 proven, 0 unproven |
| Inferred latches | 0 |

The critical path is the **test counter's carry chain**, not the datapath — the scramble path
itself is only 2 XOR levels. That made `TEST.PERIOD`'s width the one real f<sub>max</sub> lever:
narrowing it from 31 to 16 bits cut the longest path from 31 levels to 16 and removed 30
flip-flops. Removing the APB adapter's redundant FSM took out 2 more.

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

- Self-checking APB regression (`RTL/tb/tb_scrambler_apb_regression.sv`): **384 checks, 0 failures**
  across 14 sub-tests. Every CSR write — mode select, seed load, test period, W1C clears — goes
  through a real APB SETUP→ACCESS handshake rather than poking the wrapper's CSR ports directly,
  so a failure means the APB bridge broke something that direct CSR access did not.
- **32 SVA properties** (24 assert + 8 cover/assume) across the three RTL layers. The covers are
  checked for non-vacuity: a property that passes because its scenario never occurs is worse than
  no property at all.
- Netlist cross-checked against the RTL by formal equivalence.

Sub-tests: bypass · scramble · descramble · loopback · non-zero-seed reject · forced-reset period
(TX and RX) · `PERIOD=0` boundary · `TEST` reserved bits · APB back-to-back transfers ·
back-pressure · `BIT_ORDER` mirror · all-zero alarm · parity (SEU) alarm.

## Roadmap

- [ ] Coverage + CI (GitHub Actions: lint → simulate → synthesize) — *in progress*
- [ ] Formal property checks (no-deadlock, scramble/descramble invertibility, sync convergence)
- [ ] Real-PDK flow (sky130 / FPGA) for genuine area and timing
- [ ] Constrained-random verification with a coverage report

## Notes

A few design choices are documented in more detail in `Doc/`: reset to all-ones + zero-seed
reject to avoid the LFSR all-zero lock-up, and `seed_load` guarding during active data flow.

Two findings worth repeating, both from the same lesson — *green numbers do not mean everything
was tested*:

- `COV_BACK2BACK_C` matched **0 times** for a long while. Every test dropped `psel` between
  transfers, so the APB FSM's `ACCESS → SETUP` arc — its only reason to exist — had never been
  executed. That cover being empty is what exposed the FSM as dead logic. **A cover that never
  matches is a hint that the logic it guards is never reached.**
- `TEST.PERIOD = 0` used to latch `force_rst` high permanently, holding both cores in reset.
  The failure was silent: every CSR read back exactly as written and no status bit reported it;
  the only symptom was a `dout_valid` that never arrived.

## License

Released under the [MIT License](LICENSE).
