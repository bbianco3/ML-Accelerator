//-----------------------------------------------------------------------------
// accel_core.sv
//-----------------------------------------------------------------------------
// One compute core: a small RISC-V control core that runs a kernel out of
// HBM, plus its vector unit.
//
// The control core is an UNPIPELINED multi-cycle state machine. Exactly one
// instruction is in flight; it finishes completely (including its memory
// access) before the next one is fetched. There are no hazards to handle.
//
//   IDLE --start--> FETCH -> FETCH_WAIT -> EXEC --+--> FETCH        (ALU, branch, jump,
//                                                 |                  csrr, vsetvl, vector arith)
//                                                 +--> MEM -> MEM_WAIT -> FETCH
//                                                 |                 (lw/sw..., vle16/vse16)
//                                                 +--> VWAIT -> FETCH (element-wise vector op:
//                                                 |                    VPU pipeline, 3 cycles)
//                                                 +--> VRED -> FETCH (vfredsum/vfredmax:
//                                                 |                   2 cycles per element)
//                                                 +--> MROW -> FETCH
//                                                 |       (mld/mst/msta: MAT_DIM rows,
//                                                 |        requested back to back)
//                                                 +--> MXU_WAIT -> FETCH (mmacc)
//                                                 +--> HCPY_RD <-> HCPY_WR -> FETCH (hcpy:
//                                                 |       copy a run of halfwords, one
//                                                 |       beat-sized chunk at a time;
//                                                 |       hcpy2d: several strided runs)
//                                                 +--> BARRIER -> FETCH  (barrier: wait for
//                                                 |                       every launched core)
//                                                 +--> IDLE         (ecall, or a fault)
//
// Instruction fetch goes through a small instruction cache (accel_icache):
// a hit goes FETCH -> EXEC in one cycle; a miss reads the whole beat from
// memory in FETCH_WAIT, fills the line and uses it. The cache is flushed at
// every launch.
//
// Multi-core: if another core faults, `abort` is raised and this core stops
// (without an error of its own) at its next FETCH or BARRIER.
//
// Memory: the core talks to accel_spad / accel_axi_master one bus beat (HBM_DATA_W bits)
// at a time. Every access lies inside one beat, because accesses are
// naturally aligned and VLEN, MAT_DIM*16 <= HBM_DATA_W, so the core only has to shift
// the data to/from the right byte offset and set the byte strobes.
//
// Not implemented yet (they raise ILLEGAL or are simply absent):
//-----------------------------------------------------------------------------

module accel_core
  import accel_pkg::*;
#(
  parameter int CORE_ID    = 0,
  parameter int VLEN       = 256,
  parameter int HBM_DATA_W = 256,
  parameter int NUM_VPUS   = 1,
  parameter int NUM_MXUS   = 1,
  parameter int MAT_DIM    = 16,
  parameter int NUM_TREGS  = 4,
  parameter int NUM_ACCS   = 2,
  parameter int MXU_ROWS   = 4,
  parameter int SPAD_KB    = 16,
  parameter int ICACHE_LINES = 16
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- launch, from accel_csr ----
  input  logic                    start,
  input  logic [31:0]             start_pc,
  input  logic [7:0][31:0]        args,
  input  logic [7:0]              ncores,       // cores launched together

  // ---- multi-core control, from/to accel_top ----
  output logic                    at_barrier,   // waiting in a barrier
  input  logic                    barrier_go,   // every launched core arrived
  input  logic                    abort,        // another core faulted: stop

  // ---- run status, to accel_top / accel_csr ----
  output logic                    busy,
  output logic                    end_valid,    // 1-cycle pulse: this core stopped
  output logic                    end_error,
  output logic [7:0]              end_cause,
  output logic [31:0]             end_pc,
  output logic [31:0]             end_insn,
  output logic [63:0]             instret,

  // ---- memory, to accel_axi_master ----
  output logic                    mem_req_valid,
  input  logic                    mem_req_ready,
  output logic                    mem_req_write,
  output logic [31:0]             mem_req_addr,
  output logic [HBM_DATA_W-1:0]   mem_req_wdata,
  output logic [HBM_DATA_W/8-1:0] mem_req_wstrb,
  output logic [7:0]              mem_req_len,    // read burst: beats - 1 (else 0)
  input  logic                    mem_resp_valid,
  input  logic [HBM_DATA_W-1:0]   mem_resp_rdata,
  input  logic                    mem_resp_err
);

  localparam int  VLMAX   = VLEN / 16;
  localparam int  VL_W    = $clog2(VLMAX) + 1;     // holds 0 .. VLMAX
  localparam int  BYTES   = HBM_DATA_W / 8;
  localparam int  OFF_W   = $clog2(BYTES);
  localparam bit  HAS_VPU = (CORE_ID < NUM_VPUS);
  localparam bit  HAS_MXU = (CORE_ID < NUM_MXUS);
  localparam int  ROW_BYTES = MAT_DIM * 2;        // one tile row in memory
  localparam int  ROW_IDX_W = $clog2(MAT_DIM);

  // synopsys translate_off
  initial begin
    if (VLEN > HBM_DATA_W)
      $fatal(1, "accel_core: VLEN (%0d) > HBM_DATA_W (%0d) is not supported yet", VLEN, HBM_DATA_W);
    if (MAT_DIM * 16 > HBM_DATA_W)
      $fatal(1, "accel_core: MAT_DIM*16 (%0d) > HBM_DATA_W (%0d) is not supported yet", MAT_DIM * 16, HBM_DATA_W);
  end
  // synopsys translate_on

  //===========================================================================
  // Architectural state
  //===========================================================================
  typedef enum logic [3:0] {
    S_IDLE, S_FETCH, S_FETCH_WAIT, S_EXEC, S_MEM, S_MEM_WAIT, S_VRED,
    S_MROW, S_MROW_WAIT /* unused */, S_MXU_WAIT, S_BARRIER, S_VWAIT,
    S_HCPY_RD, S_HCPY_RD_WAIT, S_HCPY_WR, S_HCPY_WR_WAIT
  } state_e;

  state_e          state;
  logic [31:0]     pc;
  logic [31:0]     insn;            // the instruction being executed
  logic [31:0]     xreg [32];       // x0..x31; x0 is never written
  logic [VL_W-1:0] vl;
  logic [7:0]      ncores_q;
  logic [63:0]     cycle_cnt, instret_cnt;
  logic [ROW_IDX_W-1:0] mrow;       // mld/mst/msta: the next tile row to request
  logic [31:0]     maddr;           // ... and its memory address
  logic [ROW_IDX_W-1:0] mrow_rx;    // the row the next response belongs to
  logic [31:0]     maddr_rx;        // ... and its address (for the in-beat offset)
  logic [ROW_IDX_W:0]   mr_iss;     // rows requested so far (0 .. MAT_DIM)
  logic [ROW_IDX_W:0]   mr_out;     // requests sent, response not back yet
  logic            mr_tgt;          // where those go: 1 = scratchpad, 0 = HBM
  logic            mr_err;          // a row came back with a bus error
  logic            mr_burst;        // mld: all rows in one HBM read burst

  assign busy       = (state != S_IDLE);
  assign at_barrier = (state == S_BARRIER);
  assign instret = instret_cnt;

  //===========================================================================
  // Decode: instruction fields and immediates
  //===========================================================================
  logic [6:0]  opcode, funct7;
  logic [2:0]  funct3;
  logic [4:0]  rd, rs1, rs2;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  logic [31:0] rs1v, rs2v, rdv;          // rdv: rd read as a source (hcpy)

  assign opcode = insn[6:0];
  assign rd     = insn[11:7];
  assign funct3 = insn[14:12];
  assign rs1    = insn[19:15];
  assign rs2    = insn[24:20];
  assign funct7 = insn[31:25];

  assign imm_i = {{20{insn[31]}}, insn[31:20]};
  assign imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
  assign imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  assign imm_u = {insn[31:12], 12'b0};
  assign imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

  assign rs1v = xreg[rs1];          // xreg[0] stays 0
  assign rs2v = xreg[rs2];
  assign rdv  = xreg[rd];

  //===========================================================================
  // Memory instructions: address, size, alignment
  //===========================================================================
  // Valid while the instruction sits in EXEC, MEM and MEM_WAIT (the registers
  // it depends on do not change in between).
  logic        is_load, is_store, is_vload, is_vstore, mem_write;
  logic [31:0] mem_addr;
  logic [31:0] mem_size;            // bytes: 1, 2, 4 or VLEN/8
  logic        mem_misaligned;

  assign is_load   = (opcode == OPC_LOAD);
  assign is_store  = (opcode == OPC_STORE);
  assign is_vload  = (opcode == OPC_VMEM) && (funct3 == VMEM_VLE);
  assign is_vstore = (opcode == OPC_VMEM) && (funct3 == VMEM_VSE);
  assign mem_write = is_store || is_vstore;

  assign mem_addr = rs1v + ((is_store || is_vstore) ? imm_s : imm_i);

  always_comb begin
    if (is_vload || is_vstore) mem_size = VLEN / 8;
    else unique case (funct3[1:0])
      2'b00:   mem_size = 1;            // lb / lbu / sb
      2'b01:   mem_size = 2;            // lh / lhu / sh
      default: mem_size = 4;            // lw / sw
    endcase
  end
  assign mem_misaligned = (mem_addr & (mem_size - 1)) != 0;

  //===========================================================================
  // Instruction cache
  //===========================================================================
  logic        ic_hit;
  logic [31:0] ic_insn;
  logic        ic_hit2;                           // pc + 4 is in the cache
  logic [31:0] ic_insn2;                          // ... and this is it
  logic        fast_next;                         // go to pc + 4 without S_FETCH

  accel_icache #(.LINES(ICACHE_LINES), .HBM_DATA_W(HBM_DATA_W)) u_icache (
    .clk, .rst_n,
    .flush     (start),                           // new launch: forget old code
    .pc        (pc),
    .hit       (ic_hit),
    .insn      (ic_insn),
    .pc2       (pc + 32'd4),
    .hit2      (ic_hit2),
    .insn2     (ic_insn2),
    .fill_en   ((state == S_FETCH_WAIT) && mem_resp_valid && !mem_resp_err),
    .fill_pc   (pc),
    .fill_data (mem_resp_rdata)
  );

  // Fetch overlap: when an instruction finishes and the next one is pc + 4
  // and already in the cache, it is loaded into insn right away and the core
  // goes straight back to S_EXEC, skipping the S_FETCH cycle. (S_FETCH also
  // checks abort, so this does too.) Taken branches and jumps still go
  // through S_FETCH.
  assign fast_next = ic_hit2 && !abort;

  //===========================================================================
  // Vector unit
  //===========================================================================
  logic            vpu_ar_en, vpu_ar_busy, vpu_ld_en, vpu_sx_en, vpu_red_start, vpu_red_done;
  logic [VLEN-1:0] vpu_rd_data, vpu_ld_data;

  accel_vpu #(.VLEN(VLEN)) u_vpu (
    .clk, .rst_n,
    .vl,
    .ar_en     (vpu_ar_en),
    .ar_busy   (vpu_ar_busy),
    .ar_op     (funct7),
    .ar_vf     (funct3 == VFORM_VF),
    .ar_vd     (rd),
    .ar_vs1    (rs1),
    .ar_vs2    (rs2),
    .ar_scalar (rs1v[15:0]),
    .ld_en     (vpu_ld_en),
    .ld_vd     (rd),
    .ld_data   (vpu_ld_data),
    .rd_idx    (rs2),                    // vse16: vs3 / vmv.x.s: vs2, both in rs2
    .rd_data   (vpu_rd_data),
    .sx_en     (vpu_sx_en),               // vmv.s.x
    .sx_vd     (rd),
    .sx_data   (rs1v[15:0]),
    .red_start (vpu_red_start),           // vfredsum / vfredmax
    .red_max   (funct7 == VOP_REDMAX),
    .red_vf    (funct3 == VFORM_VF),
    .red_vd    (rd),
    .red_vs1   (rs1),
    .red_vs2   (rs2),
    .red_scalar(rs1v[15:0]),
    .red_done  (vpu_red_done)
  );

  //===========================================================================
  // Matrix unit
  //===========================================================================
  logic                     mxu_wr_en, mxu_zero, mxu_macc, mxu_busy;
  logic [MAT_DIM*16-1:0]    mxu_wr_data, mxu_rd_data;

  accel_mxu #(
    .MAT_DIM(MAT_DIM), .NUM_TREGS(NUM_TREGS), .NUM_ACCS(NUM_ACCS), .MXU_ROWS(MXU_ROWS)
  ) u_mxu (
    .clk, .rst_n,
    .wr_en   (mxu_wr_en),               // mld: one row per memory response
    .wr_tr   (rd[1:0]),
    .wr_row  (mrow_rx),                 // rows are written as they come back
    .wr_col  (funct3 == MLAYOUT_COL),
    .wr_data (mxu_wr_data),
    .rd_acc  (funct7 == MOP_STA),       // mst reads a tile, msta an accumulator
    .rd_idx  (rd[1:0]),
    .rd_row  (mrow),
    .rd_col  (funct3 == MLAYOUT_COL),
    .rd_data (mxu_rd_data),
    .cmd_zero(mxu_zero),
    .cmd_macc(mxu_macc),
    .cmd_acc (rd[1:0]),
    .cmd_ta  (rs1[1:0]),
    .cmd_tb  (rs2[1:0]),
    .busy    (mxu_busy)
  );

  //===========================================================================
  // Read-only kernel CSRs (csrr)
  //===========================================================================
  logic        csr_ok;
  logic [31:0] csr_val;

  always_comb begin
    csr_ok  = 1'b1;
    csr_val = '0;
    unique case (insn[31:20])
      KCSR_CYCLE:    csr_val = cycle_cnt[31:0];
      KCSR_CYCLEH:   csr_val = cycle_cnt[63:32];
      KCSR_INSTRET:  csr_val = instret_cnt[31:0];
      KCSR_INSTRETH: csr_val = instret_cnt[63:32];
      KCSR_VL:       csr_val = 32'(vl);
      KCSR_VLENB:    csr_val = 32'(VLEN / 8);
      KCSR_MHARTID:  csr_val = 32'(CORE_ID);
      KCSR_NCORES:   csr_val = 32'(ncores_q);
      KCSR_SPADSZ:   csr_val = 32'(SPAD_KB * 1024);
      KCSR_UNITS:    csr_val = {30'd0, HAS_MXU, HAS_VPU};
      default:       csr_ok  = 1'b0;
    endcase
  end

  //===========================================================================
  // EXEC: what does the current instruction do?
  //===========================================================================
  // Outcome of EXEC, one of:
  //   ex_next   : finished; optionally write rd, go to ex_pc
  //   ex_mem    : go to MEM for the load/store
  //   ex_done   : ecall, stop successfully
  //   ex_fault  : stop with error ex_cause
  logic            ex_next, ex_mem, ex_done, ex_fault;
  logic [7:0]      ex_cause;
  logic            ex_rd_we;
  logic [31:0]     ex_rd_val, ex_pc;
  logic            ex_vl_we;
  logic [VL_W-1:0] ex_vl_val;
  logic            ex_vpu_ar, ex_vpu_sx, ex_vred;
  logic            ex_mrow, ex_mzero, ex_mmacc, ex_barrier, ex_hcpy;

  logic [31:0]     alu_b, alu_out;
  logic            br_taken;
  logic            ex_seq;          // the next instruction is pc + 4 (no jump, no taken branch)
  logic [4:0]      shamt;

  always_comb begin
    // ALU: OP uses rs2, OP-IMM uses the immediate
    alu_b = (opcode == OPC_OP) ? rs2v : imm_i;
    shamt = alu_b[4:0];
    unique case (funct3)
      3'b000:  alu_out = ((opcode == OPC_OP) && funct7[5]) ? rs1v - alu_b : rs1v + alu_b;
      3'b001:  alu_out = rs1v << shamt;
      3'b010:  alu_out = {31'd0, $signed(rs1v) < $signed(alu_b)};
      3'b011:  alu_out = {31'd0, rs1v < alu_b};
      3'b100:  alu_out = rs1v ^ alu_b;
      3'b101:  alu_out = funct7[5] ? 32'($signed(rs1v) >>> shamt) : rs1v >> shamt;
      3'b110:  alu_out = rs1v | alu_b;
      default: alu_out = rs1v & alu_b;
    endcase

    // Branch condition
    unique case (funct3)
      3'b000:  br_taken = (rs1v == rs2v);                    // beq
      3'b001:  br_taken = (rs1v != rs2v);                    // bne
      3'b100:  br_taken = ($signed(rs1v) <  $signed(rs2v));  // blt
      3'b101:  br_taken = ($signed(rs1v) >= $signed(rs2v));  // bge
      3'b110:  br_taken = (rs1v <  rs2v);                    // bltu
      default: br_taken = (rs1v >= rs2v);                    // bgeu
    endcase
  end

  assign ex_seq = !((opcode == OPC_JAL) || (opcode == OPC_JALR) ||
                    ((opcode == OPC_BRANCH) && br_taken));

  always_comb begin
    ex_next    = 1'b0;
    ex_mem     = 1'b0;
    ex_done    = 1'b0;
    ex_fault   = 1'b0;
    ex_cause   = ERR_NONE;
    ex_rd_we   = 1'b0;
    ex_rd_val  = '0;
    ex_pc      = pc + 32'd4;
    ex_vl_we   = 1'b0;
    ex_vl_val  = vl;
    ex_vpu_ar  = 1'b0;
    ex_vpu_sx  = 1'b0;
    ex_vred    = 1'b0;
    ex_mrow    = 1'b0;
    ex_mzero   = 1'b0;
    ex_mmacc   = 1'b0;
    ex_barrier = 1'b0;
    ex_hcpy    = 1'b0;

    unique case (opcode)
      OPC_LUI:   begin ex_next = 1'b1; ex_rd_we = 1'b1; ex_rd_val = imm_u;      end
      OPC_AUIPC: begin ex_next = 1'b1; ex_rd_we = 1'b1; ex_rd_val = pc + imm_u; end

      OPC_JAL: begin
        ex_next = 1'b1; ex_rd_we = 1'b1; ex_rd_val = pc + 32'd4;
        ex_pc   = pc + imm_j;
      end

      OPC_JALR: begin
        if (funct3 != 3'b000) ex_fault = 1'b1;
        else begin
          ex_next = 1'b1; ex_rd_we = 1'b1; ex_rd_val = pc + 32'd4;
          ex_pc   = (rs1v + imm_i) & ~32'd1;
        end
      end

      OPC_BRANCH: begin
        if (funct3 == 3'b010 || funct3 == 3'b011) ex_fault = 1'b1;
        else begin
          ex_next = 1'b1;
          if (br_taken) ex_pc = pc + imm_b;
        end
      end

      OPC_OPIMM: begin
        // shifts: funct7 must be 0 (slli/srli) or 0x20 (srai only)
        if ((funct3 == 3'b001 && funct7 != 7'h00) ||
            (funct3 == 3'b101 && funct7 != 7'h00 && funct7 != 7'h20))
          ex_fault = 1'b1;
        else begin
          ex_next = 1'b1; ex_rd_we = 1'b1; ex_rd_val = alu_out;
        end
      end

      OPC_OP: begin
        // funct7 = 0, or 0x20 for sub/sra only (no M extension)
        if (!(funct7 == 7'h00 ||
              (funct7 == 7'h20 && (funct3 == 3'b000 || funct3 == 3'b101))))
          ex_fault = 1'b1;
        else begin
          ex_next = 1'b1; ex_rd_we = 1'b1; ex_rd_val = alu_out;
        end
      end

      OPC_LOAD: begin
        if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) ex_fault = 1'b1;
        else if (mem_misaligned) begin ex_fault = 1'b1; ex_cause = ERR_MISALIGNED; end
        else ex_mem = 1'b1;
      end

      OPC_STORE: begin
        if (funct3 > 3'b010) ex_fault = 1'b1;
        else if (mem_misaligned) begin ex_fault = 1'b1; ex_cause = ERR_MISALIGNED; end
        else ex_mem = 1'b1;
      end

      OPC_FENCE: ex_next = 1'b1;                 // no-op: accesses are already ordered

      OPC_SYSTEM: begin
        if (insn == 32'h0000_0073)       ex_done = 1'b1;                    // ecall
        else if (insn == 32'h0010_0073) begin                               // ebreak
          ex_fault = 1'b1; ex_cause = ERR_EBREAK;
        end
        else if (funct3 == 3'b010 && rs1 == 5'd0 && csr_ok) begin           // csrr
          ex_next = 1'b1; ex_rd_we = 1'b1; ex_rd_val = csr_val;
        end
        else ex_fault = 1'b1;
      end

      // ---- vector configuration and memory ----
      OPC_VMEM: begin
        if (!HAS_VPU) ex_fault = 1'b1;
        else unique case (funct3)
          VMEM_SETVL: begin
            ex_next  = 1'b1;
            ex_vl_we = 1'b1;
            if (rs1 == 5'd0 || rs1v >= VLMAX) ex_vl_val = VL_W'(VLMAX);
            else                              ex_vl_val = rs1v[VL_W-1:0];
            ex_rd_we  = 1'b1;
            ex_rd_val = 32'(ex_vl_val);
          end
          VMEM_VLE, VMEM_VSE: begin
            if (mem_misaligned) begin ex_fault = 1'b1; ex_cause = ERR_MISALIGNED; end
            else ex_mem = 1'b1;
          end
          default: ex_fault = 1'b1;
        endcase
      end

      // ---- vector arithmetic ----
      OPC_VARITH: begin
        if (!HAS_VPU || !(funct3 == VFORM_VV || funct3 == VFORM_VF)) ex_fault = 1'b1;
        else unique case (funct7)
          // element-wise: all lanes at once, through the VPU pipeline (VWAIT)
          VOP_ADD, VOP_SUB, VOP_MUL, VOP_MAX, VOP_MIN, VOP_MACC, VOP_MV: begin
            ex_vpu_ar = 1'b1;
          end
          // reductions: vl cycles in the VPU (nothing at all when vl = 0)
          VOP_REDSUM, VOP_REDMAX: begin
            if (vl == '0) ex_next = 1'b1;
            else          ex_vred = 1'b1;
          end
          // vmv.x.s rd, vs2: x[rd] = zero_extend(vs2[0]); funct3 must be 0
          VOP_MV_X_S: begin
            if (funct3 != VFORM_VV) ex_fault = 1'b1;
            else begin
              ex_next   = 1'b1;
              ex_rd_we  = 1'b1;
              ex_rd_val = {16'd0, vpu_rd_data[15:0]};
            end
          end
          // vmv.s.x vd, rs1: vd[0] = x[rs1][15:0] if vl > 0; funct3 must be 4
          VOP_MV_S_X: begin
            if (funct3 != VFORM_VF) ex_fault = 1'b1;
            else begin
              ex_next   = 1'b1;
              ex_vpu_sx = 1'b1;
            end
          end
          default: ex_fault = 1'b1;
        endcase
      end

      // ---- matrix unit ----
      OPC_MATRIX: begin
        if (!HAS_MXU) ex_fault = 1'b1;
        else unique case (funct7)
          // mld / mst / msta (and .t): MAT_DIM rows through memory
          MOP_LD, MOP_ST, MOP_STA: begin
            if (funct3 != MLAYOUT_ROW && funct3 != MLAYOUT_COL)
              ex_fault = 1'b1;
            else if ((funct7 == MOP_STA) ? (rd >= NUM_ACCS) : (rd >= NUM_TREGS)) begin
              ex_fault = 1'b1; ex_cause = ERR_BAD_REG;
            end
            else if ((rs1v % ROW_BYTES) != 0 || (rs2v % ROW_BYTES) != 0) begin
              ex_fault = 1'b1; ex_cause = ERR_MISALIGNED;
            end
            else ex_mrow = 1'b1;
          end
          // mzero acc: done in this cycle
          MOP_ZERO: begin
            if (funct3 != MLAYOUT_ROW) ex_fault = 1'b1;
            else if (rd >= NUM_ACCS) begin ex_fault = 1'b1; ex_cause = ERR_BAD_REG; end
            else begin ex_next = 1'b1; ex_mzero = 1'b1; end
          end
          // mmacc acc, ta, tb: wait in MXU_WAIT while the array runs
          MOP_MACC: begin
            if (funct3 != MLAYOUT_ROW) ex_fault = 1'b1;
            else if (rd >= NUM_ACCS || rs1 >= NUM_TREGS || rs2 >= NUM_TREGS) begin
              ex_fault = 1'b1; ex_cause = ERR_BAD_REG;
            end
            else ex_mmacc = 1'b1;
          end
          default: ex_fault = 1'b1;
        endcase
      end

      // ---- multi-core control ----
      OPC_CTRL: begin
        if (insn == INSN_BARRIER) ex_barrier = 1'b1;
        else if (funct3 == CTRL_F3_HCPY && funct7 == 7'h00) begin
          // hcpy x[rd] <- x[rs1], x[rs2] halfwords
          if (rdv[0] || rs1v[0]) begin ex_fault = 1'b1; ex_cause = ERR_MISALIGNED; end
          else if (rs2v == 32'd0) ex_next = 1'b1;      // nothing to copy
          else                    ex_hcpy = 1'b1;
        end
        else if (funct3 == CTRL_F3_HCPY2D && funct7 == 7'h00) begin
          // hcpy2d x[rd] <- x[rs1]: x[rs2] = {src stride (bytes), rows, run}
          if (rdv[0] || rs1v[0] || rs2v[16]) begin ex_fault = 1'b1; ex_cause = ERR_MISALIGNED; end
          else if (rs2v[15:8] == 8'd0 || rs2v[7:0] == 8'd0) ex_next = 1'b1;
          else                    ex_hcpy = 1'b1;
        end
        else ex_fault = 1'b1;
      end

      default: ex_fault = 1'b1;
    endcase

    // Anything that faulted without a specific cause is an illegal instruction
    if (ex_fault && ex_cause == ERR_NONE) ex_cause = ERR_ILLEGAL;
  end

  assign vpu_ar_en     = (state == S_EXEC) && ex_vpu_ar;
  assign vpu_sx_en     = (state == S_EXEC) && ex_vpu_sx;
  assign vpu_red_start = (state == S_EXEC) && ex_vred;
  assign mxu_zero      = (state == S_EXEC) && ex_mzero;
  assign mxu_macc      = (state == S_EXEC) && ex_mmacc;

  //===========================================================================
  // Memory request (MEM state) and response data (MEM_WAIT / FETCH_WAIT)
  //===========================================================================
  // EXEC computes the load/store request (address, data, byte mask) and
  // REGISTERS it (ls_*). MEM then drives the memory port straight from those
  // registers, so the long "register read -> address add" path ends at a
  // flip-flop instead of running on through the scratchpad decode and into
  // the AXI master. It costs no extra cycle: MEM already followed EXEC.
  logic [BYTES-1:0]      st_mask;          // which bytes the store writes (before shift)
  logic [HBM_DATA_W-1:0] st_data;          // store data (before shift)
  logic [HBM_DATA_W-1:0] ld_shifted;       // response beat shifted down to the access

  logic [31:0]           ls_addr;          // registered in EXEC, used in MEM / MEM_WAIT
  logic                  ls_write;
  logic [HBM_DATA_W-1:0] ls_data;
  logic [BYTES-1:0]      ls_mask;
  logic [OFF_W-1:0]      ls_off;           // byte offset inside the beat

  assign ls_off = ls_addr[OFF_W-1:0];

  always_comb begin
    st_mask = '0;
    st_data = '0;
    if (is_vstore) begin
      st_data = HBM_DATA_W'(vpu_rd_data);
      for (int i = 0; i < VLMAX; i++)
        if (i < vl) st_mask[2*i +: 2] = 2'b11;     // only lanes i < vl
    end else begin
      st_data = HBM_DATA_W'(rs2v);
      st_mask = BYTES'((1 << mem_size) - 1);       // 1, 2 or 4 bytes
    end
  end

  // Matrix rows: offset of the row inside its beat
  logic [OFF_W-1:0] moff;
  assign moff = maddr[OFF_W-1:0];

  //---------------------------------------------------------------------------
  // hcpy: copy a run of halfwords, one chunk per write
  //---------------------------------------------------------------------------
  // A chunk is as many bytes as fit before the source OR the destination
  // reaches the end of its beat (or the run ends), so a chunk is always
  // inside one source beat and one destination beat:
  //   HCPY_RD : read the beat holding cp_src            -> cp_beat
  //   HCPY_WR : rotate the chunk to its destination offset, write it with
  //             byte strobes for just those bytes; src, dst += chunk
  // If the chunk ended because of the destination beat, the next chunk is
  // still in cp_beat, so the read is skipped.
  // hcpy2d repeats this for cp_rows runs: each run starts cp_stride bytes
  // after the previous run's start (cp_srow), and the destination just keeps
  // going, so the runs land back to back (one im2col patch row).
  //
  // Posted writes: a write to the scratchpad is not waited for (its response
  // comes the next cycle and is only counted, cp_post), so a chunk takes
  // RD, RD_WAIT, WR = 3 cycles, and a same-beat chunk 1. A request to HBM
  // waits until no posted write is outstanding, so responses never pass each
  // other. The instruction's last write is always waited for, so a bus error
  // on it is reported by this instruction.
  localparam int CNT_W  = OFF_W + 1;              // holds 0 .. BYTES
  localparam int ONES_W = BYTES + 1;

  logic [31:0]           cp_src, cp_dst;
  logic [32:0]           cp_left;                 // bytes still to copy in this run
  logic [32:0]           cp_run;                  // bytes per run
  logic [31:0]           cp_srow;                 // source start of this run
  logic [15:0]           cp_stride;               // source bytes from run to run
  logic [7:0]            cp_rows;                 // runs left, this one included
  logic [HBM_DATA_W-1:0] cp_beat;                 // the source beat
  logic [OFF_W-1:0]      cp_soff, cp_doff, cp_rot;
  logic [CNT_W-1:0]      cp_room_s, cp_room_d, cp_chunk;
  logic                  cp_same_src;             // next chunk still in cp_beat
  logic [ONES_W-1:0]     cp_ones;
  logic [HBM_DATA_W-1:0] cp_wdata;
  logic [BYTES-1:0]      cp_wstrb;
  logic [2*HBM_DATA_W-1:0] cp_dbl;
  logic [1:0]            cp_post;                 // posted writes, response not back yet
  logic                  cp_src_spad, cp_dst_spad, cp_last;
  logic                  cp_rd_ok, cp_wr_ok, cp_wr_post, cp_rsp_post, cp_adv;

  always_comb begin
    cp_soff   = cp_src[OFF_W-1:0];
    cp_doff   = cp_dst[OFF_W-1:0];
    cp_room_s = CNT_W'(BYTES) - CNT_W'(cp_soff);
    cp_room_d = CNT_W'(BYTES) - CNT_W'(cp_doff);
    cp_chunk  = (cp_room_s < cp_room_d) ? cp_room_s : cp_room_d;
    if (cp_left < 33'(cp_chunk)) cp_chunk = CNT_W'(cp_left);
    cp_same_src = (cp_chunk < cp_room_s);
    // rotate the beat left by (doff - soff) bytes: source byte soff+k lands
    // on destination byte doff+k
    cp_rot   = cp_doff - cp_soff;
    cp_dbl   = {cp_beat, cp_beat} << {cp_rot, 3'b000};
    cp_wdata = cp_dbl[2*HBM_DATA_W-1 -: HBM_DATA_W];
    cp_ones  = (ONES_W'(1) << cp_chunk) - ONES_W'(1);
    cp_wstrb = cp_ones[BYTES-1:0] << cp_doff;
  end

  // Who uses the memory port: FETCH (pc), MEM (load/store) or MROW (tile row)
  assign cp_src_spad = (cp_src[31:SPAD_WINDOW_W] == SPAD_BASE[31:SPAD_WINDOW_W]);
  assign cp_dst_spad = (cp_dst[31:SPAD_WINDOW_W] == SPAD_BASE[31:SPAD_WINDOW_W]);
  assign cp_last     = (cp_left == 33'(cp_chunk)) && (cp_rows == 8'd1);
  assign cp_rd_ok    = (cp_post == 2'd0) || cp_src_spad;   // posted writes all go to the scratchpad
  assign cp_wr_ok    = (cp_post == 2'd0) || cp_dst_spad;
  assign cp_wr_post  = cp_dst_spad && !cp_last;
  // a response while posted writes are outstanding is theirs (they were sent first)
  assign cp_rsp_post = mem_resp_valid && (cp_post != 2'd0) &&
                       (state == S_HCPY_RD || state == S_HCPY_RD_WAIT ||
                        state == S_HCPY_WR || state == S_HCPY_WR_WAIT);
  // the current chunk is done: posted write taken, or a waited-for write answered
  assign cp_adv      = ((state == S_HCPY_WR) && cp_wr_ok && cp_wr_post && mem_req_ready) ||
                       ((state == S_HCPY_WR_WAIT) && mem_resp_valid && (cp_post == 2'd0));

  always_ff @(posedge clk) begin
    if (!rst_n || (state == S_EXEC))
      cp_post <= 2'd0;
    else
      cp_post <= cp_post + 2'((state == S_HCPY_WR) && cp_wr_ok && cp_wr_post && mem_req_ready)
                         - 2'(cp_rsp_post);
  end

  //---------------------------------------------------------------------------
  // mld / mst / msta: rows are requested back to back
  //---------------------------------------------------------------------------
  // The next row is requested without waiting for the previous response, as
  // long as it goes to the same place (scratchpad or HBM) as the rows still
  // in flight: each of those answers in order, so responses come back in row
  // order (mrow_rx). The AXI master keeps several reads in flight, so the
  // ~45-cycle HBM latency is paid about once per tile instead of once per row
  // (HBM writes are still one at a time: the AXI master holds req_ready low).
  logic                 mr_new_spad;      // the row about to be requested is in the scratchpad
  logic                 mr_issue, mr_hs, mr_rsp;
  logic [ROW_IDX_W:0]   mr_out_nxt;

  assign mr_new_spad = (maddr[31:SPAD_WINDOW_W] == SPAD_BASE[31:SPAD_WINDOW_W]);
  assign mr_issue    = (state == S_MROW) && (mr_iss != (ROW_IDX_W+1)'(MAT_DIM)) && !mr_err
                       && ((mr_out == '0) || (mr_new_spad == mr_tgt));
  assign mr_hs       = mr_issue && mem_req_ready;
  assign mr_rsp      = (state == S_MROW) && mem_resp_valid;
  // a burst is one request for all MAT_DIM rows
  assign mr_out_nxt  = mr_out + (mr_hs ? (mr_burst ? (ROW_IDX_W+1)'(MAT_DIM) : (ROW_IDX_W+1)'(1)) : '0)
                              - (ROW_IDX_W+1)'(mr_rsp);

  always_comb begin
    mem_req_valid = 1'b0;
    mem_req_write = 1'b0;
    mem_req_addr  = pc;
    mem_req_wdata = '0;
    mem_req_wstrb = '0;
    mem_req_len   = 8'd0;
    unique case (state)
      S_FETCH: begin
        mem_req_valid = (pc[1:0] == 2'b00) && !abort && !ic_hit;   // misses only
        mem_req_addr  = pc;
      end
      S_MEM: begin                                   // all from registers
        mem_req_valid = 1'b1;
        mem_req_write = ls_write;
        mem_req_addr  = ls_addr;
        mem_req_wdata = ls_data << {ls_off, 3'b000};
        mem_req_wstrb = ls_mask << ls_off;
      end
      S_HCPY_RD: begin
        mem_req_valid = cp_rd_ok;
        mem_req_addr  = cp_src;
      end
      S_HCPY_WR: begin
        mem_req_valid = cp_wr_ok;
        mem_req_write = 1'b1;
        mem_req_addr  = cp_dst;
        mem_req_wdata = cp_wdata;
        mem_req_wstrb = cp_wstrb;
      end
      S_MROW: begin
        mem_req_valid = mr_issue;
        mem_req_len   = mr_burst ? 8'(MAT_DIM - 1) : 8'd0;
        mem_req_write = (funct7 != MOP_LD);          // mst / msta
        mem_req_addr  = maddr;
        mem_req_wdata = HBM_DATA_W'(mxu_rd_data) << {moff, 3'b000};
        mem_req_wstrb = BYTES'({ROW_BYTES{1'b1}}) << moff;
      end
      default: ;
    endcase
  end

  assign ld_shifted = mem_resp_rdata >> {ls_off, 3'b000};

  // mld: the row from memory goes into the MXU
  logic [HBM_DATA_W-1:0] mrow_shifted;
  assign mrow_shifted = mem_resp_rdata >> {maddr_rx[OFF_W-1:0], 3'b000};
  assign mxu_wr_data  = mrow_shifted[MAT_DIM*16-1:0];
  assign mxu_wr_en    = (state == S_MROW) && mem_resp_valid && !mem_resp_err
                        && (funct7 == MOP_LD);

  // Load result for the scalar register file
  logic [31:0] ld_val;
  always_comb begin
    unique case (funct3)
      3'b000:  ld_val = {{24{ld_shifted[7]}},  ld_shifted[7:0]};    // lb
      3'b001:  ld_val = {{16{ld_shifted[15]}}, ld_shifted[15:0]};   // lh
      3'b100:  ld_val = {24'd0, ld_shifted[7:0]};                   // lbu
      3'b101:  ld_val = {16'd0, ld_shifted[15:0]};                  // lhu
      default: ld_val = ld_shifted[31:0];                           // lw
    endcase
  end

  assign vpu_ld_data = ld_shifted[VLEN-1:0];
  assign vpu_ld_en   = (state == S_MEM_WAIT) && mem_resp_valid && !mem_resp_err && is_vload;

  // The fetched instruction: the 32-bit word at pc inside the beat
  logic [HBM_DATA_W-1:0] fetch_shifted;
  assign fetch_shifted = mem_resp_rdata >> {pc[OFF_W-1:0], 3'b000};

  //===========================================================================
  // State machine
  //===========================================================================
  // Does the core stop this cycle, and how? (ecall, or a fault in any state)
  logic        stop_now, stop_err;
  logic [7:0]  stop_cause;
  logic [31:0] stop_insn;

  always_comb begin
    stop_now   = 1'b0;
    stop_err   = 1'b1;
    stop_cause = ERR_NONE;
    stop_insn  = 32'd0;
    unique case (state)
      S_FETCH: begin
        if (abort) begin
          stop_now = 1'b1; stop_err = 1'b0;                    // another core faulted
        end else if (pc[1:0] != 2'b00) begin
          stop_now = 1'b1; stop_cause = ERR_MISALIGNED;        // fetch fault: insn = 0
        end
      end
      S_BARRIER: if (abort) begin
        stop_now = 1'b1; stop_err = 1'b0;
      end
      S_FETCH_WAIT: if (mem_resp_valid && mem_resp_err) begin
        stop_now = 1'b1; stop_cause = ERR_BUS;
      end
      S_EXEC: begin
        if (ex_fault) begin
          stop_now   = 1'b1;
          stop_cause = ex_cause;
          stop_insn  = (ex_cause == ERR_EBREAK) ? 32'd0 : insn;
        end else if (ex_done) begin
          stop_now  = 1'b1;
          stop_err  = 1'b0;
          stop_insn = insn;
        end
      end
      S_MEM_WAIT, S_HCPY_RD, S_HCPY_RD_WAIT, S_HCPY_WR, S_HCPY_WR_WAIT:
        if (mem_resp_valid && mem_resp_err) begin    // (hcpy: also a posted write's)
        stop_now = 1'b1; stop_cause = ERR_BUS; stop_insn = insn;
      end
      // a bad row: stop once the rows still in flight have come back, so no
      // stray response reaches the next kernel
      S_MROW:
        if (((mem_resp_valid && mem_resp_err) || mr_err) && mr_out_nxt == '0) begin
        stop_now = 1'b1; stop_cause = ERR_BUS; stop_insn = insn;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      pc          <= '0;
      insn        <= '0;
      vl          <= VL_W'(VLMAX);
      ncores_q    <= 8'd1;
      cycle_cnt   <= '0;
      instret_cnt <= '0;
      end_valid   <= 1'b0;
      end_error   <= 1'b0;
      end_cause   <= ERR_NONE;
      end_pc      <= '0;
      end_insn    <= '0;
      mrow        <= '0;
      maddr       <= '0;
      mrow_rx     <= '0;
      maddr_rx    <= '0;
      mr_iss      <= '0;
      mr_out      <= '0;
      mr_tgt      <= 1'b0;
      mr_err      <= 1'b0;
      mr_burst    <= 1'b0;
      ls_addr     <= '0;
      ls_write    <= 1'b0;
      ls_data     <= '0;
      ls_mask     <= '0;
      cp_src      <= '0;
      cp_dst      <= '0;
      cp_left     <= '0;
      cp_run      <= '0;
      cp_srow     <= '0;
      cp_stride   <= '0;
      cp_rows     <= '0;
      cp_beat     <= '0;
      for (int i = 0; i < 32; i++) xreg[i] <= '0;
    end else begin
      end_valid <= 1'b0;                          // pulse
      if (state != S_IDLE) cycle_cnt <= cycle_cnt + 64'd1;

      if (stop_now) begin
        state     <= S_IDLE;
        end_valid <= 1'b1;
        end_error <= stop_err;
        end_cause <= stop_cause;
        end_pc    <= pc;
        end_insn  <= stop_insn;
        if (state == S_EXEC && !stop_err)                       // ecall retires
          instret_cnt <= instret_cnt + 64'd1;
      end else unique case (state)
        // ---- wait for launch ----
        S_IDLE: begin
          if (start && (CORE_ID < ncores)) begin
            pc          <= start_pc;
            vl          <= VL_W'(VLMAX);
            ncores_q    <= ncores;
            cycle_cnt   <= '0;
            instret_cnt <= '0;
            for (int i = 0; i < 32; i++) xreg[i] <= '0;
            for (int i = 0; i < 8; i++)  xreg[10 + i] <= args[i];   // a0..a7
            state <= S_FETCH;
          end
        end

        // ---- fetch the instruction at pc ----
        S_FETCH: begin
          if (ic_hit) begin                         // hit: straight to EXEC
            insn  <= ic_insn;
            state <= S_EXEC;
          end
          else if (mem_req_ready) state <= S_FETCH_WAIT;   // miss: read the beat
        end

        S_FETCH_WAIT: begin
          if (mem_resp_valid) begin                 // (the cache line is filled too)
            insn  <= fetch_shifted[31:0];
            state <= S_EXEC;
          end
        end

        // ---- execute ----
        S_EXEC: begin
          if (ex_mem) begin
            ls_addr  <= mem_addr;                   // register the request
            ls_write <= mem_write;
            ls_data  <= st_data;
            ls_mask  <= st_mask;
            state    <= S_MEM;
          end
          else if (ex_vred)
            state <= S_VRED;                        // VPU reduction started
          else if (ex_mrow) begin
            mrow     <= '0;                         // start at row 0, x[rbase]
            maddr    <= rs1v;
            mrow_rx  <= '0;
            maddr_rx <= rs1v;
            mr_iss   <= '0;
            mr_out   <= '0;
            mr_err   <= 1'b0;
            // HBM read burst: an mld whose rows are whole beats, back to back
            // (stride = one beat), all inside one 4 KiB page (AXI rule)
            mr_burst <= (funct7 == MOP_LD) && (ROW_BYTES == BYTES) && (rs2v == 32'(BYTES))
                        && (rs1v[31:SPAD_WINDOW_W] != SPAD_BASE[31:SPAD_WINDOW_W])
                        && (({1'b0, rs1v[11:0]} + 13'(MAT_DIM * BYTES - 1)) < 13'd4096);
            state    <= S_MROW;
          end
          else if (ex_mmacc)
            state <= S_MXU_WAIT;                    // MXU array started
          else if (ex_barrier)
            state <= S_BARRIER;
          else if (ex_hcpy) begin
            cp_src  <= rs1v;
            cp_srow <= rs1v;
            cp_dst  <= rdv;
            if (funct3 == CTRL_F3_HCPY2D) begin
              cp_left   <= {24'd0, rs2v[7:0], 1'b0};  // halfwords -> bytes
              cp_run    <= {24'd0, rs2v[7:0], 1'b0};
              cp_rows   <= rs2v[15:8];
              cp_stride <= rs2v[31:16];
            end else begin
              cp_left   <= {rs2v, 1'b0};
              cp_run    <= {rs2v, 1'b0};
              cp_rows   <= 8'd1;
              cp_stride <= 16'd0;
            end
            state   <= S_HCPY_RD;
          end
          else if (ex_vpu_ar)
            state <= S_VWAIT;                       // VPU op started
          else begin                                // ex_next
            if (ex_rd_we && rd != 5'd0) xreg[rd] <= ex_rd_val;
            if (ex_vl_we) vl <= ex_vl_val;
            pc          <= ex_pc;
            instret_cnt <= instret_cnt + 64'd1;
            if (ex_seq && fast_next) begin          // falls through: next insn is cached
              insn  <= ic_insn2;
              state <= S_EXEC;
            end else
              state <= S_FETCH;
          end
        end

        // ---- load / store ----
        S_MEM: if (mem_req_ready) state <= S_MEM_WAIT;

        S_MEM_WAIT: begin
          if (mem_resp_valid) begin
            if (is_load && rd != 5'd0) xreg[rd] <= ld_val;
            // (vector loads are written by the VPU: vpu_ld_en)
            pc          <= pc + 32'd4;
            instret_cnt <= instret_cnt + 64'd1;
            if (fast_next) insn <= ic_insn2;
            state       <= fast_next ? S_EXEC : S_FETCH;
          end
        end

        // ---- wait for the VPU's reduction (vl cycles) ----
        S_VRED: begin
          if (vpu_red_done) begin
            pc          <= pc + 32'd4;
            instret_cnt <= instret_cnt + 64'd1;
            if (fast_next) insn <= ic_insn2;
            state       <= fast_next ? S_EXEC : S_FETCH;
          end
        end

        // ---- mld / mst / msta: request rows back to back, collect them in order ----
        S_MROW: begin
          mr_out <= mr_out_nxt;
          if (mr_hs) begin                          // a row request was taken
            mr_iss <= mr_burst ? (ROW_IDX_W+1)'(MAT_DIM) : mr_iss + (ROW_IDX_W+1)'(1);
            mrow   <= mrow + ROW_IDX_W'(1);
            maddr  <= maddr + rs2v;                 // + x[rstride]
            mr_tgt <= mr_new_spad;
          end
          if (mr_rsp) begin                         // a row came back
            // (mld rows are written into the MXU by mxu_wr_en)
            if (mem_resp_err) mr_err <= 1'b1;      // (stop logic ends it)
            mrow_rx  <= mrow_rx + ROW_IDX_W'(1);
            maddr_rx <= maddr_rx + rs2v;
            if (mrow_rx == ROW_IDX_W'(MAT_DIM - 1) && !mem_resp_err && !mr_err) begin
              pc          <= pc + 32'd4;            // that was the last row
              instret_cnt <= instret_cnt + 64'd1;
              if (fast_next) insn <= ic_insn2;
              state       <= fast_next ? S_EXEC : S_FETCH;
            end
          end
        end

        // ---- mmacc: wait for the MAC array ----
        S_MXU_WAIT: begin
          if (!mxu_busy) begin
            pc          <= pc + 32'd4;
            instret_cnt <= instret_cnt + 64'd1;
            if (fast_next) insn <= ic_insn2;
            state       <= fast_next ? S_EXEC : S_FETCH;
          end
        end

        // ---- element-wise vector op: wait until the VPU wrote vd ----
        S_VWAIT: begin
          if (!vpu_ar_busy) begin
            pc          <= pc + 32'd4;
            instret_cnt <= instret_cnt + 64'd1;
            if (fast_next) insn <= ic_insn2;
            state       <= fast_next ? S_EXEC : S_FETCH;
          end
        end

        // ---- hcpy: read a source beat, write chunks of it ----
        S_HCPY_RD: if (cp_rd_ok && mem_req_ready) state <= S_HCPY_RD_WAIT;

        S_HCPY_RD_WAIT: begin
          if (mem_resp_valid && cp_post == 2'd0) begin   // (else: a posted write's)
            cp_beat <= mem_resp_rdata;
            state   <= S_HCPY_WR;
          end
        end

        S_HCPY_WR, S_HCPY_WR_WAIT: begin
          if (state == S_HCPY_WR && cp_wr_ok && !cp_wr_post && mem_req_ready)
            state <= S_HCPY_WR_WAIT;                // wait for this write's response
          if (cp_adv) begin                         // the chunk is written
            cp_src  <= cp_src + 32'(cp_chunk);
            cp_dst  <= cp_dst + 32'(cp_chunk);
            cp_left <= cp_left - 33'(cp_chunk);
            if (cp_left == 33'(cp_chunk)) begin     // that was the run's last chunk
              if (cp_rows == 8'd1) begin            // ... and the last run
                pc          <= pc + 32'd4;
                instret_cnt <= instret_cnt + 64'd1;
                if (fast_next) insn <= ic_insn2;
                state       <= fast_next ? S_EXEC : S_FETCH;
              end else begin                        // next run (overrides src/left)
                cp_rows <= cp_rows - 8'd1;
                cp_srow <= cp_srow + 32'(cp_stride);
                cp_src  <= cp_srow + 32'(cp_stride);
                cp_left <= cp_run;
                state   <= S_HCPY_RD;
              end
            end
            else state <= cp_same_src ? S_HCPY_WR : S_HCPY_RD;
          end
        end

        // ---- barrier: wait until every launched core is here or done ----
        S_BARRIER: begin
          if (barrier_go) begin
            pc          <= pc + 32'd4;
            instret_cnt <= instret_cnt + 64'd1;
            if (fast_next) insn <= ic_insn2;
            state       <= fast_next ? S_EXEC : S_FETCH;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  //===========================================================================
  // +accel_trace: print every instruction as it executes (simulation only)
  //===========================================================================
  // synopsys translate_off
  bit trace_en;
  initial trace_en = $test$plusargs("accel_trace");
  always @(posedge clk) begin
    if (trace_en && rst_n && state == S_EXEC)
      $display("[accel] cyc=%0d core=%0d pc=%08h insn=%08h", cycle_cnt, CORE_ID, pc, insn);
  end
  // synopsys translate_on

  //===========================================================================
  // Simulation only: how many cycles this core spends in each FSM state.
  // Printed when the simulation ends; not synthesized (SYNTHESIS is defined
  // by the synthesis script). S_EXEC cycles = instructions executed.
  //===========================================================================
`ifndef SYNTHESIS
  longint unsigned prof_cycles [16];
  initial for (int i = 0; i < 16; i++) prof_cycles[i] = 0;
  always @(posedge clk)
    if (rst_n && state != S_IDLE) prof_cycles[state] <= prof_cycles[state] + 1;
  final begin
    longint unsigned tot;
    state_e          st;
    tot = 0;
    for (int i = 0; i < 16; i++) tot += prof_cycles[i];
    if (tot != 0) begin
      $display("[core%0d] cycles per state (not idle: %0d)", CORE_ID, tot);
      for (int i = 0; i < 16; i++)
        if (prof_cycles[i] != 0) begin
          st = state_e'(i);
          $display("[core%0d]   %-16s %9d  %5.1f %%", CORE_ID, st.name(),
                   prof_cycles[i], 100.0 * real'(prof_cycles[i]) / real'(tot));
        end
    end
  end
`endif

endmodule : accel_core