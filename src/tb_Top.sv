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

        $display("System start at %0t", $time);
        repeat(500) @(posedge clk);

        $display("\n========== JAL/JALR/AUIPC/UNSIGNED TEST ==========");
        check_reg(1,  32'd5);
        check_reg(2,  32'hFFFFFFFF);                 // -1
        check_reg(3,  32'd1);                        // SLTU 5 < 0xFFFFFFFF unsigned
        check_reg(4,  32'd1);                        // SLTIU 5 < 100 unsigned
        check_reg(5,  32'h10);                       // AUIPC at PC=0x10
        check_reg(6,  32'h18);                       // JAL rd = PC+4 = 0x14+4=0x18
        check_reg(7,  32'd0);                        // skipped
        check_reg(8,  32'd30);
        check_reg(9,  32'd0);                        // skipped (BLTU taken)
        check_reg(10, 32'd40);
        check_reg(11, 32'd0);                        // skipped (BGEU taken)
        check_reg(12, 32'd50);
        check_reg(13, 32'h44);                       // = 0x38 + 12 = 0x44
        check_reg(14, 32'h44);                       // JALR rd = PC+4 = 0x40+4 = 0x44
        check_reg(15, 32'd60);
        $display("==================================================\n");
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