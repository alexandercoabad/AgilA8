<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

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
