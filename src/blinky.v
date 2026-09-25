`timescale 1ns/1ps

module blinky #(
    parameter WIDTH = 26
)(
    input wire clk,
    input wire rst,
    output wire led
);

    reg [WIDTH-1:0] count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            count <= {WIDTH{1'b0}};
        end else begin
            count <= count + 1'b1;
        end
    end

    assign led = count[WIDTH-1];

endmodule
