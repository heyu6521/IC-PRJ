// -----------------------------------------------------------------------------
// File       : axi4_defines_pkg.sv
// Author     : ChatGPT
// Description: AXI4 Full 基础常量定义包。
//              本包只放协议枚举/常量，不包含厂商私有语法，便于 RTL/TB 复用。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

package axi4_defines_pkg;

  // AXI4 response encoding
  localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI_RESP_EXOKAY = 2'b01;
  localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR = 2'b11;

  // AXI4 burst type encoding
  localparam logic [1:0] AXI_BURST_FIXED = 2'b00;
  localparam logic [1:0] AXI_BURST_INCR  = 2'b01;
  localparam logic [1:0] AXI_BURST_WRAP  = 2'b10;
  localparam logic [1:0] AXI_BURST_RSVD  = 2'b11;

  // AXI4 AxSIZE encoding: 每拍传输字节数 = 1 << AxSIZE
  localparam logic [2:0] AXI_SIZE_1_BYTE    = 3'd0;
  localparam logic [2:0] AXI_SIZE_2_BYTES   = 3'd1;
  localparam logic [2:0] AXI_SIZE_4_BYTES   = 3'd2;
  localparam logic [2:0] AXI_SIZE_8_BYTES   = 3'd3;
  localparam logic [2:0] AXI_SIZE_16_BYTES  = 3'd4;
  localparam logic [2:0] AXI_SIZE_32_BYTES  = 3'd5;
  localparam logic [2:0] AXI_SIZE_64_BYTES  = 3'd6;
  localparam logic [2:0] AXI_SIZE_128_BYTES = 3'd7;

  function automatic int unsigned axi_size_to_bytes(input logic [2:0] size);
    axi_size_to_bytes = 1 << size;
  endfunction

endpackage
