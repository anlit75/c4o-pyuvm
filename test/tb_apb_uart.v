`timescale 1ns/1ps

// A directed test of the vendored DUT, over its own loopback.
//
// tx_o is tied to rx_i, so a byte written to THR has to come back out of RBR.
// That is the whole design in one path -- APB decode, the TX FIFO, the
// serialiser, the deserialiser, the RX FIFO -- and it needs no model of the bit
// timing here, because the DUT's own receiver does that job. A testbench that
// counted cycles to sample tx_o would be asserting the divisor arithmetic twice.
//
// `make cocotb` is where the interesting verification lives. This file is the
// smoke test: if it fails, nothing else is worth reading.

module tb_apb_uart;

    // 16550 register offsets, from the DUT's own parameter list.
    localparam THR = 3'h0;   // write: data,   read (RBR): data
    localparam DLL = 3'h0;   // when LCR[7] (DLAB) is set
    localparam DLM = 3'h1;   // when LCR[7] (DLAB) is set
    localparam FCR = 3'h2;
    localparam LCR = 3'h3;
    localparam LSR = 3'h5;

    localparam DIVISOR = 4;  // cycles per UART bit, minus one
    localparam BYTE    = 8'hA5;

    reg         CLK  = 1'b0;
    reg         RSTN = 1'b0;
    reg  [11:0] PADDR = 12'h0;
    reg  [31:0] PWDATA = 32'h0;
    reg         PWRITE = 1'b0;
    reg         PSEL = 1'b0;
    reg         PENABLE = 1'b0;
    wire [31:0] PRDATA;
    wire        PREADY;
    wire        PSLVERR;
    wire        serial;          // tx_o straight back into rx_i
    wire        event_o;

    integer     waited;
    reg  [31:0] got;

    always #5 CLK = ~CLK;

    apb_uart_sv dut (
        .CLK(CLK), .RSTN(RSTN),
        .PADDR(PADDR), .PWDATA(PWDATA), .PWRITE(PWRITE),
        .PSEL(PSEL), .PENABLE(PENABLE),
        .PRDATA(PRDATA), .PREADY(PREADY), .PSLVERR(PSLVERR),
        .rx_i(serial), .tx_o(serial),
        .event_o(event_o)
    );

    // One APB write. Setup then access, which is the whole protocol.
    task apb_write(input [2:0] adr, input [31:0] data);
        begin
            @(posedge CLK);
            PADDR   <= {9'b0, adr};
            PWDATA  <= data;
            PWRITE  <= 1'b1;
            PSEL    <= 1'b1;
            PENABLE <= 1'b0;
            @(posedge CLK);
            PENABLE <= 1'b1;
            @(posedge CLK);
            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
            PWRITE  <= 1'b0;
        end
    endtask

    task apb_read(input [2:0] adr, output [31:0] data);
        begin
            @(posedge CLK);
            PADDR   <= {9'b0, adr};
            PWRITE  <= 1'b0;
            PSEL    <= 1'b1;
            PENABLE <= 1'b0;
            @(posedge CLK);
            PENABLE <= 1'b1;
            @(posedge CLK);
            data     = PRDATA;
            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
        end
    endtask

    initial begin
        $dumpfile("build/tb_apb_uart.vcd");
        $dumpvars(0, tb_apb_uart);

        repeat (4) @(posedge CLK);
        RSTN = 1'b1;
        repeat (4) @(posedge CLK);

        // Divisor latches are only reachable with DLAB set, so LCR[7] first.
        apb_write(LCR, 32'h80);
        apb_write(DLL, DIVISOR);
        apb_write(DLM, 32'h00);
        // DLAB back off, and 8 data bits: LCR[1:0] = 2'b11.
        apb_write(LCR, 32'h03);
        // Clear both FIFOs so the run does not depend on their reset state.
        apb_write(FCR, 32'h06);

        apb_write(THR, BYTE);

        // A frame is ten bits of (DIVISOR+1) cycles. Waiting far longer than
        // that and then failing is the point: a hang would otherwise look like
        // a slow test rather than a broken one.
        waited = 0;
        got    = 32'h0;
        while (!got[0] && waited < 5000) begin
            apb_read(LSR, got);
            waited = waited + 1;
        end
        if (!got[0]) begin
            $display("FAIL: LSR[0] never went high -- no byte arrived after %0d reads", waited);
            $fatal(1);
        end

        apb_read(THR, got);   // RBR at the same offset
        if (got[7:0] !== BYTE) begin
            $display("FAIL: sent 0x%02h, received 0x%02h", BYTE, got[7:0]);
            $fatal(1);
        end

        $display("PASS: 0x%02h made the round trip in %0d LSR reads", BYTE, waited);
        $finish;
    end

    // Nothing here should take this long even on a slow divisor.
    initial begin
        #2_000_000;
        $display("FAIL: timed out");
        $fatal(1);
    end

endmodule
