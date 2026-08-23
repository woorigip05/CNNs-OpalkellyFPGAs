// sim/xsim/tb_adder.sv -- native XSIM smoke test (ABACUS-15).
//
// cocotb has no XSIM backend (no Makefile.xsim shipped -- its VPI was never
// upstreamed), so this can't reuse tb/adder/test_adder.py. It exists to
// prove the vendor-simulator signoff path works *before* it's needed for
// something only XSIM can simulate (encrypted Opal Kelly IP, etc), not to
// duplicate the cocotb regression -- kept deliberately small.

`timescale 1ns / 1ps

module tb_adder;

    localparam int WIDTH = 8;
    localparam int CLK_PERIOD_NS = 10;

    logic             clk = 0;
    logic             rst_n;
    logic [WIDTH-1:0] a, b;
    logic [WIDTH:0]   sum;

    adder #(.WIDTH(WIDTH)) dut (.*);

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    int errors = 0;

    task automatic check_add(input logic [WIDTH-1:0] av, bv);
        a = av;
        b = bv;
        @(posedge clk);  // this edge captures a and b
        #1;              // let the NBA settle before sampling sum
        if (sum !== (11'(av) + 11'(bv))) begin
            $display("FAIL: %0d + %0d: expected %0d, got %0d", av, bv, av + bv, sum);
            errors++;
        end else begin
            $display("PASS: %0d + %0d = %0d", av, bv, sum);
        end
    endtask

    initial begin
        rst_n = 0;
        a = 0;
        b = 0;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        #1;
        if (sum !== '0) begin
            $display("FAIL: sum should be zero coming out of reset, got %0d", sum);
            errors++;
        end

        // Same directed cases as tb/adder/test_adder.py's directed test,
        // including the full-width carry-out case.
        check_add(8'd0, 8'd0);
        check_add(8'd1, 8'd1);
        check_add(8'd255, 8'd0);
        check_add(8'd255, 8'd255);
        check_add(8'd170, 8'd85);

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TEST(S) FAILED", errors);
            $fatal(1, "adder smoke test failed");
        end
        $finish;
    end

endmodule
