import riscv_pkg::*;
module fetch(
    input  logic        clk, resetn,
    input  logic        stall, flush,
    input  logic [31:0] flush_pc,
    input  logic [31:0] IF_instr,

    input  bpu_meta_t   bpu_predict_meta,

    output logic [31:0] IF_pc,
    output logic [31:0] IF_instr_out,
    // metadata 給 decode
    output bpu_meta_t   IF_bpu_meta_out
);
    logic [31:0] next_pc;


    wire [6:0]  opcode  = IF_instr[6:0];
    wire        is_cond = (opcode == 7'b1100011);     // OPC_BRANCH
    wire [31:0] imm_b   = {{19{IF_instr[31]}}, IF_instr[7], IF_instr[30:25],
                           IF_instr[11:8], 1'b0};

    wire [31:0] predicted_target = IF_pc + imm_b;

    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) IF_pc <= 0;
        else         IF_pc <= next_pc;
    end

    always_comb begin
        if (flush) begin
            next_pc = flush_pc;
        end
        else if (stall) begin
            next_pc = IF_pc;
        end
        else if (is_cond && bpu_predict_meta.pred_taken) begin
            next_pc = predicted_target;
        end
        else begin
            next_pc = IF_pc + 4;
        end
    end

    assign IF_instr_out    = IF_instr;
    assign IF_bpu_meta_out = bpu_predict_meta;
endmodule
