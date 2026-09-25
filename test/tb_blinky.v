`timescale 1ns/1ps

// Testbench for blinky.
//
// blinky is a clock divider: led is the top bit of a WIDTH-bit counter, so it
// should sit at each level for exactly 2**(WIDTH-1) clock cycles. WIDTH is
// reduced here so several full periods fit in a short simulation.
//
// The checks use $fatal, which makes the simulator exit non-zero. That is what
// turns a broken design into a failing `make sim` and a red CI run -- try
// changing src/blinky.v and watch this go red.

module tb_blinky;

    localparam integer WIDTH       = 4;
    localparam integer HALF_PERIOD = 1 << (WIDTH - 1); // cycles led holds a level
    localparam integer PERIODS     = 4;                // full periods to observe

    reg  clk = 0;
    reg  rst = 1;
    wire led;

    integer cycle;
    integer last_toggle;
    reg     led_prev;

    blinky #(.WIDTH(WIDTH)) uut (
        .clk (clk),
        .rst (rst),
        .led (led)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("build/wave.vcd");
        $dumpvars(0, tb_blinky);

        // Reset must hold the counter, and therefore led, at zero.
        repeat (2) @(posedge clk);
        #1;
        if (led !== 1'b0)
            $fatal(1, "led should be low while rst is asserted, got %b", led);

        // Release reset away from a rising edge.
        @(negedge clk);
        rst = 0;

        led_prev    = led;
        last_toggle = 0;

        // Every level must last exactly HALF_PERIOD cycles.
        for (cycle = 1; cycle <= PERIODS * 2 * HALF_PERIOD; cycle = cycle + 1) begin
            @(posedge clk);
            #1;
            if (led !== led_prev) begin
                if (cycle - last_toggle != HALF_PERIOD)
                    $fatal(1, "led held for %0d cycles at cycle %0d, expected %0d",
                           cycle - last_toggle, cycle, HALF_PERIOD);
                led_prev    = led;
                last_toggle = cycle;
            end
        end

        if (last_toggle == 0)
            $fatal(1, "led never toggled in %0d cycles", cycle - 1);

        $display("tb_blinky: PASS -- led toggled every %0d cycles", HALF_PERIOD);
        $finish;
    end

endmodule
