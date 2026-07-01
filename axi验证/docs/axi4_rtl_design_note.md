# AXI4 RTL 学习与验证项目说明

本目录提供一套面向 AXI4 协议学习、基础 RTL 自测、以及后续接入开源 UVM VIP `tvip-axi` 的 SystemVerilog 示例工程。当前版本优先保证协议握手清晰、代码可读、便于调试，不追求高性能。

## 1. AXI4 五通道说明

AXI4 Full 是 memory-mapped 协议，使用五个相互独立的握手通道，每个通道通过 `VALID/READY` 完成传输：

1. **AW 写地址通道**：master 发送写事务地址、ID、burst 长度、size、burst 类型等信息。
2. **W 写数据通道**：master 发送写数据、byte strobe、`WLAST`。AW 和 W 是解耦的，AXI4 的 W 通道不带 WID，因此 W beat 必须按 AW 接收顺序归属到对应写事务。
3. **B 写响应通道**：slave 在接收完整写 burst 后返回写响应，`BID` 必须对应写事务的 `AWID`。
4. **AR 读地址通道**：master 发送读事务地址、ID、burst 长度、size、burst 类型等信息。
5. **R 读数据通道**：slave 返回读数据、读响应、`RID` 和 `RLAST`。`RID` 必须对应读事务的 `ARID`。

AXI4 的 `AxLEN` 编码为 burst beat 数减 1，因此真实 beat 数为 `AxLEN + 1`。`AxSIZE` 表示每拍传输字节数，计算方式为 `1 << AxSIZE`。地址按 byte addressing 处理。

## 2. memory backend 说明

当前项目选择 `memory` 作为 AXI4 Full slave 后端，而不是 FIFO。原因是 AXI4 Full 本质是地址映射协议，读写验证最自然的模型是：

```text
AXI master / VIP master
        |
        v
axi4_mem_slave
        |
        v
byte-addressable memory
```

这样可以验证 write/read 一致性、地址映射、burst、WSTRB、size、越界访问和 response。FIFO 更适合作为后续独立的 memory-mapped FIFO 外设模型，例如 `axi4_fifo_slave`，而不是替代通用 memory slave。

## 3. `axi4_mem_slave` 设计思路

`axi4_mem_slave` 是一个 AXI4 Full memory slave model，可作为 DUT 被 AXI VIP master agent 访问。

主要设计点：

- 内部 memory 使用 byte array：`logic [7:0] mem [0:MEM_BYTES-1]`。
- 参数化支持：`ADDR_WIDTH / DATA_WIDTH / ID_WIDTH / MEM_BYTES / WR_OUTSTANDING / RD_OUTSTANDING`。
- 写路径采用 `AW context FIFO + W executor + B response FIFO`。
- `AWREADY` 在写 context FIFO 未满时可持续接收 AW，因此可形成多个写 outstanding。
- AXI4 W 通道没有 WID，所以 W beat 按 AW FIFO 顺序消耗队首写事务。
- 写事务完成后将 `{BID, BRESP}` 放入 B response FIFO，`BID` echo 对应 `AWID`。
- 读路径采用 `AR context FIFO + R executor`。
- `ARREADY` 在读 context FIFO 未满时可持续接收 AR，因此可形成多个读 outstanding。
- 当前 R 通道第一版按 AR FIFO 顺序返回，不做乱序读返回；每个 beat 的 `RID` echo 对应 `ARID`。
- 支持 `WSTRB` byte strobe。只有 `WSTRB[i] == 1` 且该 byte lane 属于当前 transfer 时才更新 memory。
- `slave_wr_enable == 0` 或 `slave_rd_enable == 0` 时，模块仍接收事务并返回 `SLVERR`，避免 master 因等待 ready 或 response 而永久阻塞。
- `WRAP` / reserved burst 当前不实现：命令会被接收，但响应为 `SLVERR`。
- `AWLOCK/ARLOCK` 为 1 时返回 `SLVERR`，当前不实现 exclusive/locked access。
- `cache/prot/qos/region` 端口保留用于 VIP 对接，当前不解释复杂语义。

## 4. `axi4_simple_master` 设计思路

`axi4_simple_master` 是一个 ID-aware 的 AXI4 simple master，可主动发起多个 outstanding 写事务和读事务，也可后续接入 AXI VIP slave agent。

app 写请求接口包括：

- `app_wr_en / app_wr_ready`
- `app_wr_id / app_wr_addr / app_wr_data / app_wr_len / app_wr_size / app_wr_burst`
- `app_wr_done / app_wr_done_id / app_wr_resp / app_wr_id_error`

app 读请求接口包括：

- `app_rd_en / app_rd_ready`
- `app_rd_id / app_rd_addr / app_rd_len / app_rd_size / app_rd_burst`
- `app_rd_done / app_rd_done_id / app_rd_data / app_rd_resp / app_rd_id_error`

当前行为：

- `app_wr_ready == 1` 时，`app_wr_en` 可以送入一笔写请求。
- `app_rd_ready == 1` 时，`app_rd_en` 可以送入一笔读请求。
- `busy == 1` 表示内部仍有在途事务，不再表示不能接收新请求；是否可接收新请求应看 `app_wr_ready/app_rd_ready`。
- master 发出的 `AWID/ARID` 来自 app 侧 `app_wr_id/app_rd_id`。
- master 使用 active ID table 跟踪未完成写/读事务。
- 收到 `BVALID` 时检查 `BID` 是否属于未完成写事务；未知 `BID` 会通过 `app_wr_id_error` 标记。
- 收到 `RVALID` 时检查 `RID` 是否属于未完成读事务；未知 `RID` 会通过 `app_rd_id_error` 标记。
- master 会检查 `RLAST` 是否与该 `RID` 对应事务的 beat 计数一致；不一致时将 app 读响应标记为 `SLVERR`。
- 写数据第一版每个 beat 发送相同的 `app_wr_data`；后续可扩展为 FIFO 或 stream 数据源。
- 读数据第一版只保存完成事务的最后一个 R beat 到 `app_rd_data`；后续可扩展为 FIFO 缓存完整 burst。

## 5. 当前支持的 AXI4 特性

- AXI4 Full 基础五通道握手。
- 参数化 `ADDR_WIDTH / DATA_WIDTH / ID_WIDTH / MEM_BYTES`。
- 参数化 outstanding 深度：`WR_OUTSTANDING / RD_OUTSTANDING`。
- `DATA_WIDTH` 设计目标支持 32 / 64 / 128 bit。
- `STRB_WIDTH = DATA_WIDTH / 8`。
- byte addressing。
- 后端 byte-addressable memory。
- memory 范围检查。
- 多 AW outstanding，W 按 AW 顺序执行。
- 多 AR outstanding，R 当前按 AR 顺序返回。
- ID echo：`BID <- AWID`，`RID <- ARID`。
- master 侧 BID/RID active table 检查。
- AW/W 通道解耦。
- `FIXED` burst。
- `INCR` burst。
- `AxLEN` burst 长度。
- `AxSIZE` 基础检查。
- 4KB boundary 基础检查。
- `WLAST` 检查。
- `RLAST` 产生和 master 侧检查。
- `WSTRB` 部分写。
- 正常访问返回 `OKAY`。
- 地址越界、size 非法、enable 关闭、unsupported burst、locked access 返回 `SLVERR`。
- `slave_wr_enable` 和 `slave_rd_enable` 运行时控制。

## 6. 当前暂不支持或简化的特性

当前版本是学习和 smoke test 用版本，不支持或仅简化处理以下内容：

- out-of-order response。
- exclusive access / locked access。
- AXI5 atomic。
- AXI user signal。
- QoS / region / cache / prot 的复杂语义。
- `WRAP` burst 的真实地址回绕逻辑；当前返回 `SLVERR`。
- 跨越数据总线自然边界的复杂非对齐 narrow transfer。
- master 侧完整 burst 写数据 FIFO。
- master 侧完整 burst 读数据 FIFO。
- 多个相同 ID 事务的 app 侧序号区分；当前 app completion 只返回 ID，不返回额外 tag。

## 7. 如何运行 smoke test

进入仿真目录：

```bash
cd axi验证/sim
make compile
make sim
```

或直接：

```bash
make all
```

默认使用 VCS：

```bash
vcs -full64 -sverilog -timescale=1ns/1ps
```

清理生成文件：

```bash
make clean
```

如果环境支持 Verdi/FSDB，可打开 FSDB dump 宏：

```bash
make all WAVES=1
```

## 8. 后续如何接入 `tvip-axi`

仓库中预期已通过 submodule 集成：

```text
axi验证/third_party/tvip-axi
```

建议接入方式：

1. 将 `axi4_mem_slave` 作为 DUT，使用 `tvip-axi` master agent 发起 AXI write/read sequence。
2. 将 `axi4_simple_master` 作为 DUT，使用 `tvip-axi` slave agent 响应 master 发起的 write/read。
3. 保持 AXI 信号命名映射：
   - slave DUT 端口使用 `s_axi_*`。
   - master DUT 端口使用 `m_axi_*`。
4. 如果 `tvip-axi` interface 中包含当前 RTL 未实现的 USER 信号，可在 UVM wrapper 或 interface adapter 中关闭 USER 参数，或 tie-off USER 信号。
5. `cache/prot/qos/region` 当前有端口但不解释复杂语义；VIP sequence 初期建议使用默认值。
6. 当前支持多个 outstanding，但第一版不做乱序返回；VIP sequence 初期建议关闭 out-of-order response。
7. 初期 sequence 建议覆盖：
   - multiple AW outstanding。
   - multiple AR outstanding。
   - 不同 ID 的 write/read。
   - single write/read。
   - INCR burst。
   - FIXED burst。
   - WSTRB partial write。
   - out-of-range access 返回 `SLVERR`。
   - enable 关闭返回 `SLVERR`。
   - WRAP burst 返回 `SLVERR`。

## 9. 后续扩展计划

建议按以下顺序扩展：

1. 为 `axi4_simple_master` 增加写数据 FIFO，使 burst 每拍可写不同数据。
2. 为 `axi4_simple_master` 增加读数据 FIFO，保存完整读 burst。
3. 增加 app transaction tag，解决相同 ID 多事务在 app 侧的唯一匹配问题。
4. 增加 `WSTRB` partial write 的定向 test。
5. 增加地址越界、size 非法、WRAP burst 的 negative test。
6. 增加真正的 WRAP burst 地址生成。
7. 增加 out-of-order response 支持。
8. 增加 `tvip-axi` UVM smoke test 环境。
9. 若需要更完整 AXI4 compatibility，再补充 USER signal 参数化和 sideband 语义检查。
