// -----------------------------------------------------------------------------
// File       : axi4_top_demo.sv
// Author     : ChatGPT
// Description: AXI4 simple master + AXI4 multi-outstanding memory slave 直连 demo。
//              暴露 app 侧接口，可用于不依赖 UVM/VIP 的基础自测。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module axi4_top_demo #(
  parameter int ADDR_WIDTH     = 32,
  parameter int DATA_WIDTH     = 64,
  parameter int ID_WIDTH       = 4,
  parameter int MEM_BYTES      = 4096,
  parameter int WR_OUTSTANDING = 4,
  parameter int RD_OUTSTANDING = 4
) (
  input  logic                  aclk,
  input  logic                  aresetn,

  input  logic                  slave_wr_enable,
  input  logic                  slave_rd_enable,

  input  logic                  app_wr_en,
  output logic                  app_wr_ready,
  input  logic [ID_WIDTH-1:0]   app_wr_id,
  input  logic [ADDR_WIDTH-1:0] app_wr_addr,
  input  logic [DATA_WIDTH-1:0] app_wr_data,
  input  logic [7:0]            app_wr_len,
  input  logic [2:0]            app_wr_size,
  input  logic [1:0]            app_wr_burst,
  output logic                  app_wr_done,
  output logic [ID_WIDTH-1:0]   app_wr_done_id,
  output logic [1:0]            app_wr_resp,
  output logic                  app_wr_id_error,

  input  logic                  app_rd_en,
  output logic                  app_rd_ready,
  input  logic [ID_WIDTH-1:0]   app_rd_id,
  input  logic [ADDR_WIDTH-1:0] app_rd_addr,
  input  logic [7:0]            app_rd_len,
  input  logic [2:0]            app_rd_size,
  input  logic [1:0]            app_rd_burst,
  output logic                  app_rd_done,
  output logic [ID_WIDTH-1:0]   app_rd_done_id,
  output logic [DATA_WIDTH-1:0] app_rd_data,
  output logic [1:0]            app_rd_resp,
  output logic                  app_rd_id_error,

  output logic                  busy
);

  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  logic [ID_WIDTH-1:0]   axi_awid;
  logic [ADDR_WIDTH-1:0] axi_awaddr;
  logic [7:0]            axi_awlen;
  logic [2:0]            axi_awsize;
  logic [1:0]            axi_awburst;
  logic                  axi_awlock;
  logic [3:0]            axi_awcache;
  logic [2:0]            axi_awprot;
  logic [3:0]            axi_awqos;
  logic [3:0]            axi_awregion;
  logic                  axi_awvalid;
  logic                  axi_awready;

  logic [DATA_WIDTH-1:0] axi_wdata;
  logic [STRB_WIDTH-1:0] axi_wstrb;
  logic                  axi_wlast;
  logic                  axi_wvalid;
  logic                  axi_wready;

  logic [ID_WIDTH-1:0]   axi_bid;
  logic [1:0]            axi_bresp;
  logic                  axi_bvalid;
  logic                  axi_bready;

  logic [ID_WIDTH-1:0]   axi_arid;
  logic [ADDR_WIDTH-1:0] axi_araddr;
  logic [7:0]            axi_arlen;
  logic [2:0]            axi_arsize;
  logic [1:0]            axi_arburst;
  logic                  axi_arlock;
  logic [3:0]            axi_arcache;
  logic [2:0]            axi_arprot;
  logic [3:0]            axi_arqos;
  logic [3:0]            axi_arregion;
  logic                  axi_arvalid;
  logic                  axi_arready;

  logic [ID_WIDTH-1:0]   axi_rid;
  logic [DATA_WIDTH-1:0] axi_rdata;
  logic [1:0]            axi_rresp;
  logic                  axi_rlast;
  logic                  axi_rvalid;
  logic                  axi_rready;

  axi4_simple_master #(
    .ADDR_WIDTH    (ADDR_WIDTH),
    .DATA_WIDTH    (DATA_WIDTH),
    .ID_WIDTH      (ID_WIDTH),
    .MEM_BYTES     (MEM_BYTES),
    .WR_OUTSTANDING(WR_OUTSTANDING),
    .RD_OUTSTANDING(RD_OUTSTANDING)
  ) u_master (
    .aclk            (aclk),
    .aresetn         (aresetn),

    .app_wr_en       (app_wr_en),
    .app_wr_ready    (app_wr_ready),
    .app_wr_id       (app_wr_id),
    .app_wr_addr     (app_wr_addr),
    .app_wr_data     (app_wr_data),
    .app_wr_len      (app_wr_len),
    .app_wr_size     (app_wr_size),
    .app_wr_burst    (app_wr_burst),
    .app_wr_done     (app_wr_done),
    .app_wr_done_id  (app_wr_done_id),
    .app_wr_resp     (app_wr_resp),
    .app_wr_id_error (app_wr_id_error),

    .app_rd_en       (app_rd_en),
    .app_rd_ready    (app_rd_ready),
    .app_rd_id       (app_rd_id),
    .app_rd_addr     (app_rd_addr),
    .app_rd_len      (app_rd_len),
    .app_rd_size     (app_rd_size),
    .app_rd_burst    (app_rd_burst),
    .app_rd_done     (app_rd_done),
    .app_rd_done_id  (app_rd_done_id),
    .app_rd_data     (app_rd_data),
    .app_rd_resp     (app_rd_resp),
    .app_rd_id_error (app_rd_id_error),
    .busy            (busy),

    .m_axi_awid      (axi_awid),
    .m_axi_awaddr    (axi_awaddr),
    .m_axi_awlen     (axi_awlen),
    .m_axi_awsize    (axi_awsize),
    .m_axi_awburst   (axi_awburst),
    .m_axi_awlock    (axi_awlock),
    .m_axi_awcache   (axi_awcache),
    .m_axi_awprot    (axi_awprot),
    .m_axi_awqos     (axi_awqos),
    .m_axi_awregion  (axi_awregion),
    .m_axi_awvalid   (axi_awvalid),
    .m_axi_awready   (axi_awready),

    .m_axi_wdata     (axi_wdata),
    .m_axi_wstrb     (axi_wstrb),
    .m_axi_wlast     (axi_wlast),
    .m_axi_wvalid    (axi_wvalid),
    .m_axi_wready    (axi_wready),

    .m_axi_bid       (axi_bid),
    .m_axi_bresp     (axi_bresp),
    .m_axi_bvalid    (axi_bvalid),
    .m_axi_bready    (axi_bready),

    .m_axi_arid      (axi_arid),
    .m_axi_araddr    (axi_araddr),
    .m_axi_arlen     (axi_arlen),
    .m_axi_arsize    (axi_arsize),
    .m_axi_arburst   (axi_arburst),
    .m_axi_arlock    (axi_arlock),
    .m_axi_arcache   (axi_arcache),
    .m_axi_arprot    (axi_arprot),
    .m_axi_arqos     (axi_arqos),
    .m_axi_arregion  (axi_arregion),
    .m_axi_arvalid   (axi_arvalid),
    .m_axi_arready   (axi_arready),

    .m_axi_rid       (axi_rid),
    .m_axi_rdata     (axi_rdata),
    .m_axi_rresp     (axi_rresp),
    .m_axi_rlast     (axi_rlast),
    .m_axi_rvalid    (axi_rvalid),
    .m_axi_rready    (axi_rready)
  );

  axi4_mem_slave #(
    .ADDR_WIDTH    (ADDR_WIDTH),
    .DATA_WIDTH    (DATA_WIDTH),
    .ID_WIDTH      (ID_WIDTH),
    .MEM_BYTES     (MEM_BYTES),
    .WR_OUTSTANDING(WR_OUTSTANDING),
    .RD_OUTSTANDING(RD_OUTSTANDING)
  ) u_slave (
    .aclk            (aclk),
    .aresetn         (aresetn),
    .slave_wr_enable (slave_wr_enable),
    .slave_rd_enable (slave_rd_enable),

    .s_axi_awid      (axi_awid),
    .s_axi_awaddr    (axi_awaddr),
    .s_axi_awlen     (axi_awlen),
    .s_axi_awsize    (axi_awsize),
    .s_axi_awburst   (axi_awburst),
    .s_axi_awlock    (axi_awlock),
    .s_axi_awcache   (axi_awcache),
    .s_axi_awprot    (axi_awprot),
    .s_axi_awqos     (axi_awqos),
    .s_axi_awregion  (axi_awregion),
    .s_axi_awvalid   (axi_awvalid),
    .s_axi_awready   (axi_awready),

    .s_axi_wdata     (axi_wdata),
    .s_axi_wstrb     (axi_wstrb),
    .s_axi_wlast     (axi_wlast),
    .s_axi_wvalid    (axi_wvalid),
    .s_axi_wready    (axi_wready),

    .s_axi_bid       (axi_bid),
    .s_axi_bresp     (axi_bresp),
    .s_axi_bvalid    (axi_bvalid),
    .s_axi_bready    (axi_bready),

    .s_axi_arid      (axi_arid),
    .s_axi_araddr    (axi_araddr),
    .s_axi_arlen     (axi_arlen),
    .s_axi_arsize    (axi_arsize),
    .s_axi_arburst   (axi_arburst),
    .s_axi_arlock    (axi_arlock),
    .s_axi_arcache   (axi_arcache),
    .s_axi_arprot    (axi_arprot),
    .s_axi_arqos     (axi_arqos),
    .s_axi_arregion  (axi_arregion),
    .s_axi_arvalid   (axi_arvalid),
    .s_axi_arready   (axi_arready),

    .s_axi_rid       (axi_rid),
    .s_axi_rdata     (axi_rdata),
    .s_axi_rresp     (axi_rresp),
    .s_axi_rlast     (axi_rlast),
    .s_axi_rvalid    (axi_rvalid),
    .s_axi_rready    (axi_rready)
  );

endmodule

`default_nettype wire
