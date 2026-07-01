# AXI 验证

该目录用于 AXI 协议学习与验证项目。

## 目录规划

- `rtl/`：AXI4 slave / memory model 等 RTL 代码
- `tb/`：UVM testbench、top、interface、sequence 等验证代码
- `sim/`：VCS/Verdi 仿真脚本、filelist、Makefile
- `docs/`：AXI 协议笔记、测试计划、调试记录
- `third_party/`：开源 VIP 或第三方依赖

## 已集成开源 VIP

当前以 Git submodule 方式集成：

- VIP：`tvip-axi`
- 类型：SystemVerilog/UVM AXI4 / AXI4-Lite VIP
- 上游仓库：https://github.com/taichi-ishitani/tvip-axi.git
- 本仓库路径：`axi验证/third_party/tvip-axi`

## 克隆方式

第一次克隆本仓库时，建议使用：

```bash
git clone --recurse-submodules https://github.com/heyu6521/IC-PRJ.git
```

如果已经克隆过仓库，则在仓库根目录执行：

```bash
git submodule update --init --recursive
```

## 后续计划

1. 搭建 AXI4 memory slave DUT
2. 编写 VCS/Verdi 仿真 filelist 和 Makefile
3. 接入 `tvip-axi` master agent
4. 先跑 AXI4-Lite / single transfer
5. 再扩展到 AXI4 burst、backpressure、WSTRB、非法地址响应等场景
