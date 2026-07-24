# miniRV_SoC 小游戏方案

> 目标：在 miniRV_SoC 上嵌入一个小游戏，外接 VGA 小屏幕，实现可玩游戏功能
> 硬件平台：EGO1 (xc7a35tcsg324-1, Xilinx Artix-7)
> 分析日期：2026-07-13

---

## 一、现状盘点

### 1.1 你已经有的 ✅

| 资源 | 状态 |
|------|------|
| RV32I CPU 核心（8 条指令） | ✅ 五级流水线运行中 |
| 指令存储器 IROM (BRAM, 8KB) | ✅ |
| 数据存储器 DRAM (BRAM, 8KB) | ✅ |
| UART 串口 (rx/tx) | ✅ 端口已定义，地址映射已完成 (0xFFFF_3000) |
| 16 个拨码开关 (sw[15:0]) | ✅ 引脚已绑定，地址映射已完成 (0xFFFF_0000) |
| 16 个 LED (led[15:0]) | ✅ 引脚已绑定，地址映射已完成 (0xFFFF_1000) |
| 8 位数码管 (dig_en + dig_seg×2) | ✅ 引脚已绑定，地址映射已完成 (0xFFFF_2000) |
| PLL 时钟生成 (clk_wiz_0) | ✅ |
| Timer 定时器 | ✅ 地址映射已完成 (0xFFFF_4000) |

### 1.2 EGO1 板子上有但你还没用的 🔧

| 资源 | 引脚/接口 | 游戏中的用途 |
|------|----------|-------------|
| **VGA 接口** | 4-bit R/G/B + hsync + vsync | **接小屏幕显示游戏画面** |
| **5 个按键** | btn_u/d/l/r/c（上下左右中） | **游戏操控输入** |
| 100MHz 板载晶振 | P17 | 经 PLL 分出 25.175MHz 给 VGA 用 |

### 1.3 你还缺的 ❌

| 缺失项 | 说明 | 优先级 |
|--------|------|--------|
| **更多 RV32I 指令** | 做游戏需要加减法、比较、逻辑运算、Store 指令等 | 🔴 高 |
| **外设总线实现** | 地址空间已定义但外设读写逻辑未连线 | 🔴 高 |
| **VGA 控制器** | 硬件模块，生成 hsync/vsync 时序，输出 RGB 信号 | 🟡 中 |
| **帧缓冲 (Frame Buffer)** | 双口 BRAM，CPU 写像素 / VGA 读像素 | 🟡 中 |
| **按键控制器** | 消抖 + 状态寄存器，映射到 CPU 地址空间 | 🟡 中 |
| **游戏程序** | RISC-V 汇编写的游戏逻辑 | 🟢 低（最后写） |

---

## 二、整体架构

```
miniRV_SoC
├── PLL (clk_wiz_0)
│   ├── clk_out1 → sys_clk (CPU 时钟)
│   └── clk_out2 → vga_clk (25.175MHz，VGA 像素时钟)
│
├── cpu_top
│   ├── cpu_core (五级流水线 RV32I)
│   ├── Inst_ROM (存放游戏程序)
│   └── Data_RAM (游戏变量 + 栈)
│
├── 外设总线互联 (Peripheral Bus / Memory-Mapped I/O)
│   ├── 地址译码器 (address decoder)
│   ├── 读数据多路选择器 (read data mux)
│   │
│   ├── [0xFFFF_0000] 拨码开关输入寄存器      ← 已有引脚
│   ├── [0xFFFF_1000] LED 输出寄存器           ← 已有引脚
│   ├── [0xFFFF_2000] 数码管输出寄存器         ← 已有引脚
│   ├── [0xFFFF_3000] UART 收发寄存器          ← 已有引脚
│   ├── [0xFFFF_4000] Timer 定时器             ← 已预留
│   ├── [0xFFFF_5000] 按键输入寄存器           ← 新加
│   └── [0xFFFF_6000] VGA 控制寄存器           ← 新加
│
├── VGA Controller (新加，纯硬件，独立于CPU运行)
│   ├── vga_timing.v   → 生成 hsync/vsync/blanking/像素坐标
│   └── vga_pixel.v    → 从 Frame Buffer 读像素，输出 RGB
│
├── Frame Buffer (新加，双口 BRAM)
│   ├── Port A → CPU 侧：地址映射到 0x8000_0000，CPU 可读写
│   └── Port B → VGA 侧：VGA Controller 只读，按像素时钟扫描
│
└── Button Controller (新加)
    ├── 按键消抖 (debounce)
    └── 状态寄存器，映射到 0xFFFF_5000
```

### 地址空间总规划

| 基地址 | 外设 | 大小 | 方向 | 说明 |
|--------|------|------|------|------|
| `0x0000_0000` | MEM (BRAM) | 512KB | R/W | 指令 + 数据 |
| `0x8000_0000` | Frame Buffer | 640×480×3bit | R/W | 帧缓冲，CPU 可写像素 |
| `0xFFFF_0000` | Switch | 4B | R | 16-bit 拨码开关值 |
| `0xFFFF_1000` | LED | 4B | W | 16-bit LED 输出 |
| `0xFFFF_2000` | Digital Tube | 4B×2 | W | 8 位数码管 |
| `0xFFFF_3000` | UART | 8B | R/W | 串口收发 |
| `0xFFFF_4000` | Timer | 16B | R/W | 定时器 |
| `0xFFFF_5000` | Button | 4B | R | 5-bit 按键状态 |
| `0xFFFF_6000` | VGA Control | 8B | R/W | VGA 使能/分辨率/模式 |

---

## 三、分步实施计划

### 第一步：补全 RV32I 核心指令

**目标**：让 CPU 有足够的能力写游戏逻辑。

**当前已实现（8 条）**：

| 指令 | 类型 | 用途 |
|------|------|------|
| ADDI | I-type | 立即数加法 |
| ORI | I-type | 立即数或 |
| SLLI | I-type | 立即数左移 |
| LW | I-type | 从内存加载 32-bit 字 |
| BEQ | B-type | 相等则分支 |
| BNE | B-type | 不等则分支 |
| LUI | U-type | 加载立即数到高位 |
| JAL | J-type | 跳转并链接 |

**至少还需添加（~15 条）**：

| 指令 | 类型 | 用途 | 涉及修改 |
|------|------|------|---------|
| `ADD` | R-type | 寄存器加法 | Controller + ALU (已有ALU_ADD) |
| `SUB` | R-type | 寄存器减法 | Controller + ALU (新加 ALU_SUB) |
| `AND` | R-type | 按位与 | Controller + ALU (新加 ALU_AND) |
| `OR` | R-type | 按位或 | Controller + ALU (新加 ALU_OR 复用ALU_OR? 需区分) |
| `XOR` | R-type | 按位异或 | Controller + ALU (新加 ALU_XOR) |
| `SLT` | R-type | 有符号比较置位 | Controller + ALU (新加 ALU_SLT) |
| `SLTU` | R-type | 无符号比较置位 | Controller + ALU (新加 ALU_SLTU) |
| `SLTI` | I-type | 立即数有符号比较 | Controller + ALU (复用ALU_SLT) |
| `SLTIU` | I-type | 立即数无符号比较 | Controller + ALU (复用ALU_SLTU) |
| `ANDI` | I-type | 立即数与 | Controller + ALU (新加 ALU_AND) |
| `XORI` | I-type | 立即数异或 | Controller + ALU (新加 ALU_XOR) |
| `SRLI` | I-type | 逻辑右移立即数 | Controller + ALU (新加 ALU_SRL) |
| `SRAI` | I-type | 算术右移立即数 | Controller + ALU (新加 ALU_SRA) |
| `SRL` | R-type | 逻辑右移 | Controller + ALU (复用ALU_SRL) |
| `SRA` | R-type | 算术右移 | Controller + ALU (复用ALU_SRA) |
| `SW` | S-type | **存储字到内存** | Controller + MREQ（**关键！写外设必需**） |
| `JALR` | I-type | 寄存器跳转并链接 | Controller + NPC（函数返回必需） |
| `AUIPC` | U-type | PC 相对偏移加载 | Controller + ALU（可选） |

**修改文件清单**：

| 文件 | 修改内容 |
|------|---------|
| `defines.vh` | 新增 `ALU_SUB`, `ALU_AND`, `ALU_XOR`, `ALU_SLT`, `ALU_SLTU`, `ALU_SRL`, `ALU_SRA` 等宏定义 |
| `ALU.v` | 新增对应的 `case` 分支 |
| `Controller.v` | 新增指令译码 wire，新增控制信号 OR-reduction 条件和编码 |
| `SEXT.v` | 新增 S-type 立即数扩展格式（`EXT_S`） |
| `MREQ.v` | 完善 SW 指令的写请求生成 |
| `NPC.v` | 支持 JALR（`NPC_JMP_REG`） |

> **高效做法**：用 `数据通路表、控制信号取值表_miniRV - 模板.xlsx` 的 Sheet 1 和 Sheet 2，先把每条新指令的数据通路和控制信号值填好，再对照表格写代码。

---

### 第二步：实现外设总线

**目标**：让 CPU 能通过 Load/Store 指令读写外设寄存器。

**现状问题**：`miniRV_SoC.v` 目前只例化了 `cpu_top`，外设引脚（sw/led/dig_en/dig_seg/rx/tx）虽然在端口上定义了，但**完全没有连接到 CPU 的数据总线**。CPU 内部的 `daccess_*` 信号只连到了 `Data_RAM`，外设无法访问。

**需要做的事**：

1. **在 `cpu_top.v` 或新建 `peripheral_bus.v` 中**：
   - 对 `cpu2dc_addr` 做地址译码——判断落在 BRAM 范围还是外设范围
   - BRAM 范围内的访问转发给 `Data_RAM`
   - 外设范围内的访问（`0xFFFF_xxxx`）根据地址路由到对应外设寄存器
   - 实现读数据多路选择器（mux），把各外设的读数据汇总返回 CPU

2. **外设寄存器实现**（在 `miniRV_SoC.v` 层）：
   - LED：写寄存器直连 `led[15:0]` 输出引脚
   - Switch：读寄存器直连 `sw[15:0]` 输入引脚
   - 数码管：写寄存器 → 数码管扫描逻辑
   - UART：已有的 UART 控制器（或先做简单回环测试）
   - 按键：读寄存器 = 消抖后的按键值
   - VGA 控制：读写寄存器控制 VGA 启停和模式

**修改文件清单**：

| 文件 | 修改内容 |
|------|---------|
| `miniRV_SoC.v` | 例化外设总线，连接外设引脚 |
| `peripheral_bus.v`（新建） | 地址译码 + 读写路由 + 读数据 mux |
| `cpu_top.v` | 把 `daccess_*` 信号引出到 SoC 层 |
| `defines.vh` | 确认外设地址宏定义正确 |

---

### 第三步：VGA 控制器（纯硬件）

**目标**：生成标准的 VGA 显示时序，从小屏幕输出画面。

#### 3.1 VGA 时序参数（640×480@60Hz）

| 参数 | 行（Horizontal） | 场（Vertical） |
|------|-----------------|----------------|
| 有效显示区域 | 640 像素 | 480 行 |
| 前沿 (Front Porch) | 16 像素 | 10 行 |
| 同步脉冲 (Sync Pulse) | 96 像素 | 2 行 |
| 后沿 (Back Porch) | 48 像素 | 33 行 |
| **总计** | **800 像素** | **525 行** |
| 同步极性 | 负极性 | 负极性 |

- **像素时钟**：25.175 MHz（从 PLL 100MHz 分出，约 25MHz 即可）
- **带宽**：640×480×60fps ≈ 18.4 MHz

#### 3.2 颜色深度选择

EGO1 的 VGA 接口使用 12-bit 颜色（R[3:0] + G[3:0] + B[3:0]），共 4096 色。

| 方案 | 每像素位数 | BRAM 消耗 | 效果 |
|------|-----------|----------|------|
| **12-bit 真彩色** | 12 bit | 640×480×12 = 3,686,400 bit ≈ 450 KB | ❌ 远超 BRAM 容量 |
| **8-bit 调色板** | 8 bit | 640×480×8 = 2,457,600 bit ≈ 300 KB | ❌ 仍太大 |
| **1-bit 单色** | 1 bit | 640×480×1 = 307,200 bit ≈ 37.5 KB | ❌ 偏大 |
| **低分辨率 + 色块** | 2-4 bit | 取决于分块 | ✅ 推荐 |

#### 3.3 推荐方案：Tile-based（瓦片地图）

不用全帧缓冲，而是把屏幕分成 N×M 个色块（Tile），比如：

- **160×120 网格**（每个 Tile = 4×4 像素）
- **每 Tile 4-bit 颜色**：160×120×4 = 76,800 bit ≈ **9.4 KB**（适合 BRAM！）

这样 CPU 只需要写一个 160×120 的"字符"数组，VGA 控制器在硬件层面按 4×4 展开每个 Tile 的颜色。

**进一步优化**——适合游戏的方案：
- **320×240 分辨率，1-bit 位图**：320×240×1 = 76,800 bit ≈ **9.4 KB**
- 每个 bit = 一个像素的黑白
- 或者 320×240 分辨率，使用调色板：每字节=2个像素（4-bit索引），320×240/2 = 38,400 字节 ≈ **37.5 KB**

推荐 **320×240，每字节 2 像素，8 色调色板方案**：
- Frame Buffer 大小：320×240÷2 = 38,400 字节
- 需要 1 块 38KB 的 BRAM（xc7a35t 有约 225KB BRAM，完全够用）
- 颜色支持：8 种颜色可选（足够做贪吃蛇、俄罗斯方块）
- 调色板寄存器：8×12bit = 96 bit，映射到 VGA 控制寄存器区域

#### 3.4 新建的 Verilog 模块

| 模块 | 文件名 | 功能 |
|------|--------|------|
| `vga_timing` | `vga_timing.v` | 行列计数器、hsync/vsync/blanking 信号、有效像素坐标输出 |
| `vga_palette` | `vga_palette.v` | 8 色调色板，软件可写，输出 12-bit RGB |
| `vga_top` | `vga_top.v` | 整合 timing + Frame Buffer 读取 + 调色板查找 + RGB 输出 |
| `frame_buffer` | `frame_buffer.v` | 双口 BRAM（Port A: CPU R/W, Port B: VGA 只读），Xilinx True Dual-Port BRAM IP |

---

### 第四步：按键控制器

**目标**：让 CPU 能读取按键状态。

```
btn → 同步器 (2级FF) → 消抖 (20ms计数器) → 边沿检测 → 按键寄存器 (0xFFFF_5000)
```

| 寄存器位 | 含义 |
|---------|------|
| bit[0] | btn_up 当前状态 |
| bit[1] | btn_down 当前状态 |
| bit[2] | btn_left 当前状态 |
| bit[3] | btn_right 当前状态 |
| bit[4] | btn_center 当前状态 |
| bit[8:5] | 对应按键的上升沿检测（按下一瞬间为 1，读后自动清零） |

边沿检测位可以用来做"按键触发一次"的逻辑，避免游戏中按键被重复读取导致人物移动多格。

**新建模块**：

| 模块 | 文件名 | 功能 |
|------|--------|------|
| `button_ctrl` | `button_ctrl.v` | 同步 + 消抖 + 边沿检测，输出到总线 |

---

### 第五步：编写游戏程序

#### 5.1 推荐游戏：贪吃蛇 🐍

| 特性 | 说明 |
|------|------|
| 画面 | 320×240 网格地图，蛇身和食物用不同颜色 |
| 输入 | 4 个方向按键控制蛇的移动 |
| 逻辑 | 定时移动，吃食物变长，撞墙/撞自己则死亡 |
| 难度 | ⭐ 入门级，逻辑简单清晰 |

**程序结构**：

```asm
# 伪代码结构

main:
    call vga_init          # 初始化 VGA，设置调色板
    call game_init         # 初始化蛇的位置、食物位置

game_loop:
    call button_read       # 读取按键（改变方向）
    call snake_move        # 移动蛇头
    call collision_check   # 检测碰撞（墙/自身/食物）
    call frame_draw        # 重绘整个画面
    call delay             # 延时控制游戏速度
    j game_loop

game_over:
    call led_blink         # LED 闪烁表示结束
    j game_over            # 死循环，按复位重新开始
```

#### 5.2 其他可选游戏

| 游戏 | 难度 | 需要实现的额外逻辑 |
|------|------|-------------------|
| 打砖块 (Breakout) | ⭐⭐ | 弹球物理、挡板移动、砖块碰撞 |
| Flappy Bird | ⭐⭐ | 重力模拟、单按键跳跃、管道生成 |
| 俄罗斯方块 | ⭐⭐⭐ | 7 种方块旋转、消行检测、分数系统 |

#### 5.3 程序存放

- 游戏程序用 RISC-V 汇编编写
- 使用 RISC-V 汇编器（如 `riscv32-unknown-elf-as`）编译为机器码
- 生成的 `.coe` 文件写入 `IROM` 的初始化文件
- 或者通过 UART 下载到 DRAM 中执行（需要 bootloader）

---

## 四、关键设计决策

### 4.1 帧缓冲：全帧缓冲 vs Tile 展开

| 方案 | BRAM 消耗 | 复杂度 | 画面质量 | 推荐 |
|------|----------|--------|---------|------|
| 全帧 320×240×8bit | ~38 KB | 硬件简单 | 好 | ✅ **推荐** |
| Tile 160×120×4bit | ~9.4 KB | 硬件需展开 | 块状感强 | 资源紧张时可选 |
| 全帧 640×480×1bit | ~37.5 KB | 硬件简单 | 黑白 | 单色游戏可选 |

> xc7a35t 有约 225 KB BRAM，现有 IROM(8KB) + DRAM(8KB) + FrameBuffer(~38KB) ≈ 54KB，完全够用。

### 4.2 像素数据格式（320×240, 每字节 2 像素）

```
每个字节 = [pixel_even[3:0], pixel_odd[3:0]]  或反过来
同一地址存两个水平相邻像素，每个像素 4-bit 索引到 16 色调色板
```

### 4.3 CPU 和 VGA 对 Frame Buffer 的并发访问

- **读优先**：VGA 读取优先级高于 CPU 写入
- 或者利用 **BRAM 双口**特性：Port A 给 CPU，Port B 给 VGA，互不干扰
- 如果 CPU 在 VGA 扫描期间写 Frame Buffer，可能产生短暂撕裂——对简单游戏影响不大

---

## 五、实施顺序建议

```
第 1 周：补全 RV32I 指令（ADD/SUB/SW/JALR 等 ~15 条）
        ├── 填 Excel 模板（数据通路表 + 控制信号取值表）
        ├── 改 defines.vh / ALU.v / Controller.v / SEXT.v / MREQ.v / NPC.v
        └── 写测试程序验证每条新指令

第 2 周：实现外设总线
        ├── 新建 peripheral_bus.v（地址译码 + 读写路由）
        ├── 改 cpu_top.v / miniRV_SoC.v（连线）
        └── 写程序点亮 LED、读取开关——验证 Load/Store 外设

第 3 周：VGA 控制器 + 帧缓冲
        ├── vga_timing.v → 仿真验证时序波形
        ├── vga_palette.v + frame_buffer.v
        ├── vga_top.v 整合
        ├── miniRV_SoC.v 连线
        └── 写程序画彩色条纹——验证 VGA 输出

第 4 周：按键控制器 + 游戏程序
        ├── button_ctrl.v
        ├── 写贪吃蛇游戏（RISC-V 汇编）
        ├── 写入 IROM，上板运行
        └── 调试、优化、庆祝 🎉
```

---

## 六、总结

| 项目 | 说明 |
|------|------|
| **可行性** | ✅ 完全可行，xc7a35t 资源充足 |
| **最关键步骤** | 补全 RV32I 指令 → 外设总线 → VGA 控制器 |
| **推荐游戏** | 贪吃蛇（逻辑简单，适合验证整个硬件链路） |
| **屏幕方案** | 320×240 分辨率，8 色调色板，~38KB 帧缓冲 |
| **输入方案** | EGO1 板载 5 向按键，消抖后映射到外设地址 |
| **预估工时** | 约 4 周（业余时间） |
