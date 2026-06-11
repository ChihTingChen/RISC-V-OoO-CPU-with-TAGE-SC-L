import riscv_pkg::*;
module rs(
    input clk, resetn,
    input flush,//branch prediciton wrong then flush 
    //rename_stage
    input inst_pkt_t renamed_pkt,//input from rename stage
    input logic dispatch_en,
    output rs_full,
    // 當指令進站時，如果 PRF 已經有現成資料，要直接讀進來
    input  logic [31:0] rs1_data_from_prf,
    input  logic        rs1_ready_from_prf,
    input  logic [31:0] rs2_data_from_prf,
    input  logic        rs2_ready_from_prf,
    //from CDB
    input cdb_pkt_t cdb_in,
    //output to ALU
    output logic issue_en,
    output rs_entry_t data_to_ALU
    
);
    rs_entry_t rs [0:7];
    integer i, j;
    logic [2:0] vacancy;
    logic issue_found;
    logic [2:0] issue_address;
    //找空缺
    always_comb begin
        vacancy = 3'd0;
        for(int n=0;n<8;n++)begin
            if(!rs[n].busy)begin
                vacancy = n[2:0];
                break;
            end
        end
    end
    /*always_ff@(posedge clk or negedge resetn) begin
            if(!resetn || flush)begin
                vacancy <= 0;
            end
            else begin
                for(i=0;i<8;i++)begin
                    if(!rs[i].busy)begin
                        vacancy <= i;
                    end
                end
            end
    end*/
    //寫入邏輯
    always_ff@(posedge clk or negedge resetn) begin
        if(!resetn || flush)begin
            for(j=0;j<8;j++)begin
                rs[j] <= '0;
            end
        end
        else begin
            if(issue_found)begin
                rs[issue_address].busy <= '0; 
            end
            // 既有值寫入
            if (renamed_pkt.valid && dispatch_en) begin
                rs[vacancy].busy      <= 1'b1;
                rs[vacancy].pp_rs1    <= renamed_pkt.pp_rs1;
                rs[vacancy].pp_rs2    <= renamed_pkt.pp_rs2;
                rs[vacancy].alu_op    <= renamed_pkt.alu_op;
                rs[vacancy].br_op     <= renamed_pkt.br_op;
                rs[vacancy].imm       <= renamed_pkt.imm;
                rs[vacancy].pc        <= renamed_pkt.pc;
                rs[vacancy].pp_rd     <= renamed_pkt.pp_rd;          
                rs[vacancy].rob_id    <= renamed_pkt.rob_id;
                rs[vacancy].is_branch <= renamed_pkt.is_branch;
                rs[vacancy].is_load   <= renamed_pkt.is_load;
                rs[vacancy].is_store  <= renamed_pkt.is_store;
                rs[vacancy].lsq_id    <= renamed_pkt.lsq_id;
                rs[vacancy].is_jump   <= renamed_pkt.is_jump;
                
                if (rs1_ready_from_prf) begin
                    rs[vacancy].rs1_value <= rs1_data_from_prf;
                    rs[vacancy].rs1_ready <= 1'b1;
                end
                else if (cdb_in.valid && (renamed_pkt.pp_rs1 == cdb_in.tag)) begin
                    rs[vacancy].rs1_value <= cdb_in.data;
                    rs[vacancy].rs1_ready <= 1'b1;
                end
                else begin
                    rs[vacancy].rs1_ready <= 1'b0; 
                end

                if(!renamed_pkt.uses_rs2)begin
                    rs[vacancy].rs2_value <= renamed_pkt.imm;
                    rs[vacancy].rs2_ready <= 1;
                end
                //以下為使用rs2的情況
                else if(rs2_ready_from_prf)begin
                    rs[vacancy].rs2_value <= rs2_data_from_prf;
                    rs[vacancy].rs2_ready <= 1;
                end
                else if (cdb_in.valid && (renamed_pkt.pp_rs2 == cdb_in.tag)) begin
                    rs[vacancy].rs2_value <= cdb_in.data;
                    rs[vacancy].rs2_ready <= 1'b1;
                end
                else begin
                    rs[vacancy].rs2_ready <= 1'b0;
                end

            end // if(renamed_pkt.valid && dispatch_en) 的 end 應該在這裡
            for(int k=0;k<8;k++)begin
                if(rs[k].busy && !rs[k].rs1_ready && cdb_in.valid)begin
                    rs[k].rs1_value <= (rs[k].pp_rs1 == cdb_in.tag) ? cdb_in.data : rs[k].rs1_value;
                    rs[k].rs1_ready <= (rs[k].pp_rs1 == cdb_in.tag) ? 1'b1 : rs[k].rs1_ready; 
                end
                if(rs[k].busy && !rs[k].rs2_ready && cdb_in.valid)begin
                    rs[k].rs2_value <= (rs[k].pp_rs2 == cdb_in.tag) ? cdb_in.data : rs[k].rs2_value;
                    rs[k].rs2_ready <= (rs[k].pp_rs2 == cdb_in.tag) ? 1'b1 : rs[k].rs2_ready;
                end
            end
        end
    end
    
    assign rs_full = rs[0].busy && rs[1].busy && rs[2].busy && rs[3].busy && rs[4].busy && rs[5].busy && rs[6].busy && rs[7].busy;
    always_comb begin
        issue_found = 1'b0;
        issue_address = 3'b0;
        for(int p=0;p<8;p++)begin
            if (rs[p].rs1_ready && rs[p].rs2_ready && rs[p].busy)begin
                issue_found = 1'b1;
                issue_address = p[2:0];
                break;
            end
        end
        issue_en = issue_found;
        data_to_ALU = rs[issue_address];
    end
endmodule