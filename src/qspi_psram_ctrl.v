`default_nettype none

// Single-line SPI read/write controller for one APS6404L (or compatible)
// PSRAM chip on the Tiny Tapeout QSPI Pmod, used as external DMEM so the
// on-chip design doesn't have to hold a 256-byte flip-flop array (which,
// per Tiny Tapeout's own memory guide, doesn't come close to fitting in
// a 1x2 tile budget - their RAM32 macro is *half* this size and needs
// 3x2 tiles on its own).
//
// Same reasoning as qspi_flash_reader.v applies here, so this mirrors
// its structure closely rather than inventing new protocol handling:
//   - plain single-SPI commands only (03h Read, 02h Write) - no QPI
//     setup sequence to get subtly wrong
//   - MISO sampled only at the end of an extended high phase
//     (HALF_PERIOD_CYCLES + read_delay_cfg), not on the edge that raises
//     SCK - the same round-trip-margin fix qspi_flash_reader.v needed.
//     Writes don't sample anything, so this only matters for reads, but
//     the timing structure is shared for one FSM instead of two.
//
// PSRAM writes are simpler than flash writes: no write-enable, no erase,
// no busy-poll - a write is just "opcode, 24-bit address (top 16 bits
// zero, since DMEM is only a 256-byte window), data", same shape as a
// read but with the last 8 bits driven out instead of sampled in, and
// no round-trip margin needed since nothing is being sampled.
//
// Uses a different chip select (CS1, "RAM A") from qspi_flash_reader's
// CS0, but the SAME physical SD0/SD1/SCK lines - see tt_um_agila8.v for
// how those get shared between this module and the flash reader. That
// sharing relies on a8_core never asserting imem_valid and dmem_valid
// in the same cycle (true today - S_FETCH_*/S_FETCH_GAP and S_MEM are
// separate, sequential FSM states - but would need real arbitration,
// not just a mux, if the core were ever changed to overlap accesses).

module qspi_psram_ctrl #(
    parameter HALF_PERIOD_CYCLES = 1,
    parameter DEFAULT_READ_DELAY = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    // a8_core-facing side (matches a8_core's dmem_* ports, minus the
    // peripheral window - that's still decoded/handled on-chip in
    // tt_um_agila8.v, only non-peripheral DMEM addresses reach here)
    input  wire [7:0]  addr,
    input  wire [7:0]  wdata,
    input  wire        we,
    input  wire        valid,
    output wire [7:0]  rdata,
    output wire         ready,

    input  wire [3:0]  read_delay_cfg,  // see qspi_flash_reader.v header

    // Pmod-facing side (shared bus - see header)
    output wire        cs_n,   // -> uio[6] (CS1 / RAM A)
    output wire        sck,
    output wire        mosi,
    input  wire        miso
);

    localparam S_IDLE = 2'd0;
    localparam S_XFER = 2'd1;
    localparam S_DONE = 2'd2;

    localparam CMD_READ  = 8'h03;
    localparam CMD_WRITE = 8'h02;

    reg [1:0]  state;
    reg [39:0] sh;          // read:  {03h, 16'h0000, addr, 8'h00-placeholder}
                             // write: {02h, 16'h0000, addr, wdata}
    reg [5:0]  bitcnt;       // 0..39 (8 cmd + 24 addr + 8 data)
    reg        phase;
    reg [19:0] div_cnt;
    reg [3:0]  read_delay_r;
    reg        we_r;         // latched op for this transaction

    reg        cs_n_r, sck_r, mosi_r, ready_r;
    reg        just_finished; // same valid/ready race guard as
                                // qspi_flash_reader.v - see that file's
                                // header for why this is needed.

    assign cs_n  = cs_n_r;
    assign sck   = sck_r;
    assign mosi  = mosi_r;
    assign ready = ready_r;
    assign rdata = sh[7:0];

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
            we_r          <= 1'b0;
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
                        we_r <= we;
                        // *** Bug fix (off-by-one bit shift) - see
                        // qspi_flash_reader.v's S_IDLE for the full
                        // explanation; same root cause, same fix: the
                        // shift register must be pre-shifted by one bit
                        // at load time to compensate for the hardcoded
                        // first-bit mosi_r assignment below, or every
                        // bit from the second one onward (including the
                        // whole address and data fields) ends up shifted
                        // by one position, and the true final bit never
                        // gets sent. Confirmed via bit-level simulation
                        // this was corrupting every PSRAM transaction.
                        sh   <= (we ? {CMD_WRITE, 16'h0000, addr, wdata}
                                    : {CMD_READ,  16'h0000, addr, 8'h00}) << 1;
                        // First bit is always the command byte's MSB.
                        // 02h and 03h share MSB=0 (8'b0000_0010 /
                        // 8'b0000_0011), so this is a known constant
                        // either way - same reasoning as
                        // qspi_flash_reader.v's S_IDLE.
                        mosi_r       <= 1'b0;
                        cs_n_r       <= 1'b0;
                        bitcnt       <= 6'd0;
                        phase        <= 1'b0;
                        read_delay_r <= read_delay_cfg;
                        state        <= S_XFER;
                    end
                end

                S_XFER: begin
                    if (!phase_done) begin
                        div_cnt <= div_cnt + 20'd1;
                    end else begin
                        div_cnt <= 20'd0;
                        if (!phase) begin
                            // Low phase elapsed - rising edge now. MOSI
                            // already stable since the previous falling
                            // edge; don't sample yet (that's the high
                            // phase's job, and only matters for reads).
                            sck_r <= 1'b1;
                            phase <= 1'b1;
                        end else begin
                            // High phase (HALF_PERIOD_CYCLES +
                            // read_delay_r) elapsed. For a read this is
                            // the settled sample point; for a write the
                            // captured miso bit is simply unused later.
                            // Either way, fall through to the next bit
                            // the same way: falling edge + set up the
                            // next MOSI bit from the pre-shift sh.
                            sh     <= {sh[38:0], miso};
                            mosi_r <= sh[39];
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
                    ready_r <= 1'b1;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
