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
    wire SLL   = (opcode == 7'b0110011) && (funct3 == 3'b001) && (funct7 == 7'b0000000);
    wire SRL   = (opcode == 7'b0110011) && (funct3 == 3'b101) && (funct7 == 7'b0000000);
    wire SRLI  = (opcode == 7'b0010011) && (funct3 == 3'b101);    
    wire SRA   = (opcode == 7'b0110011) && (funct3 == 3'b101) && (funct7 == 7'b0100000);
    wire SRAI  = (opcode == 7'b0010011) && (funct3 == 3'b101);
    wire ADD   = (opcode == 7'b0110011) && (funct3 == 3'b000) && (funct7 == 7'b0000000);
    wire SUB   = (opcode == 7'b0110011) && (funct3 == 3'b000) && (funct7 == 7'b0100000);
    wire AUIPC = (opcode == 7'b0010111);
    wire XOR   = (opcode == 7'b0110011) && (funct3 == 3'b100) && (funct7 == 7'b0000000);
    wire XORI  = (opcode == 7'b0010011) && (funct3 == 3'b100);
    wire LB    = (opcode == 7'b0000011) && (funct3 == 3'b000);
    wire LBU   = (opcode == 7'b0000011) && (funct3 == 3'b100);
    wire LH    = (opcode == 7'b0000011) && (funct3 == 3'b001);
    wire LHU   = (opcode == 7'b0000011) && (funct3 == 3'b101);
    wire SW    = (opcode == 7'b0100011) && (funct3 == 3'b010);
    wire SB    = (opcode == 7'b0100011) && (funct3 == 3'b000);
    wire SH    = (opcode == 7'b0100011) && (funct3 == 3'b001);
    wire JALR  = (opcode == 7'b1100111) && (funct3 == 3'b000);
 
    // npc_op
    wire NPC_OP_BRA = BEQ | BNE;
    wire NPC_OP_JMP = JAL;
    wire NPC_OP_JALR = JALR;
    wire NPC_OP_PC4 = !NPC_OP_BRA & !NPC_OP_JMP & !NPC_OP_JALR;
    
    // rf_we
    wire RF_OP_WE = ADDI | ORI | SLLI | LW  | LUI | JAL |
                    SLL  | SRL | SRLI | SRA | SRAI| ADD |
                    SUB  |AUIPC| XOR  | XORI| LB  | LBU |
                    LH   | LHU | JALR;
    
    // rf_wsel
    wire WB_OP_ALU = ADDI | ORI | SLLI | SLL | SRL | SRLI |
                     SRA  | SRAI| ADD  | SUB |AUIPC| XOR  |
                     XORI ;
    wire WB_OP_RAM = LW | LB | LBU | LH | LHU;
    wire WB_OP_PC4 = JAL | JALR;
    wire WB_OP_EXT = LUI;
    
    // sext_op
    wire EXT_OP_I = ADDI| ORI | SLLI | LW  | SRLI | SRAI | XORI |
                    LW  | LBU | LH   | LHU | JALR ;
    wire EXT_OP_B = BEQ | BNE;
    wire EXT_OP_U = LUI |AUIPC;
    wire EXT_OP_J = JAL;
    wire EXT_OP_S = SW | SB | SH;
    
    // alu_op
    wire ALU_OP_ADD   = ADDI | LW | ADD |AUIPC| LB | LBU | LH | LHU | SW |
                        SB   | SH | JALR;
    wire ALU_OP_SUB   = SUB;
    wire ALU_OP_OR    = ORI;
    wire ALU_OP_XOR   = XOR | XORI;
    wire ALU_OP_SLL   = SLLI | SLL;
    wire ALU_OP_SRL   = SRL  | SRLI;
    wire ALU_OP_SRA   = SRA | SRAI;
    wire ALU_OP_EQ    = BEQ;
    wire ALU_OP_NE    = BNE;
    
    // alua_sel
    wire ALU_A_SEL_RS1 = ADDI | ORI | SLLI | LW  | BEQ | BNE | JAL | 
                         SLL  | SRL | SRLI | SRA | SRAI| ADD | SUB |
                         XOR  | XORI| LB   | LBU | LH  | LHU | SW  |
                         SB   | SH  | JALR;
    wire ALU_A_SEL_PC  = AUIPC;
                        
    // alub_sel
    wire ALU_B_SEL_RS2 = BEQ  | BNE | SLL | SRL | SRA | ADD | SUB  | XOR;
    wire ALU_B_SEL_EXT = ADDI | ORI | SLLI| LW  | JAL | SRLI| SRAI |AUIPC|
                         XORI | LB  | LBU | LH  | LHU | SW  | SB   | SH  |
                         JALR;
        
    // ram_r_op
    wire RAM_EXT_B  = LB;
    wire RAM_EXT_BU = LBU;
    wire RAM_EXT_H  = LH;
    wire RAM_EXT_HU = LHU;
    wire RAM_EXT_W  = LW;

    // ram_w_op
    wire RAM_W_B  = SB;
    wire RAM_W_H  = SH;
    wire RAM_W_W  = SW;
    
    assign npc_op = {2{NPC_OP_PC4}} & `NPC_PC4
                  | {2{NPC_OP_BRA}} & `NPC_BRA
                  | {2{NPC_OP_JMP}} & `NPC_JMP
                  | {2{NPC_OP_JALR}} & `NPC_JALR;

    assign rf_we = RF_OP_WE;

    assign rf_wsel = {2{WB_OP_ALU}} & `WB_ALU
                   | {2{WB_OP_RAM}} & `WB_RAM
                   | {2{WB_OP_PC4}} & `WB_PC4
                   | {2{WB_OP_EXT}} & `WB_EXT;

    assign sext_op = {3{EXT_OP_I}} & `EXT_I
                   | {3{EXT_OP_B}} & `EXT_B
                   | {3{EXT_OP_U}} & `EXT_U
                   | {3{EXT_OP_J}} & `EXT_J
                   | {3{EXT_OP_S}} & `EXT_S;
                   
    assign alu_op = {5{ALU_OP_ADD  }} & `ALU_ADD
                  | {5{ALU_OP_OR   }} & `ALU_OR
                  | {5{ALU_OP_SLL  }} & `ALU_SLL
                  | {5{ALU_OP_EQ   }} & `ALU_EQ
                  | {5{ALU_OP_NE   }} & `ALU_NE
                  | {5{ALU_OP_SRL  }} & `ALU_SRL 
                  | {5{ALU_OP_SRA  }} & `ALU_SRA
                  | {5{ALU_OP_SUB  }} & `ALU_SUB
                  | {5{ALU_OP_XOR  }} & `ALU_XOR;
 
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
