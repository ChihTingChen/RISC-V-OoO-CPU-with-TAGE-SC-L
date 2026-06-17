import riscv_pkg::*;

module bpu (
    input  logic        clk,
    input  logic        resetn,

    input  logic [31:0] predict_pc,
    output bpu_meta_t   predict_meta,

    input  logic        update_en,
    input  logic        update_actual_taken,
    input  bpu_meta_t   update_meta
);

    // =========================================================================
    // Storage: TAGE base
    // =========================================================================
    t0_entry_t t0_table [0:127];
    t1_entry_t t1_table [0:31];
    t2_entry_t t2_table [0:31];
    t3_entry_t t3_table [0:31];

    logic [63:0] ghr;
    logic [7:0]  aging_cnt;

    // =========================================================================
    // Storage: Loop Predictor (8 entries)
    // =========================================================================
    typedef struct packed {
        logic        valid;
        logic [9:0]  tag;           
        logic [9:0]  cur_iter;      
        logic [9:0]  conf_iter;     
        logic [1:0]  conf;          
    } lp_entry_t;
    lp_entry_t lp_table [0:7];

    // =========================================================================
    // Storage: Statistical Corrector (3 tables × 16 entries × 6-bit signed)
    // =========================================================================
    logic signed [5:0] sc_ghist [0:15];
    logic signed [5:0] sc_path  [0:15];
    logic signed [5:0] sc_bias  [0:15];

    logic [15:0] path_hist;

    // =========================================================================
    // Saturating helpers (existing)
    // =========================================================================
    function automatic logic [1:0] sat_up_2(logic [1:0] x);
        return (x == 2'b11) ? 2'b11 : x + 1'b1;
    endfunction
    function automatic logic [1:0] sat_down_2(logic [1:0] x);
        return (x == 2'b00) ? 2'b00 : x - 1'b1;
    endfunction
    function automatic logic signed [2:0] sat_up_3s(logic signed [2:0] x);
        return (x == 3'sd3) ? 3'sd3 : x + 3'sd1;
    endfunction
    function automatic logic signed [2:0] sat_down_3s(logic signed [2:0] x);
        return (x == -3'sd4) ? -3'sd4 : x - 3'sd1;
    endfunction

    function automatic logic signed [5:0] sat_up_6s(logic signed [5:0] x);
        return (x == 6'sd31) ? 6'sd31 : x + 6'sd1;
    endfunction
    function automatic logic signed [5:0] sat_down_6s(logic signed [5:0] x);
        return (x == -6'sd32) ? -6'sd32 : x - 6'sd1;
    endfunction

    function automatic logic [9:0] sat_up_10(logic [9:0] x);
        return (x == 10'h3FF) ? 10'h3FF : x + 10'd1;
    endfunction

    // =========================================================================
    // TAGE predict path (same as before)
    // =========================================================================
    logic [4:0]  folded_idx_t2;
    logic [9:0]  folded_tag_t2;
    logic [4:0]  folded_idx_t3;
    logic [11:0] folded_tag_t3;

    assign folded_idx_t2 = ghr[4:0] ^ ghr[9:5] ^ ghr[14:10] ^ {4'b0, ghr[15]};
    assign folded_tag_t2 = ghr[9:0] ^ {4'b0, ghr[15:10]};
    assign folded_idx_t3 = ghr[4:0]   ^ ghr[9:5]   ^ ghr[14:10] ^ ghr[19:15] ^ ghr[24:20]
                         ^ ghr[29:25] ^ ghr[34:30] ^ ghr[39:35] ^ ghr[44:40] ^ ghr[49:45]
                         ^ ghr[54:50] ^ ghr[59:55] ^ {1'b0, ghr[63:60]};
    assign folded_tag_t3 = ghr[11:0]  ^ ghr[23:12] ^ ghr[35:24] ^ ghr[47:36] ^ ghr[59:48]
                         ^ {8'b0, ghr[63:60]};

    logic [6:0]  idx0_w;
    logic [4:0]  idx1_w, idx2_w, idx3_w;
    logic [7:0]  tag1_w;
    logic [9:0]  tag2_w;
    logic [11:0] tag3_w;

    assign idx0_w = predict_pc[8:2];
    assign idx1_w = predict_pc[6:2] ^ {1'b0, ghr[3:0]};
    assign idx2_w = predict_pc[6:2] ^ folded_idx_t2;
    assign idx3_w = predict_pc[6:2] ^ folded_idx_t3;
    assign tag1_w = predict_pc[14:7]  ^ {4'b0, ghr[3:0]};
    assign tag2_w = predict_pc[19:10] ^ folded_tag_t2;
    assign tag3_w = predict_pc[23:12] ^ folded_tag_t3;

    t0_entry_t e0;
    t1_entry_t e1;
    t2_entry_t e2;
    t3_entry_t e3;
    assign e0 = t0_table[idx0_w];
    assign e1 = t1_table[idx1_w];
    assign e2 = t2_table[idx2_w];
    assign e3 = t3_table[idx3_w];

    logic t1_hit, t2_hit, t3_hit;
    assign t1_hit = (e1.tag == tag1_w);
    assign t2_hit = (e2.tag == tag2_w);
    assign t3_hit = (e3.tag == tag3_w);

    logic [1:0] provider_w, alt_w;
    logic       tage_pred_w;

    always_comb begin
        provider_w = 2'b00;
        alt_w      = 2'b00;
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
    end

    always_comb begin
        unique case (provider_w)
            2'b00:   tage_pred_w = e0.ctr[1];
            2'b01:   tage_pred_w = (e1.ctr >= 0);
            2'b10:   tage_pred_w = (e2.ctr >= 0);
            2'b11:   tage_pred_w = (e3.ctr >= 0);
            default: tage_pred_w = 1'b0;
        endcase
    end

    logic tage_weak_w;
    always_comb begin
        unique case (provider_w)
            2'b00:   tage_weak_w = (e0.ctr == 2'b01) || (e0.ctr == 2'b10);  // weak
            2'b01:   tage_weak_w = (e1.ctr == 3'sd0) || (e1.ctr == -3'sd1);
            2'b10:   tage_weak_w = (e2.ctr == 3'sd0) || (e2.ctr == -3'sd1);
            2'b11:   tage_weak_w = (e3.ctr == 3'sd0) || (e3.ctr == -3'sd1);
            default: tage_weak_w = 1'b1;
        endcase
    end

    // =========================================================================
    // Loop Predictor predict path
    // =========================================================================
    logic [2:0]  lp_idx_w;
    logic [9:0]  lp_tag_w;
    lp_entry_t   lp_e;
    logic        lp_hit_w, lp_pred_w, lp_conf_w;

    assign lp_idx_w  = predict_pc[4:2];
    assign lp_tag_w  = predict_pc[11:2];
    assign lp_e      = lp_table[lp_idx_w];

    assign lp_hit_w  = lp_e.valid && (lp_e.tag == lp_tag_w);
    assign lp_conf_w = lp_hit_w && (lp_e.conf >= 2'd2);
    assign lp_pred_w = lp_hit_w ? (lp_e.cur_iter < lp_e.conf_iter) : 1'b1;

    // =========================================================================
    // Statistical Corrector predict path
    // =========================================================================
    logic [3:0] sc_g_idx_w, sc_p_idx_w, sc_b_idx_w;
    logic signed [5:0] sc_g_ctr, sc_p_ctr, sc_b_ctr;
    logic signed [7:0] sc_score;
    logic              sc_pred_w;
    logic              sc_strong_w;

    assign sc_g_idx_w = predict_pc[5:2] ^ ghr[3:0];
    assign sc_p_idx_w = predict_pc[5:2] ^ path_hist[3:0];
    assign sc_b_idx_w = predict_pc[5:2];

    assign sc_g_ctr = sc_ghist[sc_g_idx_w];
    assign sc_p_ctr = sc_path [sc_p_idx_w];
    assign sc_b_ctr = sc_bias [sc_b_idx_w];

    assign sc_score = {{2{sc_g_ctr[5]}}, sc_g_ctr}
                    + {{2{sc_p_ctr[5]}}, sc_p_ctr}
                    + {{2{sc_b_ctr[5]}}, sc_b_ctr};

    assign sc_pred_w   = (sc_score >= 0);
    assign sc_strong_w = (sc_score >= 8'sd8) || (sc_score <= -8'sd8);

    // =========================================================================
    // Final prediction: merge TAGE / LP / SC
    // =========================================================================
    logic final_pred_w;
    logic lp_used_w, sc_used_w;

    always_comb begin
        lp_used_w    = 1'b0;
        sc_used_w    = 1'b0;
        final_pred_w = tage_pred_w;

        if (lp_conf_w) begin
            final_pred_w = lp_pred_w;
            lp_used_w    = 1'b1;
        end
        else if (tage_weak_w && sc_strong_w && (sc_pred_w != tage_pred_w)) begin
            final_pred_w = sc_pred_w;
            sc_used_w    = 1'b1;
        end
    end

    // =========================================================================
    // Pack into predict_meta
    // =========================================================================
    always_comb begin
        predict_meta                  = '0;
        predict_meta.pred_taken       = final_pred_w;
        predict_meta.tage_pred_taken  = tage_pred_w;
        predict_meta.provider         = provider_w;
        predict_meta.alt              = alt_w;
        predict_meta.idx0             = idx0_w;
        predict_meta.idx1             = idx1_w;
        predict_meta.idx2             = idx2_w;
        predict_meta.idx3             = idx3_w;
        predict_meta.tag1             = tag1_w;
        predict_meta.tag2             = tag2_w;
        predict_meta.tag3             = tag3_w;
        predict_meta.lp_used          = lp_used_w;
        predict_meta.lp_idx           = lp_idx_w;
        predict_meta.lp_tag           = lp_tag_w;
        predict_meta.sc_used          = sc_used_w;
        predict_meta.sc_g_idx         = sc_g_idx_w;
        predict_meta.sc_p_idx         = sc_p_idx_w;
        predict_meta.sc_b_idx         = sc_b_idx_w;
    end

    // =========================================================================
    // Update path-combinational helpers
    // =========================================================================
    logic update_alt_pred;
    logic update_provider_correct;
    logic update_pred_differ;

    always_comb begin
        unique case (update_meta.alt)
            2'b00:   update_alt_pred = t0_table[update_meta.idx0].ctr[1];
            2'b01:   update_alt_pred = (t1_table[update_meta.idx1].ctr >= 0);
            2'b10:   update_alt_pred = (t2_table[update_meta.idx2].ctr >= 0);
            2'b11:   update_alt_pred = (t3_table[update_meta.idx3].ctr >= 0);
            default: update_alt_pred = 1'b0;
        endcase
        update_provider_correct = (update_meta.tage_pred_taken == update_actual_taken);
        update_pred_differ      = (update_meta.tage_pred_taken != update_alt_pred);
    end

    // =========================================================================
    // Sequential update
    // =========================================================================
    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            for (int i = 0; i < 128; i++) t0_table[i] <= '0;
            for (int i = 0; i < 32;  i++) t1_table[i] <= '0;
            for (int i = 0; i < 32;  i++) t2_table[i] <= '0;
            for (int i = 0; i < 32;  i++) t3_table[i] <= '0;
            for (int i = 0; i < 8;   i++) lp_table[i] <= '0;
            for (int i = 0; i < 16;  i++) sc_ghist[i] <= '0;
            for (int i = 0; i < 16;  i++) sc_path [i] <= '0;
            for (int i = 0; i < 16;  i++) sc_bias [i] <= '0;
            ghr        <= '0;
            path_hist  <= '0;
            aging_cnt  <= '0;
        end
        else if (update_en) begin
            ghr <= {ghr[62:0], update_actual_taken};
            path_hist <= {path_hist[14:0], update_actual_taken};

            aging_cnt <= aging_cnt + 1'b1;
            if (aging_cnt == 8'hFF) begin
                for (int i = 0; i < 32; i++) begin
                    t1_table[i].u <= t1_table[i].u >> 1;
                    t2_table[i].u <= t2_table[i].u >> 1;
                    t3_table[i].u <= t3_table[i].u >> 1;
                end
            end

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

            if (update_meta.tage_pred_taken != update_actual_taken) begin
                unique case (update_meta.provider)
                    2'b00: begin
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
                    2'b01: begin
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
                    2'b10: begin
                        if (t3_table[update_meta.idx3].u == 2'b00) begin
                            t3_table[update_meta.idx3].tag <= update_meta.tag3;
                            t3_table[update_meta.idx3].ctr <= update_actual_taken ? 3'sd0 : -3'sd1;
                            t3_table[update_meta.idx3].u   <= 2'b00;
                        end
                    end
                    2'b11: ;
                    default: ;
                endcase
            end


            begin : lp_update_block
                logic [2:0] li;
                li = update_meta.lp_idx;

                if (!lp_table[li].valid) begin
                    lp_table[li].valid     <= 1'b1;
                    lp_table[li].tag       <= update_meta.lp_tag;
                    lp_table[li].cur_iter  <= update_actual_taken ? 10'd1 : 10'd0;
                    lp_table[li].conf_iter <= 10'd0;
                    lp_table[li].conf      <= 2'b00;
                end
                else if (lp_table[li].tag == update_meta.lp_tag) begin
                    if (update_actual_taken) begin
                        lp_table[li].cur_iter <= sat_up_10(lp_table[li].cur_iter);
                    end else begin
                        if (lp_table[li].conf_iter == 10'd0) begin
                            lp_table[li].conf_iter <= lp_table[li].cur_iter;
                            lp_table[li].conf      <= 2'b00;
                        end
                        else if (lp_table[li].cur_iter == lp_table[li].conf_iter) begin
                            if (lp_table[li].conf != 2'b11)
                                lp_table[li].conf <= lp_table[li].conf + 1'b1;
                        end
                        else begin
                            lp_table[li].conf_iter <= lp_table[li].cur_iter;
                            lp_table[li].conf      <= 2'b00;
                        end
                        lp_table[li].cur_iter <= 10'd0;
                    end
                end
            end
            if (update_meta.pred_taken != update_actual_taken) begin
                if (update_actual_taken) begin
                    sc_ghist[update_meta.sc_g_idx] <= sat_up_6s(sc_ghist[update_meta.sc_g_idx]);
                    sc_path [update_meta.sc_p_idx] <= sat_up_6s(sc_path [update_meta.sc_p_idx]);
                    sc_bias [update_meta.sc_b_idx] <= sat_up_6s(sc_bias [update_meta.sc_b_idx]);
                end else begin
                    sc_ghist[update_meta.sc_g_idx] <= sat_down_6s(sc_ghist[update_meta.sc_g_idx]);
                    sc_path [update_meta.sc_p_idx] <= sat_down_6s(sc_path [update_meta.sc_p_idx]);
                    sc_bias [update_meta.sc_b_idx] <= sat_down_6s(sc_bias [update_meta.sc_b_idx]);
                end
            end
        end
    end

endmodule
