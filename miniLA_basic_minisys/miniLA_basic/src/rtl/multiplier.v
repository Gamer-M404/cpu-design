`timescale 1ns / 1ps

module multiplier #(
    parameter WIDTH = 32
)(
    input  wire        clk,
	input  wire        rst,
	input  wire [WIDTH-1:0] x,
	input  wire [WIDTH-1:0] y,
	input  wire        start,
	output reg  [O_WID-1:0] z,
	output wire        busy 
);

	localparam O_WID = 2*WIDTH;

    // TODO
    
endmodule
