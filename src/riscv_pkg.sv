package riscv_pkg;
    typedef logic [5:0] phys_reg_t; // 物理暫存器編號 (0-63)
    // =======================================================
    // 1. Opcode 定義 (根據 RISC-V 規格書)
    // =======================================================
    typedef enum logic [6:0] {
        OPC_R_TYPE = 7'b0110011, // ADD, SUB, SLT
        OPC_I_ALU  = 7'b0010011, // ADDI
        OPC_LOAD   = 7'b0000011, // LW
        OPC_STORE  = 7'b0100011, // SW
        OPC_BRANCH = 7'b1100011, // BEQ, BNE, BLT, BGE
        OPC_JAL    = 7'b1101111, // JAL (跳轉並連結)
        OPC_JALR   = 7'b1100111, // JALR (暫存器跳轉)
        OPC_LUI    = 7'b0110111, // LUI (載入高位立即數)
        OPC_AUIPC  = 7'b0010111  // AUIPC (PC + imm<<12)
    } opcode_t;

    // =======================================================
    // 2. ALU 運算種類 (用於算術指令)
    // =======================================================
    typedef enum logic [3:0] {
        ALU_NONE,
        ALU_ADD,
        ALU_SUB,
        ALU_SLL, // 邏輯左移
        ALU_SLT, // 小於則設定 (signed)
        ALU_SLTU,// unsigned 版本
        ALU_XOR,
        ALU_SRL, // 邏輯右移
        ALU_SRA, // 算術右移
        ALU_OR,
        ALU_AND
    } alu_op_t;

    // =======================================================
    // 3. 分支比較種類 (用於 Branch 指令)
    // =======================================================
    typedef enum logic [2:0] {
        BR_NONE,
        BR_EQ,   // BEQ (相等則跳轉)
        BR_NE,   // BNE (不相等則跳轉)
        BR_LT,   // BLT (小於則跳轉)
        BR_GE,   // BGE (大於等於則跳轉)
        BR_LTU,
        BR_GEU
    } br_op_t;

    // =======================================================
    // 4. 🔥 萬能指令包裹 (Instruction Packet)
    // =======================================================
    typedef struct packed {
        // --- 基礎資訊 ---
        logic [31:0] pc;
        logic        valid;
        logic [31:0] instr;
        logic [3:0] rob_id;
        // --- 運算資訊 ---
        alu_op_t     alu_op;     // ALU 要做什麼
        br_op_t      br_op;      // Branch 要比什麼
        logic [31:0] imm;        // 解碼完的 32-bit 立即數 (支援所有 Type)

        // --- 重新命名資訊 ---
        phys_reg_t pp_rs1;   // Physical rs1
        phys_reg_t pp_rs2;   // Physical rs2
        phys_reg_t pp_rd;    // Physical rd (新領的)
        phys_reg_t pp_rd_old;// 被覆蓋掉的舊 rd (用於退休回收)
        
        // --- 暫存器控制 ---
        logic [4:0]  rs1_addr;
        logic [4:0]  rs2_addr;
        logic [4:0]  rd_addr;
        logic        uses_rs1;
        logic        uses_rs2;
        logic        writes_rd;

        // --- 記憶體與跳轉控制 ---
        logic        is_load;    // 是否是 LW
        logic        is_store;   // 是否是 SW
        logic        is_branch;  // 是否是 Branch 指令
        logic        is_jump;    // 是否是 JAL/JALR 指令

        // --- LW/SW所需要信號 ---
        logic [2:0] lsq_id; 
    } inst_pkt_t;
    // =======================================================
    // 5. ROB 專屬條目 (只存退休需要的必要資訊)
    // =======================================================
    typedef struct packed {
        logic        valid;       // 這一格是否有指令
        logic        ready;       // 指令是否執行完畢 (等待 CDB 廣播更新)
        logic [4:0]  rd_addr;     // 邏輯目的暫存器 (Debug 或 R-RAT 更新用)
        logic [5:0]  pp_rd_old;   // 舊的物理暫存器 (退休時還給 Free List)
        logic [5:0]  pp_rd;
        logic        writes_rd;   // 這條指令是否真的有寫入動作 (決定要不要還鑰匙)
        logic        is_branch;   // 是否為分支指令 (未來處理猜錯時需要)
        logic [31:0] target_pc; // 存放如果分支發生/不發生時，正確的跳轉地址
        logic        bad_branch;
        logic        is_load;
        logic        is_store;
        logic [2:0]  lsq_id;
    } rob_entry_t;
    // =======================================================
    // 5. CDB區域
    // =======================================================
    typedef struct packed{
        logic valid;
        logic [31:0] data;//運算結果
        phys_reg_t tag;// pp_rd
        logic [3:0] rob_id;//rob的entry是多少
        logic bad_branch;//是否分支預測錯誤
        logic [31:0] target_pc;//正確的跳轉地址
    }cdb_pkt_t;
    // =======================================================
    // 6. RS區域
    // =======================================================
    typedef struct packed{
        logic busy;
        logic issue_en;
        alu_op_t alu_op;
        br_op_t br_op;
        logic is_branch;
        logic [31:0] imm;
        logic [31:0] pc;
        //source reg 1
        logic rs1_ready;
        phys_reg_t pp_rs1;
        logic [31:0] rs1_value;
        //source reg 2
        logic rs2_ready;
        phys_reg_t pp_rs2;
        logic [31:0] rs2_value;
        //destination reg
        phys_reg_t pp_rd;

        logic [3:0] rob_id;
        // memory
        logic       is_load;
        logic       is_store;
        logic [2:0] lsq_id;
        logic       is_jump;
    }rs_entry_t;
    // =======================================================
    // 7. LSQ區域
    // =======================================================
typedef struct packed {
    logic        valid;        // 這格有沒有指令
    logic [3:0]  rob_id;       // 連回 ROB
    logic        is_load;      // 1=LW, 0=SW
    
    // Address
    logic        addr_ready;   // ALU 算完了沒
    logic [31:0] addr;         // effective address
    
    // Data
    logic        data_ready;
    logic [31:0] data;
    
    // LW 專用
    phys_reg_t   pp_rd;        // 結果要寫的 phys reg
    logic        completed;    // 已上 CDB
    logic [31:0] pc;           // violation 時跳回的 PC
} lsq_entry_t;
endpackage