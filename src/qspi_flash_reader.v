`default_nettype none

// Single-line SPI reader for a W25Q128JV (or any standard SPI-NOR flash
// that supports the universal 03h "Read Data" command) on the Tiny
// Tapeout QSPI Pmod (https://store.tinytapeout.com/products/QSPI-Pmod-p716541602).
//
// v3: configurable MISO sample delay.
// -----------------------------------------------------------------------
// Round-2 testing found that the previous version sampled MISO on the
// exact same registered edge that raised SCK - zero margin for the
// SCK-out -> board -> flash -> MISO-in round trip through the TT pin
// mux, which TinyQV's own QSPI controller comments put at "a little
// over 20ns". Behavioral simulation can't catch this (no interconnect
// delay modeled), so it would have shipped clean in sim and then failed
// on real silicon.
//
// Fix: SCK's high phase is now split into a base width
// (HALF_PERIOD_CYCLES, same meaning as before) plus READ_DELAY_CYCLES
// extra clk cycles during which SCK stays high but nothing is sampled
// yet. MISO is captured only on the *last* cycle of the high phase -
// i.e. READ_DELAY_CYCLES clk cycles after the edge that raised SCK, not
// on that edge itself. MOSI is unaffected: it's still set up once, on
// the falling edge that starts each bit's low phase, and held through
// that entire low phase - same setup-time margin as before, on the
// output side where TinyQV's number doesn't apply (that delay is
// specifically the input round trip).
//
// READ_DELAY_CYCLES is runtime-configurable via read_delay_cfg (latched
// once per transaction, at S_IDLE->S_XFER, so it can't glitch a
// transfer already in flight) rather than a fixed parameter - same
// reasoning as TinyQV's delay_cycles_cfg: a system clock you haven't
// taped out yet, board wiring you may not have measured, and "you only
// get one guess" once this is silicon. DEFAULT_READ_DELAY sets the
// reset value; tie read_delay_cfg to that same constant if you don't
// want it runtime-adjustable, or wire it to a spare register/pins if
// you do.
//
// Not addressed here (still true from v2, still deliberate): plain 03h
// only, no continuous-read/QPI - see the v2 header reasoning, unchanged.

module qspi_flash_reader #(
    parameter HALF_PERIOD_CYCLES = 1,   // >=1; base half-period, clk cycles
    parameter DEFAULT_READ_DELAY = 2    // reset value for read_delay_cfg;
                                          // extra clk cycles of margin
                                          // before MISO is sampled. 2
                                          // cycles @ 64MHz = ~31ns, with
                                          // real margin over the ~20ns
                                          // TinyQV measured for this
                                          // same pin path - don't shave
                                          // this down to "just barely
                                          // over" without your own
                                          // measurement.
) (
    input  wire        clk,
    input  wire        rst_n,

    // a8_core-facing side (matches a8_core's imem_* ports)
    input  wire [15:0] addr,
    input  wire        valid,
    output wire [7:0]  rdata,
    output wire         ready,

    // Runtime-tunable sample delay - see header. Latched at the start
    // of each transaction; changes apply to the *next* transfer.
    input  wire [3:0]  read_delay_cfg,

    // Pmod-facing side
    output wire        cs_n,   // -> uio[0]
    output wire        sck,    // -> uio[3]
    output wire        mosi,   // -> uio[1] (SD0)
    input  wire        miso    // <- uio[2] (SD1)
);

    localparam S_IDLE = 2'd0;
    localparam S_XFER = 2'd1;
    localparam S_DONE = 2'd2;

    reg [1:0]  state;
    reg [39:0] sh;          // {8'h03, 8'h00, addr[15:0]} shifting out,
                             // shifting miso in from the LSB end
    reg [5:0]  bitcnt;       // 0..39 (8 cmd + 24 addr + 8 data)
    reg        phase;        // 0 = low (MOSI drive/settle), 1 = high
                              // (SCK held high, settle + sample at end)
    reg [19:0] div_cnt;      // sub-bit clock divider (low or high phase)
    reg [3:0]  read_delay_r; // latched read_delay_cfg for this transfer

    reg        cs_n_r, sck_r, mosi_r, ready_r;

    // *** Bug fix carried over from round 2: valid/ready race with
    // a8_core. *** a8_core's imem_valid is a registered output - when
    // it sees `ready` pulse, it only *schedules* imem_valid<=0, not
    // visible until the following cycle. Without this guard, S_IDLE
    // would see `valid` still stale-high the cycle right after S_DONE
    // and launch a new transfer on the OLD addr, silently re-reading
    // the same byte instead of advancing. just_finished suppresses
    // `valid` for exactly that one cycle.
    reg        just_finished;

    assign cs_n  = cs_n_r;
    assign sck   = sck_r;
    assign mosi  = mosi_r;
    assign ready = ready_r;
    assign rdata = sh[7:0];

    // Low phase always lasts HALF_PERIOD_CYCLES. High phase lasts
    // HALF_PERIOD_CYCLES + read_delay_r, and MISO is captured only on
    // its last cycle - see header.
    wire [19:0] low_target   = HALF_PERIOD_CYCLES[19:0];
    wire [19:0] high_target  = HALF_PERIOD_CYCLES[19:0] + {16'd0, read_delay_r};
    wire [19:0] phase_target = phase ? high_target : low_target;
    wire        phase_done   = (div_cnt >= phase_target - 20'd1) || (phase_target <= 20'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            cs_n_r        <= 1'b1;
            sck_r         <= 1'b0;
            mosi_r        <= 1'b0;
            ready_r       <= 1'b0;
            bitcnt        <= 6'd0;
            phase         <= 1'b0;
            div_cnt       <= 20'd0;
            sh            <= 40'd0;
            just_finished <= 1'b0;
            read_delay_r  <= DEFAULT_READ_DELAY[3:0];
        end else begin
            ready_r       <= 1'b0;
            just_finished <= (state == S_DONE);

            case (state)
                S_IDLE: begin
                    cs_n_r  <= 1'b1;
                    sck_r   <= 1'b0;
                    div_cnt <= 20'd0;
                    if (valid && !just_finished) begin
                        // *** Bug fix (off-by-one bit shift): bit-index 0
                        // is sent from the hardcoded mosi_r<=0 below
                        // (valid since 0x03's MSB is always 0 - a known
                        // constant, not worth reading combinationally
                        // from sh in the same cycle it's loaded, which
                        // would race the load itself). But the shift
                        // register must be pre-shifted by that same one
                        // bit at load time to compensate, or the FIRST
                        // shift in S_XFER re-sends that already-sent MSB
                        // instead of advancing to the second real bit -
                        // and because every following bit inherits the
                        // same one-position offset, the entire rest of
                        // the transaction (every remaining address/data
                        // bit) ends up shifted by one, and the true final
                        // bit never gets sent at all (bitcnt still stops
                        // at 40 total bit-times, one of which was spent
                        // "twice" on the MSB). Confirmed via bit-level
                        // simulation: captured mosi sequence was exactly
                        // the intended sequence shifted right by one.
                        // Flash's 03h opcode masked this completely by
                        // coincidence (bit7=bit6=0, so resending bit7
                        // instead of advancing to bit6 was invisible) -
                        // PSRAM's WRITE opcode 02h (bit7=0, bit6=0,
                        // bit1=1) was where it first became visible.
                        sh           <= {8'h03, 8'h00, addr, 8'h00} << 1;
                        // First bit is opcode 0x03's MSB, which is
                        // always 0 (0x03 = 8'b0000_0011) - a known
                        // constant, not worth deriving from the sh
                        // we're loading this same cycle.
                        mosi_r       <= 1'b0;
                        cs_n_r       <= 1'b0;
                        bitcnt       <= 6'd0;
                        phase        <= 1'b0;
                        read_delay_r <= read_delay_cfg;  // latch for this xfer
                        state        <= S_XFER;
                    end
                end

                S_XFER: begin
                    if (!phase_done) begin
                        div_cnt <= div_cnt + 20'd1;
                    end else begin
                        div_cnt <= 20'd0;
                        if (!phase) begin
                            // Low phase (MOSI already stable, held
                            // since the previous falling edge) has
                            // lasted HALF_PERIOD_CYCLES - rising edge
                            // now. Don't touch MOSI here, and don't
                            // sample yet: that's the whole point of
                            // the high phase below.
                            sck_r <= 1'b1;
                            phase <= 1'b1;
                        end else begin
                            // High phase has lasted HALF_PERIOD_CYCLES
                            // + read_delay_r - the flash's MISO has
                            // had that whole time to propagate through
                            // the round trip and settle. Sample now,
                            // then falling edge + set up the *next*
                            // bit's MOSI so it's stable for the whole
                            // upcoming low phase.
                            sh     <= {sh[38:0], miso};
                            mosi_r <= sh[39];  // pre-shift sh - next bit
                            sck_r  <= 1'b0;
                            phase  <= 1'b0;
                            if (bitcnt == 6'd39) begin
                                state <= S_DONE;
                            end else begin
                                bitcnt <= bitcnt + 6'd1;
                            end
                        end
                    end
                end

                S_DONE: begin
                    cs_n_r  <= 1'b1;
                    sck_r   <= 1'b0;
                    ready_r <= 1'b1;   // 1-cycle pulse; rdata (=sh[7:0])
                                        // is already valid combinationally
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
