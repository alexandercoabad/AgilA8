`default_nettype none

module tt_um_agila8 (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    //------------------------------------------------------------------
    // Unused
    //------------------------------------------------------------------

    wire _unused_ena = ena;

    //------------------------------------------------------------------
    // CPU <-> Memory Interface
    //------------------------------------------------------------------

    wire [15:0] imem_addr;
    wire        imem_valid;
    wire [7:0]  imem_rdata;
    wire        imem_ready;

    wire [7:0]  dmem_addr;
    wire [7:0]  dmem_wdata;
    wire        dmem_we;
    wire        dmem_valid;
    wire [7:0]  dmem_rdata;
    wire        dmem_ready;

    wire halted;

    a8_core core (
        .clk        (clk),
        .rst_n      (rst_n),

        .imem_addr  (imem_addr),
        .imem_valid (imem_valid),
        .imem_rdata (imem_rdata),
        .imem_ready (imem_ready),

        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_we    (dmem_we),
        .dmem_valid (dmem_valid),
        .dmem_rdata (dmem_rdata),
        .dmem_ready (dmem_ready),

        .halted     (halted)
    );

    //------------------------------------------------------------------
    // QSPI Flash Instruction Memory
    //------------------------------------------------------------------

    wire flash_cs_n;
    wire flash_sck;
    wire flash_mosi;

    qspi_flash_reader #(
        .HALF_PERIOD_CYCLES(1),
        .DEFAULT_READ_DELAY(2)
    ) flash (
        .clk            (clk),
        .rst_n          (rst_n),
        .addr           (imem_addr),
        .valid          (imem_valid),
        .rdata          (imem_rdata),
        .ready          (imem_ready),
        .read_delay_cfg (4'd2),
        .cs_n           (flash_cs_n),
        .sck            (flash_sck),
        .mosi           (flash_mosi),
        .miso           (spi_miso_shared)
    );

    //------------------------------------------------------------------
    // Peripheral Decode
    //------------------------------------------------------------------

    wire periph_hit_comb =
           (dmem_addr == 8'hF0)
        || (dmem_addr == 8'hF1)
        || (dmem_addr == 8'hF2)
        || (dmem_addr == 8'hF8)
        || (dmem_addr == 8'hF9)
        || (dmem_addr == 8'hFA)
        || (dmem_addr == 8'hFB)
        || (dmem_addr == 8'hFC)
        || (dmem_addr == 8'hFD);

    //------------------------------------------------------------------
    // Data RAM - external PSRAM (RAM A / CS1) over the same QSPI Pmod,
    // instead of an on-chip 256-byte flip-flop array. See qspi_psram_ctrl.v
    // header: a plain flip-flop DMEM this size doesn't fit a 1x2 tile
    // budget (Tiny Tapeout's own RAM32 macro is half this size and needs
    // 3x2 tiles on its own), so DMEM moves off-chip the same way IMEM
    // already did.
    //------------------------------------------------------------------

    wire        psram_cs_n, psram_sck, psram_mosi;
    wire [7:0]  ram_rdata_r;
    wire        ram_ready_r;

    qspi_psram_ctrl #(
        .HALF_PERIOD_CYCLES(1),
        .DEFAULT_READ_DELAY(2)
    ) psram (
        .clk            (clk),
        .rst_n          (rst_n),
        .addr           (dmem_addr),
        .wdata          (dmem_wdata),
        .we             (dmem_we),
        .valid          (dmem_valid && !periph_hit_comb),
        .rdata          (ram_rdata_r),
        .ready          (ram_ready_r),
        .read_delay_cfg (4'd2),
        .cs_n           (psram_cs_n),
        .sck            (psram_sck),
        .mosi           (psram_mosi),
        .miso           (spi_miso_shared)
    );

    //------------------------------------------------------------------
    // Shared SPI bus (SD0/SD1/SCK) between the flash reader (CS0) and
    // the PSRAM controller (CS1). Safe as a plain priority mux - not
    // real arbitration - only because a8_core never asserts imem_valid
    // and dmem_valid in the same cycle (S_FETCH_*/S_FETCH_GAP vs S_MEM
    // are separate, sequential FSM states in a8_core.v). If the core
    // is ever pipelined or otherwise changed to overlap fetch and
    // memory access, this mux would silently corrupt whichever request
    // loses priority - it would need real arbitration at that point,
    // not just this mux.
    //------------------------------------------------------------------

    wire flash_active = !flash_cs_n;
    wire spi_sck_shared  = flash_active ? flash_sck  : psram_sck;
    wire spi_mosi_shared = flash_active ? flash_mosi : psram_mosi;
    wire spi_miso_shared = uio_in[2];

    //------------------------------------------------------------------
    // Peripheral Block
    //------------------------------------------------------------------

    wire [7:0] periph_rdata;
    wire       periph_ready;
    wire       periph_hit;

    wire [7:0] gpio_out_w;
    wire [7:0] gpio_dir_w;

    wire       pwm_out_w;

    a8_peripherals periph (
        .clk      (clk),
        .rst_n    (rst_n),

        .addr     (dmem_addr),
        .wdata    (dmem_wdata),
        .we       (dmem_we),
        .valid    (dmem_valid && periph_hit_comb),

        .rdata    (periph_rdata),
        .ready    (periph_ready),
        .hit      (periph_hit),

        .gpio_in  (ui_in),
        .gpio_out (gpio_out_w),
        .gpio_dir (gpio_dir_w),

        .pwm_out  (pwm_out_w)
    );

    //------------------------------------------------------------------
    // DMEM Mux
    //------------------------------------------------------------------

    assign dmem_ready =
        periph_hit_comb ? periph_ready : ram_ready_r;

    assign dmem_rdata =
        periph_hit_comb ? periph_rdata : ram_rdata_r;

    //------------------------------------------------------------------
    // Outputs
    //------------------------------------------------------------------

    // GPIO outputs
    assign uo_out[6:0] = gpio_out_w[6:0];

    // PWM output
    assign uo_out[7] = pwm_out_w;

    //------------------------------------------------------------------
    // QSPI PMOD
    //
    // uio[7:0] =
    // {CS2, CS1, SD3, SD2, SCK, SD1, SD0, CS0}
    //------------------------------------------------------------------

    assign uio_out = {
        1'b1,              // CS2 (RAM B - unused, deselected)
        psram_cs_n,        // CS1 (RAM A - DMEM)
        1'b1,              // SD3
        1'b1,              // SD2
        spi_sck_shared,    // SCK
        1'b0,              // SD1 (input)
        spi_mosi_shared,   // SD0
        flash_cs_n         // CS0
    };

    assign uio_oe = 8'b1111_1011;

    //------------------------------------------------------------------
    // Unused warning suppression
    //------------------------------------------------------------------

    wire _unused_periph =
        &{1'b0, periph_hit, gpio_dir_w};

endmodule
