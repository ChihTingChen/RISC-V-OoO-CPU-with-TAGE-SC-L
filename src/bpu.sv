import riscv_pkg::*;

// =============================================================================
// BPU (TAGE) — 4-table TAGE branch predictor
//   Scaled-down for FF-based synthesis (GPDK045 has no SRAM macro)
//
//   T0: bimodal, 128  × 2-bit (no tag, no u)            =  256 FF
//   T1: tagged,  32   × {tag[8],  ctr[3], u[2]} = 13b   =  416 FF
//   T2: tagged,  32   × {tag[10], ctr[3], u[2]} = 15b   =  480 FF
//   T3: tagged,  32   × {tag[12], ctr[3], u[2]} = 17b   =  544 FF
//   GHR: 64-bit global history (commit-time update)     =   64 FF
//   aging counter: 8-bit (fires every 256 commits)      =    8 FF
//                                                  ────────────
//                                              Total: ~1.77 K FF
//
//   Predict output uses predict_meta.pred_taken (no redundant port)
// =============================================================================
module bpu (
    input  logic        clk,
    input  logic        resetn,

    // ========== Predict interface (from fetch) ==========
    input  logic [31:0] predict_pc,         // 當前 PC
    output bpu_meta_t   predict_meta,       // 內含 pred_taken + idx/tag metadata

    // ========== Update interface (from ROB retire) ==========
    input  logic        update_en,          // conditional branch retire 時拉高
    input  logic        update_actual_taken,// 真實結果
    input  bpu_meta_t   update_meta         // 從 ROB 帶回來
);

    // =========================================================================
    // Storage 宣告
    // =========================================================================
    t0_entry_t t0_table [0:127];    // 128 × 2-bit
    t1_entry_t t1_table [0:31];     // 32  × 13-bit
    t2_entry_t t2_table [0:31];     // 32  × 15-bit
    t3_entry_t t3_table [0:31];     // 32  × 17-bit

    // Global History Register（commit-time update）
    logic [63:0] ghr;

    // Aging counter：每 256 commits → reset 所有 u counter
    // 縮小到 8-bit 讓 testbench 跑得到（256K 原版永遠不會 fire）
    logic [7:0]  aging_cnt;

    // =========================================================================
    // Saturating arithmetic helpers
    // =========================================================================
    // 2-bit unsigned (T0 ctr, all u counters)
    function automatic logic [1:0] sat_up_2(logic [1:0] x);
        return (x == 2'b11) ? 2'b11 : x + 1'b1;
    endfunction

    function automatic logic [1:0] sat_down_2(logic [1:0] x);
        return (x == 2'b00) ? 2'b00 : x - 1'b1;
    endfunction

    // 3-bit signed (T1/T2/T3 ctr)
    function automatic logic signed [2:0] sat_up_3s(logic signed [2:0] x);
        return (x == 3'sd3) ? 3'sd3 : x + 3'sd1;
    endfunction

    function automatic logic signed [2:0] sat_down_3s(logic signed [2:0] x);
        return (x == -3'sd4) ? -3'sd4 : x - 3'sd1;
    endfunction

    // =========================================================================
    // Predict path — Part A: index + tag computation (Step 4)
    // =========================================================================

    // ---- Folded history hashes ----
    // T2 needs: fold 16-bit GHR → 5-bit (idx) and → 10-bit (tag)
    // T3 needs: fold 64-bit GHR → 5-bit (idx) and → 12-bit (tag)
    logic [4:0]  folded_idx_t2;
    logic [9:0]  folded_tag_t2;
    logic [4:0]  folded_idx_t3;
    logic [11:0] folded_tag_t3;

    // T2: history is GHR[15:0]
    assign folded_idx_t2 = ghr[4:0] ^ ghr[9:5] ^ ghr[14:10] ^ {4'b0, ghr[15]};
    assign folded_tag_t2 = ghr[9:0] ^ {4'b0, ghr[15:10]};

    // T3: history is GHR[63:0], fold into 5-bit and 12-bit
    assign folded_idx_t3 = ghr[4:0]   ^ ghr[9:5]   ^ ghr[14:10] ^ ghr[19:15] ^ ghr[24:20]
                         ^ ghr[29:25] ^ ghr[34:30] ^ ghr[39:35] ^ ghr[44:40] ^ ghr[49:45]
                         ^ ghr[54:50] ^ ghr[59:55] ^ {1'b0, ghr[63:60]};
    assign folded_tag_t3 = ghr[11:0]  ^ ghr[23:12] ^ ghr[35:24] ^ ghr[47:36] ^ ghr[59:48]
                         ^ {8'b0, ghr[63:60]};

    // ---- Compute indices and tags ----
    logic [6:0]  idx0_w;
    logic [4:0]  idx1_w, idx2_w, idx3_w;
    logic [7:0]  tag1_w;
    logic [9:0]  tag2_w;
    logic [11:0] tag3_w;

    assign idx0_w = predict_pc[8:2];                       // T0: PC[8:2]
    assign idx1_w = predict_pc[6:2] ^ {1'b0, ghr[3:0]};    // T1: PC ⊕ GHR[3:0]
    assign idx2_w = predict_pc[6:2] ^ folded_idx_t2;       // T2: PC ⊕ fold5(GHR[15:0])
    assign idx3_w = predict_pc[6:2] ^ folded_idx_t3;       // T3: PC ⊕ fold5(GHR[63:0])

    assign tag1_w = predict_pc[14:7]  ^ {4'b0, ghr[3:0]};  // T1: PC高位 ⊕ GHR[3:0]
    assign tag2_w = predict_pc[19:10] ^ folded_tag_t2;     // T2: PC高位 ⊕ fold10
    assign tag3_w = predict_pc[23:12] ^ folded_tag_t3;     // T3: PC高位 ⊕ fold12

    // =========================================================================
    // Predict path — Part B: parallel lookup + provider selection (Step 5)
    // =========================================================================

    // ---- Parallel SRAM lookup ----
    t0_entry_t e0;
    t1_entry_t e1;
    t2_entry_t e2;
    t3_entry_t e3;
    assign e0 = t0_table[idx0_w];
    assign e1 = t1_table[idx1_w];
    assign e2 = t2_table[idx2_w];
    assign e3 = t3_table[idx3_w];

    // ---- Tag match detection ----
    logic t1_hit, t2_hit, t3_hit;
    assign t1_hit = (e1.tag == tag1_w);
    assign t2_hit = (e2.tag == tag2_w);
    assign t3_hit = (e3.tag == tag3_w);

    // ---- Provider / Alt selection (longest match wins) ----
    // provider/alt encoding: 00=T0, 01=T1, 10=T2, 11=T3
    logic [1:0] provider_w;
    logic [1:0] alt_w;
    logic       pred_w;

    always_comb begin
        // Default: T0 only (no tagged match)
        provider_w = 2'b00;
        alt_w      = 2'b00;

        // Priority: T3 > T2 > T1 > T0
        if (t3_hit) begin
            provider_w = 2'b11;
            if      (t2_hit) alt_w = 2'b10;
            else if (t1_hit) alt_w = 2'b01;
            else             alt_w = 2'b00;
        end
        else if (t2_hit) begin
            provider_w = 2'b10;
            if   (t1_hit) alt_w = 2'b01;
            else          alt_w = 2'b00;
        end
        else if (t1_hit) begin
            provider_w = 2'b01;
            alt_w      = 2'b00;
        end
        // else: provider = T0, alt = T0
    end

    // ---- Prediction: pick the sign of provider's counter ----
    always_comb begin
        unique case (provider_w)
            2'b00:   pred_w = e0.ctr[1];        // T0 bimodal: MSB of 2-bit ctr
            2'b01:   pred_w = (e1.ctr >= 0);    // T1: signed compare
            2'b10:   pred_w = (e2.ctr >= 0);    // T2
            2'b11:   pred_w = (e3.ctr >= 0);    // T3
            default: pred_w = 1'b0;
        endcase
    end

    // ---- Pack everything into predict_meta ----
    always_comb begin
        predict_meta            = '0;
        predict_meta.pred_taken = pred_w;
        predict_meta.provider   = provider_w;
        predict_meta.alt        = alt_w;
        predict_meta.idx0       = idx0_w;
        predict_meta.idx1       = idx1_w;
        predict_meta.idx2       = idx2_w;
        predict_meta.idx3       = idx3_w;
        predict_meta.tag1       = tag1_w;
        predict_meta.tag2       = tag2_w;
        predict_meta.tag3       = tag3_w;
    end

    // =========================================================================
    // Update path — combinational helpers (Step 6)
    // =========================================================================
    logic update_alt_pred;          // alt table 當下的預測
    logic update_provider_correct;  // provider 是否預測對
    logic update_pred_differ;       // provider 跟 alt 預測是否不同

    always_comb begin
        // 1. 算 alt table 當下的 prediction（從對應 table 拿 ctr 算 sign）
        unique case (update_meta.alt)
            2'b00:   update_alt_pred = t0_table[update_meta.idx0].ctr[1];
            2'b01:   update_alt_pred = (t1_table[update_meta.idx1].ctr >= 0);
            2'b10:   update_alt_pred = (t2_table[update_meta.idx2].ctr >= 0);
            2'b11:   update_alt_pred = (t3_table[update_meta.idx3].ctr >= 0);
            default: update_alt_pred = 1'b0;
        endcase

        // 2. provider 對不對
        update_provider_correct = (update_meta.pred_taken == update_actual_taken);

        // 3. provider 跟 alt 預測是否不同
        update_pred_differ      = (update_meta.pred_taken != update_alt_pred);
    end

    // =========================================================================
    // Update + Sequential（Step 6-8 才填）
    // =========================================================================
    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            for (int i = 0; i < 128; i++) t0_table[i] <= '0;
            for (int i = 0; i < 32;  i++) t1_table[i] <= '0;
            for (int i = 0; i < 32;  i++) t2_table[i] <= '0;
            for (int i = 0; i < 32;  i++) t3_table[i] <= '0;
            ghr        <= '0;
            aging_cnt  <= '0;
        end
        else if (update_en) begin
            // -------------------------------------------------------------
            // Step 8a: GHR shift (commit-time)
            //   把 actual_taken 從 LSB 塞進來，最舊 bit 擠掉
            // -------------------------------------------------------------
            ghr <= {ghr[62:0], update_actual_taken};

            // -------------------------------------------------------------
            // Step 8b: Aging - halve all u counters every 256 commits
            //   放在最前面，讓 Step 6b / 7 可以 override 特定 entry
            // -------------------------------------------------------------
            aging_cnt <= aging_cnt + 1'b1;     // 8-bit 自動 wrap (255→0)
            if (aging_cnt == 8'hFF) begin
                for (int i = 0; i < 32; i++) begin
                    t1_table[i].u <= t1_table[i].u >> 1;
                    t2_table[i].u <= t2_table[i].u >> 1;
                    t3_table[i].u <= t3_table[i].u >> 1;
                end
            end

            // -------------------------------------------------------------
            // Step 6a: Update provider's counter (saturate toward actual)
            // -------------------------------------------------------------
            unique case (update_meta.provider)
                2'b00:   t0_table[update_meta.idx0].ctr <= update_actual_taken
                                                       ? sat_up_2  (t0_table[update_meta.idx0].ctr)
                                                       : sat_down_2(t0_table[update_meta.idx0].ctr);
                2'b01:   t1_table[update_meta.idx1].ctr <= update_actual_taken
                                                       ? sat_up_3s  (t1_table[update_meta.idx1].ctr)
                                                       : sat_down_3s(t1_table[update_meta.idx1].ctr);
                2'b10:   t2_table[update_meta.idx2].ctr <= update_actual_taken
                                                       ? sat_up_3s  (t2_table[update_meta.idx2].ctr)
                                                       : sat_down_3s(t2_table[update_meta.idx2].ctr);
                2'b11:   t3_table[update_meta.idx3].ctr <= update_actual_taken
                                                       ? sat_up_3s  (t3_table[update_meta.idx3].ctr)
                                                       : sat_down_3s(t3_table[update_meta.idx3].ctr);
                default: ;
            endcase

            // -------------------------------------------------------------
            // Step 6b: Update provider's u counter
            //   Only when provider is tagged (T1/T2/T3) AND pred differs from alt
            // -------------------------------------------------------------
            if (update_pred_differ && update_meta.provider != 2'b00) begin
                unique case (update_meta.provider)
                    2'b01: t1_table[update_meta.idx1].u <= update_provider_correct
                                                       ? sat_up_2  (t1_table[update_meta.idx1].u)
                                                       : sat_down_2(t1_table[update_meta.idx1].u);
                    2'b10: t2_table[update_meta.idx2].u <= update_provider_correct
                                                       ? sat_up_2  (t2_table[update_meta.idx2].u)
                                                       : sat_down_2(t2_table[update_meta.idx2].u);
                    2'b11: t3_table[update_meta.idx3].u <= update_provider_correct
                                                       ? sat_up_2  (t3_table[update_meta.idx3].u)
                                                       : sat_down_2(t3_table[update_meta.idx3].u);
                    default: ;
                endcase
            end

            // -------------------------------------------------------------
            // Step 7: Allocation on misprediction
            //   Try to allocate a new entry in a "longer history than provider"
            //   table that has u==0 (replaceable).
            //   Priority: shortest "longer than provider" first.
            // -------------------------------------------------------------
            if (update_meta.pred_taken != update_actual_taken) begin
                unique case (update_meta.provider)
                    2'b00: begin  // provider = T0, try T1 → T2 → T3
                        if (t1_table[update_meta.idx1].u == 2'b00) begin
                            t1_table[update_meta.idx1].tag <= update_meta.tag1;
                            t1_table[update_meta.idx1].ctr <= update_actual_taken ? 3'sd0 : -3'sd1;
                            t1_table[update_meta.idx1].u   <= 2'b00;
                        end
                        else if (t2_table[update_meta.idx2].u == 2'b00) begin
                            t2_table[update_meta.idx2].tag <= update_meta.tag2;
                            t2_table[update_meta.idx2].ctr <= update_actual_taken ? 3'sd0 : -3'sd1;
                            t2_table[update_meta.idx2].u   <= 2'b00;
                        end
                        else if (t3_table[update_meta.idx3].u == 2'b00) begin
                            t3_table[update_meta.idx3].tag <= update_meta.tag3;
                            t3_table[update_meta.idx3].ctr <= update_actual_taken ? 3'sd0 : -3'sd1;
                            t3_table[update_meta.idx3].u   <= 2'b00;
                        end
                    end
                    2'b01: begin  // provider = T1, try T2 → T3
                        if (t2_table[update_meta.idx2].u == 2'b00) begin
                            t2_table[update_meta.idx2].tag <= update_meta.tag2;
                            t2_table[update_meta.idx2].ctr <= update_actual_taken ? 3'sd0 : -3'sd1;
                            t2_table[update_meta.idx2].u   <= 2'b00;
                        end
                        else if (t3_table[update_meta.idx3].u == 2'b00) begin
                            t3_table[update_meta.idx3].tag <= update_meta.tag3;
                            t3_table[update_meta.idx3].ctr <= update_actual_taken ? 3'sd0 : -3'sd1;
                            t3_table[update_meta.idx3].u   <= 2'b00;
                        end
                    end
                    2'b10: begin  // provider = T2, try T3 only
                        if (t3_table[update_meta.idx3].u == 2'b00) begin
                            t3_table[update_meta.idx3].tag <= update_meta.tag3;
                            t3_table[update_meta.idx3].ctr <= update_actual_taken ? 3'sd0 : -3'sd1;
                            t3_table[update_meta.idx3].u   <= 2'b00;
                        end
                    end
                    2'b11: ;     // provider = T3, no longer table → skip
                    default: ;
                endcase
            end

        end
    end

endmodule
