import riscv_pkg::*;
module imem(
    input logic [31:0] addr,
    output logic [31:0] data
);
    logic [31:0] imem [0:1023];
    logic [9:0] index;
    assign index = addr[11:2];
    initial begin
        $readmemh("code.txt",imem);
    end
    assign data = imem[index];
endmodule      

