![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# AgilA8 - an 8-bit Microcontroller
Agila is Tagalog for "eagle" - specifically evoking the Philippine Eagle (Haribon), the country's national bird. AgilA8 pairs that with A8, the name of the CPU core at the center of the design: Agil + A8 = AgilA8, the two overlapping on a shared capital A.

## Layout 
<img width="471" height="643" alt="Screenshot 2026-08-19 at 6 35 25 AM" src="https://github.com/user-attachments/assets/311f9214-8b5d-435b-8a26-f53cb2e36b4e" />

3D Viewer: https://gds-viewer.tinytapeout.com/?model=https://alexandercoabad.github.io/AgilA8/tinytapeout.oas&pdk=sky130A


## How it works

AgilA8 is a compact 8-bit microcontroller built around A8, a custom
16-instruction CPU (see `docs/ISA.md`), with memory-mapped GPIO, a 16-bit
timer, and PWM generation.

Both instruction and data memory live off-chip on the Tiny Tapeout QSPI
Pmod, sharing its SD0/SD1/SCK lines between two separate chip selects.
This keeps the on-chip design small enough to fit a 1x2 tile budget -
Tiny Tapeout's own RAM32 macro is *half* the size of this design's DMEM
and needs 3x2 tiles on its own, so a plain on-chip flip-flop array was
never going to fit. Program code is fetched from external SPI flash
(CS0) using a standard `03h` Read Data command; data memory lives on one
of the Pmod's two PSRAM chips (RAM A / CS1) using standard `02h`/`03h`
Write/Read commands. Only plain, single-line SPI commands are used -
deliberately not flash's continuous-read mode or PSRAM's QPI mode, both
of which need a mode-byte/setup sequence that's easy to get subtly wrong
without hardware to verify against.

Because `imem_valid` and `dmem_valid` are never asserted in the same
cycle (fetch and memory-access are separate, sequential states in the
core's FSM), the flash and PSRAM controllers can share the SD0/SD1/SCK
lines through a simple mux rather than needing real bus arbitration.
The Pmod's second PSRAM chip (RAM B / CS2) is left deselected and
unused - the DMEM window doesn't need it.

### Address map

| Address range | Device                                  |
| -------------- | --------------------------------------- |
| 0x00 - 0xEF, 0xF3 - 0xF7 | RAM (external PSRAM, RAM A)   |
| 0xF0 - 0xF2    | GPIO                                    |
| 0xF8 - 0xFB    | Timer                                   |
| 0xFC - 0xFD    | PWM                                     |

Instructions are fetched separately, as two consecutive bytes from
external flash (big-endian: high byte at PC, low byte at PC+1) - flash
isn't part of the 8-bit DMEM address space above.

### IO

| # | Input       | Output       | Bidirectional                    |
| - | ----------- | ------------ | --------------------------------- |
| 0 | GPIO in 0   | GPIO out 0   | Flash CS (CS0)                    |
| 1 | GPIO in 1   | GPIO out 1   | SD0 - MOSI (shared flash/PSRAM)   |
| 2 | GPIO in 2   | GPIO out 2   | SD1 - MISO (shared flash/PSRAM)   |
| 3 | GPIO in 3   | GPIO out 3   | SCK (shared flash/PSRAM)          |
| 4 | GPIO in 4   | GPIO out 4   | SD2 (held high, unused)           |
| 5 | GPIO in 5   | GPIO out 5   | SD3 (held high, unused)           |
| 6 | GPIO in 6   | GPIO out 6   | RAM A CS (CS1)                    |
| 7 | GPIO in 7   | PWM output   | RAM B CS (CS2, held high, unused) |


#### GPIO

| Register | Address     | Description                                                      |
| -------- | ----------- | ------------------------------------------------------------------ |
| GPIO_OUT | 0xF0 (R/W)  | Write sets `uo_out[6:0]`; read returns the last value written    |
| GPIO_IN  | 0xF1 (R)    | Reads the current state of `ui_in[7:0]`                          |
| GPIO_DIR | 0xF2 (R/W)  | Read/write register; not wired to anything (`ui_in`/`uo_out` are fixed-direction TT pins, so there's no direction to control) |

`uo_out[7]` is dedicated to the PWM output, not GPIO - a write of
`0xAA` to GPIO_OUT reads back as `0xAA` internally, but only
`uo_out[6:0]` (`0x2A` in that example) reaches a physical pin.

#### Timer

| Register    | Address     | Description                                                    |
| ----------- | ----------- | ---------------------------------------------------------------- |
| TIMER_LO    | 0xF8 (R)    | Bits 7:0 of the free-running 16-bit counter                    |
| TIMER_HI    | 0xF9 (R)    | Bits 15:8 of the counter                                       |
| TIMER_CTRL  | 0xFA (R/W)  | Bit 0 = enable (counts up once per clock while set). Writing bit 1 = 1 resets the counter to 0 |
| TIMER_FLAG  | 0xFB (R/W)  | Bit 0 = overflow (set when the counter wraps past 0xFFFF); any write clears it |

#### PWM

| Register  | Address     | Description                                                        |
| --------- | ----------- | ---------------------------------------------------------------------- |
| PWM_DUTY  | 0xFC (R/W)  | 8-bit duty cycle out of a free-running 256-cycle period. `0xFF` is a special-cased always-on |
| PWM_CTRL  | 0xFD (R/W)  | Bit 0 = enable. Output is forced low whenever disabled, regardless of PWM_DUTY |

## How to test

1. Program the test image onto the Pmod's flash chip (`test/imem.hex`,
   built by `test/build_prog.py` - exercises every opcode plus the GPIO,
   timer, and PWM registers) and leave the PSRAM chip's contents as-is;
   the program initializes any RAM it depends on.
2. Reset the design (`rst_n` low then high).
3. Run the clock. The CPU fetches from flash and reads/writes RAM over
   the shared SPI bus automatically - no host intervention needed once
   running.
4. Check final state against the golden reference model
   (`test/golden.py`) - `test/TESTING.md` and `test/TESTING_round2.md`
   document the expected register values, and the pipeline this was
   last verified against.

Before committing to a tapeout, the QSPI Pmod flash-read timing margin
(`read_delay_cfg` in `qspi_flash_reader.v` / `qspi_psram_ctrl.v`) is
worth validating on real hardware first, since interconnect delay isn't
visible in behavioral simulation - see the FPGA bring-up guide for the
Tiny Tapeout FPGA Development Kit + QSPI Pmod path used for that.

## External hardware

- [Tiny Tapeout QSPI Pmod](https://store.tinytapeout.com/products/QSPI-Pmod-p716541602),
  plugged into the demoboard's bidirectional Pmod header. One flash chip
  (program memory) and one of its two PSRAM chips (data memory) are
  used; the second PSRAM chip is unused.
- Tiny Tapeout demoboard, or the
  [FPGA Development Kit](https://store.tinytapeout.com/products/FPGA-Development-Kit-p813805747)
  for pre-tapeout bring-up on real silicon-adjacent hardware.


# Acknowledgments & Attribution

This file documents the open-source tools, process design kit, and prior
art that AbadMCU depends on or was inspired by. It's split into two
categories that are easy to conflate but legally distinct:

1. **Tools and IP actually incorporated into this design** - their
   licenses (all Apache-2.0) place real obligations on redistribution.
2. **Architectural inspiration from prior projects** - no code was
   copied from these; crediting them is good academic/community
   practice, not a license requirement, since taking inspiration from
   a *design pattern* (as opposed to copying source text) isn't a
   Copyright event.

---

## 1. Tools & IP incorporated into this design (Apache-2.0)

The physical chip (GDS) produced from this repository directly embeds
standard-cell layouts from, and was built using, the following
Apache-2.0-licensed projects. Their copyright notices are reproduced
below per Apache-2.0 \u00a74; none of them ship a separate `NOTICE` file as
of this writing (checked: skywater-pdk's repository root contains only
`LICENSE` and `AUTHORS`, no `NOTICE` - worth re-checking the others
listed here yourself before a formal release, since this wasn't
exhaustively verified for every entry.

### SkyWater SKY130 PDK
The standard-cell library design was synthesized and hardened
against.

```
Copyright 2020 SkyWater PDK Authors
Licensed under the Apache License, Version 2.0 (the "License");
may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```
Source: https://github.com/google/skywater-pdk

### open_pdks
PDK build/installer tooling used to assemble the sky130 PDK for the
hardening flow.

Source: https://github.com/fossi-foundation/open-pdks (Apache-2.0)

### OpenLane / OpenROAD
The RTL-to-GDS tool flow (synthesis, place & route, STA, DRC/LVS) that
produced this design's GDS.

```
OpenLane is \u00a92020-2024 Efabless Corporation and is available under
the Apache License, version 2.0.
```
Source: https://github.com/The-OpenROAD-Project/OpenLane

If citing academically:
> M. Shalan and T. Edwards, "Building OpenLANE: A 130nm OpenROAD-based
> Tapeout-Proven Flow," 2020 IEEE/ACM International Conference on
> Computer-Aided Design (ICCAD), San Diego, CA, USA, 2020, pp. 1-6.

### Tiny Tapeout project templates / tt-support-tools
The `tt_um_*` port convention, `info.yaml` schema, and CI/build
scaffolding this repo's structure follows.

Source: https://github.com/TinyTapeout (templates are Apache-2.0 by
default per Tiny Tapeout's own FAQ)

---

## 2. Architectural inspiration (no code reused)

AgilA8's central design decision - CPU with no on-chip memory,
program fetched from external QSPI flash, working data in external
QSPI PSRAM, sharing physical SPI wires between them via a separate chip
selects - follows the same strategic pattern pioneered on Tiny Tapeout
by the following projects. **No RTL, ISA encoding, or source code from
either project was copied** - AgilA8's CPU core, instruction set, and
peripheral RTL were independently designed and implemented. What's
credited here is the *architectural pattern*, not any specific
implementation of it.

### TinyQV (Michael Bell)
First (and to date, most complete) demonstration of this
flash+PSRAM-over-shared-QSPI-Pmod pattern on Tiny Tapeout, including
the specific convention of a single active chip-select and
code-execution-restricted-to-flash.

Source: https://github.com/MichaelBell/tinyQV (Apache-2.0)

### KianV (Hirosh Dabui / splinedrive)
Independent, earlier demonstration of the same external-memory-over-QSPI
pattern (both the uLinux and bare-metal editions), predating this
project.

Source: https://github.com/splinedrive/kianRiscV,
https://github.com/TinyTapeout/KianV-RV32IMA-RISC-V-uLinux-SoC
(check the repository's own LICENSE file directly before citing a
specific license - it wasn't confirmed via an explicit license badge
at the time this was written)

### RISC-V (conceptual influence only)
A8's `r0`-hardwired-to-zero convention and load/store architectural
style are modeled on RISC-V's design philosophy. RISC-V is an open,
freely usable ISA specification; no code is reused here, so this
carries no license obligation. **TT8 is not RISC-V-compliant** - it's
a custom 16-bit-instruction, 8-bit-datapath ISA in the RISC-V style,
and should not be described as a RISC-V implementation or use the
RISC-V trademark/logo.

---

## 3. What's original to this project

- The A8 instruction encoding (16-bit fixed-width, R-type/I-type
  split, the specific opcode table) is a custom design, not derived
  from any existing ISA's bit layout.
- All RTL in this repository (`a8_core.v`, `a8_alu.v`,
  `a8_regfile.v`, `a8_peripherals.v`, `qspi_flash_reader.v`,
  `qspi_psram_ctrl.v`, `tt_um_agila8.v`) was independently written for
  this project.
- The verification suite, bug fixes, and STA signoff analysis
  documented in this repository's history are this project's own work.

---

## Unverified claims to double-check before formal publication

- A code comment in `qspi_flash_reader.v` attributes a ~20ns round-trip
  timing margin figure to "TinyQV's own QSPI controller comments." This
  has not been independently confirmed against TinyQV's actual source -
  verify the exact figure and its origin before citing it as a
  TinyQV-derived fact.
- The Apache-2.0 NOTICE-file check above was only performed for
  skywater-pdk; confirm the other three Apache-2.0 entries (open_pdks,
  OpenLane, Tiny Tapeout templates) don't ship their own NOTICE files
  before finalizing this document, since if any of them do, its
  contents would need to be reproduced here per \u00a74(d).

