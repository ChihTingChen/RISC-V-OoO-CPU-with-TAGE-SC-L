import riscv_pkg::*;
//筆記
//rob retire只負責釋放retired name from free list
module rob (
    input  logic        clk,
    input  logic        resetn,
    input  logic        dispatch_en,//enable時代表該指令valid且RS和ROB都有空位

    input  inst_pkt_t   renamed_pkt,//rename過的package

    output logic [3:0]  rob_id_alloc,//要給出去的rob entry id
    output logic        rob_full,// rob_full訊號

    input  logic        cdb_valid,//ALU算完廣播說現在CDB上面的東西是valid
    input  logic [3:0]  cdb_rob_id,//ALU算完的該指令的rob entry id
    input  logic        cdb_bad_branch,//ALU發現BNE預測錯了，要告訴ROB要flush
    input  logic [31:0] cdb_target_pc,//ALU再算完的同時會回傳他如果prediction錯，應該要去哪
    input  logic        sw_ready_valid,    // 來自 LSQ：某個 SW 兩個都 ready 了
    input  logic [3:0]  sw_ready_rob_id,
    input  logic        mem_violation,     // 來自 LSQ：memory order violation，需 flush
    output logic        retire_en,//告訴其他module誰要retire了
    output logic [5:0]  retire_p_rd_old,//該retire instruction取代過的physical tag，這可以被free了
    output logic [5:0]  retire_pp_rd,//retire instruction本身的physical tag
    output logic [4:0]  retire_rd_addr,//retire instruction本身的logical address
    output logic        retire_writes_rd,//retire instruciton本身要不要WB
    output logic        retire_is_load,
    output logic        retire_is_store,
    output logic [2:0]  retire_lsq_id,

    output logic        empty,
    output logic [3:0]  head_ptr,
    output logic [3:0]  tail_ptr,
    output logic        rob_flush,        // 告訴全後端：通通清空！
    output logic [31:0] rob_redirect_pc,  // 告訴 Fetch：請從這個正確地址開始抓

    // ===== BPU update interface =====
    output logic        bpu_update_en,            // 該 cycle 有 conditional branch retire
    output logic        bpu_update_actual_taken,  // 真實 taken 結果
    output bpu_meta_t   bpu_update_meta           // predict 時存的 metadata
);
    rob_entry_t entries [0:15];//ROB有16格
    logic [3:0] head, tail;//兩個指標
    logic [4:0] counter;//用來協助判斷empty or full的counter
    assign retire_en = entries[head].valid && entries[head].ready;//可以retire的條件
    assign rob_flush = (entries[head].bad_branch && retire_en) || mem_violation;//BNE misprediction 或 memory ordering violation
    assign rob_redirect_pc = entries[head].target_pc;//把帶在身上的target_pc給到rob_redirect_pc，再輸出給fetch
    //ROB entries 更新邏輯
    always_ff@(posedge clk or negedge resetn)begin
        if(!resetn)begin
            head <= 0;
            tail <= 0;
            counter <= 0;
            for(int i=0;i<16;i++)begin
                entries[i] <= '0;
            end
        end
        else if(rob_flush)begin
            head <= 0;
            tail <= 0;
            counter <= 0;
            for(int i=0;i<16;i++)begin
                entries[i] <= '0;
            end
        end
        else begin
            if(cdb_valid)begin//alu計算完成，把東西放上cdb，
                entries[cdb_rob_id].ready <= 1;
                entries[cdb_rob_id].bad_branch <= cdb_bad_branch;
                entries[cdb_rob_id].target_pc <= cdb_target_pc;
            end
            // SW 不上 CDB，靠 LSQ 直接通知
            if(sw_ready_valid)begin
                entries[sw_ready_rob_id].ready <= 1;
            end
            if(dispatch_en && retire_en)begin//有指令從rename stage來rob，也有指令從rob retire
                head <= head + 1;
                tail <= tail + 1;
                counter <= counter;
                //dispatch
                entries[tail].valid <= 1;
                entries[tail].ready <= 0;
                entries[tail].rd_addr <= renamed_pkt.rd_addr;
                entries[tail].pp_rd_old <= renamed_pkt.pp_rd_old;
                entries[tail].pp_rd <= renamed_pkt.pp_rd;
                entries[tail].writes_rd <= renamed_pkt.writes_rd;
                entries[tail].is_branch <= renamed_pkt.is_branch;
                entries[tail].is_load   <= renamed_pkt.is_load;
                entries[tail].is_store  <= renamed_pkt.is_store;
                entries[tail].lsq_id    <= renamed_pkt.lsq_id;
                entries[tail].target_pc <= 0;
                entries[tail].bad_branch <= 0;
                entries[tail].bpu_meta  <= renamed_pkt.bpu_meta;
                //retire
                entries[head].valid <= 0;
            end
            else if(dispatch_en)begin//有指令從rename stage來rob，但沒有指令從rob retire
                tail <= tail + 1;
                counter <= counter + 1;
                //dispatch
                entries[tail].valid <= 1;
                entries[tail].ready <= 0;
                entries[tail].rd_addr <= renamed_pkt.rd_addr;
                entries[tail].pp_rd_old <= renamed_pkt.pp_rd_old;
                entries[tail].pp_rd <= renamed_pkt.pp_rd;
                entries[tail].writes_rd <= renamed_pkt.writes_rd;
                entries[tail].is_branch <= renamed_pkt.is_branch;
                entries[tail].is_load   <= renamed_pkt.is_load;
                entries[tail].is_store  <= renamed_pkt.is_store;
                entries[tail].lsq_id    <= renamed_pkt.lsq_id;
                entries[tail].target_pc <= 0;
                entries[tail].bad_branch <= 0;
                entries[tail].bpu_meta  <= renamed_pkt.bpu_meta;
            end
            else if(retire_en)begin//沒有指令從rename stage來rob，但有指令從rob retire
                head <= head + 1;
                counter <= counter - 1;
                //retire
                entries[head].valid <= 0;
            end
        end
    end
    assign rob_id_alloc = tail;
    always_comb begin
        retire_p_rd_old  = 0;
        retire_pp_rd     = 0;
        retire_rd_addr   = 0;
        retire_writes_rd = 0;
        retire_is_load   = 0;
        retire_is_store  = 0;
        retire_lsq_id    = 0;
        if(retire_en)begin
            retire_p_rd_old  = entries[head].pp_rd_old;
            retire_pp_rd     = entries[head].pp_rd;
            retire_rd_addr   = entries[head].rd_addr;
            retire_writes_rd = entries[head].writes_rd;
            retire_is_load   = entries[head].is_load;
            retire_is_store  = entries[head].is_store;
            retire_lsq_id    = entries[head].lsq_id;
        end
    end
    assign rob_full = (counter == 16);
    assign head_ptr = head;
    assign tail_ptr = tail;

    // ===== BPU update interface =====
    // 只有 conditional branch retire 時才更新 BPU（JAL/JALR 不算）
    // actual_taken 用「預測 XOR 預測錯」推出來
    always_comb begin
        bpu_update_en           = 1'b0;
        bpu_update_actual_taken = 1'b0;
        bpu_update_meta         = '0;
        if (retire_en && entries[head].is_branch) begin
            bpu_update_en           = 1'b1;
            bpu_update_meta         = entries[head].bpu_meta;
            bpu_update_actual_taken = entries[head].bpu_meta.pred_taken
                                    ^ entries[head].bad_branch;
        end
    end

endmodule