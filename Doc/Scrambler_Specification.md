# Self-Synchronizing Scrambler / Descrambler — Product Specification

|                    |                                                                             |
| ------------------ | --------------------------------------------------------------------------- |
| **IP name**        | `scrambler_apb` (multiplicative self-synchronizing scrambler / descrambler) |
| **Interface**      | AMBA APB slave (zero-wait-state) + streaming datapath                       |
| **Default config** | 58-bit LFSR, 8-bit parallel datapath, fully parametrized                    |
| **Clocking**       | Single clock domain (datapath and CSR on same clock)                        |
| **Reset**          | Active-low, asynchronous assert / synchronous release                       |
| **Deliverable**    | Synthesizable SystemVerilog RTL, technology-independent                     |
| **Spec version**   | v1.0                                                                        |

---

## 1. Overview

A multiplicative self-synchronizing scrambler and descrambler, packaged as a
software-configurable AMBA APB peripheral. The scrambler spreads a data stream so that a
high-speed serial link maintains sufficient transition density for clock/data recovery and a
flattened spectrum. The descrambler recovers the original data and **re-synchronizes on its own
from the received data alone** — no seed, key, or side-channel needs to be exchanged.

### 1.1 Features

- Multiplicative self-synchronizing scrambler (TX) and descrambler (RX).
- Automatic receiver lock after `ceil(N/W)` valid words; self-healing after transient errors.
- Parametrizable LFSR length, datapath width, feedback taps, and bit ordering.
- Four operating modes: bypass, scramble, descramble, on-chip loopback self-test.
- All-zero lock-up prevention: non-zero reset seed and zero-seed load rejection.
- Diagnostics: sync-lock status, all-zero (deadlock) alarm, and state-register parity (SEU) alarm.
- Back-pressure support via an enable/freeze input.
- AMBA APB slave interface for control/status; DFT-observable internal state.
- No latches, no combinational loops; gate-level netlist formally proven equivalent to RTL.

### 1.2 Block diagram

```
        AMBA APB                         Streaming datapath
  psel/penable/pwrite ─┐                 din / din_valid / ext_en ─┐
  paddr / pwdata       │                                          │
        ▲              ▼                                          ▼
  prdata │      ┌───────────────┐                        ┌─────────────────┐
  pready │◀────▶│ scrambler_apb │  CSR (csr_wr/addr/data)│  scrambler_top  │
  pslverr│      │  APB adapter  │───────────────────────▶│  mode mux + CSR │
        └───────┴───────────────┘                        │  + test counter │
                                        ┌────────────────┤                 │
                                        ▼                └──────┬──────────┘
                               ┌─────────────────┐             │
                               │  scrambler_core │  ┌──────────▼──────────┐
                               │  (TX, feedback) │  │  descrambler_core   │──▶ dout
                               └─────────────────┘  │  (RX, feed-forward) │    dout_valid
                                                     └─────────────────────┘
```

---

## 2. Parameters

| Parameter | Description | Default | Legal range / constraint |
|---|---|---|---|
| `N` | LFSR length (state register depth) | 58 | `N >= TAP_B` |
| `W` | Parallel datapath width (bits/clock) | 8 | `W < TAP_A` |
| `TAP_A` | First (lower) feedback tap | 39 | `W < TAP_A < TAP_B` |
| `TAP_B` | Second (upper) feedback tap | 58 | `TAP_A < TAP_B <= N` |
| `BIT_ORDER` | Bus bit ordering (0 = LSB-first, 1 = MSB-first) | 0 | 0 or 1 |
| `APB_ADDR_WIDTH` | APB address width | 8 | `>= 8` |

> Parameter legality is checked at elaboration (`$fatal`); illegal instantiations fail the build
> rather than silently generating out-of-range logic. The tap constraints guarantee no
> intra-window recursion, so the combinational path is fixed at **2 XOR levels** for the default
> 8/16-bit parallel widths (no pipelining required).

---

## 3. Interface

### 3.1 Clock / reset

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock (= APB `PCLK`) |
| `rst_n` | in | 1 | Active-low reset, async assert / sync release (= APB `PRESETn`) |

### 3.2 AMBA APB slave

| Signal | Dir | Width | Description |
|---|---|---|---|
| `psel` | in | 1 | APB select |
| `penable` | in | 1 | APB enable phase |
| `pwrite` | in | 1 | 1 = write, 0 = read |
| `paddr` | in | `APB_ADDR_WIDTH` | Byte address (4-byte aligned) |
| `pwdata` | in | 32 | Write data |
| `prdata` | out | 32 | Read data |
| `pready` | out | 1 | Always 1 (zero-wait-state slave) |
| `pslverr` | out | 1 | Always 0 (no bus error generated) |

### 3.3 Streaming datapath

| Signal | Dir | Width | Description |
|---|---|---|---|
| `din` | in | `W` | Input data; `din[0]` is first in time (before optional bit-order reversal) |
| `din_valid` | in | 1 | Input valid |
| `ext_en` | in | 1 | External enable / back-pressure; low freezes state |
| `dout` | out | `W` | Scrambled / descrambled / bypassed output |
| `dout_valid` | out | 1 | Output valid |

> Effective datapath enable = `CTRL.EN & ext_en`. When low, the LFSR state freezes and
> `dout_valid` deasserts in the same cycle.

---

## 4. Register map (CSR)

Base-relative byte offsets, 32-bit registers, 4-byte aligned. Access types: **RW** read/write,
**RO** read-only, **W1P** write-1-pulse (event, reads 0), **W1C** write-1-to-clear (sticky).

| Offset | Register | Bits | Access | Description |
|---|---|---|---|---|
| 0x00 | `CTRL` | `[1:0] MODE` | RW | 0 = bypass, 1 = scramble, 2 = descramble, 3 = loopback |
| | | `[2] EN` | RW | Module enable (total gate) |
| 0x04 | `SEED_LO` | `[31:0]` | RW | Seed, low 32 bits |
| 0x08 | `SEED_HI` | `[N-33:0]` | RW | Seed, high bits (N−32; unused high bits ignored) |
| 0x0C | `SEED_CTRL` | `[0] LOAD` | W1P | Write 1 to load the seed into the TX core |
| | | `[1] NONZERO_OK` | RO | Seed non-zero check passed (`seed != 0`) |
| 0x10 | `TEST` | `[0] FORCE_RST_EN` | RW | Enable periodic forced reset (test only) |
| | | `[31:1] PERIOD` | RW | Forced-reset period |
| 0x14 | `STATUS` | `[0] LOCKED` | RO | Descrambler synchronized |
| | | `[1] ALLZERO_ERR` | RO / W1C | LFSR all-zero deadlock alarm |
| | | `[2] PARITY_ERR` | RO / W1C | State-register parity (SEU) alarm; TX/RX OR-combined |
| 0x18 | `STATE_SCR_LO` | `[31:0]` | RO | TX core state, low 32 bits |
| 0x1C | `STATE_SCR_HI` | `[N-33:0]` | RO | TX core state, high bits (zero-padded) |
| 0x20 | `STATE_DES_LO` | `[31:0]` | RO | RX core state, low 32 bits |
| 0x24 | `STATE_DES_HI` | `[N-33:0]` | RO | RX core state, high bits (zero-padded) |

> The N-bit seed and state values exceed the 32-bit CSR data port, so both are split across low/high
> address pairs. `NONZERO_OK` is computed in the wrapper (the core silently rejects a zero seed and
> has no feedback port). W1P/W1C bits self-clear and read back 0.

---

## 5. Functional description

### 5.1 Scrambler core (TX, with feedback)

Maintains an N-bit state holding the most recently transmitted output bits. Each clock it computes
`W` output bits in parallel:

```
out[i] = data[i] XOR state[TAP_A-1-i] XOR state[TAP_B-1-i]
```

The `W` new output bits are then shifted into the state register (feedback topology). Output is
combinational (zero latency); `dout_valid = din_valid & en`.

### 5.2 Descrambler core (RX, feed-forward)

Structurally mirrored, but the `W` **received** input bits are shifted in instead of the output —
there is no feedback loop. A fill counter asserts `locked` after `ceil(N/W)` valid clocks, at which
point the state matches the transmitter and recovery is exact. Output is registered (+1 cycle) and
gated by `locked`: before lock, `dout = 0` and `dout_valid = 0`, masking synchronization-time
garbage; after lock, recovered words are released one per valid clock.

> The only functional difference between the two cores: the TX shifts in **its own output**
> (feedback); the RX shifts in **the received input** (feed-forward).

### 5.3 Bit ordering (`BIT_ORDER`)

The core math assumes a single fixed time convention (`index 0 = earliest in time`). Bit ordering
is handled **only at the I/O boundary** by mirror-reversal, never by touching the tap/shift logic:

- `BIT_ORDER = 0`: external bus is LSB-first — input and output pass through unchanged.
- `BIT_ORDER = 1`: external bus is MSB-first — input and output are both mirror-reversed
  (`[i] = [W-1-i]`).

Both boundaries must use the identical reversal rule. Reversing only one side desynchronizes the
byte time-order and produces garbage that is difficult to trace.

### 5.4 Deadlock prevention

The LFSR must never enter the all-zero state (feedback would stay zero, output = input). Two
guards: (1) reset and `force_rst` load all-ones (`{N{1'b1}}`), a legal non-zero seed; (2) a zero
seed presented on `SEED_CTRL.LOAD` is rejected and `NONZERO_OK` stays 0. Runtime all-zero state is
flagged by `STATUS.ALLZERO_ERR`.

---

## 6. Operating modes and latency

| MODE | Name | TX core input | RX core input | `dout` source | Latency |
|---|---|---|---|---|---|
| 0 | bypass | frozen | frozen | `din` (direct) | 0 |
| 1 | scramble | external `din` | frozen | TX core | 0 (combinational) |
| 2 | descramble | frozen | external `din` | RX core | +1 cycle (registered) |
| 3 | loopback | external `din` | TX core output | RX core | +1 cycle |

> **Latency varies by mode.** Downstream logic must align on `dout_valid` and must not assume a
> fixed latency. Unused cores are frozen (`valid = 0`) to save power and prevent state pollution.
> Loopback connects TX output directly to RX input on-chip (self-test criterion: recovered == source).

---

## 7. Programming sequences

### 7.1 Normal scramble/descramble startup

1. Ensure `CTRL.EN = 0`.
2. Write `SEED_LO` / `SEED_HI` with a non-zero seed (TX side only).
3. Write `SEED_CTRL.LOAD = 1`; read `SEED_CTRL.NONZERO_OK` to confirm acceptance.
4. Write `CTRL.MODE` to the desired mode.
5. Set `CTRL.EN = 1` and stream data.

### 7.2 Mode change (avoids stale state)

`clear EN → issue force_rst (or write TEST/mode per RTL) → change MODE → set EN`. Changing MODE
while running can leave residual state (notably the RX `locked` flag), which may mark unsynchronized
data as valid. The wrapper auto-issues a `force_rst` on a detected MODE change; software should
still follow the sequence above.

### 7.3 Clearing an alarm (W1C)

Write 1 to `STATUS.ALLZERO_ERR` or `STATUS.PARITY_ERR`. The clear only takes effect once the
underlying fault has cleared (detection has priority over clear); while the fault persists the
alarm cannot be cleared.

---

## 8. Diagnostics and error handling

| Flag | Register | Meaning | Clear |
|---|---|---|---|
| `LOCKED` | STATUS[0] | RX has synchronized (sticky until reset / force_rst) | auto |
| `ALLZERO_ERR` | STATUS[1] | LFSR reached all-zero state | W1C (after fault clears) |
| `PARITY_ERR` | STATUS[2] | State-register parity mismatch (SEU/fault); TX or RX | W1C (after fault clears) |

`PARITY_ERR` uses a shadow parity register updated in lockstep with the state; it detects
disturbances to the state register that occur outside the normal RTL update path.

---

## 9. Constraints and limitations

- **Seed must be non-zero.** Enforced by reset value and load rejection.
- **Bit order must match the link partner** and be identical on both I/O boundaries.
- **Error multiplication.** A single bit error on the line produces multiple errors at the
  descrambler output (count related to the number of taps). Systems should provide retransmission
  rather than rely solely on forward error correction.
- **Parity coverage.** `PARITY_ERR` detects only an odd number of simultaneously flipped state bits;
  an even number is not detected (inherent to single-bit parity).
- **Latency is mode-dependent** (see §6); align on `dout_valid`.
- **Single clock domain.** If the CSR bus is asynchronous to the datapath, external synchronizers
  are required (level sync for quasi-static config, pulse sync for one-shot events).

---

## 10. Synthesis summary (technology-independent)

Generic synthesis with Yosys (no ASIC standard-cell library or FPGA device yet — figures are
complexity indicators, not real PPA):

| Metric | Value |
|---|---|
| Cells (generic gates) | 1650 |
| Flip-flops | 274 |
| Longest logic depth | 32 levels (32-bit test counter; ripple chain under generic mapping) |
| Formal equivalence (netlist vs RTL) | 1011 / 1011 proven, 0 unproven |
| Inferred latches | 0 |

Real area, timing (STA), and power require mapping to a target technology (e.g. SkyWater sky130) or an FPGA vendor flow.

---

