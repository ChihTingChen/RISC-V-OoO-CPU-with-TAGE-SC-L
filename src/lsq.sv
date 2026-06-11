import riscv_pkg::*;
module lsq (
    input  logic        clk,
    input  logic        resetn,
    input  logic        flush,
    
    input  inst_pkt_t   dispatch_pkt,    // 來自 rename_stage
    input  logic        dispatch_en,     // 來自 Top
    output logic [2:0]  lsq_id_alloc,    // 給 dispatch_pkt 的 lsq_id
    output logic        lsq_full,        // 給 dispatch 阻塞用
    
    // -------------- Retire interface --------------
    input  logic        retire_en,       // 來自 ROB
    input  logic [2:0]  retire_lsq_id,   // 來自 ROB
    input  logic        retire_is_load,  // 來自 ROB
    input  logic        retire_is_store, // 來自 ROB

    // --------------ALU to LSQ ---------------------
    input  logic        alu_mem_valid,
    input  logic [2:0]  alu_mem_lsq_id,
    input  logic [31:0] alu_mem_addr,
    input  logic [31:0] alu_mem_data,
    input  logic        alu_mem_is_load,

    // --------------LSQ <-> dmem ---------------------
    output logic [31:0] dmem_addr,   // LW 讀地址
    output logic [31:0] dmem_waddr,  // SW 寫地址
    output logic [31:0] dmem_wdata,  // SW 寫資料
    output logic        dmem_wen,    // SW retire 才拉高
    input  logic [31:0] dmem_rdata,   // LW 讀回來的資料
    // --------------cdb------------------------------
    output cdb_pkt_t lsq_cdb_out,
    input  logic     alu_cdb_valid,   // 來自 Top.sv：ALU 正在廣播時 LSQ 要讓

    // --------------SW ready -> ROB ---------------------
    output logic        sw_ready_valid,
    output logic [3:0]  sw_ready_rob_id,

    // --------------Memory Order Violation ---------------------
    output logic        mem_violation,
    output logic [31:0] mem_violation_pc
);
    //lsq array
    lsq_entry_t lsq [0:7];
    //pointers
    logic [2:0] head, tail;
    logic [3:0] counter;//used for counting full or empty
    
    //find the ready LW
    logic        lw_exec_found;
    logic [2:0]  lw_exec_idx;
    always_comb begin
        lw_exec_found = 1'b0;
        lw_exec_idx   = 3'd0;
        for (int i = 0; i < 8; i++) begin
            if (!lw_exec_found && lsq[i].valid && lsq[i].is_load && lsq[i].addr_ready && !lsq[i].completed) begin
                lw_exec_found = 1'b1;
                lw_exec_idx   = i[2:0];
            end
        end
    end
    assign dmem_addr = lw_exec_found ? lsq[lw_exec_idx].addr : '0;

    // ===== Store-to-Load Forwarding =====
    // LW 執行時，找最新的「比我老 + 同 addr + data_ready」的 SW，拿它的 data
    logic        fwd_found;
    logic [31:0] fwd_data;
    logic [2:0]  fwd_best_age;

    always_comb begin
        fwd_found    = 1'b0;
        fwd_data     = '0;
        fwd_best_age = '0;

        if (lw_exec_found) begin
            for (int i = 0; i < 8; i++) begin
                if (lsq[i].valid
                    && !lsq[i].is_load                                   // 是 SW
                    && lsq[i].data_ready                                  // SW 的 data 已準備
                    && lsq[i].addr == lsq[lw_exec_idx].addr               // addr 相同
                    && ((i[2:0] - head) < (lw_exec_idx - head)))          // 比 LW 老
                begin
                    // 拿 age 最大的（最新的 older SW）
                    if (!fwd_found || ((i[2:0] - head) > fwd_best_age)) begin
                        fwd_found    = 1'b1;
                        fwd_data     = lsq[i].data;
                        fwd_best_age = i[2:0] - head;
                    end
                end
            end
        end
    end

    //find a ready SW
    always_comb begin
    sw_ready_valid  = 1'b0;
    sw_ready_rob_id = '0;
        for (int i = 0; i < 8; i++) begin
            if (!sw_ready_valid && lsq[i].valid && !lsq[i].is_load && lsq[i].addr_ready && lsq[i].data_ready) begin
                sw_ready_valid  = 1'b1;
                sw_ready_rob_id = lsq[i].rob_id;
            end
        end
    end
    
    always_comb begin
        lsq_cdb_out = '0;
        if (lw_exec_found && !alu_cdb_valid) begin  // ALU 在廣播時讓
            lsq_cdb_out.valid  = 1'b1;
            lsq_cdb_out.data   = fwd_found ? fwd_data : dmem_rdata;  // forward 優先
            lsq_cdb_out.tag    = lsq[lw_exec_idx].pp_rd;
            lsq_cdb_out.rob_id = lsq[lw_exec_idx].rob_id;
        end
    end

    // ===== Memory Order Violation 偵測 =====
    // SW 算完 addr 時，掃 younger 已 completed 的 LW 看有沒有 addr 衝突
    always_comb begin
        mem_violation    = 1'b0;
        mem_violation_pc = '0;
        if (alu_mem_valid && !alu_mem_is_load) begin
            for (int i = 0; i < 8; i++) begin
                if (lsq[i].valid
                    && lsq[i].is_load
                    && lsq[i].completed
                    && lsq[i].addr == alu_mem_addr
                    && ((i[2:0] - head) > (alu_mem_lsq_id - head)))
                begin
                    mem_violation    = 1'b1;
                    mem_violation_pc = lsq[alu_mem_lsq_id].pc;
                end
            end
        end
    end

    always_ff@(posedge clk or negedge resetn)begin
        if(!resetn || flush)begin
            head    <= 0;
            tail    <= 0;
            counter <= 0;
            for(int i=0; i<8; i++)begin
                lsq[i] <= '0; 
            end
        end
        else begin
            //---- 接收 ALU 算完的 addr/data ----
            if (alu_mem_valid) begin
                lsq[alu_mem_lsq_id].addr       <= alu_mem_addr;
                lsq[alu_mem_lsq_id].addr_ready <= 1'b1;
                // SW 才存 data
                if (!alu_mem_is_load) begin
                    lsq[alu_mem_lsq_id].data       <= alu_mem_data;
                    lsq[alu_mem_lsq_id].data_ready <= 1'b1;
                end
            end
            if (lw_exec_found && !alu_cdb_valid) begin  // 廣播沒被擋掉才標記
                lsq[lw_exec_idx].data       <= fwd_found ? fwd_data : dmem_rdata;
                lsq[lw_exec_idx].data_ready <= 1'b1;
                lsq[lw_exec_idx].completed  <= 1'b1;
            end
            //dispatch
            if(dispatch_en && (dispatch_pkt.is_load||dispatch_pkt.is_store))begin
                lsq[tail].valid <= 1'b1;
                lsq[tail].rob_id <= dispatch_pkt.rob_id;
                lsq[tail].is_load <= dispatch_pkt.is_load;
                lsq[tail].addr_ready <= 1'b0;
                lsq[tail].addr <= '0;
                lsq[tail].data_ready <= 1'b0;
                lsq[tail].data <= '0;
                lsq[tail].pp_rd <= dispatch_pkt.pp_rd;
                lsq[tail].completed <= 1'b0;
                lsq[tail].pc <= dispatch_pkt.pc;
                tail <= tail + 3'b1;
            end
            //retire
            if(retire_en && (retire_is_load || retire_is_store))begin
                lsq[head].valid <= 1'b0;
                head <= head + 3'b1;
            end
            //counter update
            case({(dispatch_en && (dispatch_pkt.is_load||dispatch_pkt.is_store)),((retire_en) && (retire_is_load || retire_is_store))})
                2'b00: counter <= counter;          //nothing happen
                2'b01: counter <= counter - 4'b1;   //retire only
                2'b10: counter <= counter + 4'b1;   //dispatch only
                2'b11: counter <= counter;          //dispatch + retire
            endcase
        end
    end
    assign lsq_id_alloc = tail;
    assign lsq_full     = (counter == 4'd8);

    // ----- SW retire 寫 dmem -----
    assign dmem_waddr = lsq[retire_lsq_id].addr;
    assign dmem_wdata = lsq[retire_lsq_id].data;
    assign dmem_wen   = retire_en && retire_is_store;
endmodule