# tvip-axi 集成说明

## 选择原因

`tvip-axi` 是开源 SystemVerilog/UVM AXI VIP，适合作为公司商业 VIP 不方便外网使用时的学习替代。

本项目先用它完成 AXI4 / AXI4-Lite 基础验证环境搭建，后续如果需要接公司 VIP，可以保持 DUT 端 AXI4 标准端口不变，只替换 testbench/VIP 层。

## submodule 路径

```text
axi验证/third_party/tvip-axi
```

## 初始化命令

```bash
git submodule update --init --recursive
```

## 后续接入思路

1. 先跑通 `tvip-axi` 自带 example。
2. 编写本项目自己的 `axi4_mem_slave.sv`。
3. 用 `tvip-axi` 的 master agent 访问 DUT。
4. 第一阶段限制 outstanding = 1，burst 先从 INCR 开始。
5. 基础通过后再打开 backpressure、FIXED/WRAP、partial write、非法访问等场景。

## 注意

`tvip-axi` 本身还有自己的依赖，拉取时要使用 `--recursive`，否则可能缺少它内部依赖的 submodule。
