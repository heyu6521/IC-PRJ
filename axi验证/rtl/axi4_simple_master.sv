// -----------------------------------------------------------------------------
// File       : axi4_simple_master.sv
// Author     : ChatGPT
// Description: AXI4 Full simple master with ID-aware multi-outstanding support。
//
// 特性：
//   * app_wr_en/app_rd_en 触发 AXI 写/读请求，app_wr_ready/app_rd_ready 表示可接收
//   * app 侧可指定 AWID/ARID，master 检查 BID/RID 是否属于未完成事务
//   * 支持多个写/读 outstanding；写数据按 AW 接收顺序发送，读响应按 RID 匹配
//   * 写数据源第一版固定为 app_wr_data，每个 beat 重复发送同一个数据
//   * 读数据缓存第一版只把完成事务的最后一拍 RDATA 放到 app_rd_data
//   * 正确产生 AWVALID/WVALID/WLAST/BREADY/ARVALID/RREADY，并检查 RLAST
//
// 说明：
//   AXI4 W 通道没有 WID，所以即使 AW 可以多 outstanding，W beat 仍按 AW 顺序发送。
//   busy=1 表示内部仍有事务在途；不再表示不能接收新请求，请使用 app_*_ready。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module axi4_simple_master #(
  parameter int ADDR_WIDTH     = 32,
  parameter int DATA_WIDTH     = 64,
  parameter int ID_WIDTH       = 4,
  parameter int MEM_BYTES      = 4096,
  parameter int WR_OUTSTANDING = 4,
  parameter int RD_OUTSTANDING = 4
) (
  input  logic                     aclk,
  input  logic                     aresetn,

  // app write request
  input  logic                     app_wr_en,
  output logic                     app_wr_ready,
  input  logic [ID_WIDTH-1:0]      app_wr_id,
  input  logic [ADDR_WIDTH-1:0]    app_wr_addr,
  input  logic [DATA_WIDTH-1:0]    app_wr_data,
  input  logic [7:0]               app_wr_len,
  input  logic [2:0]               app_wr_size,
  input  logic [1:0]               app_wr_burst,

  // app write completion
  output logic                     app_wr_done,
  output logic [ID_WIDTH-1:0]      app_wr_done_id,
  output logic [1:0]               app_wr_resp,
  output logic                     app_wr_id_error,

  // app read request
  input  logic                     app_rd_en,
  output logic                     app_rd_ready,
  input  logic [ID_WIDTH-1:0]      app_rd_id,
  input  logic [ADDR_WIDTH-1:0]    app_rd_addr,
  input  logic [7:0]               app_rd_len,
  input  logic [2:0]               app_rd_size,
  input  logic [1:0]               app_rd_burst,

  // app read completion
  output logic                     app_rd_done,
  output logic [ID_WIDTH-1:0]      app_rd_done_id,
  output logic [DATA_WIDTH-1:0]    app_rd_data,
  output logic [1:0]               app_rd_resp,
  output logic                     app_rd_id_error,

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
  localparam int WR_PTR_W   = (WR_OUTSTANDING <= 1) ? 1 : $clog2(WR_OUTSTANDING);
  localparam int RD_PTR_W   = (RD_OUTSTANDING <= 1) ? 1 : $clog2(RD_OUTSTANDING);

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] data;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
  } wr_req_t;

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [DATA_WIDTH-1:0] data;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
    logic [7:0]            beat;
  } wr_data_ctx_t;

  typedef struct packed {
    logic                  valid;
    logic [ID_WIDTH-1:0]   id;
  } wr_active_t;

  typedef struct packed {
    logic [ID_WIDTH-1:0]   id;
    logic [ADDR_WIDTH-1:0] addr;
    logic [7:0]            len;
    logic [2:0]            size;
    logic [1:0]            burst;
  } rd_req_t;

  typedef struct packed {
    logic                  valid;
    logic [ID_WIDTH-1:0]   id;
    logic [7:0]            len;
    logic [7:0]            beat;
    logic [1:0]            resp;
  } rd_active_t;

  wr_req_t      wr_req_fifo  [0:WR_OUTSTANDING-1];
  wr_data_ctx_t wr_data_fifo [0:WR_OUTSTANDING-1];
  wr_active_t   wr_active    [0:WR_OUTSTANDING-1];

  rd_req_t      rd_req_fifo  [0:RD_OUTSTANDING-1];
  rd_active_t   rd_active    [0:RD_OUTSTANDING-1];

  logic [WR_PTR_W-1:0] wr_req_wptr_q;
  logic [WR_PTR_W-1:0] wr_req_rptr_q;
  logic [WR_PTR_W-1:0] wr_data_wptr_q;
  logic [WR_PTR_W-1:0] wr_data_rptr_q;
  logic [RD_PTR_W-1:0] rd_req_wptr_q;
  logic [RD_PTR_W-1:0] rd_req_rptr_q;

  int unsigned wr_req_count_q;
  int unsigned wr_data_count_q;
  int unsigned wr_active_count_q;
  int unsigned rd_req_count_q;
  int unsigned rd_active_count_q;

  logic wr_req_empty;
  logic wr_req_full;
  logic wr_data_empty;
  logic wr_data_full;
  logic wr_active_full;
  logic rd_req_empty;
  logic rd_req_full;
  logic rd_active_full;

  logic wr_app_fire;
  logic rd_app_fire;
  logic aw_fire;
  logic w_fire;
  logic w_last_fire;
  logic b_fire;
  logic ar_fire;
  logic r_fire;

  logic wr_alloc_found;
  int unsigned wr_alloc_idx;
  logic wr_match_found;
  int unsigned wr_match_idx;

  logic rd_alloc_found;
  int unsigned rd_alloc_idx;
  logic rd_match_found;
  int unsigned rd_match_idx;

  initial begin
    assert ((DATA_WIDTH == 32) || (DATA_WIDTH == 64) || (DATA_WIDTH == 128))
      else $error("axi4_simple_master: DATA_WIDTH must be 32, 64, or 128");
    assert ((DATA_WIDTH % 8) == 0)
      else $error("axi4_simple_master: DATA_WIDTH must be byte aligned");
    assert (WR_OUTSTANDING > 0)
      else $error("axi4_simple_master: WR_OUTSTANDING must be greater than 0");
    assert (RD_OUTSTANDING > 0)
      else $error("axi4_simple_master: RD_OUTSTANDING must be greater than 0");
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

  always_comb begin
    wr_req_empty     = (wr_req_count_q == 0);
    wr_req_full      = (wr_req_count_q >= WR_OUTSTANDING);
    wr_data_empty    = (wr_data_count_q == 0);
    wr_data_full     = (wr_data_count_q >= WR_OUTSTANDING);
    wr_active_full   = (wr_active_count_q >= WR_OUTSTANDING);
    rd_req_empty     = (rd_req_count_q == 0);
    rd_req_full      = (rd_req_count_q >= RD_OUTSTANDING);
    rd_active_full   = (rd_active_count_q >= RD_OUTSTANDING);

    app_wr_ready     = aresetn && !wr_req_full;
    app_rd_ready     = aresetn && !rd_req_full;

    wr_alloc_found   = 1'b0;
    wr_alloc_idx     = 0;
    for (int i = 0; i < WR_OUTSTANDING; i++) begin
      if (!wr_active[i].valid && !wr_alloc_found) begin
        wr_alloc_found = 1'b1;
        wr_alloc_idx   = i;
      end
    end

    wr_match_found   = 1'b0;
    wr_match_idx     = 0;
    for (int i = 0; i < WR_OUTSTANDING; i++) begin
      if (wr_active[i].valid && (wr_active[i].id === m_axi_bid) && !wr_match_found) begin
        wr_match_found = 1'b1;
        wr_match_idx   = i;
      end
    end

    rd_alloc_found   = 1'b0;
    rd_alloc_idx     = 0;
    for (int i = 0; i < RD_OUTSTANDING; i++) begin
      if (!rd_active[i].valid && !rd_alloc_found) begin
        rd_alloc_found = 1'b1;
        rd_alloc_idx   = i;
      end
    end

    rd_match_found   = 1'b0;
    rd_match_idx     = 0;
    for (int i = 0; i < RD_OUTSTANDING; i++) begin
      if (rd_active[i].valid && (rd_active[i].id === m_axi_rid) && !rd_match_found) begin
        rd_match_found = 1'b1;
        rd_match_idx   = i;
      end
    end

    m_axi_awvalid    = aresetn && !wr_req_empty && !wr_data_full && !wr_active_full && wr_alloc_found;
    m_axi_awid       = wr_req_empty ? '0 : wr_req_fifo[wr_req_rptr_q].id;
    m_axi_awaddr     = wr_req_empty ? '0 : wr_req_fifo[wr_req_rptr_q].addr;
    m_axi_awlen      = wr_req_empty ? '0 : wr_req_fifo[wr_req_rptr_q].len;
    m_axi_awsize     = wr_req_empty ? '0 : wr_req_fifo[wr_req_rptr_q].size;
    m_axi_awburst    = wr_req_empty ? AXI_BURST_INCR : wr_req_fifo[wr_req_rptr_q].burst;
    m_axi_awlock     = 1'b0;
    m_axi_awcache    = 4'b0011;
    m_axi_awprot     = 3'b000;
    m_axi_awqos      = 4'b0000;
    m_axi_awregion   = 4'b0000;

    m_axi_wvalid     = aresetn && !wr_data_empty;
    m_axi_wdata      = wr_data_empty ? '0 : align_wdata(wr_data_fifo[wr_data_rptr_q].addr,
                                                        wr_data_fifo[wr_data_rptr_q].size,
                                                        wr_data_fifo[wr_data_rptr_q].data);
    m_axi_wstrb      = wr_data_empty ? '0 : gen_wstrb(wr_data_fifo[wr_data_rptr_q].addr,
                                                     wr_data_fifo[wr_data_rptr_q].size);
    m_axi_wlast      = (!wr_data_empty) &&
                       (wr_data_fifo[wr_data_rptr_q].beat == wr_data_fifo[wr_data_rptr_q].len);
    m_axi_bready     = aresetn;

    m_axi_arvalid    = aresetn && !rd_req_empty && !rd_active_full && rd_alloc_found;
    m_axi_arid       = rd_req_empty ? '0 : rd_req_fifo[rd_req_rptr_q].id;
    m_axi_araddr     = rd_req_empty ? '0 : rd_req_fifo[rd_req_rptr_q].addr;
    m_axi_arlen      = rd_req_empty ? '0 : rd_req_fifo[rd_req_rptr_q].len;
    m_axi_arsize     = rd_req_empty ? '0 : rd_req_fifo[rd_req_rptr_q].size;
    m_axi_arburst    = rd_req_empty ? AXI_BURST_INCR : rd_req_fifo[rd_req_rptr_q].burst;
    m_axi_arlock     = 1'b0;
    m_axi_arcache    = 4'b0011;
    m_axi_arprot     = 3'b000;
    m_axi_arqos      = 4'b0000;
    m_axi_arregion   = 4'b0000;
    m_axi_rready     = aresetn;

    // busy 表示仍有请求排队、写数据未发完、或响应未回完；不再用于阻塞 app 新请求。
    busy             = (wr_req_count_q != 0) || (wr_data_count_q != 0) ||
                       (wr_active_count_q != 0) || (rd_req_count_q != 0) ||
                       (rd_active_count_q != 0) || m_axi_awvalid || m_axi_arvalid ||
                       m_axi_wvalid;

    wr_app_fire      = app_wr_en && app_wr_ready;
    rd_app_fire      = app_rd_en && app_rd_ready;
    aw_fire          = m_axi_awvalid && m_axi_awready;
    w_fire           = m_axi_wvalid  && m_axi_wready;
    w_last_fire      = w_fire && m_axi_wlast;
    b_fire           = m_axi_bvalid  && m_axi_bready;
    ar_fire          = m_axi_arvalid && m_axi_arready;
    r_fire           = m_axi_rvalid  && m_axi_rready;
  end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      wr_req_wptr_q     <= '0;
      wr_req_rptr_q     <= '0;
      wr_data_wptr_q    <= '0;
      wr_data_rptr_q    <= '0;
      wr_req_count_q    <= 0;
      wr_data_count_q   <= 0;
      wr_active_count_q <= 0;
      app_wr_done       <= 1'b0;
      app_wr_done_id    <= '0;
      app_wr_resp       <= AXI_RESP_OKAY;
      app_wr_id_error   <= 1'b0;

      for (int i = 0; i < WR_OUTSTANDING; i++) begin
        wr_active[i].valid <= 1'b0;
        wr_active[i].id    <= '0;
      end
    end else begin
      app_wr_done     <= 1'b0;
      app_wr_id_error <= 1'b0;

      if (wr_app_fire) begin
        wr_req_fifo[wr_req_wptr_q].id    <= app_wr_id;
        wr_req_fifo[wr_req_wptr_q].addr  <= app_wr_addr;
        wr_req_fifo[wr_req_wptr_q].data  <= app_wr_data;
        wr_req_fifo[wr_req_wptr_q].len   <= app_wr_len;
        wr_req_fifo[wr_req_wptr_q].size  <= app_wr_size;
        wr_req_fifo[wr_req_wptr_q].burst <= app_wr_burst;
        wr_req_wptr_q <= inc_wr_ptr(wr_req_wptr_q);
      end

      if (aw_fire) begin
        // AW 被 slave 接收后，写数据事务进入 W 队列；BID 用 active ID 表跟踪。
        wr_data_fifo[wr_data_wptr_q].id    <= wr_req_fifo[wr_req_rptr_q].id;
        wr_data_fifo[wr_data_wptr_q].addr  <= wr_req_fifo[wr_req_rptr_q].addr;
        wr_data_fifo[wr_data_wptr_q].data  <= wr_req_fifo[wr_req_rptr_q].data;
        wr_data_fifo[wr_data_wptr_q].len   <= wr_req_fifo[wr_req_rptr_q].len;
        wr_data_fifo[wr_data_wptr_q].size  <= wr_req_fifo[wr_req_rptr_q].size;
        wr_data_fifo[wr_data_wptr_q].burst <= wr_req_fifo[wr_req_rptr_q].burst;
        wr_data_fifo[wr_data_wptr_q].beat  <= '0;
        wr_data_wptr_q <= inc_wr_ptr(wr_data_wptr_q);

        wr_active[wr_alloc_idx].valid <= 1'b1;
        wr_active[wr_alloc_idx].id    <= wr_req_fifo[wr_req_rptr_q].id;
        wr_req_rptr_q <= inc_wr_ptr(wr_req_rptr_q);
      end

      if (w_fire) begin
        if (m_axi_wlast) begin
          wr_data_rptr_q <= inc_wr_ptr(wr_data_rptr_q);
        end else begin
          wr_data_fifo[wr_data_rptr_q].beat <= wr_data_fifo[wr_data_rptr_q].beat + 8'd1;
          wr_data_fifo[wr_data_rptr_q].addr <= next_addr(wr_data_fifo[wr_data_rptr_q].addr,
                                                         wr_data_fifo[wr_data_rptr_q].size,
                                                         wr_data_fifo[wr_data_rptr_q].burst);
        end
      end

      if (b_fire) begin
        app_wr_done    <= 1'b1;
        app_wr_done_id <= m_axi_bid;

        if (wr_match_found) begin
          app_wr_resp <= m_axi_bresp;
          wr_active[wr_match_idx].valid <= 1'b0;
        end else begin
          // 收到未知 BID：说明 slave/VIP 返回了不属于未完成事务的响应。
          app_wr_resp     <= AXI_RESP_SLVERR;
          app_wr_id_error <= 1'b1;
        end
      end

      unique case ({wr_app_fire, aw_fire})
        2'b10: wr_req_count_q <= wr_req_count_q + 1;
        2'b01: wr_req_count_q <= wr_req_count_q - 1;
        default: wr_req_count_q <= wr_req_count_q;
      endcase

      unique case ({aw_fire, w_last_fire})
        2'b10: wr_data_count_q <= wr_data_count_q + 1;
        2'b01: wr_data_count_q <= wr_data_count_q - 1;
        default: wr_data_count_q <= wr_data_count_q;
      endcase

      unique case ({aw_fire, (b_fire && wr_match_found)})
        2'b10: wr_active_count_q <= wr_active_count_q + 1;
        2'b01: wr_active_count_q <= wr_active_count_q - 1;
        default: wr_active_count_q <= wr_active_count_q;
      endcase
    end
  end

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      rd_req_wptr_q     <= '0;
      rd_req_rptr_q     <= '0;
      rd_req_count_q    <= 0;
      rd_active_count_q <= 0;
      app_rd_done       <= 1'b0;
      app_rd_done_id    <= '0;
      app_rd_data       <= '0;
      app_rd_resp       <= AXI_RESP_OKAY;
      app_rd_id_error   <= 1'b0;

      for (int i = 0; i < RD_OUTSTANDING; i++) begin
        rd_active[i].valid <= 1'b0;
        rd_active[i].id    <= '0;
        rd_active[i].len   <= '0;
        rd_active[i].beat  <= '0;
        rd_active[i].resp  <= AXI_RESP_OKAY;
      end
    end else begin
      app_rd_done     <= 1'b0;
      app_rd_id_error <= 1'b0;

      if (rd_app_fire) begin
        rd_req_fifo[rd_req_wptr_q].id    <= app_rd_id;
        rd_req_fifo[rd_req_wptr_q].addr  <= app_rd_addr;
        rd_req_fifo[rd_req_wptr_q].len   <= app_rd_len;
        rd_req_fifo[rd_req_wptr_q].size  <= app_rd_size;
        rd_req_fifo[rd_req_wptr_q].burst <= app_rd_burst;
        rd_req_wptr_q <= inc_rd_ptr(rd_req_wptr_q);
      end

      if (ar_fire) begin
        rd_active[rd_alloc_idx].valid <= 1'b1;
        rd_active[rd_alloc_idx].id    <= rd_req_fifo[rd_req_rptr_q].id;
        rd_active[rd_alloc_idx].len   <= rd_req_fifo[rd_req_rptr_q].len;
        rd_active[rd_alloc_idx].beat  <= '0;
        rd_active[rd_alloc_idx].resp  <= AXI_RESP_OKAY;
        rd_req_rptr_q <= inc_rd_ptr(rd_req_rptr_q);
      end

      if (r_fire) begin
        if (rd_match_found) begin
          logic rd_last_expected;
          logic [1:0] rd_resp_new;

          rd_last_expected = (rd_active[rd_match_idx].beat == rd_active[rd_match_idx].len);
          rd_resp_new      = rd_active[rd_match_idx].resp;

          if (m_axi_rresp != AXI_RESP_OKAY) begin
            rd_resp_new = m_axi_rresp;
          end

          if (m_axi_rlast != rd_last_expected) begin
            rd_resp_new = AXI_RESP_SLVERR;
          end

          app_rd_data <= m_axi_rdata;

          if (m_axi_rlast || rd_last_expected) begin
            app_rd_done    <= 1'b1;
            app_rd_done_id <= m_axi_rid;
            app_rd_resp    <= rd_resp_new;
            rd_active[rd_match_idx].valid <= 1'b0;
          end else begin
            rd_active[rd_match_idx].beat <= rd_active[rd_match_idx].beat + 8'd1;
            rd_active[rd_match_idx].resp <= rd_resp_new;
          end
        end else begin
          // 收到未知 RID：说明 slave/VIP 返回了不属于未完成事务的数据。
          app_rd_done     <= 1'b1;
          app_rd_done_id  <= m_axi_rid;
          app_rd_data     <= m_axi_rdata;
          app_rd_resp     <= AXI_RESP_SLVERR;
          app_rd_id_error <= 1'b1;
        end
      end

      unique case ({rd_app_fire, ar_fire})
        2'b10: rd_req_count_q <= rd_req_count_q + 1;
        2'b01: rd_req_count_q <= rd_req_count_q - 1;
        default: rd_req_count_q <= rd_req_count_q;
      endcase

      unique case ({ar_fire, (r_fire && rd_match_found && (m_axi_rlast || (rd_active[rd_match_idx].beat == rd_active[rd_match_idx].len)))})
        2'b10: rd_active_count_q <= rd_active_count_q + 1;
        2'b01: rd_active_count_q <= rd_active_count_q - 1;
        default: rd_active_count_q <= rd_active_count_q;
      endcase
    end
  end

  // MEM_BYTES 参数保留用于和 slave/top 参数列表保持一致，当前 master 不直接使用 memory。
  logic unused_param;
  assign unused_param = (MEM_BYTES == 0);

endmodule

`default_nettype wire
