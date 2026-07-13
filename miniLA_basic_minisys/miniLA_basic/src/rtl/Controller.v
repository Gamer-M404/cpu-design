`timescale 1ns / 1ps

`include "defines.vh"

module Controller (
    input  wire [31:15] inst_31_15,
    output wire [ 1: 0] npc_op,
    output wire [ 2: 0] ext_op,
    output wire         r2_sel,
    output wire         alua_sel,
    output wire         alub_sel,
    output wire [ 4: 0] alu_op,
    output wire         is_mul,
    output wire         is_div,
    output wire [ 2: 0] ram_r_op,
    output wire [ 3: 0] ram_w_op,
    output wire         rf_we,
    output wire         wr_sel,
    output wire [ 1: 0] rf_wsel
);

    wire LU12I_W   = (inst_31_15[31:25] == 7'h0A    );
    wire ADDI_W    = (inst_31_15[31:22] == 10'h00A  );
    wire SLLI_W    = (inst_31_15[31:15] == 17'h00081);
    wire LD_W      = (inst_31_15[31:22] == 10'h0A2  );
    wire BEQ       = (inst_31_15[31:26] == 6'h16    );
    wire BNE       = (inst_31_15[31:26] == 6'h17    );
    wire B         = (inst_31_15[31:26] == 6'h14    );
    wire ORI       = (inst_31_15[31:22] == 10'h00E  );

    // npc_op
    wire NPC_OP_BRCH = BEQ | BNE;
    wire NPC_OP_JMP  = B;
    wire NPC_OP_PC4  = !NPC_OP_BRCH & !NPC_OP_JMP;

    // ext_op
    wire EXT_OP_5   = SLLI_W;
    wire EXT_OP_12U = ORI;
    wire EXT_OP_12  = ADDI_W | LD_W;
    wire EXT_OP_16  = BEQ | BNE;
    wire EXT_OP_20  = LU12I_W;
    wire EXT_OP_26  = B;

    // alu_op
    wire ALU_OP_ADD  = ADDI_W | LD_W;
    wire ALU_OP_OR   = ORI;
    wire ALU_OP_SLL  = SLLI_W;
    wire ALU_OP_EQ   = BEQ;
    wire ALU_OP_NE   = BNE;

    // r2_sel
    wire R2_SEL_RD = BEQ | BNE;

    // alua_sel
    wire ALU_A_SEL_PC = 1'b0;

    // alub_sel
    wire ALU_B_SEL_EXT = SLLI_W | ADDI_W | ORI | LD_W;

    // ram_r_op
    wire RAM_EXT_B  = 1'b0;
    wire RAM_EXT_BU = 1'b0;
    wire RAM_EXT_H  = 1'b0;
    wire RAM_EXT_HU = 1'b0;
    wire RAM_EXT_W  = LD_W;

    // ram_w_op
    wire RAM_W_B  = 1'b0;
    wire RAM_W_H  = 1'b0;
    wire RAM_W_W  = 1'b0;

    // rf_we
    wire RF_OP_WE = LU12I_W | ADDI_W | SLLI_W | LD_W | ORI;

    // wr_sel
    wire WR_SEL_R1 = 1'b0;

    // rf_wsel
    wire WB_OP_ALU = SLLI_W | ADDI_W | ORI;
    wire WB_OP_RAM = LD_W;
    wire WB_OP_EXT = LU12I_W;

    assign npc_op = {2{NPC_OP_PC4 }} & `NPC_PC4  |
                    {2{NPC_OP_BRCH}} & `NPC_BRCH |
                    {2{NPC_OP_JMP }} & `NPC_JMP; 

    assign ext_op = {3{EXT_OP_5  }} & `EXT_5   |
                    {3{EXT_OP_12U}} & `EXT_12U |
                    {3{EXT_OP_12 }} & `EXT_12  |
                    {3{EXT_OP_16 }} & `EXT_16  |
                    {3{EXT_OP_20 }} & `EXT_20  |
                    {3{EXT_OP_26 }} & `EXT_26;

    assign r2_sel = R2_SEL_RD ? `R2_RD : `R2_RK;

    assign alua_sel = ALU_A_SEL_PC ? `ALUA_PC : `ALUA_R1;

    assign alub_sel = ALU_B_SEL_EXT ? `ALUB_EXT : `ALUB_R2;

    assign alu_op = {5{ALU_OP_ADD  }} & `ALU_ADD   |
                    {5{ALU_OP_OR   }} & `ALU_OR    |
                    {5{ALU_OP_SLL  }} & `ALU_SLL   |
                    {5{ALU_OP_EQ   }} & `ALU_BEQ   |
                    {5{ALU_OP_NE   }} & `ALU_BNE;

    assign is_mul = 1'b0;
    assign is_div = 1'b0;
    
    assign ram_r_op = {3{RAM_EXT_B }} & `RAM_EXT_B  |
                      {3{RAM_EXT_BU}} & `RAM_EXT_BU |
                      {3{RAM_EXT_H }} & `RAM_EXT_H  |
                      {3{RAM_EXT_HU}} & `RAM_EXT_HU |
                      {3{RAM_EXT_W }} & `RAM_EXT_W;

    assign ram_w_op = {4{RAM_W_B}} & `RAM_WE_B |
                      {4{RAM_W_H}} & `RAM_WE_H |
                      {4{RAM_W_W}} & `RAM_WE_W;

    assign rf_we = RF_OP_WE;

    assign wr_sel = WR_SEL_R1 ? `WR_Rr1: `WR_RD;

    assign rf_wsel = {2{WB_OP_ALU}} & `WB_ALU |
                     {2{WB_OP_RAM}} & `WB_RAM |
                     {2{WB_OP_EXT}} & `WB_EXT;

endmodule
