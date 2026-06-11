module dmem(
    input logic clk, resetn,
    input logic wen,
    input logic [31:0] waddr,//write address
    input logic [31:0] addr,//read address
    input logic [31:0] wdata,//write address
    output logic [31:0] rdata
);
    logic [31:0] dmem [0:1023];
    always_ff@(posedge clk or negedge resetn)begin
        if(!resetn)begin
           for(int i=0; i<1024; i++)begin
                dmem[i] <= 32'b0;
           end
        end
        else begin
            if(wen) dmem[waddr[11:2]] <= wdata;
        end
    end
    assign rdata = dmem[addr[11:2]];
endmodule