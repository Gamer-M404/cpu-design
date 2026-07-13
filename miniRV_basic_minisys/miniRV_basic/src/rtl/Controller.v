`timescale 1ns / 1ps

`include "defines.vh"

module Controller (
    input  wire [ 6:0]  opcode,
    input  wire [ 2:0]  funct3,
    input  wire [ 6:0]  funct7,
    output wire [ 1:0]  npc_op,
    output wire [ 2:0]  sext_op,
    output wire         alua_sel,
    output wire         alub_sel,
    output wire [ 4:0]  alu_op,
    output wire         is_mul,
    output wire         is_div,
    output wire [ 2:0]  ram_r_op,
    output wire [ 3:0]  ram_w_op,
    output wire         rf_we,
    output wire [ 1:0]  rf_wsel
);

    wire ADDI  = (opcode == 7'b0010011) && (funct3 == 3'b000);
    wire ORI   = (opcode == 7'b0010011) && (funct3 == 3'b110);
    wire SLLI  = (opcode == 7'b0010011) && (funct3 == 3'b001) && (funct7 == 7'b0000000);
    wire LW    = (opcode == 7'b0000011) && (funct3 == 3'b010);
    wire BEQ   = (opcode == 7'b1100011) && (funct3 == 3'b000);
    wire BNE   = (opcode == 7'b1100011) && (funct3 == 3'b001);
    wire LUI   = (opcode == 7'b0110111);
    wire JAL   = (opcode == 7'b1101111);
 
    // npc_op
    wire NPC_OP_BRA = BEQ | BNE;
    wire NPC_OP_JMP = JAL;
    wire NPC_OP_PC4 = !NPC_OP_BRA & !NPC_OP_JMP;
    
    // rf_we
    wire RF_OP_WE = ADDI | ORI | SLLI | LW | LUI | JAL;
    
    // rf_wsel
    wire WB_OP_ALU = ADDI | ORI | SLLI;
    wire WB_OP_RAM = LW;
    wire WB_OP_PC4 = JAL;
    wire WB_OP_EXT = LUI;
    
    // sext_op
    wire EXT_OP_I = ADDI | ORI | SLLI | LW;
    wire EXT_OP_B = BEQ | BNE;
    wire EXT_OP_U = LUI;
    wire EXT_OP_J = JAL;
    
    // alu_op
    wire ALU_OP_ADD   = ADDI | LW;
    wire ALU_OP_OR    = ORI;
    wire ALU_OP_SLL   = SLLI;
    wire ALU_OP_EQ    = BEQ;
    wire ALU_OP_NE    = BNE;
    
    // alua_sel
    wire ALU_A_SEL_RS1 = ADDI | ORI | SLLI | LW | BEQ | BNE | JAL;
    wire ALU_A_SEL_PC  = 1'b0;
                        
    // alub_sel
    wire ALU_B_SEL_RS2 = BEQ | BNE;
    wire ALU_B_SEL_EXT = ADDI | ORI | SLLI | LW | JAL;
        
    // ram_r_op
    wire RAM_EXT_B  = 1'b0;
    wire RAM_EXT_BU = 1'b0;
    wire RAM_EXT_H  = 1'b0;
    wire RAM_EXT_HU = 1'b0;
    wire RAM_EXT_W  = LW;

    // ram_w_op
    wire RAM_W_B  = 1'b0;
    wire RAM_W_H  = 1'b0;
    wire RAM_W_W  = 1'b0;
    
    assign npc_op = {2{NPC_OP_PC4}} & `NPC_PC4
                  | {2{NPC_OP_BRA}} & `NPC_BRA
                  | {2{NPC_OP_JMP}} & `NPC_JMP;

    assign rf_we = RF_OP_WE;

    assign rf_wsel = {2{WB_OP_ALU}} & `WB_ALU
                   | {2{WB_OP_RAM}} & `WB_RAM
                   | {2{WB_OP_PC4}} & `WB_PC4
                   | {2{WB_OP_EXT}} & `WB_EXT;

    assign sext_op = {3{EXT_OP_I}} & `EXT_I
                   | {3{EXT_OP_B}} & `EXT_B
                   | {3{EXT_OP_U}} & `EXT_U
                   | {3{EXT_OP_J}} & `EXT_J;
                   
    assign alu_op = {5{ALU_OP_ADD  }} & `ALU_ADD
                  | {5{ALU_OP_OR   }} & `ALU_OR
                  | {5{ALU_OP_SLL  }} & `ALU_SLL
                  | {5{ALU_OP_EQ   }} & `ALU_EQ
                  | {5{ALU_OP_NE   }} & `ALU_NE;

    assign alua_sel = ALU_A_SEL_PC & `ALU_A_PC | ALU_A_SEL_RS1 & `ALU_A_RS1;

    assign alub_sel = ALU_B_SEL_RS2 & `ALU_B_RS2 | ALU_B_SEL_EXT & `ALU_B_EXT;
  
    assign ram_r_op = {3{RAM_EXT_B }} & `RAM_EXT_B
                    | {3{RAM_EXT_BU}} & `RAM_EXT_BU
                    | {3{RAM_EXT_H }} & `RAM_EXT_H
                    | {3{RAM_EXT_HU}} & `RAM_EXT_HU
                    | {3{RAM_EXT_W }} & `RAM_EXT_W;

    assign ram_w_op = {4{RAM_W_B}} & `RAM_WE_B
                    | {4{RAM_W_H}} & `RAM_WE_H
                    | {4{RAM_W_W}} & `RAM_WE_W;

    assign is_mul = 1'b0;
    assign is_div = 1'b0;

endmodule
