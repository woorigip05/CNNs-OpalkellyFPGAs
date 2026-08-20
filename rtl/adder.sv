// adder.sv -- trivial registered adder, used to smoke-test the
// cocotb + Verilator toolchain loop (ABACUS-13).
//
// sum is WIDTH+1 bits so the carry out is captured rather than truncated.

`timescale 1ns / 1ps

module adder #(
    parameter int WIDTH = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] a,
    input  logic [WIDTH-1:0] b,
    output logic [WIDTH:0]   sum
);

    // Operands are zero-extended explicitly so Verilator doesn't emit a
    // WIDTHEXPAND warning (which is fatal by default in Verilator 5).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum <= '0;
        end else begin
            sum <= {1'b0, a} + {1'b0, b};
        end
    end

endmodule