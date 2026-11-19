//-----------------------------------------------------------------------------
// accel_pkg.sv
//-----------------------------------------------------------------------------
// Shared constants for the SIGARCH ML accelerator: instruction encodings,
// CSR (host register) map and error codes.
//
// The authoritative human-readable description of everything in this file is
// docs/isa.md (instructions) and docs/memory-map.md (registers). If you change
// an encoding here, change sw/common/accel_isa.h and the docs too.
//-----------------------------------------------------------------------------

package accel_pkg;

  //===========================================================================
  // RV32I base opcodes (subset executed by the accelerator's control core)
  //===========================================================================
  localparam logic [6:0] OPC_LUI    = 7'b0110111;
  localparam logic [6:0] OPC_AUIPC  = 7'b0010111;
  localparam logic [6:0] OPC_JAL    = 7'b1101111;
  localparam logic [6:0] OPC_JALR   = 7'b1100111;
  localparam logic [6:0] OPC_BRANCH = 7'b1100011;
  localparam logic [6:0] OPC_LOAD   = 7'b0000011;
  localparam logic [6:0] OPC_STORE  = 7'b0100011;
  localparam logic [6:0] OPC_OPIMM  = 7'b0010011;
  localparam logic [6:0] OPC_OP     = 7'b0110011;
  localparam logic [6:0] OPC_FENCE  = 7'b0001111;
  localparam logic [6:0] OPC_SYSTEM = 7'b1110011;

  //===========================================================================
  // Accelerator extension opcodes (RISC-V "custom" opcode space)
  //===========================================================================
  localparam logic [6:0] OPC_VARITH = 7'b0001011;  // custom-0 (0x0B) vector arith
  localparam logic [6:0] OPC_VMEM   = 7'b0101011;  // custom-1 (0x2B) vector cfg/mem
  localparam logic [6:0] OPC_MATRIX = 7'b1011011;  // custom-2 (0x5B) matrix unit
  localparam logic [6:0] OPC_CTRL   = 7'b1111011;  // custom-3 (0x7B) multi-core control

  // ---- OPC_CTRL ---------------------------------------------------------------
  // barrier: wait until every launched core has reached a barrier (or halted)
  localparam logic [31:0] INSN_BARRIER = 32'h0000_007B;
  // hcpy rd, rs1, rs2 (R-type, funct3 = 1, funct7 = 0): copy x[rs2] bf16
  // elements (halfwords) from address x[rs1] to address x[rd]
  localparam logic [2:0]  CTRL_F3_HCPY = 3'd1;

  // ---- OPC_VARITH: R-type, funct7 = operation, funct3 = operand form -------
  //   .vv : vd = vs2 OP vs1
  //   .vf : vd = vs2 OP broadcast(x[rs1][15:0])
  localparam logic [2:0] VFORM_VV   = 3'd0;
  localparam logic [2:0] VFORM_VF   = 3'd4;

  localparam logic [6:0] VOP_ADD    = 7'h00;  // vd = vs2 + op1
  localparam logic [6:0] VOP_SUB    = 7'h01;  // vd = vs2 - op1
  localparam logic [6:0] VOP_MUL    = 7'h02;  // vd = vs2 * op1
  localparam logic [6:0] VOP_MAX    = 7'h03;  // vd = max(vs2, op1)
  localparam logic [6:0] VOP_MIN    = 7'h04;  // vd = min(vs2, op1)
  localparam logic [6:0] VOP_MACC   = 7'h05;  // vd = vd + vs2 * op1
  localparam logic [6:0] VOP_REDSUM = 7'h08;  // vd[0] = op1[0] + sum(vs2[0..vl-1])
  localparam logic [6:0] VOP_REDMAX = 7'h09;  // vd[0] = max(op1[0], vs2[0..vl-1])
  localparam logic [6:0] VOP_MV     = 7'h10;  // vd = op1           (vmv.v.v / vmv.v.x)
  localparam logic [6:0] VOP_MV_X_S = 7'h11;  // x[rd] = zext(vs2[0])
  localparam logic [6:0] VOP_MV_S_X = 7'h12;  // vd[0] = x[rs1][15:0]

  // ---- OPC_VMEM: funct3 selects the instruction -----------------------------
  localparam logic [2:0] VMEM_SETVL = 3'd0;   // I-type: x[rd] = vl = min(avl, VLMAX)
  localparam logic [2:0] VMEM_VLE   = 3'd1;   // I-type: vd  <- mem[x[rs1] + imm]
  localparam logic [2:0] VMEM_VSE   = 3'd2;   // S-type: vs3 -> mem[x[rs1] + imm]

  // ---- OPC_MATRIX: R-type, funct7 = operation -------------------------------
  //   funct3 = MLAYOUT_ROW (0): memory row r      <-> register row r
  //   funct3 = MLAYOUT_COL (1): memory row r      <-> register column r
  //            (".t" forms: the matrix is stored column-major / transposed)
  //   MOP_ZERO and MOP_MACC require funct3 = 0.
  localparam logic [2:0] MLAYOUT_ROW = 3'd0;
  localparam logic [2:0] MLAYOUT_COL = 3'd1;
  localparam logic [6:0] MOP_LD     = 7'h00;  // tile[rd]  <- rows @ x[rs1], stride x[rs2]
  localparam logic [6:0] MOP_ST     = 7'h01;  // tile[rd]  -> rows @ x[rs1], stride x[rs2]
  localparam logic [6:0] MOP_STA    = 7'h02;  // bf16(acc[rd]) -> rows @ x[rs1], stride x[rs2]
  localparam logic [6:0] MOP_ZERO   = 7'h03;  // acc[rd] = 0
  localparam logic [6:0] MOP_MACC   = 7'h04;  // acc[rd] += tile[rs1] x tile[rs2]

  // ---- Read-only CSRs readable by kernels via `csrr` ------------------------
  localparam logic [11:0] KCSR_CYCLE    = 12'hC00;
  localparam logic [11:0] KCSR_INSTRET  = 12'hC02;
  localparam logic [11:0] KCSR_VL       = 12'hC20;
  localparam logic [11:0] KCSR_VLENB    = 12'hC22;
  localparam logic [11:0] KCSR_CYCLEH   = 12'hC80;
  localparam logic [11:0] KCSR_INSTRETH = 12'hC82;
  localparam logic [11:0] KCSR_MHARTID  = 12'hF14;  // this core's index, 0 .. ncores-1
  localparam logic [11:0] KCSR_NCORES   = 12'hFC0;  // number of cores launched together
  localparam logic [11:0] KCSR_SPADSZ   = 12'hFC1;  // scratchpad bytes per core (0 = none)
  localparam logic [11:0] KCSR_UNITS    = 12'hFC2;  // bit 0: this core has a VPU, bit 1: an MXU

  //===========================================================================
  // Kernel address map (accelerator side)
  //===========================================================================
  // Each core's private scratchpad appears at SPAD_BASE (same address in every
  // core). Addresses with the top byte SPAD_BASE[31:24] never reach HBM.
  localparam logic [31:0] SPAD_BASE     = 32'h2000_0000;
  localparam int          SPAD_WINDOW_W = 24;          // 16 MiB window

  //===========================================================================
  // Error causes (STATUS.ERR_CAUSE)
  //===========================================================================
  localparam logic [7:0] ERR_NONE       = 8'd0;
  localparam logic [7:0] ERR_ILLEGAL    = 8'd1;  // undecodable / unsupported instruction
  localparam logic [7:0] ERR_MISALIGNED = 8'd2;  // misaligned fetch / load / store
  localparam logic [7:0] ERR_BUS        = 8'd3;  // AXI SLVERR/DECERR from HBM
  localparam logic [7:0] ERR_EBREAK     = 8'd4;  // kernel executed ebreak
  localparam logic [7:0] ERR_BAD_REG    = 8'd5;  // tile/accumulator index out of range

  //===========================================================================
  // Host-visible CSR map (byte offsets on the AXI4-Lite port)
  //===========================================================================
  localparam logic [11:0] CSR_ID         = 12'h000;  // RO  magic/version
  localparam logic [11:0] CSR_CTRL       = 12'h004;  // WO  bit0 = START
  localparam logic [11:0] CSR_STATUS     = 12'h008;  // RO/W1C
  localparam logic [11:0] CSR_IRQ_EN     = 12'h00C;  // RW  bit0 = enable irq on done/error
  localparam logic [11:0] CSR_START_PC   = 12'h010;  // RW  kernel entry point (HBM address)
  localparam logic [11:0] CSR_ERR_PC     = 12'h014;  // RO  PC of faulting / final instruction
  localparam logic [11:0] CSR_ERR_INSN   = 12'h018;  // RO  encoding of that instruction
  localparam logic [11:0] CSR_CYCLES_LO  = 12'h020;  // RO  cycles of current/last run
  localparam logic [11:0] CSR_CYCLES_HI  = 12'h024;
  localparam logic [11:0] CSR_INSTRET_LO = 12'h028;  // RO  instructions retired
  localparam logic [11:0] CSR_INSTRET_HI = 12'h02C;
  localparam logic [11:0] CSR_CORES      = 12'h030;  // RW  cores to launch (1..NUM_CORES), reset 1
  localparam logic [11:0] CSR_ERR_CORE   = 12'h034;  // RO  core that reported ERR_PC/ERR_INSN
  localparam logic [11:0] CSR_CFG0       = 12'h040;  // RO  VLEN
  localparam logic [11:0] CSR_CFG1       = 12'h044;  // RO  {MXU_ROWS, NUM_ACCS, NUM_TREGS, MAT_DIM} bytes
  localparam logic [11:0] CSR_CFG2       = 12'h048;  // RO  {ICACHE_LINES[15:0], HBM_DATA_W[15:0]}
  localparam logic [11:0] CSR_CFG3       = 12'h04C;  // RO  {SPAD_KB[15:0], NUM_MXUS[3:0], NUM_VPUS[3:0], NUM_CORES[7:0]}
  localparam logic [11:0] CSR_ARG0       = 12'h080;  // RW  ARG0..ARG7 at 0x080..0x09C -> a0..a7

  localparam logic [31:0] ACCEL_ID_VALUE = 32'hACCE_0200;  // "ACCE", v2.0 (multi-core + scratchpad)

  // STATUS bit positions
  localparam int STATUS_BUSY  = 0;
  localparam int STATUS_DONE  = 1;
  localparam int STATUS_ERROR = 2;
  // STATUS[15:8] = error cause

  //===========================================================================
  // AXI constants
  //===========================================================================
  localparam logic [1:0] AXI_BURST_INCR = 2'b01;
  localparam logic [1:0] AXI_RESP_OKAY  = 2'b00;
  localparam logic [1:0] AXI_RESP_SLVERR= 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR= 2'b11;

endpackage : accel_pkg