`timescale 1ns/1ps
module tb_Top;
    logic clk, resetn;
    Top dut(
        .clk(clk),
        .resetn(resetn)
    );
    initial clk = 0;
    always #5 clk = ~clk;

    // ===== PASS/FAIL counters =====
    int total_pass = 0;
    int total_fail = 0;
    int test_pass  = 0;
    int test_fail  = 0;

    // ============================================================
    // Helper tasks
    // ============================================================
    task check_reg(input int lgc_addr, input logic [31:0] expected);
        logic [5:0] phys_idx;
        logic [31:0] actual;
        phys_idx = dut.arat.arat_table[lgc_addr];
        actual = dut.prf.prf[phys_idx];
        if(actual === expected) begin
            $display("  x%0d = %0d, PASS", lgc_addr, actual);
            test_pass = test_pass + 1;
        end
        else begin
            $display("  x%0d: got %0d, expected %0d, FAIL", lgc_addr, actual, expected);
            test_fail = test_fail + 1;
        end
    endtask

    task check_dmem(input int addr, input logic [31:0] expected);
        if (dut.dmem.dmem[addr] === expected) begin
            $display("  dmem[%0d] = %0d, PASS", addr, expected);
            test_pass = test_pass + 1;
        end
        else begin
            $display("  dmem[%0d]: got %0d, expected %0d, FAIL", addr, dut.dmem.dmem[addr], expected);
            test_fail = test_fail + 1;
        end
    endtask

    task start_test(input string name);
        $display("\n========== %s ==========", name);
        test_pass = 0;
        test_fail = 0;
        // Reset CPU
        resetn = 1'b0;
        repeat(3) @(posedge clk);
    endtask

    task finish_test();
        total_pass = total_pass + test_pass;
        total_fail = total_fail + test_fail;
        $display("  Result: %0d PASS, %0d FAIL", test_pass, test_fail);
    endtask

    task fill_nop(input int start);
        for (int i = start; i < 64; i++)
            dut.imem.imem[i] = 32'h00000013;
    endtask

    // ============================================================
    // Test 1: Basic ALU
    // ============================================================
    task run_test1();
        start_test("Test 1: Basic ALU Operations");
        dut.imem.imem[0]  = 32'h00A00093;  // addi x1, x0, 10
        dut.imem.imem[1]  = 32'h00300113;  // addi x2, x0, 3
        dut.imem.imem[2]  = 32'h002081B3;  // add  x3, x1, x2
        dut.imem.imem[3]  = 32'h40208233;  // sub  x4, x1, x2
        dut.imem.imem[4]  = 32'h0020F2B3;  // and  x5, x1, x2
        dut.imem.imem[5]  = 32'h0020E333;  // or   x6, x1, x2
        dut.imem.imem[6]  = 32'h0020C3B3;  // xor  x7, x1, x2
        dut.imem.imem[7]  = 32'h00209433;  // sll  x8, x1, x2
        dut.imem.imem[8]  = 32'h0020D4B3;  // srl  x9, x1, x2
        dut.imem.imem[9]  = 32'h00112533;  // slt  x10, x2, x1
        fill_nop(10);
        resetn = 1'b1;
        @(posedge clk);
        repeat(300) @(posedge clk);
        check_reg(1,  32'd10);
        check_reg(2,  32'd3);
        check_reg(3,  32'd13);
        check_reg(4,  32'd7);
        check_reg(5,  32'd2);
        check_reg(6,  32'd11);
        check_reg(7,  32'd9);
        check_reg(8,  32'd80);
        check_reg(9,  32'd1);
        check_reg(10, 32'd1);
        finish_test();
    endtask

    // ============================================================
    // Test 2: Fibonacci (10 iterations with BNE mispredict recovery)
    // ============================================================
    task run_test2();
        start_test("Test 2: Fibonacci (10 iterations, 9 mispredicts)");
        dut.imem.imem[0] = 32'h00100093;  // addi x1, x0, 1
        dut.imem.imem[1] = 32'h00100113;  // addi x2, x0, 1
        dut.imem.imem[2] = 32'h00A00193;  // addi x3, x0, 10
        dut.imem.imem[3] = 32'h00208233;  // loop: add x4, x1, x2
        dut.imem.imem[4] = 32'h00010093;  // addi x1, x2, 0
        dut.imem.imem[5] = 32'h00020113;  // addi x2, x4, 0
        dut.imem.imem[6] = 32'hFFF18193;  // addi x3, x3, -1
        dut.imem.imem[7] = 32'hFE0198E3;  // bne x3, x0, loop (-16)
        fill_nop(8);
        resetn = 1'b1;
        @(posedge clk);
        repeat(600) @(posedge clk);
        check_reg(1, 32'd89);
        check_reg(2, 32'd144);
        check_reg(3, 32'd0);
        check_reg(4, 32'd144);
        finish_test();
    endtask

    // ============================================================
    // Test 3: 4 signed branches (BEQ/BLT/BGE taken + BEQ not-taken)
    // ============================================================
    task run_test3();
        start_test("Test 3: All 4 Signed Branches");
        dut.imem.imem[0]  = 32'h00500093;
        dut.imem.imem[1]  = 32'h00500113;
        dut.imem.imem[2]  = 32'h00A00193;
        dut.imem.imem[3]  = 32'hFFD00213;
        dut.imem.imem[4]  = 32'h00000293;
        dut.imem.imem[5]  = 32'h00000313;
        dut.imem.imem[6]  = 32'h00000393;
        dut.imem.imem[7]  = 32'h00000413;
        dut.imem.imem[8]  = 32'h00208463;
        dut.imem.imem[9]  = 32'h06328293;
        dut.imem.imem[10] = 32'h00128293;
        dut.imem.imem[11] = 32'h00124463;
        dut.imem.imem[12] = 32'h06330313;
        dut.imem.imem[13] = 32'h00130313;
        dut.imem.imem[14] = 32'h0041D463;
        dut.imem.imem[15] = 32'h06338393;
        dut.imem.imem[16] = 32'h00138393;
        dut.imem.imem[17] = 32'h00308463;
        dut.imem.imem[18] = 32'h00140413;
        dut.imem.imem[19] = 32'h00A40413;
        fill_nop(20);
        resetn = 1'b1;
        @(posedge clk);
        repeat(500) @(posedge clk);
        check_reg(1, 32'd5);
        check_reg(2, 32'd5);
        check_reg(3, 32'd10);
        check_reg(4, 32'hFFFFFFFD);
        check_reg(5, 32'd1);
        check_reg(6, 32'd1);
        check_reg(7, 32'd1);
        check_reg(8, 32'd11);
        finish_test();
    endtask

    // ============================================================
    // Test 4: Unsigned compare + branch
    // ============================================================
    task run_test4();
        start_test("Test 4: Unsigned Compare & Branch");
        dut.imem.imem[0]  = 32'hFFF00093;  // addi x1, x0, -1
        dut.imem.imem[1]  = 32'h00100113;  // addi x2, x0, 1
        dut.imem.imem[2]  = 32'h0020B1B3;  // sltu x3, x1, x2
        dut.imem.imem[3]  = 32'h00113233;  // sltu x4, x2, x1
        dut.imem.imem[4]  = 32'h06413293;  // sltiu x5, x2, 100
        dut.imem.imem[5]  = 32'h00116463;  // bltu x2, x1, +8
        dut.imem.imem[6]  = 32'h06300313;  // addi x6, x0, 99 (SKIPPED)
        dut.imem.imem[7]  = 32'h04600393;  // addi x7, x0, 70
        dut.imem.imem[8]  = 32'h0020F463;  // bgeu x1, x2, +8
        dut.imem.imem[9]  = 32'h05800413;  // addi x8, x0, 88 (SKIPPED)
        dut.imem.imem[10] = 32'h05000493;  // addi x9, x0, 80
        fill_nop(11);
        resetn = 1'b1;
        @(posedge clk);
        repeat(400) @(posedge clk);
        check_reg(1, 32'hFFFFFFFF);
        check_reg(2, 32'd1);
        check_reg(3, 32'd0);
        check_reg(4, 32'd1);
        check_reg(5, 32'd1);
        check_reg(6, 32'd0);
        check_reg(7, 32'd70);
        check_reg(8, 32'd0);
        check_reg(9, 32'd80);
        finish_test();
    endtask

    // ============================================================
    // Test 5: JAL / JALR / AUIPC
    // ============================================================
    task run_test5();
        start_test("Test 5: Jump and Link Instructions");
        dut.imem.imem[0]  = 32'h00500093;  // addi x1, x0, 5
        dut.imem.imem[1]  = 32'h0080016F;  // jal x2, +8
        dut.imem.imem[2]  = 32'h06300193;  // addi x3, x0, 99 (SKIP)
        dut.imem.imem[3]  = 32'h00A00213;  // addi x4, x0, 10
        dut.imem.imem[4]  = 32'h00000297;  // auipc x5, 0
        dut.imem.imem[5]  = 32'h00C28293;  // addi x5, x5, 12
        dut.imem.imem[6]  = 32'h00028367;  // jalr x6, x5, 0
        dut.imem.imem[7]  = 32'h01400393;  // addi x7, x0, 20
        dut.imem.imem[8]  = 32'h0080046F;  // jal x8, +8
        dut.imem.imem[9]  = 32'h06300493;  // addi x9, x0, 99 (SKIP)
        dut.imem.imem[10] = 32'h01E00513;  // addi x10, x0, 30
        fill_nop(11);
        resetn = 1'b1;
        @(posedge clk);
        repeat(400) @(posedge clk);
        check_reg(1,  32'd5);
        check_reg(2,  32'h08);
        check_reg(3,  32'd0);
        check_reg(4,  32'd10);
        check_reg(5,  32'h1C);
        check_reg(6,  32'h1C);
        check_reg(7,  32'd20);
        check_reg(8,  32'h24);
        check_reg(9,  32'd0);
        check_reg(10, 32'd30);
        finish_test();
    endtask

    // ============================================================
    // Test 6: LW from preloaded dmem
    // ============================================================
    task run_test6();
        start_test("Test 6: LW from Pre-loaded dmem");
        dut.imem.imem[0] = 32'h02800093;  // addi x1, x0, 40
        dut.imem.imem[1] = 32'h0000A103;  // lw x2, 0(x1)
        fill_nop(2);
        resetn = 1'b1;
        @(posedge clk);
        // Backdoor-load dmem AFTER reset release (NBA race avoidance)
        dut.dmem.dmem[10] = 32'h12345678;
        repeat(300) @(posedge clk);
        check_reg(1, 32'd40);
        check_reg(2, 32'h12345678);
        finish_test();
    endtask

    // ============================================================
    // Test 7: SW to dmem
    // ============================================================
    task run_test7();
        start_test("Test 7: SW Store to dmem");
        dut.imem.imem[0] = 32'h02800093;  // addi x1, x0, 40
        dut.imem.imem[1] = 32'h06400113;  // addi x2, x0, 100
        dut.imem.imem[2] = 32'h0020A023;  // sw x2, 0(x1)
        fill_nop(3);
        resetn = 1'b1;
        @(posedge clk);
        repeat(300) @(posedge clk);
        check_reg(1, 32'd40);
        check_reg(2, 32'd100);
        check_dmem(10, 32'd100);
        finish_test();
    endtask

    // ============================================================
    // Test 8: Store-to-Load Forwarding
    // ============================================================
    task run_test8();
        start_test("Test 8: Store-to-Load Forwarding");
        dut.imem.imem[0] = 32'h02800093;  // addi x1, x0, 40
        dut.imem.imem[1] = 32'h06400113;  // addi x2, x0, 100
        dut.imem.imem[2] = 32'h0020A023;  // sw x2, 0(x1)
        dut.imem.imem[3] = 32'h0000A183;  // lw x3, 0(x1)
        fill_nop(4);
        resetn = 1'b1;
        @(posedge clk);
        repeat(300) @(posedge clk);
        check_reg(1, 32'd40);
        check_reg(2, 32'd100);
        check_reg(3, 32'd100);
        check_dmem(10, 32'd100);
        finish_test();
    endtask

    // ============================================================
    // Test 9: Multi-Store Forward LATEST
    // ============================================================
    task run_test9();
        start_test("Test 9: Multi-Store Forward LATEST");
        dut.imem.imem[0] = 32'h02800093;  // addi x1, x0, 40
        dut.imem.imem[1] = 32'h06400113;  // addi x2, x0, 100
        dut.imem.imem[2] = 32'h0C800193;  // addi x3, x0, 200
        dut.imem.imem[3] = 32'h12C00213;  // addi x4, x0, 300
        dut.imem.imem[4] = 32'h0020A023;  // sw x2, 0(x1)
        dut.imem.imem[5] = 32'h0030A023;  // sw x3, 0(x1)
        dut.imem.imem[6] = 32'h0040A023;  // sw x4, 0(x1)
        dut.imem.imem[7] = 32'h0000A283;  // lw x5, 0(x1)
        fill_nop(8);
        resetn = 1'b1;
        @(posedge clk);
        repeat(400) @(posedge clk);
        check_reg(1, 32'd40);
        check_reg(2, 32'd100);
        check_reg(3, 32'd200);
        check_reg(4, 32'd300);
        check_reg(5, 32'd300);
        check_dmem(10, 32'd300);
        finish_test();
    endtask

    // ============================================================
    // Main: run all 9 tests
    // ============================================================
    initial begin
        // Initial reset
        resetn = 1'b0;
        repeat(3) @(posedge clk);
        resetn = 1'b1;
        @(posedge clk);

        $display("\n##############################################");
        $display("#  OoO RV32I CPU - Full Regression (9 tests) #");
        $display("##############################################");

        run_test1();
        run_test2();
        run_test3();
        run_test4();
        run_test5();
        run_test6();
        run_test7();
        run_test8();
        run_test9();

        $display("\n##############################################");
        $display("#               OVERALL SUMMARY              #");
        $display("##############################################");
        $display("  TOTAL PASS : %0d", total_pass);
        $display("  TOTAL FAIL : %0d", total_fail);
        if (total_fail == 0)
            $display("  >>>>>>>>>>  ALL TESTS PASSED  <<<<<<<<<<");
        else
            $display("  !!!!!!!!  %0d FAILURES DETECTED  !!!!!!!!", total_fail);
        $display("##############################################\n");
        $finish;
    end

    // Timeout safety
    initial begin
        #200000;
        $display("TIMEOUT! CPU might be stuck.");
        $finish;
    end
endmodule
