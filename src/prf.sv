import riscv_pkg::*;
module prf(
    input logic clk,resetn,
    //read port 1
    input phys_reg_t read_addr1,
    output logic [31:0] read_data1,
    //read port 2
    input phys_reg_t read_addr2,
    output logic [31:0] read_data2,
    //write port
    input phys_reg_t write_addr,
    input logic [31:0] write_data,
    input logic wen,
    //進站指令的destination reg
    input logic [5:0] pp_rd,
    input logic pp_rd_valid,
    output logic rs1_ready_from_prf,
    output logic rs2_ready_from_prf
    );
    logic [31:0] prf [0:63];
    logic [63:0] valid_bit;
    always_ff@(posedge clk or negedge resetn)begin
        if(!resetn)begin
            for(int i=0;i<64;i++)begin
                prf[i] <= '0;
            end
            for(int j=0;j<32;j++)begin
                valid_bit[j] <= 1;
            end
            for(int n=32;n<64;n++)begin
                valid_bit[n] <= 0;
            end
        end
        else begin
            //write back邏輯
            if(wen && (write_addr!=0))begin
                prf[write_addr] <= write_data;
                valid_bit[write_addr] <= 1'b1;
            end
            //dispatch邏輯
            if(pp_rd_valid && (pp_rd != 6'b0)) begin
                valid_bit[pp_rd] <= 1'b0;
            end
        end
    end
    //指定輸出data腳位
    assign read_data1 = (read_addr1 == 6'b0) ? 32'b0 : prf[read_addr1];
    assign read_data2 = (read_addr2 == 6'b0) ? 32'b0 : prf[read_addr2];
    //指定輸出valid_bit腳位
    assign rs1_ready_from_prf = (read_addr1 == 6'b0) ? 1'b1 : valid_bit[read_addr1];
    assign rs2_ready_from_prf = (read_addr2 == 6'b0) ? 1'b1 : valid_bit[read_addr2];

endmodule