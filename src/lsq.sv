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
    input  logic     alu_cdb_valid    // 來自 Top.sv：ALU 正在廣播時 LSQ 要讓
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
            if (!lw_exec_found
                && lsq[i].valid
                && lsq[i].is_load
                && lsq[i].addr_ready
                && !lsq[i].completed) begin
                lw_exec_found = 1'b1;
                lw_exec_idx   = i[2:0];
            end
        end
    end
    assign dmem_addr = lw_exec_found ? lsq[lw_exec_idx].addr : '0;
    always_comb begin
        lsq_cdb_out = '0;
        if (lw_exec_found && !alu_cdb_valid) begin  // ALU 在廣播時讓
            lsq_cdb_out.valid  = 1'b1;
            lsq_cdb_out.data   = dmem_rdata;
            lsq_cdb_out.tag    = lsq[lw_exec_idx].pp_rd;
            lsq_cdb_out.rob_id = lsq[lw_exec_idx].rob_id;
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
                lsq[lw_exec_idx].data       <= dmem_rdata;
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

    // ----- dmem placeholder（B-8/B-10 才實作）-----
    assign dmem_waddr = '0;
    assign dmem_wdata = '0;
    assign dmem_wen   = 1'b0;
endmodule