// -----------------------------------------------------------------------------
// File       : axi4_mem_slave.sv
// Author     : ChatGPT
// Description: AXI4 Full multi-outstanding memory slave model。
//
// 特性：
//   * 支持 AXI4 AW/W/B/AR/R 五通道基础握手
//   * AW 和 W 通道解耦：AW 可提前进入队列，W 按 AW 接收顺序消耗队首事务
//   * 支持多个写/读 outstanding；第一版顺序执行并正确 echo ID，不做乱序返回
//   * 后端接入 byte-addressable memory，可用于 AXI 读写一致性验证
//   * 支持 FIXED / INCR burst；WRAP / reserved burst 会接收事务并返回 SLVERR
//   * 支持 WSTRB byte strobe 部分写
//   * 支持 slave_wr_enable / slave_rd_enable 控制；关闭时仍接收事务并返回 SLVERR，
//     避免 master 因等待 ready 或 response 而永久阻塞
//
// 说明：
//   当前版本为学习和 VIP 对接用 DUT，优先保证握手合法、结构清晰、易调试。
//   cache/prot/qos/region 端口保留用于标准 AXI4 连接，当前不解释复杂语义。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module axi4_mem_slave #(
  parameter int ADDR_WIDTH     = 32,
  parameter int DATA_WIDTH     = 64,
  parameter int ID_WIDTH       = 4,
  parameter int MEM_BYTES      = 4096,
  parameter int WR_OUTSTANDING = 4,
  parameter int RD_OUTSTANDING = 4
) (
  input  logic                     aclk,
  input  logic                     aresetn,

  input  logic                     slave_wr_enable,
  input  logic                     slave_rd_enable,

  // AXI4 write address channel
  input  logic [ID_WIDTH-1:0]      s_axi_awid,
  input  logic [ADDR_WIDTH-1:0]    s_axi_awaddr,
  input  logic [7:0]               s_axi_awlen,
  input  logic [2:0]               s_axi_awsize,
  input  logic [1:0]               s_axi_awburst,
  input  logic                     s_axi_awlock,
  input  logic [3:0]               s_axi_awcache,
  input  logic [2:0]               s_axi_awprot,
  input  logic [3:0]               s_axi_awqos,
  input  logic [3:0]               s_axi_awregion,
  input  logic                     s_axi_awvalid,
  output logic                     s_axi_awready,

  // AXI4 write data channel
  input  logic [DATA_WIDTH-1:0]    s_axi_wdata,
  input  logic [DATA_WIDTH/8-1:0]  s_axi_wstrb,
  input  logic                     s_axi_wlast,
  input  logic                     s_axi_wvalid,
  output logic                     s_axi_wready,

  // AXI4 write response channel
  output logic [ID_WIDTH-1:0]      s_axi_bid,
  output logic [1:0]               s_axi_bresp,
  output logic                     s_axi_bvalid,
  input  logic                     s_axi_bready,

  // AXI4 read address channel
  input  logic [ID_WIDTH-1:0]      s_axi_arid,
  input  logic [ADDR_WIDTH-1:0]    s_axi_araddr,
  input  logic [7:0]               s_axi_arlen,
  input  logic [2:0]               s_axi_arsize,
  input  logic [1:0]               s_axi_arburst,
  input  logic                     s_axi_arlock,
  input  logic [3:0]               s_axi_arcache,
  input  logic [2:0]               s_axi_arprot,
  input  logic [3:0]               s_axi_arqos,
  input  logic [3:0]               s_axi_arregion,
  input  logic                     s_axi_arvalid,
  output logic                     s_axi_arready,

  // AXI4 read data channel
  output logic [ID_WIDTH-1:0]      s_axi_rid,
  output logic [DATA_WIDTH-1:0]    s_axi_rdata,
  output logic [1:0]               s_axi_rresp,
  output logic                     s_axi_rlast,
  output logic                     s_axi_rvalid,
  input  logic                     s_axi_rready
);

  import axi4_defines_pkg::*;

  localparam int STRB_WIDTH  = DATA_WIDTH / 8;
  localparam int WR_PTR_W    = (WR_OUTSTANDING <= 1) ? 1 : $clog2(WR_OUTSTANDING);
  localparam int RD_PTR_W    = (RD_OUTSTANDING <= 1) ? 1 : $clog2(RD_OUTSTANDING);
  localparam int B_PTR_W     = WR_PTR_W;

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
    logic [7:0]            beat;
    logic [1:0]            resp;
  } wr_ctx_t;

  typedef struct packed {
    logic [ID_WIDTH-1:0] id;
    logic [1:0]          resp;
  } b_resp_t;

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
    logic [7:0]            beat;
    logic [1:0]            resp;
  } rd_ctx_t;

  // 后端 memory：AXI4 Full 是 memory-mapped 协议，本模块提供真实 byte storage。
  logic [7:0] mem [0:MEM_BYTES-1];

  wr_ctx_t wr_ctx_fifo [0:WR_OUTSTANDING-1];
  b_resp_t b_resp_fifo [0:WR_OUTSTANDING-1];
  rd_ctx_t rd_ctx_fifo [0:RD_OUTSTANDING-1];

  logic [WR_PTR_W-1:0] wr_ctx_wptr_q;
  logic [WR_PTR_W-1:0] wr_ctx_rptr_q;
  logic [B_PTR_W-1:0]  b_resp_wptr_q;
  logic [B_PTR_W-1:0]  b_resp_rptr_q;
  logic [RD_PTR_W-1:0] rd_ctx_wptr_q;
  logic [RD_PTR_W-1:0] rd_ctx_rptr_q;

  int unsigned wr_ctx_count_q;
  int unsigned b_resp_count_q;
  int unsigned rd_ctx_count_q;

  logic aw_fire;
  logic w_fire;
  logic b_fire;
  logic ar_fire;
  logic r_fire;

  logic wr_ctx_empty;
  logic wr_ctx_full;
  logic b_resp_empty;
  logic b_resp_full;
  logic rd_ctx_empty;
  logic rd_ctx_full;

  logic wr_last_expected;
  logic wr_wstrb_extra;
  logic wr_finishing;
  logic wr_pop_fire;
  logic [1:0] wr_resp_after_w;

  logic rd_pop_fire;
  logic unused_sideband;

  integer mem_init_i;

  initial begin
    assert ((DATA_WIDTH == 32) || (DATA_WIDTH == 64) || (DATA_WIDTH == 128))
      else $error("axi4_mem_slave: DATA_WIDTH must be 32, 64, or 128");
    assert ((DATA_WIDTH % 8) == 0)
      else $error("axi4_mem_slave: DATA_WIDTH must be byte aligned");
    assert (MEM_BYTES > 0)
      else $error("axi4_mem_slave: MEM_BYTES must be greater than 0");
    assert (WR_OUTSTANDING > 0)
      else $error("axi4_mem_slave: WR_OUTSTANDING must be greater than 0");
    assert (RD_OUTSTANDING > 0)
      else $error("axi4_mem_slave: RD_OUTSTANDING must be greater than 0");
  end

  function automatic logic [WR_PTR_W-1:0] inc_wr_ptr(input logic [WR_PTR_W-1:0] ptr);
    begin
      if (int'(ptr) == (WR_OUTSTANDING - 1)) begin
        inc_wr_ptr = '0;
      end else begin
        inc_wr_ptr = ptr + 1'b1;
      end
    end
  endfunction

  function automatic logic [B_PTR_W-1:0] inc_b_ptr(input logic [B_PTR_W-1:0] ptr);
    begin
      if (int'(ptr) == (WR_OUTSTANDING - 1)) begin
        inc_b_ptr = '0;
      end else begin
        inc_b_ptr = ptr + 1'b1;
      end
    end
  endfunction

  function automatic logic [RD_PTR_W-1:0] inc_rd_ptr(input logic [RD_PTR_W-1:0] ptr);
    begin
      if (int'(ptr) == (RD_OUTSTANDING - 1)) begin
        inc_rd_ptr = '0;
      end else begin
        inc_rd_ptr = ptr + 1'b1;
      end
    end
  endfunction

  function automatic logic [ADDR_WIDTH-1:0] next_addr(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0]            size,
    input logic [1:0]            burst
  );
    logic [ADDR_WIDTH-1:0] inc;
    begin
      inc = {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
      inc = inc << size;
      unique case (burst)
        AXI_BURST_FIXED: next_addr = addr;
        AXI_BURST_INCR : next_addr = addr + inc;
        default        : next_addr = addr;  // WRAP 第一版不实现，命令阶段已标记 SLVERR
      endcase
    end
  endfunction

  function automatic logic [DATA_WIDTH/8-1:0] beat_strobe_mask(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0]            size
  );
    int unsigned                bytes;
    int unsigned                lane;
    longint unsigned            addr_u;
    logic [DATA_WIDTH/8-1:0]    mask;
    begin
      bytes  = axi_size_to_bytes(size);
      addr_u = longint unsigned'(addr);
      lane   = int'(addr_u % STRB_WIDTH);
      mask   = '0;

      // 只产生本 beat 中由 AxADDR/AxSIZE 覆盖的合法 byte lane。
      for (int i = 0; i < STRB_WIDTH; i++) begin
        if ((bytes <= STRB_WIDTH) && (i >= lane) && (i < (lane + bytes))) begin
          mask[i] = 1'b1;
        end
      end

      beat_strobe_mask = mask;
    end
  endfunction

  function automatic logic beat_lane_range_ok(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0]            size
  );
    int unsigned     bytes;
    int unsigned     lane;
    longint unsigned addr_u;
    begin
      bytes  = axi_size_to_bytes(size);
      addr_u = longint unsigned'(addr);
      lane   = int'(addr_u % STRB_WIDTH);

      // 第一版简化：不支持一个 transfer 跨越数据总线自然边界的复杂非对齐场景。
      beat_lane_range_ok = (bytes <= STRB_WIDTH) && ((lane + bytes) <= STRB_WIDTH);
    end
  endfunction

  function automatic logic beat_mem_range_ok(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0]            size
  );
    int unsigned     bytes;
    longint unsigned addr_u;
    longint unsigned last_u;
    begin
      bytes  = axi_size_to_bytes(size);
      addr_u = longint unsigned'(addr);
      last_u = addr_u + bytes - 1;
      beat_mem_range_ok = (bytes != 0) && (addr_u < MEM_BYTES) && (last_u < MEM_BYTES);
    end
  endfunction

  function automatic logic burst_cross_4kb(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [7:0]            len,
    input logic [2:0]            size,
    input logic [1:0]            burst
  );
    int unsigned     bytes;
    longint unsigned first_u;
    longint unsigned last_u;
    begin
      bytes   = axi_size_to_bytes(size);
      first_u = longint unsigned'(addr);

      if (burst == AXI_BURST_FIXED) begin
        last_u = first_u + bytes - 1;
      end else begin
        last_u = first_u + (longint unsigned'(len) * bytes) + bytes - 1;
      end

      // AXI4 burst 不应跨越 4KB 边界。
      burst_cross_4kb = ((first_u >> 12) != (last_u >> 12));
    end
  endfunction

  function automatic logic [1:0] check_cmd(
    input logic                  enable,
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [7:0]            len,
    input logic [2:0]            size,
    input logic [1:0]            burst,
    input logic                  lock
  );
    int unsigned     bytes;
    int unsigned     beats;
    longint unsigned beat_addr;
    logic            ok;
    begin
      bytes = axi_size_to_bytes(size);
      beats = int'(len) + 1;
      ok    = 1'b1;

      if (!enable) begin
        ok = 1'b0;
      end

      // 第一版不实现 exclusive/locked access，lock=1 直接返回 SLVERR。
      if (lock) begin
        ok = 1'b0;
      end

      if (bytes > STRB_WIDTH) begin
        ok = 1'b0;
      end

      if (burst_cross_4kb(addr, len, size, burst)) begin
        ok = 1'b0;
      end

      // WRAP 和 reserved burst 当前不实现：接收事务，但返回 SLVERR。
      if ((burst == AXI_BURST_WRAP) || (burst == AXI_BURST_RSVD)) begin
        ok = 1'b0;
      end

      for (int beat = 0; beat < 256; beat++) begin
        if (beat < beats) begin
          if (burst == AXI_BURST_FIXED) begin
            beat_addr = longint unsigned'(addr);
          end else begin
            beat_addr = longint unsigned'(addr) + (longint unsigned'(beat) * bytes);
          end

          if (!beat_lane_range_ok(beat_addr[ADDR_WIDTH-1:0], size)) begin
            ok = 1'b0;
          end

          if (!beat_mem_range_ok(beat_addr[ADDR_WIDTH-1:0], size)) begin
            ok = 1'b0;
          end
        end
      end

      check_cmd = ok ? AXI_RESP_OKAY : AXI_RESP_SLVERR;
    end
  endfunction

  function automatic logic [DATA_WIDTH-1:0] read_mem_word(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0]            size
  );
    longint unsigned          base_addr;
    longint unsigned          addr_u;
    longint unsigned          mem_addr;
    int unsigned              lane;
    logic [DATA_WIDTH/8-1:0]  mask;
    logic [DATA_WIDTH-1:0]    data;
    begin
      addr_u    = longint unsigned'(addr);
      lane      = int'(addr_u % STRB_WIDTH);
      base_addr = addr_u - lane;
      mask      = beat_strobe_mask(addr, size);
      data      = '0;

      for (int i = 0; i < STRB_WIDTH; i++) begin
        mem_addr = base_addr + longint unsigned'(i);
        if (mask[i] && (mem_addr < MEM_BYTES)) begin
          data[(8*i) +: 8] = mem[int'(mem_addr)];
        end
      end

      read_mem_word = data;
    end
  endfunction

  always_comb begin
    wr_ctx_empty = (wr_ctx_count_q == 0);
    wr_ctx_full  = (wr_ctx_count_q >= WR_OUTSTANDING);
    b_resp_empty = (b_resp_count_q == 0);
    b_resp_full  = (b_resp_count_q >= WR_OUTSTANDING);
    rd_ctx_empty = (rd_ctx_count_q == 0);
    rd_ctx_full  = (rd_ctx_count_q >= RD_OUTSTANDING);

    wr_last_expected = (!wr_ctx_empty) &&
                       (wr_ctx_fifo[wr_ctx_rptr_q].beat == wr_ctx_fifo[wr_ctx_rptr_q].len);
    wr_wstrb_extra   = (!wr_ctx_empty) &&
                       ((s_axi_wstrb & ~beat_strobe_mask(wr_ctx_fifo[wr_ctx_rptr_q].addr,
                                                         wr_ctx_fifo[wr_ctx_rptr_q].size)) != '0);
    wr_finishing     = wr_last_expected || s_axi_wlast;
    wr_resp_after_w  = ((s_axi_wlast != wr_last_expected) || wr_wstrb_extra) ?
                       AXI_RESP_SLVERR : wr_ctx_fifo[wr_ctx_rptr_q].resp;

    s_axi_awready    = aresetn && !wr_ctx_full;
    s_axi_wready     = aresetn && !wr_ctx_empty && (!wr_finishing || !b_resp_full);
    s_axi_arready    = aresetn && !rd_ctx_full;

    s_axi_bvalid     = aresetn && !b_resp_empty;
    s_axi_bid        = b_resp_empty ? '0 : b_resp_fifo[b_resp_rptr_q].id;
    s_axi_bresp      = b_resp_empty ? AXI_RESP_OKAY : b_resp_fifo[b_resp_rptr_q].resp;

    aw_fire          = s_axi_awvalid && s_axi_awready;
    w_fire           = s_axi_wvalid  && s_axi_wready;
    b_fire           = s_axi_bvalid  && s_axi_bready;
    ar_fire          = s_axi_arvalid && s_axi_arready;
    r_fire           = s_axi_rvalid  && s_axi_rready;

    wr_pop_fire      = w_fire && wr_finishing;
    rd_pop_fire      = r_fire && s_axi_rlast;

    unused_sideband  = ^{s_axi_awcache, s_axi_awprot, s_axi_awqos, s_axi_awregion,
                         s_axi_arcache, s_axi_arprot, s_axi_arqos, s_axi_arregion};
  end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_ctx_wptr_q  <= '0;
      wr_ctx_rptr_q  <= '0;
      b_resp_wptr_q  <= '0;
      b_resp_rptr_q  <= '0;
      wr_ctx_count_q <= 0;
      b_resp_count_q <= 0;

      for (mem_init_i = 0; mem_init_i < MEM_BYTES; mem_init_i = mem_init_i + 1) begin
        mem[mem_init_i] <= '0;
      end
    end else begin
      if (aw_fire) begin
        // AW 可在已有写事务未完成时继续进入队列，形成多 outstanding。
        wr_ctx_fifo[wr_ctx_wptr_q].id    <= s_axi_awid;
        wr_ctx_fifo[wr_ctx_wptr_q].addr  <= s_axi_awaddr;
        wr_ctx_fifo[wr_ctx_wptr_q].len   <= s_axi_awlen;
        wr_ctx_fifo[wr_ctx_wptr_q].size  <= s_axi_awsize;
        wr_ctx_fifo[wr_ctx_wptr_q].burst <= s_axi_awburst;
        wr_ctx_fifo[wr_ctx_wptr_q].beat  <= '0;
        wr_ctx_fifo[wr_ctx_wptr_q].resp  <= check_cmd(slave_wr_enable,
                                                       s_axi_awaddr,
                                                       s_axi_awlen,
                                                       s_axi_awsize,
                                                       s_axi_awburst,
                                                       s_axi_awlock);
        wr_ctx_wptr_q <= inc_wr_ptr(wr_ctx_wptr_q);
      end

      if (w_fire) begin
        // AXI4 W 通道没有 WID，因此 W beat 必须按 AW 接收顺序归属到队首写事务。
        if ((wr_ctx_fifo[wr_ctx_rptr_q].resp == AXI_RESP_OKAY) &&
            (s_axi_wlast == wr_last_expected) &&
            !wr_wstrb_extra) begin
          longint unsigned base_addr;
          longint unsigned addr_u;
          longint unsigned mem_addr;
          int unsigned     lane;
          logic [DATA_WIDTH/8-1:0] mask;

          addr_u    = longint unsigned'(wr_ctx_fifo[wr_ctx_rptr_q].addr);
          lane      = int'(addr_u % STRB_WIDTH);
          base_addr = addr_u - lane;
          mask      = beat_strobe_mask(wr_ctx_fifo[wr_ctx_rptr_q].addr,
                                        wr_ctx_fifo[wr_ctx_rptr_q].size);

          // WSTRB byte 粒度更新：wstrb[i] 为 1 时才写对应 byte。
          for (int i = 0; i < STRB_WIDTH; i++) begin
            mem_addr = base_addr + longint unsigned'(i);
            if (mask[i] && s_axi_wstrb[i] && (mem_addr < MEM_BYTES)) begin
              mem[int'(mem_addr)] <= s_axi_wdata[(8*i) +: 8];
            end
          end
        end

        if (wr_finishing) begin
          b_resp_fifo[b_resp_wptr_q].id   <= wr_ctx_fifo[wr_ctx_rptr_q].id;
          b_resp_fifo[b_resp_wptr_q].resp <= wr_resp_after_w;
          b_resp_wptr_q <= inc_b_ptr(b_resp_wptr_q);
          wr_ctx_rptr_q <= inc_wr_ptr(wr_ctx_rptr_q);
        end else begin
          wr_ctx_fifo[wr_ctx_rptr_q].beat <= wr_ctx_fifo[wr_ctx_rptr_q].beat + 8'd1;
          wr_ctx_fifo[wr_ctx_rptr_q].addr <= next_addr(wr_ctx_fifo[wr_ctx_rptr_q].addr,
                                                       wr_ctx_fifo[wr_ctx_rptr_q].size,
                                                       wr_ctx_fifo[wr_ctx_rptr_q].burst);
          wr_ctx_fifo[wr_ctx_rptr_q].resp <= wr_resp_after_w;
        end
      end

      if (b_fire) begin
        b_resp_rptr_q <= inc_b_ptr(b_resp_rptr_q);
      end

      unique case ({aw_fire, wr_pop_fire})
        2'b10: wr_ctx_count_q <= wr_ctx_count_q + 1;
        2'b01: wr_ctx_count_q <= wr_ctx_count_q - 1;
        default: wr_ctx_count_q <= wr_ctx_count_q;
      endcase

      unique case ({wr_pop_fire, b_fire})
        2'b10: b_resp_count_q <= b_resp_count_q + 1;
        2'b01: b_resp_count_q <= b_resp_count_q - 1;
        default: b_resp_count_q <= b_resp_count_q;
      endcase
    end
  end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      rd_ctx_wptr_q  <= '0;
      rd_ctx_rptr_q  <= '0;
      rd_ctx_count_q <= 0;
      s_axi_rid      <= '0;
      s_axi_rdata    <= '0;
      s_axi_rresp    <= AXI_RESP_OKAY;
      s_axi_rlast    <= 1'b0;
      s_axi_rvalid   <= 1'b0;
    end else begin
      if (ar_fire) begin
        // AR 可提前进入读队列，形成多个读 outstanding；R 第一版按 AR 顺序返回。
        rd_ctx_fifo[rd_ctx_wptr_q].id    <= s_axi_arid;
        rd_ctx_fifo[rd_ctx_wptr_q].addr  <= s_axi_araddr;
        rd_ctx_fifo[rd_ctx_wptr_q].len   <= s_axi_arlen;
        rd_ctx_fifo[rd_ctx_wptr_q].size  <= s_axi_arsize;
        rd_ctx_fifo[rd_ctx_wptr_q].burst <= s_axi_arburst;
        rd_ctx_fifo[rd_ctx_wptr_q].beat  <= '0;
        rd_ctx_fifo[rd_ctx_wptr_q].resp  <= check_cmd(slave_rd_enable,
                                                       s_axi_araddr,
                                                       s_axi_arlen,
                                                       s_axi_arsize,
                                                       s_axi_arburst,
                                                       s_axi_arlock);
        rd_ctx_wptr_q <= inc_rd_ptr(rd_ctx_wptr_q);
      end

      if (!s_axi_rvalid && !rd_ctx_empty) begin
        s_axi_rid    <= rd_ctx_fifo[rd_ctx_rptr_q].id;
        s_axi_rresp  <= rd_ctx_fifo[rd_ctx_rptr_q].resp;
        s_axi_rdata  <= (rd_ctx_fifo[rd_ctx_rptr_q].resp == AXI_RESP_OKAY) ?
                        read_mem_word(rd_ctx_fifo[rd_ctx_rptr_q].addr,
                                      rd_ctx_fifo[rd_ctx_rptr_q].size) : '0;
        s_axi_rlast  <= (rd_ctx_fifo[rd_ctx_rptr_q].beat == rd_ctx_fifo[rd_ctx_rptr_q].len);
        s_axi_rvalid <= 1'b1;
      end else if (r_fire) begin
        if (s_axi_rlast) begin
          s_axi_rvalid  <= 1'b0;
          s_axi_rlast   <= 1'b0;
          rd_ctx_rptr_q <= inc_rd_ptr(rd_ctx_rptr_q);
        end else begin
          logic [ADDR_WIDTH-1:0] next_rd_addr;

          next_rd_addr = next_addr(rd_ctx_fifo[rd_ctx_rptr_q].addr,
                                   rd_ctx_fifo[rd_ctx_rptr_q].size,
                                   rd_ctx_fifo[rd_ctx_rptr_q].burst);

          rd_ctx_fifo[rd_ctx_rptr_q].beat <= rd_ctx_fifo[rd_ctx_rptr_q].beat + 8'd1;
          rd_ctx_fifo[rd_ctx_rptr_q].addr <= next_rd_addr;
          s_axi_rid    <= rd_ctx_fifo[rd_ctx_rptr_q].id;
          s_axi_rresp  <= rd_ctx_fifo[rd_ctx_rptr_q].resp;
          s_axi_rdata  <= (rd_ctx_fifo[rd_ctx_rptr_q].resp == AXI_RESP_OKAY) ?
                          read_mem_word(next_rd_addr, rd_ctx_fifo[rd_ctx_rptr_q].size) : '0;
          s_axi_rlast  <= ((rd_ctx_fifo[rd_ctx_rptr_q].beat + 8'd1) == rd_ctx_fifo[rd_ctx_rptr_q].len);
        end
      end

      unique case ({ar_fire, rd_pop_fire})
        2'b10: rd_ctx_count_q <= rd_ctx_count_q + 1;
        2'b01: rd_ctx_count_q <= rd_ctx_count_q - 1;
        default: rd_ctx_count_q <= rd_ctx_count_q;
      endcase
    end
  end

endmodule

`default_nettype wire
