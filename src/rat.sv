//rat主要功能就是要讓指令可以知道自己的source reg的physical reg是誰，所以餵給他x0~x31的邏輯reg地址，然後他會輸出對應的physical reg地址
import riscv_pkg::*;
module rat(
    input logic clk, resetn,
    input logic [4:0] rs1_addr, rs2_addr, rd_addr,  //邏輯reg地址
    input logic we,
    input phys_reg_t arat_recover_rat [0:31],
    input logic flush,
    input logic [5:0] p_rd,//來自Free list的空閒tag
    output logic [5:0] rs1_phy_addr, rs2_phy_addr, //physical reg地址
    output logic [5:0] rd_phy_addr_old  //用來記錄rd之前的physical reg地址，當指令commit的時候要把這個physical reg釋放掉
);
    integer i;
    phys_reg_t rat_table [0:31]; 
    assign rs1_phy_addr = (rs1_addr == 5'b0) ? 6'b0 : rat_table[rs1_addr];
    assign rs2_phy_addr = (rs2_addr == 5'b0) ? 6'b0 : rat_table[rs2_addr];
    assign rd_phy_addr_old = rat_table[rd_addr];
    always_ff @(posedge clk or negedge resetn) begin
        if(!resetn)begin
            for(i=0;i<32;i++)begin
                rat_table[i] <= i[5:0];//寫[5:0]避免合成報錯
            end
        end
        else if(flush) begin
            rat_table <= arat_recover_rat;
        end
        else begin
            if(we&&(rd_addr!=5'b0))begin
                rat_table[rd_addr] <= p_rd;
            end
        end
    end
endmodule

