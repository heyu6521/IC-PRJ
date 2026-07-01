// -----------------------------------------------------------------------------
// File       : axi4_basic_smoke_tb.sv
// Author     : ChatGPT
// Description: AXI4 top demo 基础 smoke test。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module axi4_basic_smoke_tb;

  import axi4_defines_pkg::*;

  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 64;
  localparam int ID_WIDTH   = 4;
  localparam int MEM_BYTES  = 4096;
  localparam int STRB_WIDTH = DATA_WIDTH / 8;

  localparam logic [2:0] FULL_SIZE = (STRB_WIDTH == 4)  ? AXI_SIZE_4_BYTES  :
                                     (STRB_WIDTH == 8)  ? AXI_SIZE_8_BYTES  :
                                     (STRB_WIDTH == 16) ? AXI_SIZE_16_BYTES :
                                                          AXI_SIZE_8_BYTES;

  logic                  aclk;
  logic                  aresetn;
  logic                  slave_wr_enable;
  logic                  slave_rd_enable;

  logic                  app_wr_en;
  logic [ADDR_WIDTH-1:0] app_wr_addr;
  logic [DATA_WIDTH-1:0] app_wr_data;
  logic [7:0]            app_wr_len;
  logic [2:0]            app_wr_size;
  logic [1:0]            app_wr_burst;
  logic                  app_wr_done;
  logic [1:0]            app_wr_resp;

  logic                  app_rd_en;
  logic [ADDR_WIDTH-1:0] app_rd_addr;
  logic [7:0]            app_rd_len;
  logic [2:0]            app_rd_size;
  logic [1:0]            app_rd_burst;
  logic                  app_rd_done;
  logic [DATA_WIDTH-1:0] app_rd_data;
  logic [1:0]            app_rd_resp;

  logic                  busy;
  bit                    test_failed;

  axi4_top_demo #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .ID_WIDTH  (ID_WIDTH),
    .MEM_BYTES (MEM_BYTES)
  ) dut (
    .aclk            (aclk),
    .aresetn         (aresetn),
    .slave_wr_enable (slave_wr_enable),
    .slave_rd_enable (slave_rd_enable),
    .app_wr_en       (app_wr_en),
    .app_wr_addr     (app_wr_addr),
    .app_wr_data     (app_wr_data),
    .app_wr_len      (app_wr_len),
    .app_wr_size     (app_wr_size),
    .app_wr_burst    (app_wr_burst),
    .app_wr_done     (app_wr_done),
    .app_wr_resp     (app_wr_resp),
    .app_rd_en       (app_rd_en),
    .app_rd_addr     (app_rd_addr),
    .app_rd_len      (app_rd_len),
    .app_rd_size     (app_rd_size),
    .app_rd_burst    (app_rd_burst),
    .app_rd_done     (app_rd_done),
    .app_rd_data     (app_rd_data),
    .app_rd_resp     (app_rd_resp),
    .busy            (busy)
  );

  initial begin
    aclk = 1'b0;
    forever #5 aclk = ~aclk;
  end

`ifdef FSDB
  initial begin
    $fsdbDumpfile("axi4_basic_smoke.fsdb");
    $fsdbDumpvars(0, axi4_basic_smoke_tb);
  end
`endif

  // 打印关键 AXI 握手，便于学习五通道时序。
  always @(posedge aclk) begin
    if (aresetn) begin
      if (dut.axi_awvalid && dut.axi_awready) begin
        $display("[%0t] AW handshake: addr=0x%0h len=%0d size=%0d burst=%0d",
                 $time, dut.axi_awaddr, dut.axi_awlen, dut.axi_awsize, dut.axi_awburst);
      end
      if (dut.axi_wvalid && dut.axi_wready) begin
        $display("[%0t] W  handshake: data=0x%0h strb=0x%0h last=%0b",
                 $time, dut.axi_wdata, dut.axi_wstrb, dut.axi_wlast);
      end
      if (dut.axi_bvalid && dut.axi_bready) begin
        $display("[%0t] B  handshake: resp=%0d", $time, dut.axi_bresp);
      end
      if (dut.axi_arvalid && dut.axi_arready) begin
        $display("[%0t] AR handshake: addr=0x%0h len=%0d size=%0d burst=%0d",
                 $time, dut.axi_araddr, dut.axi_arlen, dut.axi_arsize, dut.axi_arburst);
      end
      if (dut.axi_rvalid && dut.axi_rready) begin
        $display("[%0t] R  handshake: data=0x%0h resp=%0d last=%0b",
                 $time, dut.axi_rdata, dut.axi_rresp, dut.axi_rlast);
      end
    end
  end

  task automatic reset_dut;
    begin
      aresetn         = 1'b0;
      slave_wr_enable = 1'b1;
      slave_rd_enable = 1'b1;
      app_wr_en       = 1'b0;
      app_wr_addr     = '0;
      app_wr_data     = '0;
      app_wr_len      = '0;
      app_wr_size     = FULL_SIZE;
      app_wr_burst    = AXI_BURST_INCR;
      app_rd_en       = 1'b0;
      app_rd_addr     = '0;
      app_rd_len      = '0;
      app_rd_size     = FULL_SIZE;
      app_rd_burst    = AXI_BURST_INCR;
      test_failed     = 1'b0;

      repeat (5) @(posedge aclk);
      @(negedge aclk);
      aresetn = 1'b1;
      repeat (3) @(posedge aclk);
      $display("[%0t] Reset released", $time);
    end
  endtask

  task automatic axi_app_write(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [DATA_WIDTH-1:0] data,
    input logic [7:0]            len,
    input logic [2:0]            size,
    input logic [1:0]            burst,
    input logic [1:0]            exp_resp,
    input string                 name
  );
    int timeout;
    bit seen_done;
    begin
      $display("[%0t] START WRITE %s: addr=0x%0h data=0x%0h len=%0d exp_resp=%0d",
               $time, name, addr, data, len, exp_resp);

      while (busy) @(posedge aclk);
      @(negedge aclk);
      app_wr_addr  = addr;
      app_wr_data  = data;
      app_wr_len   = len;
      app_wr_size  = size;
      app_wr_burst = burst;
      app_wr_en    = 1'b1;
      @(negedge aclk);
      app_wr_en    = 1'b0;

      seen_done = 1'b0;
      timeout   = 0;
      while (!seen_done && (timeout < 1000)) begin
        @(posedge aclk);
        #1;
        if (app_wr_done) begin
          seen_done = 1'b1;
        end
        timeout++;
      end

      if (!seen_done) begin
        $display("[%0t] ERROR WRITE %s: timeout", $time, name);
        test_failed = 1'b1;
      end else if (app_wr_resp !== exp_resp) begin
        $display("[%0t] ERROR WRITE %s: resp=%0d exp=%0d", $time, name, app_wr_resp, exp_resp);
        test_failed = 1'b1;
      end else begin
        $display("[%0t] PASS WRITE %s: resp=%0d", $time, name, app_wr_resp);
      end
    end
  endtask

  task automatic axi_app_read(
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [7:0]            len,
    input  logic [2:0]            size,
    input  logic [1:0]            burst,
    input  logic [1:0]            exp_resp,
    input  logic [DATA_WIDTH-1:0] exp_data,
    input  bit                    check_data,
    input  string                 name
  );
    int timeout;
    bit seen_done;
    begin
      $display("[%0t] START READ  %s: addr=0x%0h len=%0d exp_resp=%0d",
               $time, name, addr, len, exp_resp);

      while (busy) @(posedge aclk);
      @(negedge aclk);
      app_rd_addr  = addr;
      app_rd_len   = len;
      app_rd_size  = size;
      app_rd_burst = burst;
      app_rd_en    = 1'b1;
      @(negedge aclk);
      app_rd_en    = 1'b0;

      seen_done = 1'b0;
      timeout   = 0;
      while (!seen_done && (timeout < 1000)) begin
        @(posedge aclk);
        #1;
        if (app_rd_done) begin
          seen_done = 1'b1;
        end
        timeout++;
      end

      if (!seen_done) begin
        $display("[%0t] ERROR READ %s: timeout", $time, name);
        test_failed = 1'b1;
      end else if (app_rd_resp !== exp_resp) begin
        $display("[%0t] ERROR READ %s: resp=%0d exp=%0d", $time, name, app_rd_resp, exp_resp);
        test_failed = 1'b1;
      end else if (check_data && (app_rd_data !== exp_data)) begin
        $display("[%0t] ERROR READ %s: data=0x%0h exp=0x%0h",
                 $time, name, app_rd_data, exp_data);
        test_failed = 1'b1;
      end else begin
        $display("[%0t] PASS READ  %s: resp=%0d data=0x%0h", $time, name, app_rd_resp, app_rd_data);
      end
    end
  endtask

  initial begin
    reset_dut();

    // 1) single write/read
    axi_app_write(32'h0000_0040,
                  DATA_WIDTH'(64'h1122_3344_5566_7788),
                  8'd0,
                  FULL_SIZE,
                  AXI_BURST_INCR,
                  AXI_RESP_OKAY,
                  "single_write_okay");

    axi_app_read(32'h0000_0040,
                 8'd0,
                 FULL_SIZE,
                 AXI_BURST_INCR,
                 AXI_RESP_OKAY,
                 DATA_WIDTH'(64'h1122_3344_5566_7788),
                 1'b1,
                 "single_read_okay");

    // 2) 4-beat INCR burst：simple master 每拍写相同数据，因此最后一拍读回仍应相同。
    axi_app_write(32'h0000_0100,
                  DATA_WIDTH'(64'hDEAD_BEEF_CAFE_0101),
                  8'd3,
                  FULL_SIZE,
                  AXI_BURST_INCR,
                  AXI_RESP_OKAY,
                  "burst4_write_okay");

    axi_app_read(32'h0000_0100,
                 8'd3,
                 FULL_SIZE,
                 AXI_BURST_INCR,
                 AXI_RESP_OKAY,
                 DATA_WIDTH'(64'hDEAD_BEEF_CAFE_0101),
                 1'b1,
                 "burst4_read_okay");

    // 3) slave_wr_enable=0 时仍接收事务，但返回 SLVERR。
    @(negedge aclk);
    slave_wr_enable = 1'b0;
    axi_app_write(32'h0000_0200,
                  DATA_WIDTH'(64'h1234_5678_9ABC_DEF0),
                  8'd0,
                  FULL_SIZE,
                  AXI_BURST_INCR,
                  AXI_RESP_SLVERR,
                  "write_disabled_slverr");
    @(negedge aclk);
    slave_wr_enable = 1'b1;

    // 4) slave_rd_enable=0 时仍返回读通道 beat，但 RRESP/app_rd_resp 为 SLVERR。
    @(negedge aclk);
    slave_rd_enable = 1'b0;
    axi_app_read(32'h0000_0040,
                 8'd0,
                 FULL_SIZE,
                 AXI_BURST_INCR,
                 AXI_RESP_SLVERR,
                 '0,
                 1'b0,
                 "read_disabled_slverr");
    @(negedge aclk);
    slave_rd_enable = 1'b1;

    repeat (10) @(posedge aclk);

    if (!test_failed) begin
      $display("AXI4 BASIC SMOKE TEST PASSED");
    end else begin
      $display("AXI4 BASIC SMOKE TEST FAILED");
    end

    $finish;
  end

endmodule

`default_nettype wire
