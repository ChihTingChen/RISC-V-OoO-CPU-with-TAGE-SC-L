import riscv_pkg::*;
module free_list (
    input  logic       clk,
    input  logic       resetn,
    input  logic       alloc_en,//等於write enable(要丟新name出去)
    output logic [5:0] alloc_p_reg,//要丟出去給RAT的name(要丟的name)
    input  logic       free_en,//instruction retire的時候要free name的時候發出來的enable訊號(要接retire name回來)
    input  logic [5:0] free_p_reg,//instruction retire的時候要釋放的name(要接回來的retire name)
    input  logic       flush,//branch mispredict時要recover
    input  phys_reg_t  arat_in [0:31],//ARAT當前內容，用來算哪些phys reg該回到free pool
    output logic       empty,//FIFO empty signal
    output logic       full//FIFO full signal
);
    logic [5:0] FIFO [0:31];//
    logic [4:0] wp, rp;
    integer i;
    logic [5:0] counter;
    //seq block for FIFO write
    always_ff@(posedge clk or negedge resetn)begin
        automatic logic [63:0] arat_mask;//ARAT佔用的phys reg對應bit設1
        automatic logic [5:0]  write_idx;//flush重灌FIFO時的位置計數器
        if(~resetn)begin
            for(i=0;i<32;i++)begin
                FIFO[i] <= i+32;
            end
            wp <= 0;
            rp <= 0;
            counter <= 32;
        end
        else if(flush)begin
            arat_mask = '0;
            for(int k=0;k<32;k++)
                arat_mask[arat_in[k]] = 1'b1;
            write_idx = 0;
            for(int p=0;p<64;p++)begin
                if(!arat_mask[p])begin
                    FIFO[write_idx] <= p[5:0];
                    write_idx = write_idx + 1;
                end
            end
            wp <= 0;
            rp <= 0;
            counter <= 32;
        end
        else begin
            if(free_en && alloc_en && !empty)begin
                FIFO[wp] <= free_p_reg;
                wp <= wp + 1;
                rp <= rp + 1;
            end
            else if(free_en && !full)begin
                FIFO[wp] <= free_p_reg;
                wp <= wp + 1;
                counter <= counter + 1;
            end
            else if(alloc_en && !empty)begin
                rp <= rp + 1;
                counter <= counter - 1;
            end
        end
    end
    assign alloc_p_reg = FIFO[rp];
    assign empty = (!counter);
    assign full = (counter == 32);
endmodule
