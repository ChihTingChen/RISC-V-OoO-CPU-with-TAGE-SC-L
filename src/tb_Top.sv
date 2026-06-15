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

    // ===== Performance counters (per-test) =====
    int test_cycles, test_active_cycles, test_inst_retired;
    int test_branches, test_mispredicts;
    int test_t0_cnt, test_t1_cnt, test_t2_cnt, test_t3_cnt;
    int test_lp_used, test_sc_used;

    // ===== Performance counters (cumulative across all tests) =====
    int total_cycles, total_active_cycles, total_inst_retired;
    int total_branches, total_mispredicts;
    int total_t0_cnt, total_t1_cnt, total_t2_cnt, total_t3_cnt;
    int total_lp_used, total_sc_used;

    // ===== Counter update (monitor DUT signals every clock) =====
    // 重要：resetn=0 時自動清 test counters，避免 task 用 blocking、
    //      always 用 NBA 互打架造成 race condition
    always @(posedge clk) begin
        if (!resetn) begin
            test_cycles        <= 0;
            test_active_cycles <= 0;
            test_inst_retired  <= 0;
            test_branches      <= 0;
            test_mispredicts   <= 0;
            test_t0_cnt        <= 0;
            test_t1_cnt        <= 0;
            test_t2_cnt        <= 0;
            test_t3_cnt        <= 0;
            test_lp_used       <= 0;
            test_sc_used       <= 0;
        end
        else begin
            test_cycles <= test_cycles + 1;
            if (dut.rob.retire_en) begin
                test_inst_retired  <= test_inst_retired + 1;
                test_active_cycles <= test_cycles + 1;   // 紀錄最後一次 retire 的 cycle
            end
            if (dut.rob.bpu_update_en) begin
                test_branches <= test_branches + 1;
                if (dut.rob.bpu_update_actual_taken != dut.rob.bpu_update_meta.pred_taken)
                    test_mispredicts <= test_mispredicts + 1;
                case (dut.rob.bpu_update_meta.provider)
                    2'b00: test_t0_cnt <= test_t0_cnt + 1;
                    2'b01: test_t1_cnt <= test_t1_cnt + 1;
                    2'b10: test_t2_cnt <= test_t2_cnt + 1;
                    2'b11: test_t3_cnt <= test_t3_cnt + 1;
                endcase
                if (dut.rob.bpu_update_meta.lp_used) test_lp_used <= test_lp_used + 1;
                if (dut.rob.bpu_update_meta.sc_used) test_sc_used <= test_sc_used + 1;
            end
        end
    end

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
        // 注意：test_cycles / test_inst_retired 等是由 always block 在 resetn=0
        //      時自動清零的（避免 race condition），不要在這裡手動清。
        resetn = 1'b0;
        repeat(3) @(posedge clk);
    endtask

    task finish_test();
        int ipc_x1000, acc_x10, mpki_x10;
        total_pass          = total_pass          + test_pass;
        total_fail          = total_fail          + test_fail;
        total_cycles        = total_cycles        + test_cycles;
        total_active_cycles = total_active_cycles + test_active_cycles;
        total_inst_retired  = total_inst_retired  + test_inst_retired;
        total_branches      = total_branches      + test_branches;
        total_mispredicts   = total_mispredicts   + test_mispredicts;
        total_t0_cnt        = total_t0_cnt        + test_t0_cnt;
        total_t1_cnt        = total_t1_cnt        + test_t1_cnt;
        total_t2_cnt        = total_t2_cnt        + test_t2_cnt;
        total_t3_cnt        = total_t3_cnt        + test_t3_cnt;
        total_lp_used       = total_lp_used       + test_lp_used;
        total_sc_used       = total_sc_used       + test_sc_used;

        $display("  Result: %0d PASS, %0d FAIL", test_pass, test_fail);
        if (test_active_cycles > 0) begin
            ipc_x1000 = (test_inst_retired * 1000) / test_active_cycles;
            $display("  [PERF] ActiveCycles=%0d  Inst=%0d  IPC=%0d.%03d  (excluding idle)",
                     test_active_cycles, test_inst_retired,
                     ipc_x1000/1000, ipc_x1000%1000);
        end
        if (test_branches > 0) begin
            acc_x10  = ((test_branches - test_mispredicts) * 1000) / test_branches;
            mpki_x10 = (test_inst_retired > 0)
                     ? (test_mispredicts * 10000) / test_inst_retired
                     : 0;
            $display("  [PERF] Branches=%0d  Mispredicts=%0d  Accuracy=%0d.%01d%%  MPKI=%0d.%01d",
                     test_branches, test_mispredicts,
                     acc_x10/10, acc_x10%10,
                     mpki_x10/10, mpki_x10%10);
            $display("  [PERF] Provider:  T0=%0d  T1=%0d  T2=%0d  T3=%0d",
                     test_t0_cnt, test_t1_cnt, test_t2_cnt, test_t3_cnt);
            $display("  [PERF] LP used=%0d  SC used=%0d  (overrides of TAGE)",
                     test_lp_used, test_sc_used);
        end
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
    // Test 10: BPU stress test — 100-iteration loop
    //   Same branch fires 100 times: 99 taken + 1 not-taken
    //   Designed to let TAGE warm-up + show prediction accuracy
    // ============================================================
    task run_test10();
        start_test("Test 10: BPU Stress (100-iter loop)");
        dut.imem.imem[0] = 32'h00000093;  // addi x1, x0, 0    ; x1 = 0
        dut.imem.imem[1] = 32'h06400113;  // addi x2, x0, 100  ; x2 = 100
        dut.imem.imem[2] = 32'h00108093;  // loop: addi x1, x1, 1
        dut.imem.imem[3] = 32'hFE209EE3;  // bne x1, x2, -4   ; loop while x1!=100
        fill_nop(4);
        resetn = 1'b1;
        @(posedge clk);
        repeat(1500) @(posedge clk);
        check_reg(1, 32'd100);
        check_reg(2, 32'd100);
        finish_test();
    endtask

    // ============================================================
    // Test 11: BPU pattern test — Alternating (period 2)
    //   Branch fires T, NT, T, NT, ... 60 times
    //   T0 alone gets ~50% (ctr oscillates around 0)
    //   T1 (h=4) should learn and provide near-100% accuracy after warm-up
    //   Expected: x4 = 30 (even count), x5 = 30 (odd count)
    // ============================================================
    task run_test11();
        start_test("Test 11: BPU Pattern - Alternating (period 2)");
        dut.imem.imem[0]  = 32'h00000093;  // addi x1, x0, 0       ; i = 0
        dut.imem.imem[1]  = 32'h03C00113;  // addi x2, x0, 60      ; N = 60
        dut.imem.imem[2]  = 32'h00000213;  // addi x4, x0, 0       ; even_count = 0
        dut.imem.imem[3]  = 32'h00000293;  // addi x5, x0, 0       ; odd_count  = 0
        // loop:
        dut.imem.imem[4]  = 32'h0010F193;  // andi x3, x1, 1       ; x3 = i & 1
        dut.imem.imem[5]  = 32'h00019663;  // bne  x3, x0, +12     ; if odd → jump to imem[8]
        dut.imem.imem[6]  = 32'h00120213;  // addi x4, x4, 1       ; even: x4++
        dut.imem.imem[7]  = 32'h00000463;  // beq  x0, x0, +8      ; jump to imem[9]
        dut.imem.imem[8]  = 32'h00128293;  // odd:  addi x5, x5, 1 ; odd: x5++
        dut.imem.imem[9]  = 32'h00108093;  // addi x1, x1, 1       ; i++
        dut.imem.imem[10] = 32'hFE2094E3;  // bne  x1, x2, -24     ; loop back to imem[4]
        fill_nop(11);
        resetn = 1'b1;
        @(posedge clk);
        repeat(5000) @(posedge clk);   // 大 budget：alternating 早期 mispredict 多
        check_reg(1, 32'd60);
        check_reg(2, 32'd60);
        check_reg(4, 32'd30);
        check_reg(5, 32'd30);
        finish_test();
    endtask

    // ============================================================
    // Test 12: BPU pattern test — 4-cycle (period 4)
    //   Branch fires NT NT NT T (i&3==3), repeated 16 times = 64 iters
    //   Expected: x4 = 48 (NT outcomes), x5 = 16 (T outcomes)
    //   T1 (h=4) should perfectly distinguish all 4 phases
    // ============================================================
    task run_test12();
        start_test("Test 12: BPU Pattern - 4-cycle (period 4)");
        dut.imem.imem[0]  = 32'h00000093;  // addi x1, x0, 0       ; i = 0
        dut.imem.imem[1]  = 32'h04000113;  // addi x2, x0, 64      ; N = 64
        dut.imem.imem[2]  = 32'h00000213;  // addi x4, x0, 0       ; NT_count = 0
        dut.imem.imem[3]  = 32'h00000293;  // addi x5, x0, 0       ; T_count  = 0
        dut.imem.imem[4]  = 32'h00300313;  // addi x6, x0, 3       ; mask = 3
        // loop:
        dut.imem.imem[5]  = 32'h0030F193;  // andi x3, x1, 3       ; x3 = i & 3
        dut.imem.imem[6]  = 32'h00618663;  // beq  x3, x6, +12     ; if x3==3 → jump
        dut.imem.imem[7]  = 32'h00120213;  // addi x4, x4, 1       ; NT path: x4++
        dut.imem.imem[8]  = 32'h00000463;  // beq  x0, x0, +8      ; jump to imem[10]
        dut.imem.imem[9]  = 32'h00128293;  // addi x5, x5, 1       ; T path: x5++
        dut.imem.imem[10] = 32'h00108093;  // addi x1, x1, 1       ; i++
        dut.imem.imem[11] = 32'hFE2094E3;  // bne  x1, x2, -24     ; loop back to imem[5]
        fill_nop(12);
        resetn = 1'b1;
        @(posedge clk);
        repeat(5000) @(posedge clk);   // 大 budget：4-cycle pattern warm-up 需要時間
        check_reg(1, 32'd64);
        check_reg(2, 32'd64);
        check_reg(4, 32'd48);
        check_reg(5, 32'd16);
        finish_test();
    endtask

    // ============================================================
    // Test 13: BPU pattern test — 16-cycle (period 16)
    //   Branch fires 15×NT 1×T, repeated 5 times = 80 iters
    //   Expected: x4 = 75 (NT), x5 = 5 (T)
    //   T2 (h=16) should be ideal — captures the full period
    //   T1 (h=4) NOT enough — period > history length
    // ============================================================
    task run_test13();
        start_test("Test 13: BPU Pattern - 16-cycle (period 16)");
        dut.imem.imem[0]  = 32'h00000093;  // addi x1, x0, 0       ; i = 0
        dut.imem.imem[1]  = 32'h05000113;  // addi x2, x0, 80      ; N = 80
        dut.imem.imem[2]  = 32'h00000213;  // addi x4, x0, 0       ; NT_count = 0
        dut.imem.imem[3]  = 32'h00000293;  // addi x5, x0, 0       ; T_count  = 0
        dut.imem.imem[4]  = 32'h00F00313;  // addi x6, x0, 15      ; mask = 15
        // loop:
        dut.imem.imem[5]  = 32'h00F0F193;  // andi x3, x1, 15      ; x3 = i & 15
        dut.imem.imem[6]  = 32'h00618663;  // beq  x3, x6, +12     ; if x3==15 → jump
        dut.imem.imem[7]  = 32'h00120213;  // addi x4, x4, 1       ; NT path: x4++
        dut.imem.imem[8]  = 32'h00000463;  // beq  x0, x0, +8      ; jump to imem[10]
        dut.imem.imem[9]  = 32'h00128293;  // addi x5, x5, 1       ; T path: x5++
        dut.imem.imem[10] = 32'h00108093;  // addi x1, x1, 1       ; i++
        dut.imem.imem[11] = 32'hFE2094E3;  // bne  x1, x2, -24     ; loop back to imem[5]
        fill_nop(12);
        resetn = 1'b1;
        @(posedge clk);
        repeat(3000) @(posedge clk);   // 加一點 budget 確保完成
        check_reg(1, 32'd80);
        check_reg(2, 32'd80);
        check_reg(4, 32'd75);
        check_reg(5, 32'd5);
        finish_test();
    endtask

    // ============================================================
    // Test 14: SC-friendly biased branch (no clear pattern, ~69% T)
    //   Branch outcome depends on (x3 += 17) & 31 < 22
    //   Low 5 bits cycle through 0-31 in period-32 sequence
    //   T0 saturates to T (because mostly T), but accuracy ~69%
    //   SC can use bias table to capture statistical偏向
    //
    //   Expected: x4 = 44 (T count), x5 = 20 (NT count), x1 = 64
    // ============================================================
    task run_test14();
        start_test("Test 14: SC-friendly (~69% biased branch)");
        dut.imem.imem[0]  = 32'h00000093;  // addi x1, x0, 0      ; i = 0
        dut.imem.imem[1]  = 32'h04000113;  // addi x2, x0, 64     ; N = 64
        dut.imem.imem[2]  = 32'h04900193;  // addi x3, x0, 73     ; seed
        dut.imem.imem[3]  = 32'h00000213;  // addi x4, x0, 0      ; T count
        dut.imem.imem[4]  = 32'h00000293;  // addi x5, x0, 0      ; NT count
        dut.imem.imem[5]  = 32'h01600493;  // addi x9, x0, 22     ; threshold
        // loop at imem[6]:
        dut.imem.imem[6]  = 32'h01118193;  // addi x3, x3, 17     ; x3 += 17
        dut.imem.imem[7]  = 32'h01F1F393;  // andi x7, x3, 31     ; x7 = x3 & 31
        dut.imem.imem[8]  = 32'h0093C663;  // blt  x7, x9, +12    ; if x7<22 → jump
        dut.imem.imem[9]  = 32'h00128293;  // addi x5, x5, 1      ; NT++
        dut.imem.imem[10] = 32'h00000463;  // beq  x0, x0, +8     ; jump cont
        dut.imem.imem[11] = 32'h00120213;  // addi x4, x4, 1      ; T++
        dut.imem.imem[12] = 32'h00108093;  // addi x1, x1, 1      ; i++
        dut.imem.imem[13] = 32'hFE2092E3;  // bne  x1, x2, -28    ; loop
        fill_nop(14);
        resetn = 1'b1;
        @(posedge clk);
        repeat(5000) @(posedge clk);
        check_reg(1, 32'd64);
        check_reg(2, 32'd64);
        check_reg(4, 32'd44);
        check_reg(5, 32'd20);
        finish_test();
    endtask

    // ============================================================
    // Main: run all 14 tests
    // ============================================================
    initial begin
        // Initial reset
        resetn = 1'b0;
        repeat(3) @(posedge clk);
        resetn = 1'b1;
        @(posedge clk);

        $display("\n##############################################");
        $display("#  OoO RV32I CPU - Full Regression (14 tests) #");
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
        run_test10();   // BPU stress test (100-iter loop, always-T)
        run_test11();   // BPU pattern: alternating period 2 (exercises T1)
        run_test12();   // BPU pattern: 4-cycle (exercises T1)
        run_test13();   // BPU pattern: 16-cycle (exercises T2)
        run_test14();   // SC-friendly: 69% biased branch (exercises SC)

        begin : overall_report
            int ipc_x1000, acc_x10, mpki_x10;
            $display("\n##############################################");
            $display("#            OVERALL CORRECTNESS             #");
            $display("##############################################");
            $display("  TOTAL PASS : %0d", total_pass);
            $display("  TOTAL FAIL : %0d", total_fail);
            if (total_fail == 0)
                $display("  >>>>>>>>>>  ALL TESTS PASSED  <<<<<<<<<<");
            else
                $display("  !!!!!!!!  %0d FAILURES DETECTED  !!!!!!!!", total_fail);

            $display("\n##############################################");
            $display("#          OVERALL PERFORMANCE (BPU)         #");
            $display("##############################################");
            $display("  Total Cycles (raw)  : %0d", total_cycles);
            $display("  Total Active Cycles : %0d  (idle excluded)", total_active_cycles);
            $display("  Total Instructions  : %0d", total_inst_retired);
            if (total_active_cycles > 0) begin
                ipc_x1000 = (total_inst_retired * 1000) / total_active_cycles;
                $display("  Active IPC          : %0d.%03d  (meaningful)",
                         ipc_x1000/1000, ipc_x1000%1000);
            end
            $display("  Total Branches      : %0d", total_branches);
            $display("  Total Mispredicts   : %0d", total_mispredicts);
            if (total_branches > 0) begin
                acc_x10  = ((total_branches - total_mispredicts) * 1000) / total_branches;
                mpki_x10 = (total_mispredicts * 10000) / total_inst_retired;
                $display("  Branch Accuracy     : %0d.%01d%%",
                         acc_x10/10, acc_x10%10);
                $display("  MPKI                : %0d.%01d",
                         mpki_x10/10, mpki_x10%10);
            end
            $display("  Provider distribution:");
            $display("    T0 (bimodal)      : %0d", total_t0_cnt);
            $display("    T1 (h=4)          : %0d", total_t1_cnt);
            $display("    T2 (h=16)         : %0d", total_t2_cnt);
            $display("    T3 (h=64)         : %0d", total_t3_cnt);
            $display("  SC-L override counts:");
            $display("    LP (Loop)         : %0d  (%0d%% of branches)",
                     total_lp_used,
                     (total_branches > 0) ? (total_lp_used * 100 / total_branches) : 0);
            $display("    SC (Statistical)  : %0d  (%0d%% of branches)",
                     total_sc_used,
                     (total_branches > 0) ? (total_sc_used * 100 / total_branches) : 0);
            $display("##############################################\n");
        end
        $finish;
    end

    // Timeout safety
    initial begin
        #500000;                       // 加大到 50K cycle 容納 Test 11/12 大 budget
        $display("TIMEOUT! CPU might be stuck.");
        $finish;
    end
endmodule
