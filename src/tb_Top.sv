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
        @(posedge clk);  // 等一個 cycle 讓 resetn 完全生效

        // 預載 dmem：byte addr 0x28 (index 10) = 0xDEADBEEF
        dut.dmem.dmem[10] = 32'hDEADBEEF;
        $display("Loaded dmem[10] = %h", dut.dmem.dmem[10]);

        $display("System start at %0t", $time);
        repeat(500) @(posedge clk);

        $display("\n========== LW TEST RESULTS ==========");
        check_reg(1, 32'd40);         // x1 = 40 (= 0x28)
        check_reg(2, 32'hDEADBEEF);   // x2 = mem[0x28] = 0xDEADBEEF
        $display("======================================\n");
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