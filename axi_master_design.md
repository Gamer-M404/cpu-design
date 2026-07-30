# axi_master 总线控制器设计文档

## 1. 概述

`axi_master` 是 SoC 中的总线控制器模块，位于 Cache 和 AXI4 总线之间。它接收来自 ICache（取指）和 DCache（数据访问）的访存请求，将其转换为 AXI4 协议的总线事务，发送给下游从设备（主存、外设等）。

```
CPU core -> ICache/DCache -> axi_master -> AXI4 Bus -> Bridge -> {BRAM, UART, GPIO, ...}
```

## 2. 接口信号

### 2.1 Cache 侧接口（面向 CPU/Cache）

#### ICache 读接口

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `ic_dev_rrdy` | 1 | axi_master -> ICache | 总线读就绪，为 1 时可接收取指请求 |
| `ic_cpu_ren` | 1 | ICache -> axi_master | 取指读使能 |
| `ic_cpu_raddr` | 32 | ICache -> axi_master | 取指地址 |
| `ic_dev_rvalid` | 1 | axi_master -> ICache | 返回数据有效标志（仅 1 拍） |
| `ic_dev_rdata` | IC_BLK_SIZE | axi_master -> ICache | 返回的指令数据块 |

#### DCache 读接口

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `dc_dev_rrdy` | 1 | axi_master -> DCache | 总线读就绪 |
| `dc_cpu_ren` | 1 | DCache -> axi_master | 数据读使能 |
| `dc_cpu_raddr` | 32 | DCache -> axi_master | 读地址 |
| `dc_dev_rvalid` | 1 | axi_master -> DCache | 返回数据有效标志 |
| `dc_dev_rdata` | DC_BLK_SIZE | axi_master -> DCache | 返回的数据块 |

#### DCache 写接口

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `dc_dev_wrdy` | 1 | axi_master -> DCache | 总线写就绪 |
| `dc_cpu_wen` | 4 | DCache -> axi_master | 按字节写使能 |
| `dc_cpu_waddr` | 32 | DCache -> axi_master | 写地址 |
| `dc_cpu_wdata` | 32 | DCache -> axi_master | 写数据 |

### 2.2 AXI4 Master 接口（面向总线）

#### 写地址通道（AW）

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `m_axi_awaddr` | 32 | output | 写地址 |
| `m_axi_awlen` | 8 | output | 猝发长度（实际传输次数 = awlen + 1） |
| `m_axi_awsize` | 3 | output | 每拍数据字节数（= 3'd2，即 4 字节） |
| `m_axi_awburst` | 2 | output | 地址生成方式（= 2'd1，INCR 递增模式） |
| `m_axi_awvalid` | 1 | output | 写地址有效 |
| `m_axi_awready` | 1 | input | 从设备 AW 通道就绪 |

#### 写数据通道（W）

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `m_axi_wdata` | 32 | output | 写数据 |
| `m_axi_wstrb` | 4 | output | 写字节使能 |
| `m_axi_wlast` | 1 | output | 最后一拍写数据标志（组合逻辑） |
| `m_axi_wvalid` | 1 | output | 写数据有效 |
| `m_axi_wready` | 1 | input | 从设备 W 通道就绪 |

#### 写响应通道（B）

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `m_axi_bready` | 1 | output | 主设备 B 通道就绪（常为 1） |
| `m_axi_bresp` | 2 | input | 写响应状态（简化设计忽略） |
| `m_axi_bvalid` | 1 | input | 写响应有效 |

#### 读地址通道（AR）

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `m_axi_araddr` | 32 | output | 读地址 |
| `m_axi_arlen` | 8 | output | 猝发长度 |
| `m_axi_arsize` | 3 | output | 每拍字节数（= 3'd2） |
| `m_axi_arburst` | 2 | output | 地址生成方式（= 2'd1） |
| `m_axi_arvalid` | 1 | output | 读地址有效 |
| `m_axi_arready` | 1 | input | 从设备 AR 通道就绪 |

#### 读数据通道（R）

| 信号 | 位宽 | 方向 | 说明 |
|------|------|------|------|
| `m_axi_rready` | 1 | output | 主设备 R 通道就绪（常为 1） |
| `m_axi_rdata` | 32 | input | 读数据 |
| `m_axi_rresp` | 2 | input | 读响应状态（忽略） |
| `m_axi_rlast` | 1 | input | 最后一拍读数据标志 |
| `m_axi_rvalid` | 1 | input | 读数据有效 |

## 3. 状态机设计

### 3.1 状态定义

| 状态 | 编码 | 说明 |
|------|------|------|
| `S_IDLE` | 3'd0 | 空闲，等待 Cache 请求 |
| `S_RD_ADDR` | 3'd1 | 读地址握手（AR 通道） |
| `S_RD_DATA` | 3'd2 | 读数据接收（R 通道） |
| `S_RD_RET` | 3'd3 | 向 Cache 返回读数据（1 拍脉冲） |
| `S_WR_ADDR` | 3'd4 | 写地址握手（AW 通道） |
| `S_WR_DATA` | 3'd5 | 写数据发送（W 通道） |
| `S_WR_RESP` | 3'd6 | 写响应接收（B 通道） |

### 3.2 状态转换图

```
                              +--------------+
                 +----------->|    IDLE      |<-----------+
                 |            | dev_*_rdy=1  |            |
                 |            | dev_wrdy=1   |            |
                 |            +------+-------+            |
                 |                   |                    |
                 |   +---------------+--------------+    |
                 |   | dc_cpu_wen    | dc_cpu_ren  |    |
                 |   | != 0          | or          |    |
                 |   |               | ic_cpu_ren  |    |
                 |   v               v              v    |
                 | +--------+     +----------+          |
                 | |WR_ADDR |     | RD_ADDR  |          |
                 | |AW hand |     | AR hand  |          |
                 | +---+----+     +----+-----+          |
                 |     | awready       | arready        |
                 |     v               v                |
                 | +--------+     +----------+          |
                 | |WR_DATA |     | RD_DATA  |          |
                 | |W hand  |     | R data rx|          |
                 | +---+----+     +----+-----+          |
                 |     | wlast &       | rlast &        |
                 |     | wready        | rvalid         |
                 |     v               v                |
                 | +--------+     +----------+          |
                 | |WR_RESP |     | RD_RET   |          |
                 | |B hand  |     | ret data  |         |
                 | +---+----+     +----+-----+          |
                 |     | bvalid        | (next cycle)   |
                 +-----+               +----------------+
                  write path           read path
```

### 3.3 请求优先级

在 IDLE 态同时检测到多个 Cache 请求时，按以下优先级处理：

**DCache 写 > DCache 读 > ICache 读**

低优先级的请求不会被丢弃——当 axi_master 处理完当前请求回到 IDLE 并重新拉高 ready 信号时，Cache 的使能信号仍然保持，将在下一拍被接收。

## 4. 时序设计

### 4.1 AXI4 读时序（单拍，Cache 关闭时）

```
         T0    T1    T2    T3    T4    T5
         __    __    __    __    __    __
aclk    __/  \__/  \__/  \__/  \__/  \__/

state:  IDLE  RD_ADDR RD_ADDR RD_DATA RD_DATA RD_RET  IDLE

araddr: ----< ADDR >--------------------------------
arvalid:----__________------------------------------
arready:------------___________--------------------

rdata:  -------------------< D0 >-------------------
rlast:  -------------------_______------------------
rvalid: -------------------_______------------------

dev_rvalid: -------------------------------____
dev_rdata:  -------------------------------<DATA>
```

时序说明：
1. **T0**：IDLE 态，`dev_rrdy=1`，Cache 发出 `cpu_ren=1` + 地址 -> 检测到请求，锁存地址
2. **T1~T2**：RD_ADDR 态，发送 AR 地址，等待 `arready`
3. **T3~T4**：RD_DATA 态，等待 `rvalid` + `rlast`，锁存 `rdata`
4. **T5**：RD_RET 态，拉高 `dev_rvalid` 一个周期返回数据给 Cache

### 4.2 AXI4 写时序（单拍）

```
         T0    T1    T2    T3    T4    T5    T6
         __    __    __    __    __    __    __
aclk    __/  \__/  \__/  \__/  \__/  \__/  \__/

state:  IDLE  WR_ADDR WR_ADDR WR_DATA WR_DATA WR_RESP IDLE

awaddr: ----< ADDR >-------------------------------
awvalid:----__________-----------------------------
awready:------------___________--------------------

wdata:  ------------------< DATA >----------------
wstrb:  ------------------<STRB >----------------
wlast:  ------------------_______----------------
wvalid: ------------------__________--------------
wready: -------------------------___________------

bvalid: -------------------------------------______
bready: (always 1) ---------------------------------
```

时序说明：
1. **T0**：IDLE 态，检测到 DCache 写请求，锁存地址、数据、写使能
2. **T1~T2**：WR_ADDR 态，AW 通道握手
3. **T3~T4**：WR_DATA 态，W 通道握手，单拍时 `wlast` 恒为 1
4. **T5**：WR_RESP 态，等待 `bvalid`，收到后回到 IDLE

### 4.3 AXI4 读猝发时序（4 拍，Cache 开启时）

```
state:  IDLE  RD_ADDR ... RD_DATA  RD_DATA  RD_DATA  RD_DATA  RD_RET  IDLE
                             T3      T4      T5      T6      T7

rdata:  -------------------< D0 >--< D1 >--< D2 >--< D3 >-------------
rlast:  ---------------------------------------_______----------------
rvalid: -------------------________ ________ _______________----------

rd_data_buf assembly:
  beat0: D0 -> [31:0]
  beat1: D1 -> [63:32]
  beat2: D2 -> [95:64]
  beat3: D3 -> [127:96]

beat_cnt: 0 -> 1 -> 2 -> 3 (rlast triggers state transition)
```

猝发读时，`arlen = 3`（共 4 拍），数据通过 `rd_data_buf[beat_cnt*32 +: 32] <= m_axi_rdata` 逐拍拼接。

## 5. 关键实现细节

### 5.1 猝发长度配置

猝发长度由 `defines.vh` 中的宏自动确定：

| 配置 | IC_BLK_LEN | DC_BLK_LEN | 读猝发 | 写猝发 |
|------|-----------|-----------|--------|--------|
| Cache 关闭 | 1 | 1 | 1 拍 (32-bit) | 1 拍 (32-bit) |
| Cache 开启 | 4 | 4 | 4 拍 (128-bit) | 4 拍 (128-bit) |

```verilog
wire [7:0] ic_burst_len = `IC_BLK_LEN - 1;   // 0 or 3
wire [7:0] dc_burst_len = `DC_BLK_LEN - 1;
wire [7:0] burst_len    = req_is_dc ? dc_burst_len : ic_burst_len;
```

### 5.2 拍计数器

- 进入 IDLE 时清零
- RD_DATA 态：每收到 `rvalid` 加 1
- WR_DATA 态：每收到 `wready` 加 1
- `wlast = (beat_cnt == burst_len)` （组合逻辑）

```verilog
if (state == S_IDLE)
    beat_cnt <= 8'd0;
else if ((state == S_RD_DATA) && m_axi_rvalid)
    beat_cnt <= beat_cnt + 8'd1;
else if ((state == S_WR_DATA) && m_axi_wready)
    beat_cnt <= beat_cnt + 8'd1;
```

### 5.3 读数据组装（索引部分选择）

```verilog
if (state == S_RD_DATA && m_axi_rvalid)
    rd_data_buf[beat_cnt*32 +: 32] <= m_axi_rdata;
```

使用 Verilog 索引部分选择 `[base +: width]`，将每拍 32-bit 数据放入 128-bit 缓冲区的正确位置。

### 5.4 请求信息锁存

在时序逻辑中，当 `state == IDLE` 时检测请求并锁存：

```verilog
if (state == S_IDLE) begin
    if (dc_cpu_wen != 4'h0) begin          // Priority 1: DC write
        req_addr  <= dc_cpu_waddr;
        req_wdata <= dc_cpu_wdata;
        req_wstrb <= dc_cpu_wen;
        req_is_dc <= 1'b1;
    end else if (dc_cpu_ren) begin          // Priority 2: DC read
        req_addr  <= dc_cpu_raddr;
        req_is_dc <= 1'b1;
    end else if (ic_cpu_ren) begin          // Priority 3: IC read
        req_addr  <= ic_cpu_raddr;
        req_is_dc <= 1'b0;
    end
end
```

锁存逻辑与组合逻辑中 `state_next` 的判定使用相同的优先级，确保地址/数据在状态跳转时就绪。

### 5.5 AXI 简化的常值信号

按教程建议：

| 信号 | 常值 | 说明 |
|------|------|------|
| `m_axi_rready` | 1'b1 | 主设备随时可接收读数据 |
| `m_axi_bready` | 1'b1 | 主设备随时可接收写响应 |
| `m_axi_arsize` | 3'd2 | 每拍传输 4 字节（32-bit） |
| `m_axi_awsize` | 3'd2 | 同上 |
| `m_axi_arburst` | 2'd1 | INCR 递增地址模式 |
| `m_axi_awburst` | 2'd1 | 同上 |
| `rresp`/`bresp` | - | 忽略，不做校验 |

### 5.6 代码结构

采用「两段式」状态机：

| 段落 | 类型 | 功能 |
|------|------|------|
| `always @(posedge aclk or posedge areset)` | 时序逻辑 | 状态寄存器 + 数据锁存 + 拍计数 + 读数据组装 |
| `always @(*)` | 组合逻辑 | 下一状态计算 + 全部输出信号赋值 |

组合逻辑段对所有输出信号先赋默认安全值（ready=0, valid=0, data=0），各状态再按需覆盖，避免意外生成锁存器。

## 6. 后续集成步骤

按教程顺序，`axi_master.v` 之后还需完成：

1. 将实验 3 的 `ICache.v`、`DCache.v` 拷贝到 `src/rtl/`
2. 修改 `cpu_top.v`：实例化 ICache/DCache + axi_master，添加 AXI Master 接口
3. 创建 `miniRV_SoC.v`：连接 `cpu_top` 的 AXI 接口到 `bram_axi` IP 核
4. 创建 `bram_axi` BRAM IP 核（AXI4 接口），导入 `.coe` 初始化文件
5. 先在 `defines.vh` 禁用 Cache（不定义 `ENABLE_ICACHE`/`ENABLE_DCACHE`）仿真通过后再启用
