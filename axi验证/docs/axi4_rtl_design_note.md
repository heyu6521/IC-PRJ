# AXI4 RTL 学习与验证项目说明

本目录提供一套面向 AXI4 协议学习、基础 RTL 自测、以及后续接入开源 UVM VIP `tvip-axi` 的 SystemVerilog 示例工程。当前版本优先保证协议握手清晰、代码可读、便于调试，不追求高性能。

## 1. AXI4 五通道说明

AXI4 Full 使用五个相互独立的握手通道，每个通道通过 `VALID/READY` 完成传输：

1. **AW 写地址通道**：master 发送写事务地址、ID、burst 长度、size、burst 类型等信息。
2. **W 写数据通道**：master 发送写数据、byte strobe、`WLAST`。AW 和 W 是解耦的，不能假设二者同拍出现。
3. **B 写响应通道**：slave 在接收完整写 burst 后返回写响应，常见响应包括 `OKAY` 和 `SLVERR`。
4. **AR 读地址通道**：master 发送读事务地址、ID、burst 长度、size、burst 类型等信息。
5. **R 读数据通道**：slave 返回读数据、读响应和 `RLAST`，最后一拍必须拉高 `RLAST`。

AXI4 的 `AxLEN` 编码为 burst beat 数减 1，因此真实 beat 数为 `AxLEN + 1`。`AxSIZE` 表示每拍传输字节数，计算方式为 `1 << AxSIZE`。地址按 byte addressing 处理。

## 2. `axi4_mem_slave` 设计思路

`axi4_mem_slave` 是一个单 outstanding 的 AXI4 memory slave model，可作为 DUT 被 AXI VIP master agent 访问。

主要设计点：

- 内部 memory 使用 byte array：`logic [7:0] mem [0:MEM_BYTES-1]`。
- 写事务状态机分为 `WR_IDLE / WR_DATA / WR_RESP`。
- 读事务状态机分为 `RD_IDLE / RD_DATA`。
- 写地址 AW 和写数据 W 解耦：模块先接收 AW，锁存地址、长度、size、burst 等信息，再打开 `WREADY` 接收 W beat。
- 当前允许一个写事务和一个读事务分别 outstanding；忙时拉低 `AWREADY` 或 `ARREADY`。
- 支持 `WSTRB` byte strobe。只有 `WSTRB[i] == 1` 且该 byte lane 属于当前 transfer 时才更新 memory。
- `slave_wr_enable == 0` 或 `slave_rd_enable == 0` 时，模块仍接收事务并返回 `SLVERR`，避免 master 因等待 ready 或 response 而永久阻塞。
- `WRAP` / reserved burst 当前不实现：命令会被接收，但响应为 `SLVERR`。
- `AWLOCK/ARLOCK` 为 1 时返回 `SLVERR`，当前不实现 exclusive/locked access。
- `cache/prot/qos/region` 端口保留用于 VIP 对接，当前不解释复杂语义。

## 3. `axi4_simple_master` 设计思路

`axi4_simple_master` 是一个简单 AXI4 master，可主动发起 AXI 写事务和读事务，也可后续接入 AXI VIP slave agent。

app 侧接口包括：

- `app_wr_en/app_wr_addr/app_wr_data/app_wr_len/app_wr_size/app_wr_burst`
- `app_rd_en/app_rd_addr/app_rd_len/app_rd_size/app_rd_burst`
- `app_wr_done/app_wr_resp`
- `app_rd_done/app_rd_data/app_rd_resp`
- `busy`

当前行为：

- `app_wr_en` 拉高一个周期后，master 发起一次 AXI 写 burst。
- `app_rd_en` 拉高一个周期后，master 发起一次 AXI 读 burst。
- `busy == 1` 时忽略新的 app 请求，app 侧应等待 `busy` 拉低后再发起下一笔。
- 若 `app_wr_en` 和 `app_rd_en` 同时有效，写请求优先。
- 写数据第一版每个 beat 发送相同的 `app_wr_data`；后续可扩展为 FIFO 或 stream 数据源。
- 读数据第一版只保存最后一个 R beat 到 `app_rd_data`；后续可扩展为 FIFO 缓存完整 burst。
- master 会产生 `WLAST`，并检查 `RLAST` 是否与期望 beat 计数一致；若不一致，将 `app_rd_resp` 标记为 `SLVERR`。

## 4. 当前支持的 AXI4 特性

- AXI4 Full 基础五通道握手。
- 参数化 `ADDR_WIDTH / DATA_WIDTH / ID_WIDTH / MEM_BYTES`。
- `DATA_WIDTH` 设计目标支持 32 / 64 / 128 bit。
- `STRB_WIDTH = DATA_WIDTH / 8`。
- byte addressing。
- memory 范围检查。
- single outstanding 写事务。
- single outstanding 读事务。
- AW/W 通道解耦。
- `FIXED` burst。
- `INCR` burst。
- `AxLEN` burst 长度。
- `AxSIZE` 基础检查。
- `WLAST` 检查。
- `RLAST` 产生和 master 侧检查。
- `WSTRB` 部分写。
- 正常访问返回 `OKAY`。
- 地址越界、size 非法、enable 关闭、unsupported burst、locked access 返回 `SLVERR`。
- `slave_wr_enable` 和 `slave_rd_enable` 运行时控制。

## 5. 当前暂不支持或简化的特性

当前版本是学习和 smoke test 用第一版，不支持或仅简化处理以下内容：

- multiple outstanding。
- out-of-order response。
- exclusive access / locked access。
- AXI5 atomic。
- AXI user signal。
- QoS / region / cache / prot 的复杂语义。
- 4KB boundary 完整检查。
- `WRAP` burst 的真实地址回绕逻辑；当前返回 `SLVERR`。
- 跨越数据总线自然边界的复杂非对齐 narrow transfer。
- master 侧完整 burst 写数据 FIFO。
- master 侧完整 burst 读数据 FIFO。
- master 侧 BID/RID 复杂匹配；由于 single outstanding 且固定 ID=0，当前只保留端口，不做复杂检查。

## 6. 如何运行 smoke test

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

没有 Verdi/FSDB 环境时，不设置 `WAVES=1` 即可正常运行普通仿真。

smoke test 覆盖：

1. reset DUT。
2. single write/read。
3. 4-beat `INCR` burst write/read。
4. `slave_wr_enable = 0` 时写响应为 `SLVERR`。
5. `slave_rd_enable = 0` 时读响应为 `SLVERR`。

通过时打印：

```text
AXI4 BASIC SMOKE TEST PASSED
```

失败时打印：

```text
AXI4 BASIC SMOKE TEST FAILED
```

## 7. 后续如何接入 `tvip-axi`

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
6. 当前 slave/master 都是 single outstanding，因此 VIP sequence 初期应限制 outstanding depth 为 1。
7. 初期 sequence 建议覆盖：
   - single write/read。
   - INCR burst。
   - FIXED burst。
   - WSTRB partial write。
   - out-of-range access 返回 `SLVERR`。
   - enable 关闭返回 `SLVERR`。
   - WRAP burst 返回 `SLVERR`。

## 8. 后续扩展计划

建议按以下顺序扩展：

1. 为 `axi4_simple_master` 增加写数据 FIFO，使 burst 每拍可写不同数据。
2. 为 `axi4_simple_master` 增加读数据 FIFO，保存完整读 burst。
3. 增加 `WSTRB` partial write 的定向 test。
4. 增加地址越界、size 非法、WRAP burst 的 negative test。
5. 增加 4KB boundary 检查。
6. 增加 multiple outstanding 支持。
7. 增加 ID-based response tracking。
8. 增加 `tvip-axi` UVM smoke test 环境。
9. 若需要更完整 AXI4 compatibility，再补充 USER signal 参数化和 sideband 语义检查。
