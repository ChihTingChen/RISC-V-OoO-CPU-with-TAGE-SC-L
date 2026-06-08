import riscv_pkg::*;
module fetch(
    input logic clk, resetn,
    input logic stall, flush,//stall when the queue is full, flush when the branch is taken
    input logic [31:0] flush_pc,//corresponding pc when flush
    input logic [31:0] IF_instr,//instruction from imem
    output logic [31:0] IF_pc,//pc for imem
    output logic [31:0] IF_instr_out//instruction for the next stage
);
    logic [31:0] next_pc;
    always@(posedge clk or negedge resetn)begin
        if(!resetn)begin
            IF_pc <= 0;
        end
        else begin
            IF_pc <= next_pc;
        end
    end
    always@(*)begin
            if(flush)begin
                next_pc = flush_pc;
            end
            else if(stall)begin
                next_pc = IF_pc;
            end
            else begin
                next_pc = IF_pc + 4;
            end
    end
    assign IF_instr_out = IF_instr;
endmodule