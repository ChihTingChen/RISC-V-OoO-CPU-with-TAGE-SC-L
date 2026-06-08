`timescale 1ns/1ps
module tb_Top;
    logic clk,resetn;
    Top dut(
        .clk(clk),
        .resetn(resetn)
    );
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        resetn = 1'b0;
        repeat(3) @(posedge clk);
        resetn = 1'b1;
        $display("resetn released, system start at %0t",$time);
        repeat(500) @(posedge clk);

        //start inspecting result
        $display("\n========== FIBONACCI TEST RESULTS ==========");
        check_reg(1, 32'd5);
        check_reg(2, 32'd10);
        check_reg(3, 32'd1);          // SLT TRUE
        check_reg(4, 32'd0);          // SLT FALSE
        check_reg(5, 32'hffffffff);   // -1
        check_reg(6, 32'd1);          // signed -1 < 5
        check_reg(7, 32'd1);          // SLTI TRUE
        check_reg(8, 32'd0);          // SLTI FALSE
        $display("============================================\n");

        $finish;
    end

    task check_reg(
        input int lgc_addr,
        input logic [31:0] expected
    );
        logic [5:0] phys_idx;
        logic [31:0] actual;
        phys_idx = dut.arat.arat_table[lgc_addr];
        actual = dut.prf.prf[phys_idx];
        if(actual === expected)
            $display("lgc_addr %0d = %0d,PASS",lgc_addr,actual);
        else
            $display("lgc_addr %0d: got %0d, expected %0d, FAIL",lgc_addr,actual,expected);

    endtask

    //timeout 防呆
    initial begin
        #50000;
        $display("TIMEOUT! CPU might be stuck.");
        $finish;
    end
endmodule