`timescale 1ns/1ps

// Gate-level testbench for blinky.
//
// This is not test/tb_blinky.v with a different file name. That testbench sets
// WIDTH to 4 so a full divider period fits in a handful of cycles -- and after
// synthesis there is no WIDTH left to set. The netlist is 26 flops wired
// together; its port list is (clk, led, rst) and nothing else. So the only way
// to watch led toggle is to actually run the divider, all 2**25 cycles of it.
//
// That costs about four minutes of wall clock -- 3:36 on a CI runner, 4:41 on
// an earlier probe -- which is why `make gatesim` is a separate target and CI
// runs it on pushes to main rather than on every pull request.
//
// The two constants below were measured on a real LibreLane netlist before
// they were written down. Writing `2**25` from first principles and letting a
// five-minute run discover the off-by-one is a bad trade.

module tb_blinky_gl;

    localparam integer CLK_PERIOD = 10;   // ns, matches CLOCK_PERIOD in config.yaml

    // From the first posedge after reset is released (count becomes 1 there),
    // led rises when count reaches 2**25 -- 33554431 cycles later -- and falls
    // when count wraps at 2**26, a further 33554432 cycles on.
    localparam integer FIRST_RISE = 33554431;
    localparam integer THEN_FALL  = 33554432;

    // A little over the 67108863 cycles the two edges need. Without this the
    // testbench does not fail when led never toggles, it hangs, and a hung job
    // burns the runner's whole timeout before saying anything.
    localparam integer CYCLE_CAP  = 70000000;

    reg  clk = 0;
    reg  rst = 1;
    wire led;

    time t_prev, t_now;
    integer elapsed;

    blinky uut (
        .clk (clk),
        .rst (rst),
        .led (led)
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    // One event scheduled far in the future, not a per-cycle check: this
    // testbench has to stay out of the way of a 67-million-cycle run.
    initial begin
        #(CLK_PERIOD * CYCLE_CAP);
        $fatal(1, "led did not toggle twice within %0d cycles", CYCLE_CAP);
    end

    initial begin
        // Reset must hold the counter, and therefore led, at zero.
        repeat (2) @(posedge clk);
        #1;
        if (led !== 1'b0)
            $fatal(1, "led should be low while rst is asserted, got %b", led);

        // Release reset away from a rising edge, then start counting from the
        // first edge that actually increments the counter.
        @(negedge clk);
        rst = 0;
        @(posedge clk);
        t_prev = $time;

        @(led);
        t_now   = $time;
        elapsed = (t_now - t_prev) / CLK_PERIOD;
        if (led !== 1'b1)
            $fatal(1, "first edge took led to %b, expected 1", led);
        if (elapsed != FIRST_RISE)
            $fatal(1, "led rose after %0d cycles, expected %0d", elapsed, FIRST_RISE);
        t_prev = t_now;

        @(led);
        t_now   = $time;
        elapsed = (t_now - t_prev) / CLK_PERIOD;
        if (led !== 1'b0)
            $fatal(1, "second edge took led to %b, expected 0", led);
        if (elapsed != THEN_FALL)
            $fatal(1, "led fell after %0d cycles, expected %0d", elapsed, THEN_FALL);

        $display("tb_blinky_gl: PASS -- gate-level led rose after %0d and fell after %0d cycles",
                 FIRST_RISE, THEN_FALL);
        $finish;
    end

endmodule
