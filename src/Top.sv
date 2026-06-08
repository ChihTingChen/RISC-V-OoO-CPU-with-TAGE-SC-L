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
rs_entry_t data_to_ALU;
phys_reg_t arat_recover_rat [0:31];
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
    .rs_full(rs_full),
    .rob_full(rob_full),
    .arat_recover_rat(arat_recover_rat),
    .flush(flush),
    .dispatch_en(dispatch_en),
    .renamed_pkt(renamed_pkt),
    .stall(stall)
);
assign dispatch_en = renamed_pkt.valid && (!rob_full) && (!rs_full);
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
    .retire_en(retire_en),
    .retire_p_rd_old(retire_p_rd_old),//舊的physical addr
    .retire_pp_rd(retire_pp_rd),//該指令的physical address
    .retire_rd_addr(retire_rd_addr),//該指令的logical addr
    .retire_writes_rd(retire_writes_rd),//out
    .empty(),//out
    .head_ptr(),//out
    .tail_ptr(),//out
    .rob_flush(flush),//out
    .rob_redirect_pc(flush_pc)//接給fetch供他flush的時候使用
);
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
    .op1_data(data_to_ALU.rs1_value),//不是從prf接，而是要從rs接過來
    .op2_data(data_to_ALU.rs2_value),//不是從prf接，而是要從rs接過來
    .inst_pc(data_to_ALU.pc),
    .pp_rd(data_to_ALU.pp_rd),
    .rob_id(data_to_ALU.rob_id),
    .is_branch(data_to_ALU.is_branch),
    .inst_imm(data_to_ALU.imm),
    .alu_cdb_out(common_data_bus)
);
endmodule