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

        // ============================================================
        // Test 9: Multi-Store Forward LATEST  ⭐⭐⭐ FORWARDING EDGE CASE
        // 程式：
        //   addi x1, x0, 40
        //   addi x2, x0, 100
        //   addi x3, x0, 200
        //   addi x4, x0, 300
        //   sw   x2, 0(x1)        # mem[40] = 100 (oldest SW)
        //   sw   x3, 0(x1)        # mem[40] = 200 (middle SW)
        //   sw   x4, 0(x1)        # mem[40] = 300 (newest SW)
        //   lw   x5, 0(x1)        # x5 = ?
        //
        // 關鍵：3 個 SW 寫同一個 addr。LW 該拿哪個值？
        //   - 程式語意：應該拿「最新的 older SW」= 300（最後寫的）
        //   - 簡單實作可能拿錯（拿到 100 或 200）
        //
        // LSQ forwarding 邏輯要會：
        //   1. 掃所有 older SW
        //   2. 過濾 addr 相同的
        //   3. 挑「age 最大」（最年輕但仍 < LW age）的那個 SW
        //   4. 拿它的 data
        //
        // 驗證：x5 = 300（最新）
        //       dmem[10] 最終也 = 300（3 個 SW 依序 retire，最後寫 300）
        // ============================================================
        $display("\n========== Test 9: Multi-Store Forward LATEST ==========");
        check_reg(1, 32'd40);          // x1 = 40
        check_reg(2, 32'd100);         // x2 = 100
        check_reg(3, 32'd200);         // x3 = 200
        check_reg(4, 32'd300);         // x4 = 300
        check_reg(5, 32'd300);         // x5 = LATEST forwarded = 300
        $display("dmem[10] = %0d (expected 300 after all SW retire)", dut.dmem.dmem[10]);
        if (dut.dmem.dmem[10] === 32'd300)
            $display("dmem[10] PASS (final SW won)");
        else
            $display("dmem[10] FAIL: got %0d", dut.dmem.dmem[10]);
        $display("=========================================================\n");
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