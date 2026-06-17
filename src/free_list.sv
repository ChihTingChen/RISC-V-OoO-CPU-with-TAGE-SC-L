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
    logic [5:0] FIFO [0:31];
    logic [4:0] wp, rp;
    logic [5:0] counter;

    logic [63:0] arat_mask;
    always_comb begin
        arat_mask = 64'b0;
        for(int k=0; k<32; k++)
            arat_mask[arat_in[k]] = 1'b1;
    end

    logic [5:0] flush_fifo [0:31];
    logic [5:0] flush_idx;
    always_comb begin
        flush_idx = 6'd0;
        for(int i=0; i<32; i++) flush_fifo[i] = 6'd0;
        for(int p=0; p<64; p++) begin
            if(!arat_mask[p] && flush_idx < 6'd32) begin
                flush_fifo[flush_idx] = p[5:0];
                flush_idx = flush_idx + 6'd1;
            end
        end
    end

    always_ff@(posedge clk or negedge resetn)begin
        if(!resetn)begin
            for(int i=0; i<32; i++) FIFO[i] <= 6'(i+32);
            wp      <= 5'd0;
            rp      <= 5'd0;
            counter <= 6'd32;
        end
        else if(flush)begin
            for(int i=0; i<32; i++) FIFO[i] <= flush_fifo[i];
            wp      <= 5'd0;
            rp      <= 5'd0;
            counter <= 6'd32;
        end
        else begin
            if(free_en && alloc_en && !empty)begin
                FIFO[wp] <= free_p_reg;
                wp <= wp + 5'd1;
                rp <= rp + 5'd1;
            end
            else if(free_en && !full)begin
                FIFO[wp] <= free_p_reg;
                wp <= wp + 5'd1;
                counter <= counter + 6'd1;
            end
            else if(alloc_en && !empty)begin
                rp <= rp + 5'd1;
                counter <= counter - 6'd1;
            end
        end
    end
    assign alloc_p_reg = FIFO[rp];
    assign empty = (counter == 6'd0);
    assign full  = (counter == 6'd32);
endmodule
