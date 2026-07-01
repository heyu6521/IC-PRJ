// -----------------------------------------------------------------------------
// File       : axi4_simple_master.sv
// Author     : ChatGPT
// Description: AXI4 Full simple master。
//
// 特性：
//   * app_wr_en 触发一次 AXI 写 burst；app_rd_en 触发一次 AXI 读 burst
//   * 第一版 single outstanding，busy=1 时忽略新的 app 请求
//   * 写数据源第一版固定为 app_wr_data，每个 beat 重复发送同一个数据
//   * 读数据缓存第一版只保存最后一拍 RDATA 到 app_rd_data
//   * 正确产生 AWVALID/WVALID/WLAST/BREADY/ARVALID/RREADY，并检查 RLAST
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module axi4_simple_master #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 64,
  parameter int ID_WIDTH   = 4,
  parameter int MEM_BYTES  = 4096
) (
  input  logic                     aclk,
  input  logic                     aresetn,

  // app write control
  input  logic                     app_wr_en,
  input  logic [ADDR_WIDTH-1:0]    app_wr_addr,
  input  logic [DATA_WIDTH-1:0]    app_wr_data,
  input  logic [7:0]               app_wr_len,
  input  logic [2:0]               app_wr_size,
  input  logic [1:0]               app_wr_burst,
  output logic                     app_wr_done,
  output logic [1:0]               app_wr_resp,

  // app read control
  input  logic                     app_rd_en,
  input  logic [ADDR_WIDTH-1:0]    app_rd_addr,
  input  logic [7:0]               app_rd_len,
  input  logic [2:0]               app_rd_size,
  input  logic [1:0]               app_rd_burst,
  output logic                     app_rd_done,
  output logic [DATA_WIDTH-1:0]    app_rd_data,
  output logic [1:0]               app_rd_resp,

  output logic                     busy,

  // AXI4 write address channel
  output logic [ID_WIDTH-1:0]      m_axi_awid,
  output logic [ADDR_WIDTH-1:0]    m_axi_awaddr,
  output logic [7:0]               m_axi_awlen,
  output logic [2:0]               m_axi_awsize,
  output logic [1:0]               m_axi_awburst,
  output logic                     m_axi_awlock,
  output logic [3:0]               m_axi_awcache,
  output logic [2:0]               m_axi_awprot,
  output logic [3:0]               m_axi_awqos,
  output logic [3:0]               m_axi_awregion,
  output logic                     m_axi_awvalid,
  input  logic                     m_axi_awready,

  // AXI4 write data channel
  output logic [DATA_WIDTH-1:0]    m_axi_wdata,
  output logic [DATA_WIDTH/8-1:0]  m_axi_wstrb,
  output logic                     m_axi_wlast,
  output logic                     m_axi_wvalid,
  input  logic                     m_axi_wready,

  // AXI4 write response channel
  input  logic [ID_WIDTH-1:0]      m_axi_bid,
  input  logic [1:0]               m_axi_bresp,
  input  logic                     m_axi_bvalid,
  output logic                     m_axi_bready,

  // AXI4 read address channel
  output logic [ID_WIDTH-1:0]      m_axi_arid,
  output logic [ADDR_WIDTH-1:0]    m_axi_araddr,
  output logic [7:0]               m_axi_arlen,
  output logic [2:0]               m_axi_arsize,
  output logic [1:0]               m_axi_arburst,
  output logic                     m_axi_arlock,
  output logic [3:0]               m_axi_arcache,
  output logic [2:0]               m_axi_arprot,
  output logic [3:0]               m_axi_arqos,
  output logic [3:0]               m_axi_arregion,
  output logic                     m_axi_arvalid,
  input  logic                     m_axi_arready,

  // AXI4 read data channel
  input  logic [ID_WIDTH-1:0]      m_axi_rid,
  input  logic [DATA_WIDTH-1:0]    m_axi_rdata,
  input  logic [1:0]               m_axi_rresp,
  input  logic                     m_axi_rlast,
  input  logic                     m_axi_rvalid,
  output logic                     m_axi_rready
);

  import axi4_defines_pkg::*;

  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  typedef enum logic [1:0] {
    MST_IDLE,
    MST_WRITE,
    MST_RD_ADDR,
    MST_RD_DATA
  } mst_state_e;

  mst_state_e mst_state_q;

  logic [7:0]            wr_len_q;
  logic [2:0]            wr_size_q;
  logic [ADDR_WIDTH-1:0] wr_addr_q;
  logic [DATA_WIDTH-1:0] wr_data_q;
  logic [7:0]            wr_beat_q;

  logic [7:0]            rd_len_q;
  logic [7:0]            rd_beat_q;
  logic [1:0]            rd_resp_q;

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
        default        : next_addr = addr;
      endcase
    end
  endfunction

  function automatic logic [STRB_WIDTH-1:0] gen_wstrb(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [2:0]            size
  );
    int unsigned      bytes;
    int unsigned      lane;
    longint unsigned  addr_u;
    logic [STRB_WIDTH-1:0] strobe;
    begin
      bytes  = axi_size_to_bytes(size);
      addr_u = longint unsigned'(addr);
      lane   = int'(addr_u % STRB_WIDTH);
      strobe = '0;

      for (int i = 0; i < STRB_WIDTH; i++) begin
        if ((bytes <= STRB_WIDTH) && (i >= lane) && (i < (lane + bytes))) begin
          strobe[i] = 1'b1;
        end
      end
      gen_wstrb = strobe;
    end
  endfunction

  function automatic logic [DATA_WIDTH-1:0] align_wdata(
    input logic [ADDR_WIDTH-1:0]  addr,
    input logic [2:0]             size,
    input logic [DATA_WIDTH-1:0]  data
  );
    int unsigned      bytes;
    int unsigned      lane;
    longint unsigned  addr_u;
    logic [DATA_WIDTH-1:0] aligned;
    begin
      bytes   = axi_size_to_bytes(size);
      addr_u  = longint unsigned'(addr);
      lane    = int'(addr_u % STRB_WIDTH);
      aligned = '0;

      // app_wr_data 的低 bytes 放入 AxADDR 对应的 byte lane，便于 app 侧使用。
      for (int i = 0; i < STRB_WIDTH; i++) begin
        if ((i < bytes) && ((lane + i) < STRB_WIDTH)) begin
          aligned[(8*(lane+i)) +: 8] = data[(8*i) +: 8];
        end
      end

      align_wdata = aligned;
    end
  endfunction

  logic wr_last_expected;
  logic rd_last_expected;
  logic [1:0] rd_resp_after_r;

  assign wr_last_expected = (wr_beat_q == wr_len_q);
  assign rd_last_expected = (rd_beat_q == rd_len_q);
  assign rd_resp_after_r  = (m_axi_rresp != AXI_RESP_OKAY) ? m_axi_rresp :
                            ((m_axi_rlast != rd_last_expected) ? AXI_RESP_SLVERR : rd_resp_q);

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      mst_state_q    <= MST_IDLE;
      busy           <= 1'b0;

      app_wr_done    <= 1'b0;
      app_wr_resp    <= AXI_RESP_OKAY;
      app_rd_done    <= 1'b0;
      app_rd_data    <= '0;
      app_rd_resp    <= AXI_RESP_OKAY;

      m_axi_awid     <= '0;
      m_axi_awaddr   <= '0;
      m_axi_awlen    <= '0;
      m_axi_awsize   <= '0;
      m_axi_awburst  <= AXI_BURST_INCR;
      m_axi_awlock   <= 1'b0;
      m_axi_awcache  <= 4'b0011;
      m_axi_awprot   <= 3'b000;
      m_axi_awqos    <= 4'b0000;
      m_axi_awregion <= 4'b0000;
      m_axi_awvalid  <= 1'b0;

      m_axi_wdata    <= '0;
      m_axi_wstrb    <= '0;
      m_axi_wlast    <= 1'b0;
      m_axi_wvalid   <= 1'b0;

      m_axi_bready   <= 1'b0;

      m_axi_arid     <= '0;
      m_axi_araddr   <= '0;
      m_axi_arlen    <= '0;
      m_axi_arsize   <= '0;
      m_axi_arburst  <= AXI_BURST_INCR;
      m_axi_arlock   <= 1'b0;
      m_axi_arcache  <= 4'b0011;
      m_axi_arprot   <= 3'b000;
      m_axi_arqos    <= 4'b0000;
      m_axi_arregion <= 4'b0000;
      m_axi_arvalid  <= 1'b0;

      m_axi_rready   <= 1'b0;

      wr_len_q       <= '0;
      wr_size_q      <= '0;
      wr_addr_q      <= '0;
      wr_data_q      <= '0;
      wr_beat_q      <= '0;
      rd_len_q       <= '0;
      rd_beat_q      <= '0;
      rd_resp_q      <= AXI_RESP_OKAY;
    end else begin
      // done 信号为单周期脉冲。
      app_wr_done <= 1'b0;
      app_rd_done <= 1'b0;

      unique case (mst_state_q)
        MST_IDLE: begin
          busy          <= 1'b0;
          m_axi_awvalid <= 1'b0;
          m_axi_wvalid  <= 1'b0;
          m_axi_wlast   <= 1'b0;
          m_axi_bready  <= 1'b0;
          m_axi_arvalid <= 1'b0;
          m_axi_rready  <= 1'b0;

          // 当 app_wr_en 和 app_rd_en 同时有效时，写请求优先。
          // busy=1 时新的 app 请求会被忽略，app 侧应等待 busy 拉低后再发起下一笔。
          if (app_wr_en) begin
            busy           <= 1'b1;
            mst_state_q    <= MST_WRITE;

            wr_len_q       <= app_wr_len;
            wr_size_q      <= app_wr_size;
            wr_addr_q      <= app_wr_addr;
            wr_data_q      <= app_wr_data;
            wr_beat_q      <= '0;

            m_axi_awid     <= '0;
            m_axi_awaddr   <= app_wr_addr;
            m_axi_awlen    <= app_wr_len;
            m_axi_awsize   <= app_wr_size;
            m_axi_awburst  <= app_wr_burst;
            m_axi_awlock   <= 1'b0;
            m_axi_awcache  <= 4'b0011;
            m_axi_awprot   <= 3'b000;
            m_axi_awqos    <= 4'b0000;
            m_axi_awregion <= 4'b0000;
            m_axi_awvalid  <= 1'b1;

            m_axi_wdata    <= align_wdata(app_wr_addr, app_wr_size, app_wr_data);
            m_axi_wstrb    <= gen_wstrb(app_wr_addr, app_wr_size);
            m_axi_wlast    <= (app_wr_len == 8'd0);
            m_axi_wvalid   <= 1'b1;

            // BREADY 可以提前拉高，表示 master 随时可接收写响应。
            m_axi_bready   <= 1'b1;
            app_wr_resp    <= AXI_RESP_OKAY;
          end else if (app_rd_en) begin
            busy           <= 1'b1;
            mst_state_q    <= MST_RD_ADDR;

            rd_len_q       <= app_rd_len;
            rd_beat_q      <= '0;
            rd_resp_q      <= AXI_RESP_OKAY;
            app_rd_resp    <= AXI_RESP_OKAY;

            m_axi_arid     <= '0;
            m_axi_araddr   <= app_rd_addr;
            m_axi_arlen    <= app_rd_len;
            m_axi_arsize   <= app_rd_size;
            m_axi_arburst  <= app_rd_burst;
            m_axi_arlock   <= 1'b0;
            m_axi_arcache  <= 4'b0011;
            m_axi_arprot   <= 3'b000;
            m_axi_arqos    <= 4'b0000;
            m_axi_arregion <= 4'b0000;
            m_axi_arvalid  <= 1'b1;
          end
        end

        MST_WRITE: begin
          busy <= 1'b1;

          if (m_axi_awvalid && m_axi_awready) begin
            m_axi_awvalid <= 1'b0;
          end

          if (m_axi_wvalid && m_axi_wready) begin
            if (wr_last_expected) begin
              m_axi_wvalid <= 1'b0;
              m_axi_wlast  <= 1'b0;
            end else begin
              wr_beat_q    <= wr_beat_q + 8'd1;
              wr_addr_q    <= next_addr(wr_addr_q, wr_size_q, m_axi_awburst);
              m_axi_wdata  <= align_wdata(next_addr(wr_addr_q, wr_size_q, m_axi_awburst), wr_size_q, wr_data_q);
              m_axi_wstrb  <= gen_wstrb(next_addr(wr_addr_q, wr_size_q, m_axi_awburst), wr_size_q);
              m_axi_wlast  <= ((wr_beat_q + 8'd1) == wr_len_q);
              // 第一版每拍重复发送 app_wr_data，后续可替换为 FIFO 数据源。
            end
          end

          if (m_axi_bvalid && m_axi_bready) begin
            app_wr_resp   <= m_axi_bresp;
            app_wr_done   <= 1'b1;
            m_axi_bready  <= 1'b0;
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_wlast   <= 1'b0;
            busy          <= 1'b0;
            mst_state_q   <= MST_IDLE;
          end
        end

        MST_RD_ADDR: begin
          busy <= 1'b1;

          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b1;
            mst_state_q   <= MST_RD_DATA;
          end
        end

        MST_RD_DATA: begin
          busy <= 1'b1;

          if (m_axi_rvalid && m_axi_rready) begin
            app_rd_data <= m_axi_rdata;  // 第一版只保留最后一次握手看到的数据。
            rd_resp_q   <= rd_resp_after_r;

            if (rd_last_expected || m_axi_rlast) begin
              app_rd_resp  <= rd_resp_after_r;
              app_rd_done  <= 1'b1;
              m_axi_rready <= 1'b0;
              busy         <= 1'b0;
              mst_state_q  <= MST_IDLE;
            end else begin
              rd_beat_q <= rd_beat_q + 8'd1;
            end
          end
        end

        default: begin
          mst_state_q <= MST_IDLE;
          busy        <= 1'b0;
        end
      endcase
    end
  end

  // 当前 master 固定发 ID=0，不检查 BID/RID 与 ID 匹配；single outstanding 下不会乱序。
  logic unused_axi_id;
  assign unused_axi_id = ^{m_axi_bid, m_axi_rid};

  // MEM_BYTES 参数保留用于和 slave/top 参数列表保持一致，当前 master 不直接使用 memory。
  logic unused_param;
  assign unused_param = (MEM_BYTES == 0);

endmodule

`default_nettype wire
