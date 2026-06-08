import riscv_pkg::*;
module arat(
    input logic clk, resetn,
    input logic commit_from_rob,
    input logic [4:0] rd_addr,
    input logic [5:0] pp_rd,
    output phys_reg_t arat_recover_rat [0:31]
);
    phys_reg_t arat_table [0:31];
    always_ff@(posedge clk or negedge resetn)begin
        if(!resetn)begin
            for(int i=0;i<32;i++)begin
                arat_table[i] <= i[5:0];
            end
        end
        else begin
            if(commit_from_rob && (rd_addr!=5'b0))begin
                arat_table[rd_addr] <= pp_rd;
            end
        end
    end
    assign arat_recover_rat = arat_table;
endmodule