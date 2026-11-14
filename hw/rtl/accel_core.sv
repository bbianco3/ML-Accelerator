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
//                                                 +--> VRED -> FETCH (vfredsum/vfredmax:
//                                                 |                   vl cycles in the VPU)
//                                                 +--> IDLE         (ecall, or a fault)
//
// Memory: the core talks to accel_axi_master one bus beat (HBM_DATA_W bits)
// at a time. Every access lies inside one beat, because accesses are
// naturally aligned and VLEN <= HBM_DATA_W, so the core only has to shift
// the data to/from the right byte offset and set the byte strobes.
//
// Not implemented yet (they raise ILLEGAL or are simply absent):
//   * matrix unit, barrier                          (milestones 5, 6)
//   * scratchpad (0x2000_0000 currently goes to HBM and gets a BUS error)
//   * instruction cache: every fetch is an HBM read (~45 cycles)
//-----------------------------------------------------------------------------

module accel_core
  import accel_pkg::*;
#(
  parameter int CORE_ID    = 0,
  parameter int VLEN       = 256,
  parameter int HBM_DATA_W = 256,
  parameter int NUM_VPUS   = 1,
  parameter int NUM_MXUS   = 1
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // ---- launch, from accel_csr ----
  input  logic                    start,
  input  logic [31:0]             start_pc,
  input  logic [7:0][31:0]        args,
  input  logic [7:0]              ncores,       // cores launched together

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
  input  logic                    mem_resp_valid,
  input  logic [HBM_DATA_W-1:0]   mem_resp_rdata,
  input  logic                    mem_resp_err
);

  localparam int  VLMAX   = VLEN / 16;
  localparam int  VL_W    = $clog2(VLMAX) + 1;     // holds 0 .. VLMAX
  localparam int  BYTES   = HBM_DATA_W / 8;
  localparam int  OFF_W   = $clog2(BYTES);
  localparam bit  HAS_VPU = (CORE_ID < NUM_VPUS);

  // synopsys translate_off
  initial begin
    if (VLEN > HBM_DATA_W)
      $fatal(1, "accel_core: VLEN (%0d) > HBM_DATA_W (%0d) is not supported yet", VLEN, HBM_DATA_W);
  end
  // synopsys translate_on

  //===========================================================================
  // Architectural state
  //===========================================================================
  typedef enum logic [2:0] {
    S_IDLE, S_FETCH, S_FETCH_WAIT, S_EXEC, S_MEM, S_MEM_WAIT, S_VRED
  } state_e;

  state_e          state;
  logic [31:0]     pc;
  logic [31:0]     insn;            // the instruction being executed
  logic [31:0]     xreg [32];       // x0..x31; x0 is never written
  logic [VL_W-1:0] vl;
  logic [7:0]      ncores_q;
  logic [63:0]     cycle_cnt, instret_cnt;

  assign busy    = (state != S_IDLE);
  assign instret = instret_cnt;

  //===========================================================================
  // Decode: instruction fields and immediates
  //===========================================================================
  logic [6:0]  opcode, funct7;
  logic [2:0]  funct3;
  logic [4:0]  rd, rs1, rs2;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  logic [31:0] rs1v, rs2v;

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
  // Vector unit
  //===========================================================================
  logic            vpu_ar_en, vpu_ld_en, vpu_sx_en, vpu_red_start, vpu_red_done;
  logic [VLEN-1:0] vpu_rd_data, vpu_ld_data;

  accel_vpu #(.VLEN(VLEN)) u_vpu (
    .clk, .rst_n,
    .vl,
    .ar_en     (vpu_ar_en),
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
      KCSR_SPADSZ:   csr_val = 32'd0;           // no scratchpad yet (milestone 6)
      KCSR_UNITS:    csr_val = {30'd0, 1'b0, HAS_VPU};  // MXU bit set in milestone 5
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

  logic [31:0]     alu_b, alu_out;
  logic            br_taken;
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
          // element-wise: all lanes in one cycle
          VOP_ADD, VOP_SUB, VOP_MUL, VOP_MAX, VOP_MIN, VOP_MACC, VOP_MV: begin
            ex_next   = 1'b1;
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

      default: ex_fault = 1'b1;
    endcase

    // Anything that faulted without a specific cause is an illegal instruction
    if (ex_fault && ex_cause == ERR_NONE) ex_cause = ERR_ILLEGAL;
  end

  assign vpu_ar_en     = (state == S_EXEC) && ex_vpu_ar;
  assign vpu_sx_en     = (state == S_EXEC) && ex_vpu_sx;
  assign vpu_red_start = (state == S_EXEC) && ex_vred;

  //===========================================================================
  // Memory request (MEM state) and response data (MEM_WAIT / FETCH_WAIT)
  //===========================================================================
  logic [OFF_W-1:0]      mem_off;          // byte offset inside the beat
  logic [BYTES-1:0]      st_mask;          // which bytes the store writes (before shift)
  logic [HBM_DATA_W-1:0] st_data;          // store data (before shift)
  logic [HBM_DATA_W-1:0] ld_shifted;       // response beat shifted down to the access

  assign mem_off = mem_addr[OFF_W-1:0];

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

  // FETCH uses pc; MEM uses the load/store address.
  assign mem_req_valid = ((state == S_FETCH) && (pc[1:0] == 2'b00)) || (state == S_MEM);
  assign mem_req_write = (state == S_MEM) && mem_write;
  assign mem_req_addr  = (state == S_FETCH) ? pc : mem_addr;
  assign mem_req_wdata = st_data << {mem_off, 3'b000};
  assign mem_req_wstrb = st_mask << mem_off;

  assign ld_shifted = mem_resp_rdata >> {mem_off, 3'b000};

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
      S_FETCH: if (pc[1:0] != 2'b00) begin
        stop_now = 1'b1; stop_cause = ERR_MISALIGNED;          // fetch fault: insn = 0
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
      S_MEM_WAIT: if (mem_resp_valid && mem_resp_err) begin
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
        if (!stop_err) instret_cnt <= instret_cnt + 64'd1;   // ecall retires
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
          if (mem_req_ready) state <= S_FETCH_WAIT;
        end

        S_FETCH_WAIT: begin
          if (mem_resp_valid) begin
            insn  <= fetch_shifted[31:0];
            state <= S_EXEC;
          end
        end

        // ---- execute ----
        S_EXEC: begin
          if (ex_mem)
            state <= S_MEM;
          else if (ex_vred)
            state <= S_VRED;                        // VPU reduction started
          else begin                                // ex_next
            if (ex_rd_we && rd != 5'd0) xreg[rd] <= ex_rd_val;
            if (ex_vl_we) vl <= ex_vl_val;
            pc          <= ex_pc;
            instret_cnt <= instret_cnt + 64'd1;
            state       <= S_FETCH;
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
            state       <= S_FETCH;
          end
        end

        // ---- wait for the VPU's reduction (vl cycles) ----
        S_VRED: begin
          if (vpu_red_done) begin
            pc          <= pc + 32'd4;
            instret_cnt <= instret_cnt + 64'd1;
            state       <= S_FETCH;
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

endmodule : accel_core