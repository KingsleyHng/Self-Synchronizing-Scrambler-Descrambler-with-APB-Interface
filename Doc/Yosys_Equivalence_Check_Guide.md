# Yosys 形式等价性检查(Formal Equivalence Check)完全指南

> 面向完全没接触过 Yosys 脚本的人。读完你应该能自己从零写出一个 `.ys` 等价性检查脚本,
> 并且看懂它报出来的每一行结果。
>
> 本文所有命令都在 Yosys 0.67 上实测跑通(2026-07-14),不是纸上谈兵。
> 示例设计:`scrambler_apb`(58-bit LFSR 加扰器 + APB 寄存器接口)。

---

## 目录

1. [先搞懂:等价性检查到底在干什么](#1-先搞懂等价性检查到底在干什么)
2. [`.ys` 文件是什么](#2-ys-文件是什么)
3. [核心概念:gold 与 gate](#3-核心概念gold-与-gate)
4. [完整脚本(可直接抄)](#4-完整脚本可直接抄)
5. [逐行拆解:每一行在干嘛、参数怎么填](#5-逐行拆解每一行在干嘛参数怎么填)
6. [怎么读结果](#6-怎么读结果)
7. [真实踩坑记录(三个坑,全是实战遇到的)](#7-真实踩坑记录三个坑全是实战遇到的)
8. [排错速查表](#8-排错速查表)
9. [换到新项目要改哪几行](#9-换到新项目要改哪几行)
10. [附录:命令参数全表](#10-附录命令参数全表)

---

## 1. 先搞懂:等价性检查到底在干什么

### 1.1 它解决什么问题

你写了 RTL,跑 Yosys 综合,得到一堆门电路(网表)。问题来了:

> **综合工具会不会把我的设计改错?**

综合器要做几百个优化步骤 —— 常量传播、逻辑化简、状态机重编码、门级映射……
任何一步有 bug,或者你的 RTL 里有某种它误解了的写法,出来的电路行为就变了。
而这种错误**仿真常常抓不到**,因为你的 testbench 只跑了有限的激励。

等价性检查就是回答这个问题的。

### 1.2 它和仿真的根本区别

| | 仿真(Simulation) | 形式等价性检查(FEC) |
|---|---|---|
| 做法 | 喂进去一堆激励,看输出对不对 | 用 SAT 求解器**数学证明** |
| 覆盖 | 只覆盖你想到的 case | **穷尽所有可能的输入组合** |
| 结论 | "我测了 10000 个 case 没发现问题" | "对任何输入,两者输出必然相同" |
| 失败时 | 你看到波形不对 | 它给你一个**反例**(能让两者不同的具体输入) |

**关键**:等价性检查不需要你写 testbench,不需要激励。它把两个电路做成一个数学命题
("存在某组输入使得两者输出不同吗?"),扔给 SAT 求解器去解。解不出来 = 不存在 = 等价。

### 1.3 一句话总结

> 仿真证明"存在正确";形式验证证明"不存在错误"。

---

## 2. `.ys` 文件是什么

### 2.1 它没有格式

这是新手最容易想复杂的地方。`.ys` 文件**不是**什么特殊 DSL,它就是:

> **一个文本文件,一行一条 Yosys 命令,从上往下依次执行。**

跟你在 `yosys>` 提示符下手动一条条敲进去,**完全等价**。`.ys` 只是帮你把它们存下来重复用。

```tcl
# 井号开头是注释
read_verilog design.v      # 一行一条命令
hierarchy -top top_module  # 参数用空格分隔,选项用 - 开头
stat
```

规则就这些:
- `#` 开头 = 注释,整行忽略
- 空行 = 忽略
- 其余每行 = 一条命令,格式是 `命令名 [选项] [参数]`
- **从上往下顺序执行,有状态**(后面的命令看得到前面命令的结果)

### 2.2 三种等效的运行方式

```bash
# 方式 A:跑脚本文件(适合固定流程)
yosys equiv_check.ys

# 方式 B:命令行直接给(适合临时试一下,命令间用分号)
yosys -p "read_verilog a.v; hierarchy -top top; stat"

# 方式 C:交互式(适合探索,不知道下一步干嘛的时候)
yosys
yosys> read_verilog a.v
yosys> help equiv_make      ← 随时查任何命令怎么用
```

**学习技巧**:任何时候不确定一个命令怎么用,就 `yosys -p "help 命令名"`。
本文所有参数说明都是这么查出来的,你也能自己查。

### 2.3 有用的运行选项

| 选项 | 作用 |
|---|---|
| `-l <文件>` | 把完整日志写到文件(**强烈建议一直加**,出问题全靠它) |
| `-q` | 终端安静,只显示 warning/error(日志文件仍然完整) |
| `-p "<命令>"` | 直接在命令行执行命令 |

推荐组合:`yosys -q -l reports/equiv.log equiv_check.ys`

---

## 3. 核心概念:gold 与 gate

整个等价性检查围绕两个词,记住它们:

| 名字 | 中文 | 是什么 | 怎么来的 |
|---|---|---|---|
| **gold** | 金标准 / 参考 | 你的 **RTL**,只做基本 elaborate | `read_verilog` + `prep` |
| **gate** | 待验电路 | **综合后的门级网表** | `read_verilog` + `synth` |

我们要证明:**gate 的行为 == gold 的行为**。

### 3.1 Yosys 怎么做这个证明

三步:

1. **`equiv_make`** —— 把 gold 和 gate 合并成一个新模块 `equiv`。
   它会**按信号名把两边的对应信号配对**,每配一对就插入一个 `$equiv` 单元。
   你可以把 `$equiv` 理解成一个便利贴:"我断言这两个点永远相等,但还没证明"。

2. **`equiv_simple` / `equiv_induct`** —— 拿 SAT 求解器逐个去证那些 `$equiv`,
   证明一个就把便利贴标成 "proven"。

3. **`equiv_status -assert`** —— 清点便利贴。还有没证明的就**报错退出**。

### 3.2 一个必须理解的坑:名字匹配

> **`equiv_make` 靠信号名配对。**

这是它能工作的前提,也是它最脆弱的地方。如果综合把某个信号优化没了、改名了、
或者把状态机重新编码了,名字对不上,就配不了对,也就证不出来。
第 7 节有一个真实的例子。

### 3.3 另一个坑:一个进程里塞两份设计

`read_verilog` 读进来的模块都叫 `scrambler_apb`。读两次会打架。
解决办法是用 `design` 命令管理"设计快照":

| 命令 | 作用 |
|---|---|
| `design -stash <名字>` | 把当前设计存成快照,**并清空当前设计** |
| `design -save <名字>` | 存快照,但**不清空**(区别就在这) |
| `design -load <名字>` | 清空当前设计,加载快照 |
| `design -copy-from <快照> -as <新名> <模块>` | 从快照里捞一个模块出来,顺便改名 |
| `design -reset` | 清空当前设计 |

所以套路是:
```
读 RTL → prep → 存成快照 gold(当前清空)
读 RTL → synth → 存成快照 gate(当前清空)
从 gold 快照捞出来,改名叫 gold
从 gate 快照捞出来,改名叫 gate
现在当前设计里同时有 gold 和 gate 两个模块了 ✓
```

---

## 4. 完整脚本(可直接抄)

这是**实测跑通、100% 证明成功**的版本。放在 `syn/equiv_check.ys`:

```tcl
# ============================================================
#  形式等价性检查:RTL(gold) vs 综合后网表(gate)
#  跑法:  yosys -q -l reports/equiv.log equiv_check.ys
#  成功: "Equivalence successfully proven!" 且退出码 0
# ============================================================

# ---- 步骤 1:构建 gold(参考模型 = 你的 RTL)----------------
read_verilog -sv ../RTL/scrambler_core.sv
read_verilog -sv ../RTL/descrambler_core.sv
read_verilog -sv ../RTL/scrambler_top.sv
read_verilog -sv ../RTL/scrambler_apb.sv

hierarchy -check -top scrambler_apb
prep -flatten -top scrambler_apb

design -stash gold

# ---- 步骤 2:构建 gate(待验电路 = 综合后网表)---------------
read_verilog -sv ../RTL/scrambler_core.sv
read_verilog -sv ../RTL/descrambler_core.sv
read_verilog -sv ../RTL/scrambler_top.sv
read_verilog -sv ../RTL/scrambler_apb.sv

hierarchy -check -top scrambler_apb

# ⚠️ 这一段必须和你的综合脚本(synth_generic.ys)逐字一致!
#    否则"验证的网表"就不是"交付的网表"。见第 7.5 节。
synth -nofsm -top scrambler_apb      # -nofsm 很关键,见第 7 节
flatten
opt -full
techmap
opt -full
abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX
opt_clean

design -stash gate

# ---- 步骤 3:把两份设计捞回来,并排放在一起 -------------------
design -copy-from gold -as gold scrambler_apb
design -copy-from gate -as gate scrambler_apb

# ---- 步骤 4:处理异步复位 ------------------------------------
async2sync

# ---- 步骤 5:造 equiv 模块,然后证明 --------------------------
# -blacklist 排除 ABC don't-care 优化导致对不上的内部点,见第 7.6 节
equiv_make -blacklist equiv_blacklist.txt gold gate equiv
hierarchy -top equiv

equiv_simple -seq 5
equiv_induct -seq 5

# ---- 步骤 6:记录结果 ----------------------------------------
log ================ EQUIVALENCE RESULT ================
tee -o reports/equiv_status.txt equiv_status -assert
```

配套的 `syn/equiv_blacklist.txt`(**必须用打平后的完整层次路径**):
```
scrambler_top_inst.non_zero_ok
```

**实测结果**:
```
Found 961 $equiv cells in equiv:
  Of those cells 961 are proven and 0 are unproven.
  Equivalence successfully proven!
```
退出码 0。

---

## 5. 逐行拆解:每一行在干嘛、参数怎么填

### `read_verilog -sv <文件>`

**干嘛的**:把 Verilog/SystemVerilog 源文件读进来,变成 Yosys 内部表示(叫 RTLIL)。

| 参数 | 说明 | 怎么填 |
|---|---|---|
| `-sv` | 启用 SystemVerilog 语法 | 文件是 `.sv` 就必须加。`.v` 可以不加 |
| `-I <目录>` | 添加 \`include 搜索路径 | 有 include 文件时才需要 |
| `-D <宏>` | 定义宏,等于 \`define | 如 `-D SYNTHESIS` |
| `<文件>` | 源文件,可以一次给多个 | 路径相对于**你运行 yosys 的目录** |

**注意**:路径是相对于**当前工作目录**,不是相对于 `.ys` 文件的位置。
所以脚本里写 `../RTL/xxx.sv`,就必须先 `cd` 到 `syn/` 再跑。
(这就是为什么我们有个 `run_synth.sh` wrapper 帮你自动 `cd`。)

**为什么这里要读两次**:因为步骤 1 结束时 `design -stash` 把当前设计清空了。
步骤 2 要重新读一份干净的 RTL 来综合。

---

### `hierarchy -check -top <模块>`

**干嘛的**:确定顶层模块是谁,把参数化模块实例化出来(例如把 `N=58` 代进去),
并且检查有没有引用了但根本不存在的模块。

| 参数 | 说明 | 怎么填 |
|---|---|---|
| `-top <模块>` | 指定顶层模块名 | **必填**。写你要验的那个模块名 |
| `-check` | 检查有没有缺失的模块定义 | **建议一直加**。少一个文件能立刻发现,不然错误会拖到很后面才炸 |
| `-auto-top` | 自动猜顶层 | 不推荐,显式指定更安全 |

**为什么必须有它**:不指定顶层,Yosys 不知道从哪儿开始展开层次,
也不知道哪些模块是死代码可以扔掉。

---

### `prep -flatten -top <模块>`  ← gold 用这个

**干嘛的**:做**保守的、轻量的** RTL 准备。官方帮助原文说得很清楚:

> "This command runs a conservative RTL synthesis.
> **A typical application for this is the preparation stage of a verification flow.**"

翻译:它专门就是给形式验证准备参考模型用的。

它做的事:`proc`(把 always 块变成逻辑)、`opt`(基本优化)、`memory` 等。
它**不做**的事:技术映射、门级优化、状态机重编码 —— 也就是**不碰电路的结构**。

| 参数 | 说明 | 怎么填 |
|---|---|---|
| `-top <模块>` | 顶层 | 跟 `hierarchy` 写一样的 |
| `-flatten` | 打平层次(把子模块内容拉到顶层) | **建议加**。gold 和 gate 都打平,信号名才好对上 |
| `-nomem` | 不跑 memory 相关 pass | 一般不用 |
| `-ifx` | 用 Verilog 仿真语义处理 if/case 的 undef | 关心 X 传播时才用 |

> ⚠️ **为什么 gold 不能用 `synth`**:`synth` 会做各种优化和映射,
> 那就变成"用综合结果验证综合结果"了,毫无意义。
> gold 必须尽量贴近你写的原始 RTL。

---

### `synth -nofsm -top <模块>`  ← gate 用这个

**干嘛的**:完整综合。这是"待验电路"的来源。

| 参数 | 说明 | 怎么填 |
|---|---|---|
| `-top <模块>` | 顶层 | 同上 |
| `-nofsm` | **不做 FSM 优化/重编码** | 见第 7 节。**做等价性检查时强烈建议加** |
| `-noabc` | 不跑 ABC 门级优化 | 一般不加(你想验的就是含 ABC 的完整流程) |
| `-flatten` | 综合前打平 | 可选 |
| `-run <a>:<b>` | 只跑其中一段 | 调试用 |

---

### `flatten`

**干嘛的**:把所有子模块的内容"拆开"拉进顶层,消灭层次结构。

**为什么要打平**:`equiv_make` 按名字匹配信号。如果 gold 是层次化的、
gate 被综合器打平了,名字空间对不上,一个都配不上。
**两边都打平,起跑线才一致。**

---

### `design -stash <名字>`

**干嘛的**:把当前设计存成一个命名快照,**然后清空当前设计**。

| 参数 | 说明 |
|---|---|
| `-stash <名字>` | 存快照 + 清空当前设计 |
| `-save <名字>` | 存快照,**不清空**(区别在这) |

这里用 `-stash` 而不是 `-save`,就是因为我们要腾空场地去读第二份 RTL。
名字(`gold`/`gate`)随便取,只要后面 `-copy-from` 对得上。

---

### `design -copy-from <快照> -as <新名> <模块>`

**干嘛的**:从快照里把模块捞回当前设计,顺便重命名。

```tcl
design -copy-from gold -as gold scrambler_apb
#                  ↑        ↑        ↑
#            快照名字   新模块名   快照里的原模块名
```

读作:"从名叫 `gold` 的快照里,把 `scrambler_apb` 这个模块拷过来,改名叫 `gold`。"

**为什么要改名**:两个快照里的模块都叫 `scrambler_apb`,不改名就撞车了。
改成 `gold` 和 `gate` 之后,当前设计里就有了两个名字不同、内容各异的模块,
正好喂给下一步。

---

### `async2sync`

**干嘛的**:把**异步复位**的触发器,转换成等效的同步电路。

**为什么需要**:你的设计写的是
```systemverilog
always_ff @(posedge clk or negedge rst_n)   // ← 异步复位
```
SAT 求解器的世界里只有"时钟周期"这个概念,它处理不了"复位可以在任意时刻到来"。
`async2sync` 把异步复位改写成一个 SAT 能理解的同步等效形式。

> **判断要不要加**:你的 always 块里有 `or negedge rst_n` / `or posedge rst` 之类的
> → **必须加**。只有 `@(posedge clk)` → 可以不加。
>
> 你的设计从 `scrambler_core` 到 `scrambler_apb` 全是异步复位,所以这行不能少。

**相关命令**:`clk2fflogic` —— 如果你的设计有**多个时钟域**,用这个(更慢但更通用)。
单时钟域用 `async2sync` 就够。

---

### `equiv_make gold gate equiv`

**干嘛的**:核心命令。拿 gold 和 gate 两个模块,生成第三个模块 `equiv`,
里面塞满了 `$equiv` 单元(那些"待证明的便利贴")。

```tcl
equiv_make gold gate equiv
#           ↑     ↑     ↑
#        参考   待验  输出模块名(随便取)
```

**参数顺序不能错**:gold 在前,gate 在后。

| 选项 | 说明 | 什么时候用 |
|---|---|---|
| `-inames` | 也匹配 `$...` 开头的自动生成名 | 匹配点太少时可以试 |
| `-blacklist <文件>` | 文件里列的信号名**不参与匹配** | 有些信号明知对不上时(见第 7 节) |
| `-encfile <文件>` | 用 FSM 编码描述文件来匹配状态机 | 状态机被重编码时的正统解法 |
| `-make_assert` | 用 `$assert` 而不是 `$equiv` | 想接 SVA 流程时 |

---

### `hierarchy -top equiv`

**干嘛的**:把顶层切换到刚生成的 `equiv` 模块。

**为什么**:后面的 `equiv_simple`/`equiv_induct` 是在**当前顶层**上工作的。
不切过去,它们找不到那些 `$equiv` 单元。

---

### `equiv_simple -seq <N>`

**干嘛的**:用**直接 SAT** 逐个证明 `$equiv`。

这是"笨办法但可靠":对每个 `$equiv`,把它上游的逻辑锥展开成一个 SAT 问题,
问"有没有可能让这两个点不相等?"。解不出来 = 证明了。

| 参数 | 说明 | 怎么填 |
|---|---|---|
| `-seq <N>` | 最多考虑 N 个时钟周期 | **默认 1**。时序逻辑深的设计要调大,先试 1,不够就 5、10 |
| `-short` | 逻辑锥在共享节点处截断 | SAT 太慢时试试,但可能证不出来 |
| `-undef` | 建模 undef(X)状态 | 关心 X 传播时用,会更慢 |
| `-v` | 详细输出 | 调试用 |

---

### `equiv_induct -seq <N>`

**干嘛的**:用**时序归纳法**证明剩下那些 `equiv_simple` 啃不动的。

官方帮助原文:
> "This command is very effective in proving complex sequential circuits."

**它和 `equiv_simple` 的关系**:互补。
- `equiv_simple` 先跑,把简单的组合等价点快速证掉(实测证了 293 个)
- `equiv_induct` 再跑,用归纳法处理深时序的(实测又证了 712 个)

**两个都要跑,顺序不能反。** 先 simple 后 induct。

| 参数 | 说明 | 怎么填 |
|---|---|---|
| `-seq <N>` | 归纳的时间步数 | **默认 4**。一般 5 够用 |
| `-undef` | 建模 undef 状态 | 同上 |

> ⚠️ **一个诚实的说明**:`equiv_induct` 用的是**较弱的等价定义**。官方原文:
>
> > "This command proves that the two circuits **will not diverge after they produce
> > equal outputs for at least \<N\> cycles**."
>
> 白话:它证明的是"如果两个电路已经同步了 N 个周期,那它们永远不会再分岔"。
> 它**没有**证明"从复位开始它们就一定同步"。
>
> 实践中这够用了 —— 因为你的仿真已经验证了复位后的行为。
> 形式归纳 + 仿真,两者合起来才是完整的信心。这不是 Yosys 偷懒,
> 商业工具的时序等价检查也是同样的数学基础。

---

### `equiv_status -assert`

**干嘛的**:清点战果,汇报有多少证明了、多少没证明。

| 参数 | 说明 |
|---|---|
| `-assert` | **有任何一个没证明就报错退出**(退出码非 0) |

> ⚠️ **`-assert` 一定要加!**
> 不加的话,即使一堆没证出来,Yosys 也会**开开心心退出码 0**,
> 你的脚本会假装成功。CI 里这是灾难。

---

### `tee -o <文件> <命令>` —— 把结果单独存一份

**干嘛的**:把后面那条命令**照常执行**,同时把它的输出**额外抄一份**到文件。
名字就是 Unix 那个 `tee`。

```tcl
tee -o reports/equiv_status.txt equiv_status -assert
```

| 选项 | 作用 |
|---|---|
| `-o <文件>` | 写文件,**覆盖** |
| `-a <文件>` | 写文件,**追加** |
| `-q` | 只写文件,不往终端/主日志打 |

**和 `yosys -l` 的区别**(这是重点):

- **`-l <文件>`** 记录**整个 run 的所有输出** —— 几万行,什么都有,但找结论要翻半天
- **`tee`** 只抓**那一条命令**的输出,单独存一个干净的小文件

所以 `tee -o reports/equiv_status.txt equiv_status -assert` 给你一份
**只包含证明结论**的报告:证了多少、没证多少、哪些信号没证、成功还是失败。
CI 里 grep 它、或者贴给别人看,都直接用这个文件。

> ✅ **实测确认**:即使 `-assert` 失败并中止,`tee` 的报告文件**照样写得出来**,
> 连最后那行 `ERROR: Found N unproven $equiv cells` 都完整记进去。
> 所以不管成功失败,报告文件里永远有结论 —— 而失败恰恰是你最需要它的时候。

---

### `log <字符串>` —— 往日志里插自定义文字

```tcl
log ================ EQUIVALENCE RESULT ================
```

纯粹是给日志分段用的,方便你在几万行里一眼找到关键位置。

| 选项 | 作用 |
|---|---|
| `-stdout` | 同时打到 stdout(配合 `-q` 运行时有用) |
| `-stderr` | 同时打到 stderr |

---

## 6. 怎么读结果

### 6.1 成功长这样

```
  Of those cells 1005 are proven and 0 are unproven.
  Equivalence successfully proven!
```

退出码 0。这就是你要的。

### 6.2 失败长这样

```
Found a total of 66 unproven $equiv cells.
ERROR: Found 66 unproven $equiv cells in 'equiv_status -assert'.
```

### 6.3 ⚠️ 最重要的一件事:"unproven" ≠ "设计错了"

这是新手最容易恐慌的地方。**分清两种结果**:

| 报告 | 含义 | 严重性 |
|---|---|---|
| **unproven**(未证明) | SAT 没能证明它们相等,但**也没找到反例** | ⚠️ 需要调查,但**通常是方法学问题**(见第 7 节) |
| **proven inequivalent**(证明不等价) | SAT **找到了具体反例** —— 存在输入让两者输出不同 | 🔴 **真的有 bug**,综合器或 RTL 出问题了 |

绝大多数时候你遇到的是 unproven,而绝大多数 unproven 的原因是:
**综合器做了某种结构变换,导致名字对不上了**。

### 6.4 排查 unproven 的方法

日志里会列出每一个未证明的信号:
```
Unproven $equiv ...: \csr_wdata_gold [17] \csr_wdata_gate [17]
```

把它们的名字提取出来,统计一下,**看它们有没有共同点**:

```bash
grep "Unproven" reports/equiv.log \
  | sed 's/.*find_same_wires[^ ]* //' \
  | sed 's/\[[0-9]*\]//g' \
  | sort | uniq -c
```

如果它们全部集中在某个功能块(比如都是某个状态机的扇出),
那基本就是结构变换导致的,不是 bug。

**还有一个关键检查**:看看**输出端口**有没有在未证明列表里。

```bash
grep "Unproven" reports/equiv.log | grep -E "dout|prdata|pready"
```

> **如果所有输出端口都证明了,内部节点没证明 —— 你的设计在功能上是等价的。**
> 因为等价性的定义就是"对外可观测行为相同",内部长啥样根本无所谓。
> 那些内部 `$equiv` 只是帮助 SAT 求解的**辅助匹配点**,不是验证目标。

---

## 7. 真实踩坑记录(三个坑,全是实战遇到的)

本项目在做等价性检查时,**连续踩了三个坑**。全部完整记录在这里 —— 因为它们极具代表性,
下一个项目大概率还会遇到。

| # | 坑 | 症状 | 解法 |
|---|---|---|---|
| 1 | **FSM 重编码**(7.1–7.4) | 66 个 unproven,集中在状态机扇出 | `synth -nofsm` |
| 2 | **验证的 ≠ 交付的**(7.5) | 检查过了但根本没验到 `abc` | gate 流程照抄综合脚本 |
| 3 | **ABC don't-care 优化**(7.6) | 1 个孤立 unproven,输出全好 | blacklist(用层次路径) |

---

### 7.1 症状(坑 1:FSM 重编码)

第一版脚本(gate 用 `synth`,没加 `-nofsm`)跑出来:

```
Of those cells 935 are proven and 66 are unproven.
ERROR: Found 66 unproven $equiv cells
```

### 7.2 调查

66 个未证明的信号是哪些?统计一下:

```
     32 \csr_wdata_gold  \csr_wdata_gate
      1 \csr_wr_gold     \csr_wr_gate
     32 \scrambler_top_inst.csr_wdata_gold  ...
      1 \scrambler_top_inst.csr_wr_gold     ...
```

不是随机的 —— **全部集中在 `csr_wr` 和 `csr_wdata`**。

看 RTL(`scrambler_apb.sv`):
```systemverilog
assign csr_wr    = (cur_state == SETUP) && penable && pwrite;
assign csr_wdata = (cur_state == SETUP && penable) ? pwdata : 'b0;
```

两个信号都是 **`cur_state`(状态机)的组合函数**。

再翻综合日志 `synth.log`:
```
6.7.1. Executing FSM_DETECT pass
  Found FSM state register scrambler_apb.cur_state.
6.7.6. Executing FSM_RECODE pass (re-assigning FSM state encoding).
  Recoding FSM `cur_state' using `auto' encoding:
  mapping auto encoding to `one-hot` for this FSM.     ← 真相
```

### 7.3 根因

**`synth` 里的 FSM pass 把 `cur_state` 从 2-bit 二进制重编码成了 one-hot。**

- gold 里:`cur_state` 是 2 位,`IDLE=00, SETUP=01, ACCESS=10`
- gate 里:`cur_state` 变成 3 位 one-hot,`IDLE=001, SETUP=010, ACCESS=100`

状态寄存器的**位宽和编码都变了**,`equiv_make` 按名字/位宽根本配不上对。
而 `csr_wr`/`csr_wdata` 依赖 `cur_state`,于是整个扇出锥都证不出来。

这**不是 bug** —— one-hot 编码是完全合法的优化,功能一模一样。
只是 Yosys 的名字匹配机制跟不上这种结构变换。

### 7.4 三种解法(推荐第一种)

**解法 1:`synth -nofsm`(推荐,实测 100% 证明成功)**

```tcl
synth -nofsm -top scrambler_apb
```

告诉综合器"这次别动状态机",状态编码保持原样,名字自然对得上。

- ✅ 干净,全部证明,退出码 0
- ⚠️ 代价:你验证的网表**不是**生产用的那份(少了 FSM 优化)
- 💡 但这是**可接受且常见**的工程折中:FSM 重编码是局部的、良性的变换,
  而其余 99% 的综合优化(逻辑化简、门级映射、常量传播 —— 真正容易出 bug 的地方)
  **都还在被验证**。

**解法 2:`equiv_make -blacklist <文件>`**

准备一个文件列出对不上的信号名,让它们不参与匹配。

- ⚠️ 用在 FSM 这个场景**很脆弱**:实测只把 66 降到 41。因为不只 `csr_wr`/`csr_wdata`,
  它们的**整个下游扇出**(`seed_load`、`err_clr`、`parity_clr`……)也一样证不出来,
  你得把整个锥都列进去。
- 💡 但 blacklist 用在**孤立的单个信号**上很好用 —— 见第 7.6 节。

**解法 3:`equiv_make -encfile <文件>`**

正统解法:把 FSM 的新旧编码对应关系导出来,让 `equiv_make` 据此匹配状态。
(细节查 `help fsm_recode`。)最严谨,但设置最麻烦。

### 7.5 更深的一个坑:"验证的" 必须等于 "交付的"

搞定 FSM 之后,还有一个**更容易被忽略、也更危险**的问题。

对比一下两个脚本的 gate 构建流程:

| `synth_generic.ys`(交付用) | `equiv_check.ys`(验证用,第一版) |
|---|---|
| `synth -nofsm` | `synth -nofsm` |
| `flatten` | `flatten` |
| `opt -full` | ❌ 没有 |
| `techmap` | ❌ 没有 |
| `opt -full` | ❌ 没有 |
| `abc -g AND,NAND,...` | ❌ 没有 |
| `opt_clean` | ❌ 没有 |

> 🔴 **你交付的网表,多走了 5 个 pass —— 而这 5 个 pass 一个都没被验证。**
>
> 尤其是 **`abc`**,它是整个流程里最复杂、最容易出 bug 的一步(几万行的逻辑综合引擎)。
> 结果它恰恰在验证覆盖之外。这个等价性检查等于白做了一大半。

**铁律**:

> ### `equiv_check.ys` 里 gate 的构建流程,必须和你的综合脚本**逐字一致**。
>
> 你的综合脚本改了一行,等价检查脚本就得跟着改一行。
> 建议在两个文件里都写上注释互相提醒。

### 7.6 第三个坑:ABC 的 don't-care 优化

把完整流程(含 `abc`)搬进 gate 之后,又冒出 **1 个**未证明的点:

```
Unproven $equiv: \scrambler_top_inst.non_zero_ok_gold  \scrambler_top_inst.non_zero_ok_gate
```

看 RTL:
```systemverilog
assign non_zero_ok = (seed_reg != '0);   // 58 位非零检测,seed_load 的守门条件
```

**根因:ABC 做了 don't-care 优化。**

ABC 在优化时会分析:某个中间信号的取值,在**下游是不是真的能被观察到**。
如果发现 `non_zero_ok` 在某些输入组合下,无论取 0 还是 1 都不影响任何输出
(这些就叫 "don't-care" 条件),它就有权把这个信号化简成一个
**逻辑上不完全相同、但外部行为完全一致**的更便宜的函数。

于是:
- gate 的 `non_zero_ok` ≠ gold 的 `non_zero_ok`(**真的不相等**,不是匹配问题)
- 但**所有输出端口(`dout`/`dout_valid`/`prdata`/`pready`/`pslverr`)全部证明通过**

这是形式验证里的经典现象,**不是 bug,是优化器在正常工作**。

**解法:blacklist 掉这一个信号**

`syn/equiv_blacklist.txt`:
```
scrambler_top_inst.non_zero_ok
```
```tcl
equiv_make -blacklist equiv_blacklist.txt gold gate equiv
```
→ 961 proven / 0 unproven,`Equivalence successfully proven!`

> ⚠️ **必须用打平后的完整层次路径!**
> 实测只写 `non_zero_ok` **完全无效**(仍然 1 个未证明)。
> 因为 `flatten` 之后,信号的全名带着实例前缀 `scrambler_top_inst.`。
> **直接从日志的 `Unproven` 那一行里把名字抄下来**(去掉 `_gold`/`_gate` 后缀和位下标)。

**blacklist 的代价,要诚实面对**:
它的意思是"这个点不参与匹配",也就是你**主动放弃**验证这一个内部节点。

之所以安全,是因为**所有输出端口仍被完整证明** —— 而等价性的定义本来就是
"对外可观测行为相同",内部节点长什么样根本无所谓。
那些内部 `$equiv` 只是帮 SAT 爬升的梯子,不是验证目标本身。

**但你必须先确认输出端口都证明了,才能理直气壮地 blacklist。**
顺序不能反:先看输出,再决定要不要 blacklist,而不是看到 unproven 就无脑 blacklist。

### 7.7 通用教训

> **当你看到 unproven 时,按这个顺序走:**
>
> 1. **先看输出端口有没有在未证明列表里** —— 有的话是大事,可能真有 bug
> 2. **统计未证明信号的名字,找共同点** —— 它们几乎总是集中在某个被"结构性改造"过的地方
> 3. **去综合日志里找那个变换是什么** —— FSM 重编码?寄存器复制?retiming?don't-care 优化?
> 4. **然后要么关掉它**(如 `-nofsm`)**,要么告诉 Yosys 怎么匹配**(如 `-encfile`)**,
>    要么在确认输出无恙后 blacklist 它**

---

## 8. 排错速查表

| 报错 / 现象 | 原因 | 怎么修 |
|---|---|---|
| `ERROR: Module ... not found` | 少读了一个源文件 | 检查 `read_verilog` 是不是漏了文件;`hierarchy -check` 会帮你早点发现 |
| `Found N unproven $equiv cells` | 见第 6.3 节 | 先统计未证明信号的共同点。**先确认输出端口是否已证明** |
| 很多 unproven,集中在某状态机的扇出 | FSM 重编码 | gate 侧加 `synth -nofsm`(第 7.3 节) |
| **少数几个孤立的** unproven,输出端口全证明了 | ABC 的 don't-care 优化 | blacklist 掉那几个信号(第 7.6 节) |
| blacklist 写了却**完全没效果** | 名字没写全 | **必须用打平后的完整层次路径**,如 `scrambler_top_inst.non_zero_ok`。从日志的 `Unproven` 行里抄 |
| 等价检查过了,但心里不踏实 | 可能验的不是交付的网表 | 对照第 7.5 节:gate 流程和综合脚本**逐字一致**了吗? |
| unproven 数量随 `-seq` 增大而减少 | SAT 展开深度不够 | 把 `-seq` 调大(5 → 10 → 20),但会变慢 |
| 几乎**全部** unproven,匹配点极少 | gold/gate 名字空间对不上 | 确认**两边都做了 `flatten`** |
| 复位相关的点证不出来 | 异步复位没处理 | 加 `async2sync`(多时钟域用 `clk2fflogic`) |
| **`proven inequivalent`** | 🔴 **真的不等价** | 这是真 bug。看日志里的反例,拿去仿真复现 |
| 脚本明明有 unproven 却退出码 0 | 忘了 `-assert` | `equiv_status -assert` |
| `Can't open ../RTL/xxx.sv` | 工作目录不对 | `.ys` 里的相对路径是相对**运行目录**的。先 `cd syn/` 再跑 |
| SAT 跑到天荒地老 | 设计太大 | 分模块验(顶层换成子模块),或试 `equiv_simple -short` |

---

## 9. 换到新项目要改哪几行

**5 个地方要改**,其余原样照抄。

```tcl
# ① 源文件列表 —— 改成你的文件
read_verilog -sv ../RTL/你的_模块1.sv
read_verilog -sv ../RTL/你的_模块2.sv

# ② 顶层模块名 —— 4 处都要改成同一个名字
hierarchy -check -top 你的顶层
prep -flatten -top 你的顶层
# (第二遍)
hierarchy -check -top 你的顶层
synth -nofsm -top 你的顶层

# ③ ⚠️ gate 的构建流程 —— 必须复制粘贴你自己的综合脚本!(第 7.5 节)
synth -nofsm -top 你的顶层
flatten
opt -full
techmap
abc -g ...          # ← 你综合脚本里怎么写,这里就怎么写
opt_clean

# ④ design -copy-from 里的模块名 —— 也是你的顶层
design -copy-from gold -as gold 你的顶层
design -copy-from gate -as gate 你的顶层

# ⑤ 有异步复位就留着,没有就删掉
async2sync
```

`equiv_make` / `equiv_simple` / `equiv_induct` / `equiv_status -assert`
这几行**永远不用改**(blacklist 文件的内容要按你的实际情况填,一开始可以是空的)。

### 新项目的推荐调试顺序

1. 先只写到 `design -stash gold`,跑一遍,确认 RTL 读得进去
2. 加上 gate 部分,跑一遍,确认综合能过
3. 加上 `equiv_make` + `equiv_status`(**先不加 `-assert`**),看看有多少匹配点
4. 加上 `equiv_simple -seq 5` 和 `equiv_induct -seq 5`,看证明率
5. 最后才加 `-assert`,让它变成"不通过就报错"

**不要一开始就写完整脚本然后瞪着 200 行报错发呆。** 一步一步加,每步都跑。

---

## 10. 附录:命令参数全表

> 所有内容来自 `yosys -p "help <命令>"` 的官方输出。
> **你随时可以自己查,不用记。**

### `design`
| 用法 | 作用 |
|---|---|
| `design -reset` | 清空当前设计 |
| `design -save <名>` | 存快照(不清空) |
| `design -stash <名>` | 存快照 **并清空** |
| `design -load <名>` | 清空并加载快照 |
| `design -copy-from <名> [-as <新名>] <选择>` | 从快照拷模块进来 |
| `design -copy-to <名> [-as <新名>] [选择]` | 把当前模块拷进快照 |
| `design -delete <名>` | 删快照 |
| `design -push` / `-pop` | 快照栈操作 |

### `equiv_make [选项] <gold> <gate> <输出模块>`
| 选项 | 作用 |
|---|---|
| `-inames` | 也匹配 `$...` 自动生成名 |
| `-blacklist <文件>` | 文件里的名字不参与匹配 |
| `-encfile <文件>` | 用 FSM 编码文件匹配状态机 |
| `-make_assert` | 用 `$assert` 代替 `$equiv` |

### `equiv_simple [选项]`
| 选项 | 默认 | 作用 |
|---|---|---|
| `-seq <N>` | **1** | 最大时间步数 |
| `-short` | — | 更短的逻辑锥(更快,但可能证不出来) |
| `-undef` | — | 建模 undef 状态 |
| `-nogroup` | — | 不按输出线分组 |
| `-v` | — | 详细输出 |

### `equiv_induct [选项]`
| 选项 | 默认 | 作用 |
|---|---|---|
| `-seq <N>` | **4** | 归纳时间步数 |
| `-undef` | — | 建模 undef 状态 |
| `-ignore-unknown-cells` | — | 忽略无法建模的单元 |

### `equiv_status [选项]`
| 选项 | 作用 |
|---|---|
| `-assert` | **有未证明就报错退出**(务必加) |

### 其他有用的
| 命令 | 作用 |
|---|---|
| `equiv_purge` | 删掉已证明的部分,只留未证明的(方便 debug 时看波形) |
| `async2sync` | 异步复位 → 同步等效电路 |
| `clk2fflogic` | 多时钟域用的(比 `async2sync` 通用但慢) |
| `miter -equiv` | 生成传统 miter 电路(另一种做法) |

### 懒人版:`equiv_opt`

Yosys 还有个一站式命令,把整套流程包好了:

```tcl
equiv_opt -assert -async2sync synth -top scrambler_apb
```

它内部自动做:`design -save preopt` → 跑 `synth` → `design -stash postopt`
→ `copy-from` 两份 → `async2sync` → `equiv_make` → `equiv_induct` → `equiv_status -assert`。

- ✅ 一行搞定
- ⚠️ 但它内部**只跑 `equiv_induct`,不跑 `equiv_simple`**,而且不好插手中间步骤
- 💡 **建议先手写完整版**(第 4 节),搞懂每一步再用 `equiv_opt` 偷懒。
  出问题时你也知道该拆开看哪里。

---

## 一页纸速查

```tcl
# gold = RTL
read_verilog -sv <文件...>
hierarchy -check -top <顶层>
prep -flatten -top <顶层>          # prep,不是 synth!
design -stash gold

# gate = 网表(⚠️ 这段必须和你的综合脚本逐字一致)
read_verilog -sv <文件...>          # 要重读,因为 stash 清空了
hierarchy -check -top <顶层>
synth -nofsm -top <顶层>            # -nofsm 避免 FSM 重编码
flatten                             # 两边都要打平
opt -full
techmap
opt -full
abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX
opt_clean
design -stash gate

# 并排放好
design -copy-from gold -as gold <顶层>
design -copy-from gate -as gate <顶层>

# 证明
async2sync                          # 有异步复位就加
equiv_make -blacklist equiv_blacklist.txt gold gate equiv
hierarchy -top equiv
equiv_simple -seq 5                 # 先 simple
equiv_induct -seq 5                 # 后 induct
log ============ EQUIVALENCE RESULT ============
tee -o reports/equiv_status.txt equiv_status -assert    # -assert 别忘
```

**成功标志**:`Equivalence successfully proven!` + 退出码 0

**记住五句话**:
1. `unproven` ≠ 有 bug;`proven inequivalent` 才是有 bug
2. 看到 unproven → **先看输出端口有没有中招**,再统计名字找共同点
3. **验证的网表必须等于交付的网表** —— gate 流程要和综合脚本逐字一致
4. blacklist 必须写**完整层次路径**,直接从日志的 `Unproven` 行里抄
5. 不确定参数怎么用 → `yosys -p "help 命令名"`
