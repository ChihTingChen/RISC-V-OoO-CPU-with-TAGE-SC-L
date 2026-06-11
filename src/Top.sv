import riscv_pkg::*;
module Top(
    input logic clk,resetn

);
logic stall, flush, rob_full, rs_full;
logic [31:0] flush_pc, IF_pc;
logic [31:0] IF_instr, IF_instr_out;
logic [31:0] read_data1, read_data2;
logic [3:0] rob_id_alloc;
logic [5:0] retire_p_rd_old, retire_pp_rd;
logic [4:0] retire_rd_addr;
inst_pkt_t decoded_pkt, renamed_pkt;
logic retire_en;
logic retire_writes_rd;
logic free_list_free_en;
logic issue_en;
logic rs1_ready_from_prf, rs2_ready_from_prf;
cdb_pkt_t common_data_bus;
cdb_pkt_t alu_cdb_raw;
cdb_pkt_t lsq_cdb_out;
rs_entry_t data_to_ALU;
phys_reg_t arat_recover_rat [0:31];
// LSQ 相關訊號
logic [2:0]  lsq_id_alloc;
logic        lsq_full;
logic        retire_is_load, retire_is_store;
logic [2:0]  retire_lsq_id;
// ALU → LSQ
logic        alu_mem_valid;
logic [2:0]  alu_mem_lsq_id;
logic [31:0] alu_mem_addr, alu_mem_data;
logic        alu_mem_is_load;
// LSQ ↔ dmem
logic [31:0] dmem_addr, dmem_waddr, dmem_wdata, dmem_rdata;
logic        dmem_wen;
// LSQ → ROB: SW ready
logic        sw_ready_valid;
logic [3:0]  sw_ready_rob_id;
// LSQ → ROB/Fetch: memory order violation
logic        mem_violation;
logic [31:0] mem_violation_pc;
logic [31:0] rob_redirect_pc_raw;
//IF instantiate
fetch IF(
    .clk(clk),
    .resetn(resetn),
    .stall(stall),//in
    .flush(flush),//in
    .flush_pc(flush_pc),//in
    .IF_instr(IF_instr),//in
    .IF_pc(IF_pc),//out
    .IF_instr_out(IF_instr_out)//out
);
//imem instantiate
imem imem(
    .addr(IF_pc),//in
    .data(IF_instr)//out
);
//dcode instantiate
decode decode(
    .IF_pc(IF_pc),//in
    .IF_instr(IF_instr),//in
    .decoded_pkt(decoded_pkt)//out
);
logic dispatch_en;
rename_stage rename_stage(
    .clk(clk),
    .resetn(resetn),
    .rename_pkt(decoded_pkt),//decode instruciton from decode stage
    .rob_retire_en(free_list_free_en),//rob signal (gated by writes_rd)
    .rob_retire_p_rd(retire_p_rd_old),//rob signal
    .rob_id(rob_id_alloc),
    .lsq_id(lsq_id_alloc),
    .rs_full(rs_full),
    .rob_full(rob_full),
    .arat_recover_rat(arat_recover_rat),
    .flush(flush),
    .dispatch_en(dispatch_en),
    .renamed_pkt(renamed_pkt),
    .stall(stall)
);
assign dispatch_en = renamed_pkt.valid && (!rob_full) && (!rs_full)
                  && (!((renamed_pkt.is_load || renamed_pkt.is_store) && lsq_full));
rob rob(
    .clk(clk),
    .resetn(resetn),
    .dispatch_en(dispatch_en),
    .renamed_pkt(renamed_pkt),
    .rob_id_alloc(rob_id_alloc),
    .rob_full(rob_full),
    .cdb_valid(common_data_bus.valid),//alu signal
    .cdb_rob_id(common_data_bus.rob_id),//alu signal
    .cdb_bad_branch(common_data_bus.bad_branch),//alu signal
    .cdb_target_pc(common_data_bus.target_pc),//alu signal
    .sw_ready_valid(sw_ready_valid),
    .sw_ready_rob_id(sw_ready_rob_id),
    .mem_violation(mem_violation),
    .retire_en(retire_en),
    .retire_p_rd_old(retire_p_rd_old),//舊的physical addr
    .retire_pp_rd(retire_pp_rd),//該指令的physical address
    .retire_rd_addr(retire_rd_addr),//該指令的logical addr
    .retire_writes_rd(retire_writes_rd),//out
    .retire_is_load(retire_is_load),
    .retire_is_store(retire_is_store),
    .retire_lsq_id(retire_lsq_id),
    .empty(),//out
    .head_ptr(),//out
    .tail_ptr(),//out
    .rob_flush(flush),//out
    .rob_redirect_pc(rob_redirect_pc_raw)//先接 raw，下面 mux 後再到 flush_pc
);
assign flush_pc = mem_violation ? mem_violation_pc : rob_redirect_pc_raw;
assign free_list_free_en = retire_en && retire_writes_rd;//只有真的有寫rd的指令retire時才把pp_rd_old還給free_list
rs rs(
    .clk(clk),
    .resetn(resetn),
    .flush(flush),
    .renamed_pkt(renamed_pkt),
    .dispatch_en(dispatch_en),
    .rs_full(rs_full),
    .rs1_data_from_prf(read_data1),
    .rs1_ready_from_prf(rs1_ready_from_prf),
    .rs2_data_from_prf(read_data2),
    .rs2_ready_from_prf(rs2_ready_from_prf),
    .cdb_in(common_data_bus),
    .issue_en(issue_en),
    .data_to_ALU(data_to_ALU)
);
prf prf(
    .clk(clk),
    .resetn(resetn),
    .read_addr1(renamed_pkt.pp_rs1),
    .read_data1(read_data1),
    .read_addr2(renamed_pkt.pp_rs2),
    .read_data2(read_data2),
    .write_addr(common_data_bus.tag),//cdb上面運行完的指令的physical address
    .write_data(common_data_bus.data),
    .wen(common_data_bus.valid),
    .pp_rd(renamed_pkt.pp_rd),
    .pp_rd_valid(dispatch_en),
    .rs1_ready_from_prf(rs1_ready_from_prf),
    .rs2_ready_from_prf(rs2_ready_from_prf)
);
arat arat(
    .clk(clk),
    .resetn(resetn),
    .commit_from_rob(retire_en),
    .rd_addr(retire_rd_addr),
    .pp_rd(retire_pp_rd),
    .arat_recover_rat(arat_recover_rat)//進去rename stage恢復rat
);
alu alu(
    .clk(clk),
    .resetn(resetn),
    .issue_en(issue_en),
    .alu_op(data_to_ALU.alu_op),
    .br_op(data_to_ALU.br_op),
    .op1_data(data_to_ALU.rs1_value),
    .op2_data(data_to_ALU.rs2_value),
    .inst_pc(data_to_ALU.pc),
    .pp_rd(data_to_ALU.pp_rd),
    .rob_id(data_to_ALU.rob_id),
    .is_branch(data_to_ALU.is_branch),
    .inst_imm(data_to_ALU.imm),
    .is_load(data_to_ALU.is_load),
    .is_store(data_to_ALU.is_store),
    .lsq_id(data_to_ALU.lsq_id),
    .is_jump(data_to_ALU.is_jump),
    .alu_cdb_out(alu_cdb_raw),
    .alu_mem_valid(alu_mem_valid),
    .alu_mem_lsq_id(alu_mem_lsq_id),
    .alu_mem_addr(alu_mem_addr),
    .alu_mem_data(alu_mem_data),
    .alu_mem_is_load(alu_mem_is_load)
);
lsq lsq(
    .clk(clk),
    .resetn(resetn),
    .flush(flush),
    .dispatch_pkt(renamed_pkt),
    .dispatch_en(dispatch_en),
    .lsq_id_alloc(lsq_id_alloc),
    .lsq_full(lsq_full),
    .retire_en(retire_en),
    .retire_lsq_id(retire_lsq_id),
    .retire_is_load(retire_is_load),
    .retire_is_store(retire_is_store),
    .alu_mem_valid(alu_mem_valid),
    .alu_mem_lsq_id(alu_mem_lsq_id),
    .alu_mem_addr(alu_mem_addr),
    .alu_mem_data(alu_mem_data),
    .alu_mem_is_load(alu_mem_is_load),
    .dmem_addr(dmem_addr),
    .dmem_waddr(dmem_waddr),
    .dmem_wdata(dmem_wdata),
    .dmem_wen(dmem_wen),
    .dmem_rdata(dmem_rdata),
    .lsq_cdb_out(lsq_cdb_out),
    .alu_cdb_valid(alu_cdb_raw.valid),
    .sw_ready_valid(sw_ready_valid),
    .sw_ready_rob_id(sw_ready_rob_id),
    .mem_violation(mem_violation),
    .mem_violation_pc(mem_violation_pc)
);
// 兩條 CDB merge：ALU 優先，LSQ 次之
always_comb begin
    if (alu_cdb_raw.valid)
        common_data_bus = alu_cdb_raw;
    else if (lsq_cdb_out.valid)
        common_data_bus = lsq_cdb_out;
    else
        common_data_bus = '0;
end
dmem dmem(
    .clk(clk),
    .resetn(resetn),
    .wen(dmem_wen),
    .waddr(dmem_waddr),
    .addr(dmem_addr),
    .wdata(dmem_wdata),
    .rdata(dmem_rdata)
);
endmodule