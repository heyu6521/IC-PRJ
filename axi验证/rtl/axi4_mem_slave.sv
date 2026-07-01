// -----------------------------------------------------------------------------
// File       : axi4_mem_slave.sv
// Author     : ChatGPT
// Description: AXI4 Full single-outstanding memory slave model。
//
// 特性：
//   * 支持 AXI4 AW/W/B/AR/R 五通道基础握手
//   * AW 和 W 通道解耦：先接收 AW，再逐拍接收 W
//   * 支持 FIXED / INCR burst；WRAP / reserved burst 会接收事务并返回 SLVERR
//   * 支持 WSTRB byte strobe 部分写
//   * 支持 slave_wr_enable / slave_rd_enable 控制；关闭时仍接收事务并返回 SLVERR，
//     避免 master 因等待 ready 或 response 而永久阻塞
//   * 第一版允许单写事务 outstanding、单读事务 outstanding
//
// 说明：
//   当前版本为学习和 VIP 对接用 DUT，优先保证握手合法、结构清晰、易调试。
//   cache/prot/qos/region 端口保留用于标准 AXI4 连接，当前不解释复杂语义。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module axi4_mem_slave #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 64,
  parameter int ID_WIDTH   = 4,
  parameter int MEM_BYTES  = 4096
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

  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  typedef enum logic [1:0] {
    WR_IDLE,
    WR_DATA,
    WR_RESP
  } wr_state_e;

  typedef enum logic [0:0] {
    RD_IDLE,
    RD_DATA
  } rd_state_e;

  wr_state_e wr_state_q;
  rd_state_e rd_state_q;

  logic [7:0] mem [0:MEM_BYTES-1];

  logic [ID_WIDTH-1:0]   wr_id_q;
  logic [ADDR_WIDTH-1:0] wr_addr_q;
  logic [7:0]            wr_len_q;
  logic [2:0]            wr_size_q;
  logic [1:0]            wr_burst_q;
  logic [7:0]            wr_beat_q;
  logic [1:0]            wr_resp_q;

  logic [ID_WIDTH-1:0]   rd_id_q;
  logic [ADDR_WIDTH-1:0] rd_addr_q;
  logic [7:0]            rd_len_q;
  logic [2:0]            rd_size_q;
  logic [1:0]            rd_burst_q;
  logic [7:0]            rd_beat_q;
  logic [1:0]            rd_resp_q;

  logic                  wr_last_expected;
  logic                  wr_wstrb_extra;
  logic [1:0]            wr_resp_after_w;
  logic                  unused_sideband;

  integer mem_init_i;

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
    s_axi_awready  = aresetn && (wr_state_q == WR_IDLE);
    s_axi_wready   = aresetn && (wr_state_q == WR_DATA);
    s_axi_arready  = aresetn && (rd_state_q == RD_IDLE);

    wr_last_expected = (wr_beat_q == wr_len_q);
    wr_wstrb_extra   = ((s_axi_wstrb & ~beat_strobe_mask(wr_addr_q, wr_size_q)) != '0);
    wr_resp_after_w  = ((s_axi_wlast != wr_last_expected) || wr_wstrb_extra) ?
                       AXI_RESP_SLVERR : wr_resp_q;

    unused_sideband  = ^{s_axi_awcache, s_axi_awprot, s_axi_awqos, s_axi_awregion,
                         s_axi_arcache, s_axi_arprot, s_axi_arqos, s_axi_arregion};
  end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_state_q   <= WR_IDLE;
      s_axi_bid    <= '0;
      s_axi_bresp  <= AXI_RESP_OKAY;
      s_axi_bvalid <= 1'b0;
      wr_id_q      <= '0;
      wr_addr_q    <= '0;
      wr_len_q     <= '0;
      wr_size_q    <= '0;
      wr_burst_q   <= AXI_BURST_INCR;
      wr_beat_q    <= '0;
      wr_resp_q    <= AXI_RESP_OKAY;

      for (mem_init_i = 0; mem_init_i < MEM_BYTES; mem_init_i = mem_init_i + 1) begin
        mem[mem_init_i] <= '0;
      end
    end else begin
      unique case (wr_state_q)
        WR_IDLE: begin
          s_axi_bvalid <= 1'b0;

          if (s_axi_awvalid && s_axi_awready) begin
            // AW 和 W 解耦：先锁存 AW，再进入 WR_DATA 接收 W burst。
            wr_id_q    <= s_axi_awid;
            wr_addr_q  <= s_axi_awaddr;
            wr_len_q   <= s_axi_awlen;
            wr_size_q  <= s_axi_awsize;
            wr_burst_q <= s_axi_awburst;
            wr_beat_q  <= '0;
            wr_resp_q  <= check_cmd(slave_wr_enable,
                                    s_axi_awaddr,
                                    s_axi_awlen,
                                    s_axi_awsize,
                                    s_axi_awburst,
                                    s_axi_awlock);
            wr_state_q <= WR_DATA;
          end
        end

        WR_DATA: begin
          if (s_axi_wvalid && s_axi_wready) begin
            // 只有命令合法、WLAST 匹配、WSTRB 未越过当前 transfer byte lane 时才更新 memory。
            if ((wr_resp_q == AXI_RESP_OKAY) &&
                (s_axi_wlast == wr_last_expected) &&
                !wr_wstrb_extra) begin
              longint unsigned base_addr;
              longint unsigned addr_u;
              longint unsigned mem_addr;
              int unsigned     lane;
              logic [DATA_WIDTH/8-1:0] mask;

              addr_u    = longint unsigned'(wr_addr_q);
              lane      = int'(addr_u % STRB_WIDTH);
              base_addr = addr_u - lane;
              mask      = beat_strobe_mask(wr_addr_q, wr_size_q);

              // WSTRB byte 粒度更新：wstrb[i] 为 1 时才写对应 byte。
              for (int i = 0; i < STRB_WIDTH; i++) begin
                mem_addr = base_addr + longint unsigned'(i);
                if (mask[i] && s_axi_wstrb[i] && (mem_addr < MEM_BYTES)) begin
                  mem[int'(mem_addr)] <= s_axi_wdata[(8*i) +: 8];
                end
              end
            end

            if (wr_last_expected || s_axi_wlast) begin
              s_axi_bid    <= wr_id_q;
              s_axi_bresp  <= wr_resp_after_w;
              s_axi_bvalid <= 1'b1;
              wr_resp_q    <= wr_resp_after_w;
              wr_state_q   <= WR_RESP;
            end else begin
              wr_beat_q  <= wr_beat_q + 8'd1;
              wr_addr_q  <= next_addr(wr_addr_q, wr_size_q, wr_burst_q);
              wr_resp_q  <= wr_resp_after_w;
            end
          end
        end

        WR_RESP: begin
          if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            wr_state_q   <= WR_IDLE;
          end
        end

        default: begin
          wr_state_q <= WR_IDLE;
        end
      endcase
    end
  end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      rd_state_q   <= RD_IDLE;
      s_axi_rid    <= '0;
      s_axi_rdata  <= '0;
      s_axi_rresp  <= AXI_RESP_OKAY;
      s_axi_rlast  <= 1'b0;
      s_axi_rvalid <= 1'b0;
      rd_id_q      <= '0;
      rd_addr_q    <= '0;
      rd_len_q     <= '0;
      rd_size_q    <= '0;
      rd_burst_q   <= AXI_BURST_INCR;
      rd_beat_q    <= '0;
      rd_resp_q    <= AXI_RESP_OKAY;
    end else begin
      unique case (rd_state_q)
        RD_IDLE: begin
          s_axi_rvalid <= 1'b0;
          s_axi_rlast  <= 1'b0;

          if (s_axi_arvalid && s_axi_arready) begin
            logic [1:0] cmd_resp;

            cmd_resp = check_cmd(slave_rd_enable,
                                 s_axi_araddr,
                                 s_axi_arlen,
                                 s_axi_arsize,
                                 s_axi_arburst,
                                 s_axi_arlock);

            rd_id_q      <= s_axi_arid;
            rd_addr_q    <= s_axi_araddr;
            rd_len_q     <= s_axi_arlen;
            rd_size_q    <= s_axi_arsize;
            rd_burst_q   <= s_axi_arburst;
            rd_beat_q    <= '0;
            rd_resp_q    <= cmd_resp;

            s_axi_rid    <= s_axi_arid;
            s_axi_rresp  <= cmd_resp;
            s_axi_rdata  <= (cmd_resp == AXI_RESP_OKAY) ? read_mem_word(s_axi_araddr, s_axi_arsize) : '0;
            s_axi_rlast  <= (s_axi_arlen == 8'd0);
            s_axi_rvalid <= 1'b1;
            rd_state_q   <= RD_DATA;
          end
        end

        RD_DATA: begin
          if (s_axi_rvalid && s_axi_rready) begin
            if (rd_beat_q == rd_len_q) begin
              s_axi_rvalid <= 1'b0;
              s_axi_rlast  <= 1'b0;
              rd_state_q   <= RD_IDLE;
            end else begin
              logic [ADDR_WIDTH-1:0] next_rd_addr;

              next_rd_addr = next_addr(rd_addr_q, rd_size_q, rd_burst_q);

              rd_beat_q   <= rd_beat_q + 8'd1;
              rd_addr_q   <= next_rd_addr;
              s_axi_rid   <= rd_id_q;
              s_axi_rresp <= rd_resp_q;
              s_axi_rdata <= (rd_resp_q == AXI_RESP_OKAY) ? read_mem_word(next_rd_addr, rd_size_q) : '0;
              s_axi_rlast <= ((rd_beat_q + 8'd1) == rd_len_q);
            end
          end
        end

        default: begin
          rd_state_q <= RD_IDLE;
        end
      endcase
    end
  end

endmodule

`default_nettype wire
