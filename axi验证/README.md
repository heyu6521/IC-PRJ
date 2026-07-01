# AXI 验证

该目录用于 AXI 协议学习与验证项目。

## 初步规划

- `rtl/`：AXI4 slave / memory model 等 RTL 代码
- `tb/`：UVM testbench、top、interface、sequence 等验证代码
- `sim/`：VCS/Verdi 仿真脚本、filelist、Makefile
- `docs/`：AXI 协议笔记、测试计划、调试记录
- `third_party/`：开源 VIP 或第三方依赖说明

后续计划：先搭建 AXI4 memory slave DUT，再接入开源 AXI VIP 进行基础读写、burst、backpressure 等测试。
