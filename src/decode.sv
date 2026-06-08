import riscv_pkg::*;
module decode(
    input [31:0] IF_pc,
    input [31:0] IF_instr,
    output inst_pkt_t decoded_pkt
);
    wire [6:0] opcode = IF_instr[6:0];
    wire [2:0] funct3 = IF_instr[14:12];
    wire [6:0] funct7 = IF_instr[31:25];
    //imm generation
    wire [31:0] imm_i = {{20{IF_instr[31]}},IF_instr[31:20]};
    wire [31:0] imm_b = {{19{IF_instr[31]}},IF_instr[7],IF_instr[30:25],IF_instr[11:8],1'b0};
    wire [31:0] imm_u = {IF_instr[31:12],12'b0};

    //put the decoded information into the packet
    always_comb begin
        decoded_pkt = '0; // default value
        decoded_pkt.pc = IF_pc;
        decoded_pkt.valid = 1'b1; // assume all instructions are valid for now
        decoded_pkt.instr = IF_instr;
        decoded_pkt.rs1_addr = IF_instr[19:15];
        decoded_pkt.rs2_addr = IF_instr[24:20];
        decoded_pkt.rd_addr = IF_instr[11:7];
        case(opcode)
            //R-Type instruction
            OPC_R_TYPE:begin
                decoded_pkt.uses_rs1 = 1'b1;
                decoded_pkt.uses_rs2 = 1'b1;
                decoded_pkt.writes_rd = 1'b1;
                case(funct3)
                    //ADD, SUB
                    3'b000:decoded_pkt.alu_op = (funct7[5]) ? ALU_SUB : ALU_ADD;
                    //AND
                    3'b111:decoded_pkt.alu_op = ALU_AND;
                    //OR
                    3'b110:decoded_pkt.alu_op = ALU_OR;
                    //XOR
                    3'b100:decoded_pkt.alu_op = ALU_XOR;
                    //SLT
                    3'b010:decoded_pkt.alu_op = ALU_SLT;
                    //SLL
                    3'b001:decoded_pkt.alu_op = ALU_SLL;
                    //SRL & SRA
                    3'b101:decoded_pkt.alu_op = (funct7[5]) ? ALU_SRA : ALU_SRL;
                    default: ;
                endcase
            end
            //I-Type instruction
            OPC_I_ALU:begin
                decoded_pkt.uses_rs1 = 1'b1;
                decoded_pkt.uses_rs2 = 1'b0;
                decoded_pkt.writes_rd = 1'b1;
                //decoded_pkt.alu_op = ALU_ADD;
                decoded_pkt.imm = imm_i;
                case(funct3)
                    //ADDI
                    3'b000:decoded_pkt.alu_op = ALU_ADD;
                    //ANDI
                    3'b111:decoded_pkt.alu_op = ALU_AND;
                    //ORI
                    3'b110:decoded_pkt.alu_op = ALU_OR;
                    //XORI
                    3'b100:decoded_pkt.alu_op = ALU_XOR;
                    //SLTI
                    3'b010:decoded_pkt.alu_op = ALU_SLT;
                    //SLLI
                    3'b001: decoded_pkt.alu_op = ALU_SLL;
                    //SRAI & SRLI
                    3'b101: decoded_pkt.alu_op = (funct7[5]) ? ALU_SRA : ALU_SRL;

                    default: ;
                endcase
            end
            OPC_BRANCH:begin//目前只有BNE
                decoded_pkt.uses_rs1 = 1'b1;
                decoded_pkt.uses_rs2 = 1'b1;
                decoded_pkt.writes_rd = 1'b0;
                decoded_pkt.is_branch = 1'b1;
                decoded_pkt.br_op = BR_NE;
                decoded_pkt.imm = imm_b;
                decoded_pkt.rd_addr = 5'b0;
            end
            OPC_LUI:begin
                decoded_pkt.rs1_addr = '0;
                decoded_pkt.rs2_addr = '0;
                decoded_pkt.writes_rd = 1'b1;
                decoded_pkt.alu_op = ALU_ADD;//LUI can be treated as ADD with imm_u
                decoded_pkt.imm = imm_u;
            end
            default:begin
                decoded_pkt.valid = 1'b0;
            end
        endcase
    end
endmodule