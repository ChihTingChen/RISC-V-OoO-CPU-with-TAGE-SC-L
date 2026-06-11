import riscv_pkg::*;
module rename_stage(
    input clk,resetn,
    input inst_pkt_t rename_pkt,//input 進來的packet
    input  logic        rob_retire_en,// rob retire的enable信號
    input  logic [5:0]  rob_retire_p_rd,//rob retire的name
    input  logic [3:0] rob_id,
    input  logic [2:0] lsq_id,
    input  logic rs_full,
    input  logic rob_full,
    input  phys_reg_t arat_recover_rat [0:31],
    input  logic flush,
    input  logic dispatch_en,//只有真的能dispatch時才允許alloc/RAT更新
    output inst_pkt_t renamed_pkt,//輸出出去的packet
    output logic stall//stall信號
    );
    logic FIFO_empty, FIFO_full;
    logic actual_alloc_en;
    assign actual_alloc_en = rename_pkt.valid && (rename_pkt.rd_addr !=0) && rename_pkt.writes_rd && dispatch_en;
    logic [5:0] internal_pp_rd, internal_pp_rs1, internal_pp_rs2, internal_pp_rd_old;
    always_comb begin
        renamed_pkt = rename_pkt;//複製前級packet給後級
        renamed_pkt.pp_rs1 = internal_pp_rs1;
        renamed_pkt.pp_rs2 = internal_pp_rs2;
        renamed_pkt.pp_rd  = (actual_alloc_en) ? internal_pp_rd : 0;
        renamed_pkt.pp_rd_old = internal_pp_rd_old;
        renamed_pkt.rob_id = rob_id;
        renamed_pkt.lsq_id = lsq_id;
    end
    //紀錄目前有哪些name被使用過的FIFO
    free_list u_free_list(
        .clk(clk),
        .resetn(resetn),
        .alloc_en(actual_alloc_en),
        .alloc_p_reg(internal_pp_rd),
        .free_en(rob_retire_en),//來自ROB
        .free_p_reg(rob_retire_p_rd),
        .flush(flush),
        .arat_in(arat_recover_rat),
        .empty(FIFO_empty),
        .full(FIFO_full)
    );
    //紀錄現在哪個logical regfile對應到哪一個physical regfile(name)
    rat u_rat(
        .clk(clk),
        .resetn(resetn),
        .rs1_addr(rename_pkt.rs1_addr),
        .rs2_addr(rename_pkt.rs2_addr),
        .rd_addr(rename_pkt.rd_addr),
        .we(actual_alloc_en),
        .arat_recover_rat(arat_recover_rat),
        .flush(flush),
        .p_rd(internal_pp_rd),//來自Free list的空閒tag
        .rs1_phy_addr(internal_pp_rs1),//physical reg地址
        .rs2_phy_addr(internal_pp_rs2),//physical reg地址
        .rd_phy_addr_old(internal_pp_rd_old)//用來記錄rd之前的physical reg地址，當指令commit的時候要把這個physical reg釋放掉
    );
    assign stall = (FIFO_empty && actual_alloc_en) || rs_full || rob_full;//free list空、RS滿、ROB滿 → fetch stage不要前進
endmodule