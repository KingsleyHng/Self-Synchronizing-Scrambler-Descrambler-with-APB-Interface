# Scrambler/Descrambler SoC 模块 —— Yosys 综合报告

> 生成日期:2026-07-15
> Yosys 版本:`Yosys 0.67+24 (git sha1 0e82bbefe)`,运行环境:Linux x86_64(WSL2,oss-cad-suite)
> 数据来源:`syn/synth_generic.ys`、`syn/reports/synth_generic.log`、`syn/reports/stat_hier.txt`、`syn/reports/stat_flat.txt`、`syn/reports/ltp.txt`、`syn/reports/equiv_status.txt`(**所有数字均取自实际综合日志,非估算**)

---

## 1. Design Overview(设计概述)

### 1.1 功能描述

本设计是一个**乘法型自同步扰码器(Multiplicative Self-Synchronizing Scrambler)** 收发通道,并逐层封装为可挂载到 AMBA APB 总线的 SoC 外设:

- **`scrambler_core`**:扰码器发送端核心。内部维护一个 `N=58` bit 的 LFSR 状态寄存器,每拍并行处理 `W=8` bit 数据。输出 `dout[i] = din[i] ⊕ state[TAP_A-1-i] ⊕ state[TAP_B-1-i]`(默认 `TAP_A=39`、`TAP_B=58`),随后把本拍的扰码输出反馈移入状态寄存器(自反馈/乘法型结构)。含种子非零校验(防全零死锁)、`allzero_err` 粘滞告警(W1C)、`parity_err` 奇偶校验告警、`force_rst` 测试复位。
- **`descrambler_core`**:解扰端,与 `scrambler_core` 电路结构几乎镜像,唯一本质区别是**纯前馈**——移入状态寄存器的是"收到的输入" `din_core`,而不是自己的输出,因此没有反馈环路。额外含 `lock_counter`/`locked` 逻辑,累计收到 `ceil(N/W)=8` 个有效拍后判定同步锁定,锁定前 `dout`/`dout_valid` 被抑制为 0。
- **`scrambler_top`**:软件可配置封装层。把上面两个核用同一套参数例化,通过 4 选 1 模式多路器(`bypass`/`scramble`/`descramble`/`loopback`)选择数据通路,并实现一个 10×32-bit 的 CSR 寄存器堆(模式/使能/种子/测试周期/状态回读),以及一个 32-bit `test_counter` 用于周期性产生 `force_rst` 测试波形。
- **`scrambler_apb`(顶层)**:AMBA APB(3 态:`IDLE`/`SETUP`/`ACCESS`)从设备适配器,把 `psel/penable/pwrite/paddr/pwdata` 翻译为 `scrambler_top` 的 `csr_wr/csr_addr/csr_wdata` 接口,`pready` 恒为 1(零等待周期从设备),`pslverr` 恒为 0(不产生总线错误)。

### 1.2 顶层模块(Top Module)

```
scrambler_apb
```

综合脚本以 `hierarchy -check -top scrambler_apb` 显式指定,日志第 32~44 行确认:`Top module: \scrambler_apb`。

### 1.3 例化的子模块(Instantiated Submodules)

| 层级 | 模块名 | 例化名 | 例化次数 |
|---|---|---|---|
| 1 | `scrambler_top` | `scrambler_top_inst` | 1 |
| 2 | `scrambler_core` | `scrambler`(位于 `scrambler_top` 内) | 1 |
| 2 | `descrambler_core` | `descrambler`(位于 `scrambler_top` 内) | 1 |

共 **4 个 RTL 模块**(1 个顶层 + 3 个子模块),日志 "design hierarchy" 小节(`stat_hier.txt` 第 98~106 行)与之完全对应:`scrambler_apb` 下仅有 1 个直接子模块 `scrambler_top`,`scrambler_top` 下有 2 个子模块 `scrambler_core`/`descrambler_core`。

### 1.4 设计层级结构(Design Hierarchy)

```
scrambler_apb                          (AMBA APB 从设备适配层 + 3 态 FSM)
└── scrambler_top_inst : scrambler_top (软件可配置封装层:模式 mux + CSR + 测试计数器)
    ├── scrambler    : scrambler_core     (扰码发送端:自反馈 LFSR)
    └── descrambler  : descrambler_core   (解扰接收端:前馈 LFSR + 锁定检测)
```

四个模块共用同一套参数(`N=58, W=8, TAP_A=39, TAP_B=58, BIT_ORDER=0`),由顶层 `scrambler_apb` 逐级透传例化,未出现参数不一致的情况(日志中每一层 `Parameter \N = 58 ...` 均保持一致)。

---

## 2. Yosys Synthesis Script(综合脚本)

以下为项目中实际使用的 `syn/synth_generic.ys`(通用/工艺无关综合,尚无 ASIC Liberty 库,故未做真实工艺映射):

```tcl
# ============================================================
#  Generic synthesis - scrambler_apb
#  Run from the syn/ directory:
#     yosys -l reports/synth.log synth_generic.ys
# ============================================================

# ---- 1. Read RTL -------------------------------------------------------
read_verilog -sv ../RTL/scrambler_core.sv
read_verilog -sv ../RTL/descrambler_core.sv
read_verilog -sv ../RTL/scrambler_top.sv
read_verilog -sv ../RTL/scrambler_apb.sv

# ---- 2. Elaborate ------------------------------------------------------
hierarchy -check -top scrambler_apb

# ---- 3. Synthesise (hierarchy preserved) -------------------------------
synth -nofsm -top scrambler_apb
check -assert

# Per-module cost breakdown while module boundaries still exist
tee -o reports/stat_hier.txt stat

# ---- 4. Flatten and re-optimise for the true gate count ----------------
flatten
opt -full
techmap
opt -full
abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX
opt_clean

tee -o reports/stat_flat.txt stat

# Longest combinational path = logic depth, the proxy for critical path
tee -o reports/ltp.txt ltp -noff

# ---- 5. Write outputs --------------------------------------------------
write_verilog -noattr netlist/scrambler_apb_netlist.v
write_json netlist/scrambler_apb.json
```

该脚本由 `syn/run_synth.sh` 通过 WSL 调用(工具链是 linux-x64 版 `oss-cad-suite`,无法在原生 Windows PowerShell 直接执行)。产出分别落在 `syn/reports/`(统计与日志)和 `syn/netlist/`(网表)。

---

## 3. Synthesis Flow Explanation(综合流程详解)

Yosys 的 `synth` 是一个宏命令,内部依次调用了下面这些底层 pass。逐条解释如下,并标注它在本项目脚本里对应的具体位置:

| 命令                             | 作用                                                                                                                                                                                                                                      | 在本项目中的角色                                                                                                                                                                                                                                                                                                                                |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `read_verilog -sv`             | 把 Verilog/SystemVerilog 源码解析为 AST,再生成 RTLIL(Yosys 内部中间表示)。`-sv` 打开 SystemVerilog 语法子集(如 `always_comb/always_ff`、`logic`、`typedef enum`)。                                                                                                | 依次读入 4 个 `.sv` 文件,建立各模块的独立 RTLIL 表示(日志第 11~30 行)。                                                                                                                                                                                                                                                                                       |
| `hierarchy -check -top <mod>`  | 分析模块间的实例化关系,确定设计层级、展开带参数例化的模块(生成 `$paramod$...` 副本),并检查是否存在未定义模块/端口不匹配等问题;`-check` 会在发现连接性问题时报错终止。                                                                                                                                      | 以 `scrambler_apb` 为根,递归展开 `scrambler_top → {scrambler_core, descrambler_core}`,为每种参数组合各生成一份特化模块(日志第 32~112 行)。                                                                                                                                                                                                                          |
| `proc`                         | 把 `always`/`always_comb`/`always_ff` 等过程块转换为纯网表结构:拆分为 `proc_clean`(清空的分支)→`proc_rmdead`(死分支)→`proc_prune`(冗余赋值)→`proc_init`→`proc_arst`(识别异步复位)→`proc_rom`→`proc_mux`(判定树转多路器)→`proc_dlatch`(残留锁存检测)→`proc_dff`(时序逻辑转触发器)→`proc_memwr`。 | `synth` 内部自动调用,是本设计体量最大的一步(日志第 131~491 行)。**关键结果**:`proc_dlatch` 报告 "No latch inferred" 覆盖了全部组合信号 → **确认设计中不存在非预期锁存器**(RTL 质量良好的直接证据)。`proc_arst` 正确识别出所有 `rst_n` 均为异步复位。                                                                                                                                                               |
| `opt`                          | 一轮"快速"优化:常数折叠(`opt_expr`)、死代码/未用信号清除(`opt_clean`)、`opt_dff`(触发器合并/化简)、`opt_share`(逻辑共享)等的组合,循环执行直至收敛。`opt -full` 会额外做更激进、更耗时的一轮(如跨模块的 `opt_merge`)。                                                                                     | `synth` 流程中反复出现(日志 6.3/6.4/6.6 等节);脚本第 25/27 行的两次显式 `opt -full` 分别在 `flatten` 前后做深度优化——第一次清理跨模块边界残留冗余,第二次清理 `techmap` 展开原语后产生的新冗余。                                                                                                                                                                                                      |
| `fsm`                          | 自动探测状态机(`cur_state`/`next_state` 这类模式),抽取为 `$fsm` cell,可选择重新编码(默认转 one-hot)以提升面积/速度。                                                                                                                                                    | **本项目显式加了 `-nofsm` 关闭该步骤**。原因:`scrambler_apb` 内的 3 态 APB FSM(`cur_state`,2-bit 二进制编码)若被 `fsm` 重编码为 one-hot 会多用 1 个触发器,且会导致后续形式等价检查中 66 个内部节点因编码变化而无法逐一对应(端口级仍可证明,但内部命名对不上)。保持二进制编码后面积更小、等价检查 100% 通过。                                                                                                                                   |
| `memory`                       | 探测数组式访问模式,尝试推断为存储器原语(`$mem`),否则展开为寄存器堆 + 多路器。                                                                                                                                                                                           | `scrambler_top.sv:209` 的 `csr_reg[0:9]`(10×32-bit)被前端标记为疑似 memory,但因其读写地址全部是**编译期常量**(`case` 分支里的字面量),`memory` 阶段判定其不具备真正的存储器访问模式,判决结果是 **"Replacing memory `csr_reg` with list of registers"**(日志第 24、78 行,共出现 2 次——一次在主模块解析,一次在参数化副本解析),即完全展开为独立触发器 + 组合读多路器,**不推断 BRAM**。最终统计里 memories 计数为 0(`stat_hier.txt` 第 115 行 "- memories")。 |
| `techmap`                      | 把 Yosys 的高层算术/逻辑 cell(`$add`、`$eq`、`$mux` 等宏 cell)映射到一组更底层的通用逻辑原语(`$_AND_`、`$_XOR_`、`$_DFF_*` 等),为送入 `abc` 做门级优化做准备。                                                                                                                    | 脚本第 26 行,在 `flatten` 之后执行,把 `test_counter+1`、`test_counter==test_period`、`lock_counter+1` 等算术/比较宏统统展开为门级原语——**因此最终网表中不存在专用加法器/比较器 cell,全部退化为 AND/OR/XOR/NAND/NOR/XNOR 门链**。                                                                                                                                                             |
| `abc`                          | 调用外部逻辑综合工具 ABC,对 techmap 后的门级网表做进一步的逻辑优化与工艺映射;`-g <cell list>` 表示映射到一组指定的通用门(而非真实 Liberty 库单元)。                                                                                                                                         | 脚本第 28 行:`abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX`。日志第 1823~1858 行显示 ABC 内部执行了 `strash → &fraig -x → dc2 → dretime → &dch -f → &nf` 等优化序列,最终产出 1425 个门、327 输入、264 输出的网表,并统计出各类型门数量(394 AND / 365 NAND / 159 OR / 110 NOR / 179 XNOR / 72 XOR / 58 MUX / 36 NOT)。**这一步是唯一的"技术映射"**——由于目前没有 ASIC Liberty 库,只能映射到这组抽象通用门,尚不是真实工艺下的门级面积/时序。     |
| `opt_clean` / `clean`          | 删除网表中不再被使用的 cell 与 wire(悬空信号、`techmap`/`abc` 展开后残留的中间信号等)。                                                                                                                                                                              | 脚本第 29 行,紧跟在 `abc` 之后;日志显示 `abc` 之后又清除了 1597 个未用 wire(主要是 `abc` 内部命名的中间节点在 `flatten` 后不再需要保留独立 wire 名)。综合前期(`synth` 阶段内部)也执行过一次,清除了 34 个未用 cell + 193 个未用 wire(**重构前此处曾是 64 cell / 660 wire**,多出的部分正是已消除的"幽灵"循环变量寄存器,详见第 6 节)。                                                                                                                              |
| `stat`                         | 打印当前设计的模块数、wire/cell 统计,是本报告第 4 节数据的直接来源。                                                                                                                                                                                               | 脚本中用 `tee -o <file> stat` 调用了两次:`hierarchy` 展开后立即调用(`stat_hier.txt`,含逐模块的分层统计),`flatten+opt+techmap+abc+opt_clean` 之后再调用一次(`stat_flat.txt`,真实门级总数)。                                                                                                                                                                                     |
| `write_verilog` / `write_json` | 把当前 RTLIL 网表导出为门级 Verilog 网表 / JSON 格式,供后续仿真、形式验证(`equiv_check.ys`)或第三方工具消费。                                                                                                                                                            | 脚本第 37~38 行,产出 `syn/netlist/scrambler_apb_netlist.v` 与 `scrambler_apb.json`。`-noattr` 去掉了 Yosys 内部调试属性,使网表更精简。                                                                                                                                                                                                                          |

此外脚本还用到了两个未在需求列表中、但对本设计很关键的命令:
- **`check -assert`**:执行 `check` pass(检测未驱动的输出、组合环、宽度不匹配等常见问题)并在发现任何问题时让脚本失败退出。日志第 517~522 行:"Found and reported 0 problems" —— **零问题**。
- **`flatten`**:把层级化的设计打平为单一模块,消除模块边界带来的接口开销,从而得到与实际投片/落地一致的真实门数(否则 `stat_hier.txt` 的分模块统计会因端口复制而偏高)。
- **`ltp -noff`**:Longest Topological Path,统计组合逻辑最长拓扑路径深度,作为关键路径(时序瓶颈)的代理指标(本设计未提供 Liberty 库,无法做真正的 STA)。

---

## 4. Synthesis Statistics(综合统计数据)

以下数字全部取自 `syn/reports/stat_flat.txt`(`flatten + opt -full + techmap + opt -full + abc + opt_clean` 之后的**最终门级统计**,即将投入 `write_verilog` 网表的真实内容)。

### 4.1 总体规模

| 指标 | 数值 |
|---|---|
| 模块数(综合前,RTL 层面) | 4(`scrambler_apb`、`scrambler_top`、`scrambler_core`、`descrambler_core`) |
| 模块数(`flatten` 后,最终网表) | 1(全部打平进 `scrambler_apb`) |
| Wires(线网数) | 1382 |
| Wire bits(线网总位宽) | 2451 |
| Public wires(具名/保留的线网) | 84 |
| Public wire bits | 1153 |
| Ports(顶层端口数) | 15 |
| Port bits(顶层端口总位宽) | 98 |
| **Cells 总数** | **1650** |
| Memories | 0(`csr_reg` 已被判定为纯组合可展开,未推断为 BRAM) |
| Processes(综合完成后残留的过程块) | 0(全部被 `proc` 转换为门级/触发器) |
| FSMs($fsm cell) | 0(`-nofsm` 显式关闭了 FSM 抽取,APB 状态机以普通寄存器+组合逻辑形式保留) |

### 4.2 Cells by Type(按类型统计,`stat_flat.txt`)

| Cell 类型 | 数量 | 说明 |
|---|---:|---|
| `$_AND_` | 394 | 2 输入与门 |
| `$_NAND_` | 365 | 2 输入与非门 |
| `$_OR_` | 159 | 2 输入或门 |
| `$_NOR_` | 110 | 2 输入或非门 |
| `$_XNOR_` | 179 | 2 输入同或门 |
| `$_XOR_` | 72 | 2 输入异或门 |
| `$_NOT_` | 36 | 反相器 |
| `$_MUX_` | 58 | 2 选 1 多路器 |
| `$_DFFE_PN1P_` | 174 | 带使能、正边沿时钟、异步复位到 **1** 的触发器 |
| `$_DFF_PN0_` | 52 | 无独立使能、正边沿时钟、异步复位到 **0** 的触发器(每拍都更新) |
| `$_DFFE_PN0P_` | 48 | 带使能、正边沿时钟、异步复位到 **0** 的触发器 |
| `$scopeinfo` | 3 | 调试用作用域标记,非真实逻辑 cell |
| **合计** | **1650** | |

> 组合逻辑门(AND/NAND/OR/NOR/XNOR/XOR/NOT/MUX)合计 **1373** 个;时序单元(三类 DFF)合计 **274** 个;另有 3 个 `$scopeinfo` 属调试元数据。

### 4.3 逐模块统计(打平前,`stat_hier.txt`,用于理解各层贡献)

| 模块 | 本地 Cells(不含子模块) | 主要构成 |
|---|---:|---|
| `scrambler_apb`(顶层壳) | 42 | APB FSM 组合/时序逻辑(`$_AND_`/`$_NAND_`/`$_DFFE_PN0P_` 等) |
| `scrambler_top` | 917 | CSR 译码/回读多路器、模式 mux、`test_counter` |
| `scrambler_core` | 467 | 含 59 个 `$_MUX_`(唯一含 MUX 的模块;flatten 后再优化为 58) |
| `descrambler_core` | 273 | 无 `$_MUX_`(见第 6 节分析) |

（注:分模块合计 42+917+467+273=1699,与最终打平后 1650 的差异来自跨模块接口 wire/端口在 `flatten` 后被 `opt`/`opt_clean` 折叠消除,属正常现象。）

### 4.4 关键路径深度(Longest Topological Path)

`syn/reports/ltp.txt`:

```
Longest topological path in scrambler_apb (length=32):
    0: scrambler_top_inst.test_counter [1]
    ...(31 级 ABC 内部合成节点)...
   32: ...flatten\scrambler_top_inst.$0\test_counter[31:0][30]
   ff: scrambler_top_inst.test_counter [30]
```

最长拓扑路径为 **32 级**,起止均落在 `scrambler_top` 的 32-bit `test_counter` 上,对应 RTL 中 `test_counter + 1'b1` 的自增运算与 `test_counter == test_period` 的比较运算(`RTL/scrambler_top.sv:265-269`)。这是本设计目前唯一的深度算术逻辑,详见第 6 节分析。

### 4.5 形式验证结果(交叉印证)

`syn/reports/equiv_status.txt`:

```
Found 1011 $equiv cells in equiv:
  Of those cells 1011 are proven and 0 are unproven.
  Equivalence successfully proven!
```

即 `syn/equiv_check.ys` 对本次综合产出的网表与 RTL 做了形式等价检查,**1011/1011 全部证明通过**,可信度上为本报告的门级统计数据提供了独立交叉验证(网表功能确实与 RTL 一致,而不是综合脚本产生了功能性偏差)。

---

## 5. Resource Utilization Analysis(资源利用率分析)

### 5.1 触发器(Flip-Flops)

总计 **274 个 FF bit**,与综合日志 `proc_dff`(第 401~451 行)阶段列出的"源信号"逐条核对如下(汇总自各模块 `always_ff` 块):

| 模块 | 寄存器(信号名) | 位宽 | 复位值 |
|---|---|---:|---|
| `scrambler_apb` | `cur_state`(APB FSM 状态) | 2 | `IDLE`(2'b00) |
| `scrambler_top` | `test_counter` | 32 | 0 |
| `scrambler_top` | `mode` | 2 | `MODE_BYPASS` |
| `scrambler_top` | `ctrl_en` | 1 | 0 |
| `scrambler_top` | `seed_reg` | 58 | 全 1 |
| `scrambler_top` | `test_period` | 31 | 0 |
| `scrambler_top` | `test_en` | 1 | 0 |
| `scrambler_top` | `prev_mode` | 2 | `MODE_BYPASS` |
| `scrambler_core` | `state`(LFSR) | 58 | 全 1 |
| `scrambler_core` | `state_parity` | 1 | — |
| `scrambler_core` | `parity_err` | 1 | 0 |
| `scrambler_core` | `allzero_err` | 1 | 0 |
| `scrambler_core` | `dout_valid` | 1 | 0 |
| `scrambler_core` | `dout_tmp` | 8 | 0 |
| `descrambler_core` | `locked` | 1 | 0 |
| `descrambler_core` | `lock_counter` | 5 | 0 |
| `descrambler_core` | `state`(LFSR) | 58 | 全 1 |
| `descrambler_core` | `state_parity` | 1 | — |
| `descrambler_core` | `parity_err` | 1 | 0 |
| `descrambler_core` | `dout_valid` | 1 | 0 |
| `descrambler_core` | `dout_tmp` | 8 | 0 |
| **合计** | | **274** | 与 `stat_flat.txt` 完全吻合 |

寄存器绝大部分集中在两条 58-bit LFSR 状态链(共 116 bit,占比 42%),其次是 `test_counter`(32 bit,12%)与 `seed_reg`(58 bit,21%)。整体寄存器密度不高,属控制/移位寄存器占主导的小型外设逻辑,不存在大型深流水寄存器堆。

### 5.2 多路器(Multiplexers)

最终统计共 **58 个 `$_MUX_`**,且**全部来自 `scrambler_core`**(`stat_hier.txt` 显示 `descrambler_core` 本地 0 个 MUX)。这与两个核内部 `state` 更新的优先级链直接相关:

- `scrambler_core.state` 更新优先级为 `reset > force_rst > seed_load > shift > hold`,其中 `reset` 与 `force_rst` 的目标值**相同**(均为 `{N{1'b1}}`),`hold` 由 `$_DFFE_*` 的使能端隐式实现,因此**只剩 `seed_load` 值与 `shift` 值这两个互斥的动态数据源需要显式选择**——这正是 58 个 `$_MUX_`(每个状态位 1 个)存在的原因。
- `descrambler_core.state` 没有 `seed_load` 输入,优先级链退化为 `reset > force_rst(=同一常量) > shift > hold`,已经可以完全靠 FF 的复位端 + 使能端表达,**不需要任何显式 MUX**。

### 5.3 加法器 / 比较器(Adders / Comparators)

由于 `abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX` 只映射到通用门集合,**网表级不存在独立的 `$add`/`$eq` 等算术 cell**,均已展开为门链。但从 RTL 可精确定位两处算术逻辑来源:

| 位置 | 运算 | 位宽 | 说明 |
|---|---|---:|---|
| `scrambler_top.sv:269` | `test_counter + 1'b1` | 32-bit | 周期性测试计数器自增 |
| `scrambler_top.sv:265` | `test_counter == test_period` | 31-bit | 判定测试周期到达,触发 `force_rst` |
| `descrambler_core.sv:179` | `lock_counter + 1'b1` | 5-bit | 同步锁定计数器自增 |
| `descrambler_core.sv:176` | `lock_counter == LOCK_CYCLES-1` | 5-bit | 判定同步锁定 |

**第 4.4 节报告的 32 级最长路径正是来自 `test_counter` 这一路 32-bit 增量器/比较器**,与 RTL 定位完全一致——`ltp` 的自动化分析结果与人工代码审查相互印证。`lock_counter` 只有 5 bit,深度远小于 `test_counter`,不构成瓶颈。

### 5.4 存储器(Memories)

**0 个**。`scrambler_top.sv` 中的 `csr_reg[0:9]`(10×32-bit)本质上是一个用编译期常量地址读写的寄存器堆,Yosys 在 `memory` 阶段判定其不具备真正存储器语义,已完全展开为寄存器 + 译码/回读多路器(见第 3 节 `memory` 行)。**这一判断是合理的**:10 个字的容量本就不适合推断为 BRAM(嵌入式 RAM 通常要几十至几百字以上才划算),寄存器实现在面积和访问延迟上都更优。

### 5.5 LUT 估算(Estimated Combinational Logic / LUT Estimation)

目前网表仅映射到通用 2 输入门(AND/OR/XOR/NAND/NOR/XNOR/NOT/MUX),**并非真实工艺库**,因此无法给出精确 LUT/门数,只能做粗略折算:若目标是典型 4 输入 FPGA LUT(如 Xilinx 7-series/UltraScale 的 LUT4~LUT6),按经验每 1.5~2.5 个 2 输入门可折算为 1 个 LUT 计算,组合逻辑门数 1373 个,**估算 LUT 占用量级约 550~915 个 LUT**(不含触发器,不含真实布线/工艺优化后的差异,仅供数量级参考,实际数字须用目标厂商工具(Vivado/Quartus)重新综合得出)。

### 5.6 寄存器数量与组合逻辑复杂度总结

| 维度 | 数值 |
|---|---:|
| 触发器(时序)总位数 | 274 |
| 组合逻辑门总数 | 1373 |
| 组合:时序 比例 | 约 5.0 : 1 |
| 关键路径深度(LTP) | 32 级 |

组合:时序比例偏高([扰码运算](#11-功能描述)本身只有 2 级 XOR,真正拉高组合门数的是 CSR 地址译码/回读多路器与 `test_counter` 比较逻辑),整体仍属于小型控制类外设的正常范围。

---

## 6. Critical Design Observations(关键设计观察)

1. **深组合路径 / 时序瓶颈定位明确**:32 级最长路径完全来自 `test_counter`(32-bit 自增 + 与 `test_period` 的比较),这是一条纯粹的纹波进位(ripple-carry)链——因为当前 `abc -g` 只映射到基本门,没有专用快速进位链原语,所以 32-bit 加法器天然表现为线性深度的门链。**注意**:这在真实 FPGA(专用 carry chain)或 ASIC 工艺库(专用加法器单元)下深度会显著下降,当前 32 这个数字**更多是通用门映射的产物,而非电路本征限制**,不宜直接等同于真实关键路径周期数。真正决定 SoC 通道数据率的扰码/解扰组合路径(`din ⊕ state[a] ⊕ state[b]`)只有 2 级 XOR,远非瓶颈。

2. **大型多路器**:未见异常。最大的 MUX 结构是 `scrambler_core` 的 58 个逐位 2 选 1 `$_MUX_`(状态位:`seed_reg` vs. shift 值),规模合理,且已如第 5.2 节分析,是设计中真实存在的、不可再简化的数据选择点(种子加载与正常移位互斥)。CSR 读多路器(`scrambler_top.sv:222` 起的 `case(csr_addr)`)在 `techmap`/`abc` 阶段被拆散为门级结构,未表现为独立大 MUX。

3. **高扇出信号**:`rst_n` 作为异步复位驱动全部 274 个触发器(`proc_arst` 阶段确认全部 11 处 `always_ff` 块都使用同一个异步、低有效复位),是设计中最高扇出信号,属正常且预期的复位树结构,综合阶段未见异常复制或扇出瓶颈提示。`en`(`ext_en && ctrl_en`)驱动两个核的使能路径及 `dout_valid` 门控,扇出中等。

4. **FSM 实现**:`scrambler_apb` 内的 3 态 APB 从设备 FSM(`IDLE→SETUP→ACCESS`)因 `-nofsm` 保持**二进制编码**(2-bit,而非默认的 one-hot 3-bit)。这是一次经过验证的、有意识的取舍(详见项目记忆:裸 `synth` 会把该 FSM 重编码为 one-hot,导致形式等价检查出现 66 个内部节点无法证明,且 one-hot 反而多用 1 个触发器)。**对 ASIC 目标而言二进制编码通常更省面积**;但若未来把目标切换到 LUT 型 FPGA,one-hot 在译码延迟上可能更优,该权衡需要按最终工艺重新评估(见第 7 节建议)。

5. **存储器推断**:CSR 寄存器堆(10×32-bit,常量地址访问)被正确判定为**非**存储器语义,完整展开为寄存器,未误推断/未误跳过任何 BRAM,行为符合预期。

6. **算术优化 / "幽灵"寄存器现象(已于 2026-07-15 重构消除)**:`scrambler_core.sv`/`descrambler_core.sv` **原先**在 `always_ff` 块内使用普通 `for (int j...)` 循环描述移位逻辑。早期综合中 Yosys 的 `proc_dff` 阶段会**把循环变量 `j`/`k` 本身也当作真实寄存器创建**(每个都是完整的 32-bit `$dff`,4 处循环共 128 bit),虽然随后被 `opt_clean` 清除、不影响最终网表,但这是一个**工具依赖性风险点**——换用优化能力较弱的综合工具未必能同样干净地清除。**现已按第 7.6 节建议完成重构**:把移位逻辑改写为"组合的 next-state(位拼接 `{state[N-W-1:0], 翻转后的新数据}`)+ 时序块只做 `state <= state_next`"。重跑综合验证结果:
   - `proc_dff` 阶段**不再产生任何** `$fordecl_block$...j`/`k` 寄存器(日志中 21 条 `Creating register` 全部是真实设计寄存器);
   - `synth` 内部 opt_clean 的清理量从 **64 cell / 660 wire 降至 34 cell / 193 wire**(佐证幽灵寄存器不再产生);
   - FF 总数仍为 **274**,形式等价检查 **1011/1011 全证明通过**。

   **该风险点已从源头消除**,不再依赖工具的事后优化来兜底。

---

## 7. Optimization Recommendations(优化建议)

1. **资源共享(Resource Sharing)**:当前设计规模小,未发现明显的可共享冗余算术单元(`test_counter`/`lock_counter` 的加法器功能不同、无法合并)。暂无需引入资源共享。

2. **流水线插入(Pipeline Insertion)**:若后续要冲击更高工作频率,`test_counter`(32-bit)与其比较逻辑是当前(通用门映射下)最深的一条路径。可选方案:
   - 改自增+全量比较为**递减计数器**(从 `test_period` 倒数到 0),把 `== test_period` 的宽比较替换为更快的 "是否为全零" 判断树(部分工艺/工具下深度更浅);
   - 若目标频率确实吃紧,可对 `test_counter` 做 1 级流水线切割(例如高 16 位/低 16 位分段比较后再合并),但需注意 `force_rst` 的产生时机会因此延后一拍,需要评估对测试波形周期精度的影响是否可接受。
   - 更根本的做法是**换上真实工艺库(sky130/Nangate45 或目标 FPGA 器件)重新综合**——专用进位链/加法器原语通常能把这条路径的深度大幅压低,当前 32 级很大程度是通用门映射的伪影,不建议在拿到真实 STA 数据前投入过多精力做人工流水线优化。

3. **寄存器平衡 / 重定时(Register Balancing / Retiming)**:本设计是控制面为主的小型外设,未见深层组合逻辑夹在寄存器之间需要重定时的场景,暂不建议引入。

4. **FSM 编码改进(FSM Encoding)**:当前 `-nofsm` 锁定二进制编码,已用形式等价检查验证正确、面积更优。**建议**:该选择应作为项目综合规范的固定项(已记录在 `syn/equiv_check.ys` 需与 `synth_generic.ys` 逐字同步的注意事项中),避免今后误改成裸 `synth` 导致编码漂移和验证覆盖率下降。若未来新增基于 FPGA 的实现目标,应单独跑一次 `synth -top scrambler_apb`(去掉 `-nofsm`)对比时序,而不是想当然复用 ASIC 结论。

5. **存储器推断改进(Memory Inference)**:CSR 寄存器堆容量小(10 字),继续保持寄存器实现即可,**不建议**人为强制推断为 BRAM——徒增地址译码开销和访问延迟,对这种小容量场景没有收益。

6. **逻辑化简(Logic Simplification)—— ✅ 已实施(2026-07-15)**:已把 `scrambler_core.sv`/`descrambler_core.sv` 中 `always_ff` 内部的移位 `for` 循环重构为"组合 next-state(用 `generate/genvar` 的 `assign` 做位翻转 + 位拼接)+ 时序块只做 `state <= state_next`"的结构(详见第 6 节)。重构后功能等价(equiv **1011/1011**)、FF 数不变(**274**)、幽灵寄存器从源头消失。这降低了对特定综合工具优化能力的隐性依赖,提升了跨工具可移植性。**副作用记录**:最终 cell 数从 1627 微增至 1650(+23 门,主要是 AND/NAND/OR/NOT),这是 `abc` 对不同输入网表结构做门级映射时的正常波动,不改变逻辑功能与 FF 数;组合:时序比例仍在小型外设的合理范围。

7. **常数传播机会(Constant Propagation)**:`scrambler_apb.sv` 中 `pslverr` 恒接 0、`pready` 恒接 1(`assign pslverr = 0; assign pready = 1'b1;`),这两处已经是最简形式的常量,`opt_expr`/`opt_clean` 已充分传播,未见遗漏的常量折叠机会。

---

## 8. Final Assessment(总体评估)

| 维度 | 评估 |
|---|---|
| **设计质量(Design Quality)** | 良好。层级清晰(壳层与算法核心分离),复位策略统一且经过深思(异步复位到全 1 而非全 0,从源头规避 LFSR 全零死锁),`proc_dlatch` 确认全设计无意外锁存器,参数合法性有 `initial + $fatal` 门禁。 |
| **可综合性(Synthesizability)** | 优秀。整套 `synth -nofsm` 流程一次性无警告(除 1 处良性的 memory→register 提示)、无错误跑通,`check -assert` 报告 0 个问题,并已用形式等价检查(1011/1011 证明)交叉验证网表与 RTL 完全一致。 |
| **资源效率(Resource Efficiency)** | 较高。274 FF / 1373 组合门的规模对应其功能(2 条 58-bit LFSR + CSR + 测试计数器)是合理的,未发现明显冗余(MUX/FF 数量均可用 RTL 逻辑直接解释)。 |
| **可维护性(Maintainability)** | 良好。壳层(`scrambler_top`/`scrambler_apb`)与算法核心(`scrambler_core`/`descrambler_core`)职责分离清晰;此前 `always_ff` 内 `for` 循环的跨工具可移植性隐患已重构消除(第 6 节),移位逻辑现以"组合 next-state + 位拼接"表达,可读性与跨工具一致性均获提升。 |
| **FPGA/ASIC 落地就绪度** | **中等偏前期**。功能与结构层面已具备落地条件(无锁存器、无组合环、复位策略清晰、等价性已验证),但**当前只做了工艺无关(generic)综合,尚未接入任何真实 Liberty(sky130/Nangate45 等)或 FPGA 器件库**,因此本报告中的门数、LUT 估算、32 级关键路径深度均只能作为"设计复杂度"的参考量级,不能作为真实 PPA(功耗/性能/面积)或时序收敛(STA)结论使用。**下一步建议**:接入目标工艺库(ASIC)或用 Vivado/Quartus 等厂商工具跑一次真实综合+STA,才能给出可用于流片/上板决策的时序与面积数字。 |

**结论**:该 Scrambler/Descrambler APB 外设的 RTL 设计在综合阶段表现干净、可验证、无异常告警,是一个适合作为教学案例或 IP 复用起点的中小型数字设计;若要推进到实际流片或量产 FPGA 部署,唯一的实质性缺口是接入真实工艺/器件库做正式的时序与面积收敛。
