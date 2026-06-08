import riscv_pkg::*;

module alu (
    input  logic        clk,
    input  logic        resetn,

    // --- 來自 RS (Issue Stage) 的發射封包 ---
    input  logic        issue_en,
    input  alu_op_t     alu_op,
    input  br_op_t      br_op,
    input  logic [31:0] op1_data,     // PRF 讀出的真實數據 1
    input  logic [31:0] op2_data,     // PRF 讀出的真實數據 2 (或是立即數)
    input  logic [31:0] inst_pc,      // 此指令的 PC (算 BNE 猜錯地址用)
    input  phys_reg_t   pp_rd,        // 目的地實體暫存器編號
    input  logic [3:0]  rob_id,       // 指令在 ROB 的位置
    input  logic        is_branch,    // 標記這是不是一條分支指令
    input  logic [31:0] inst_imm,
    
    output cdb_pkt_t    alu_cdb_out   // 直接丟出一整包
);
    logic branch_taken;
    logic [31:0] result;
    always_comb begin
        result = '0;
        branch_taken = 0;
        if(!is_branch)begin
            result = '0;
            case(alu_op)
                ALU_ADD: result = op1_data + op2_data;
                ALU_SUB: result = op1_data - op2_data;
                ALU_AND: result = op1_data & op2_data;
                ALU_OR:  result = op1_data | op2_data;
                ALU_XOR: result = op1_data ^ op2_data;
                ALU_SLT: result = ($signed(op1_data) < $signed(op2_data)) ? 1:0;
                default: result = '0;
            endcase
        end
        else if(is_branch)begin
            branch_taken = 0;
            case(br_op)
                BR_NE:begin
                    branch_taken = (op1_data != op2_data);
                    //待未來擴充
                end
                default: branch_taken = 0;
            endcase
        end
    end
    always_comb begin
        alu_cdb_out = '0;
        if(issue_en)begin
            alu_cdb_out.valid = 1'b1;
            alu_cdb_out.tag   = pp_rd;
            alu_cdb_out.rob_id= rob_id;
            if(is_branch)begin
                alu_cdb_out.data = '0;
                alu_cdb_out.bad_branch = branch_taken;
                alu_cdb_out.target_pc  = inst_pc + inst_imm;
            end
            else begin
                alu_cdb_out.data = result;
                alu_cdb_out.bad_branch = 1'b0;
            end
        end

    end
    
    
endmodule