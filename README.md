# research-runtime — 自动化神经网络架构研究循环框架

**research-runtime** 是基于 [Claude Code](https://claude.ai/claude-code) 的自动化神经网络架构探索框架。它运行一个**闭环状态机**：探索方向 → 多视角评审 → 票选 → 代码修改 → 训练验证 → 经验回收，自动迭代改进神经网络模型。

## 项目构成

```
research-runtime/
├── .claude/                          # 由 install.sh 安装（来自 agent-system/oh-my-autoresearch）
│   ├── CLAUDE.md                     # team-lead 主程序指令（状态机 / 工作流）
│   ├── settings.json                 # 工具权限、hook 注册、环境变量
│   ├── agents/                       # 注册的 subagent 定义
│   ├── commands/                     # slash 命令定义
│   ├── hooks/                        # 生命周期 hook
│   ├── schemas/                      # 状态机 & subagent 返回校验 schema
│   └── scripts/                      # 辅助脚本
│
├── runtime/                          # 由 install.sh 安装（来自 agent-system/oh-my-autoresearch）
│   ├── states/                       # 状态机 & 目标描述
│   ├── knowledges/                   # 经验知识库（baseline / learned / rejected）
│   ├── logs/                         # 训练日志（train-of-exp_*.log）
│   ├── observations/                 # observer 产出的观察日志
│   ├── db/                           # SQLite 数据库（runtime.sqlite）
│   ├── schemas/                      # JSON 校验 schema
│   ├── scripts/                      # 执行脚本（training / validate / coding / git / database / utils）
│   └── observer/                     # Observer sidecar（事件驱动持久化）
│
├── project/                          # 🔧 你的研究项目（手动创建或已有）
│   └── nn-architecture/              # 示例：GPT-2 小模型架构优化项目
│       ├── model.py                  # 模型定义（被优化的目标）
│       ├── train.py                  # 训练入口
│       ├── data.py                   # 数据加载
│       ├── launchscripts/            # 训练启动脚本（框架自动生成）
│       └── output/                   # 训练产出
│
├── agent-system/                     # Git submodule（框架源码来源）
│   └── oh-my-autoresearch/           # https://github.com/Liu-Xiaoyan97/oh-my-autoresearch
│
├── output/                           # 大文件产出（如 model.pt，由 .gitignore 排除）
├── .venv/                            # Python 虚拟环境
├── pyproject.toml                    # 项目依赖 & 元信息
├── objective.json                    → runtime/states/objective.json 的符号链接
└── uv.lock                           # uv 锁定文件
```

### 架构概览

```
┌─────────────────────────────────────────────────────┐
│                    team-lead (Claude)               │
│  ┌───────────────────────────────────────────────┐  │
│  │  状态机 (states.json): Step 0→1→...→9→0        │  │
│  └───────────────────────────────────────────────┘  │
│           │ 串行调用           │            │        │
│  ┌────────▼────────┐ ┌───────▼──────┐ ┌────▼─────┐  │
│  │ direction-scout │ │ summarizer   │ │  coder   │  │
│  │  ┌────┬────┬──┐ │ │ ┌────┬───┬──┐│ │  (叶子)   │  │
│  │  │AR │ MT │ ND│ │ │ │ AR │MT │ND││ │          │  │
│  │  └────┴────┴──┘ │ │ └────┴───┴──┘│ └──────────┘  │
│  └─────────────────┘ └───────────────┘              │
│           │ emit_event.py (唯一持久化出口)              │
│           ▼                                          │
│  ┌───────────────────────────────────────────────┐  │
│  │          Observer Sidecar (Python daemon)       │  │
│  │  events.jsonl → offset consume → dispatch      │  │
│  │    ├─ write_state.py        → states.json       │  │
│  │    ├─ write_log.py          → observations/*    │  │
│  │    ├─ write_exploration.py  → SQLite            │  │
│  │    ├─ write_experiments.py  → SQLite            │  │
│  │    ├─ write_knowledge.py    → knowledges/*      │  │
│  │    ├─ 失败 → deadletter.jsonl                   │  │
│  │    └─ state=9 触发 → LLM observation 生成      │  │
│  │         (独立 api/key/model)                    │  │
│  │       └─ 存 observations/ + 回灌 knowledges     │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**核心设计原则：**

- **team-lead 无写权**：所有持久化通过 observer event 完成，team-lead 只发事件，由 observer sidecar 落盘
- **两级 subagent 架构**：一级（scout/summarizer/coder）串行、二级（reviewer）并行
- **N 选 1 决策管线**：scout 找多个正交候选 → 三个 reviewer 各自评分 → summarizer 票选最高 → coder 实施
- **文件优先**：所有 writer 优先从权威文件读取上下文参数（exp_name 从 states.json、指标列名从 objective.json），payload 只作兜底

## 安装

### 前置条件

- **Python ≥ 3.10**
- **[uv](https://docs.astral.sh/uv/)**（推荐包管理器）
- **[Claude Code](https://claude.ai/code)**（CLI）

### 步骤

```bash
# 1. 克隆宿主仓库（含子模块）
git clone --recurse-submodules https://github.com/Liu-Xiaoyan97/research-runtime.git
cd research-runtime

# 2. 从子模块安装框架（.claude/ 和 runtime/）
bash agent-system/oh-my-autoresearch/install.sh "$(pwd)"

# 3. 创建虚拟环境并安装依赖
uv venv
source .venv/bin/activate   # macOS / Linux

uv sync                      # 安装生产依赖
uv sync --group dev          # 安装开发依赖（可选，含 pytest / ruff）

# 4. 确认环境就绪
python3 -c "import jsonschema; print('OK')"

# 5. 在 Claude Code 中打开项目
claude .
```

### 配置研究目标

编辑 `runtime/states/objective.json`（或直接编辑根目录 `objective.json` 符号链接）：

```json
{
  "goal": "降低模型的val_loss",
  "primary_metrics": {
    "name": "val_loss",
    "mode": "minimization"
  },
  "project_root": "project/nn-architecture",
  "command": "train.py",
  "remote": false,
  "num_training_steps": 200,
  "eval_n_steps": 50
}
```

- `project_root`：被优化的神经网络项目路径
- `command`：训练入口脚本（如 `train.py`）
- `num_training_steps` / `eval_n_steps`：训练步数和评估间隔
- `remote`：是否通过 SSH 在远程机器训练
- `hosts`：远程主机列表（仅 remote=true 时需要）

## 在 Claude Code 中启动

```bash
# 进入项目目录
cd research-runtime

# 启动 Claude Code
claude .
```

Claude Code 启动时会自动：
1. 运行 `session-start.sh` hook，启动 **observer sidecar**（事件驱动持久化守护进程）
2. 加载 `.claude/CLAUDE.md` 中的 team-lead 指令
3. 注册所有 slash 命令和 subagent

### 开始一次循环

在 Claude Code 中运行：

```
/loop
```

系统将自动执行完整状态机。状态机会自动循环迭代，直到遇到不可恢复错误或用户显式停止。

### 查看状态

```
/loop-status
```

显示当前迭代、实验名称、observer 健康状态、训练进度摘要。

## Slash 命令

| 命令 | 说明 |
|------|------|
| `/loop` | **触发状态机主循环。** 根据 `states.json` 的 `current_step` 执行对应 Phase：0 校验 → 1 探索 & 票选 → 代码修改 & git 提交 → SSH 同步 → 训练启动 & 监控 → 经验回收，然后自动进入下一轮迭代。 |
| `/loop-status` | **查看当前状态。** 显示 `current_step` / `next_step` / `iteration` / `exp_name`、最近训练日志尾部、observer 健康检查、SQLite 实验数据摘要。 |
| `/loop-doctor` | **全面环境诊断。** 执行 `validate_runtime.py` 和系列校验脚本，输出 PASS/FAIL/WARN 诊断报告，对 FAIL 项给出修复建议。 |
| `/loop-reset` | **重置状态机。** 将 `states.json` 重置为 `current_step=0`、`iteration=0`、`exp_name=exp_0`。⚠️ 不可逆，当前实验状态丢失，但不会删除训练数据和 knowledge。 |
| `/loop-recover` | **从异常恢复。** 检查状态机一致性、尝试重启 observer、重新解析训练日志。恢复操作会记录到 observer log。 |

## 状态机（Phases）

| Step | Phase | 说明 | 产出 |
|------|-------|------|------|
| 0 | 校验 | 运行 validate_runtime、check_clean | 校验通过报告 |
| 1 | 历史载入 | 读取 baseline / learned / rejected | 经验上下文 |
| 2 | → 1 | （过渡状态） | — |
| 3 | 方向探索 | scout + 3 个 reviewer 并行 | 正交候选集 |
| 4 | 票选决策 | summarizer + 3 个 reviewer 并行评分 | 最高票方法 |
| 5 | 代码变更 | coder 实施、冒烟测试、git 提交 | commit result |
| 6 | 远程同步 | SSH 同步代码（可选） | 同步完成 |
| 7 | 训练启动 | generate → start → CronCreate 轮询 | 训练进程 PID |
| 8 | 训练结束 | CronDelete 销掉 cron，解析日志 | 训练指标 |
| 9 | 经验回收 | reviewer analysis → 分类 learned/rejected/baseline | knowledge 更新 |

每一轮完成后自动进入下一轮（`iteration + 1`），形成持续优化循环。

## 被优化项目配置（project/）

这是 **research-runtime 最重要的配置**。`project/` 下存放的是你要优化的神经网络研究项目，框架会反复修改其代码来尝试各种架构改进。

### 目录结构要求

```
project/<your-project>/
├── train.py                      # 训练入口（必须支持 CLI 参数，见下文）
├── model.py                      # 模型定义
├── data.py                       # 数据加载
├── launchscripts/                # 由框架自动生成，不手动修改
│   └── launch_exp_*.sh
├── output/                       # 训练产出（checkpoint 等）
│   └── model.pt
└── ...                           # 其他依赖文件
```

### 如何新建自己的研究项目

1. 在 `project/` 下创建目录，如 `project/my-research/`
2. 编写训练脚本（见下文入口要求）
3. 在 `runtime/states/objective.json` 中将 `project_root` 指向该目录：

```json
{
  "project_root": "project/my-research",
  "command": "train.py",
  ...
}
```

### coder subagent 的编辑范围

框架的 `coder` subagent 只能编辑 `objective.json` 中 `project_root` 指向目录下的文件。
以下区域为**硬约束，coder 不能触碰**：
- `<project_root>/launchscripts/` — 自动生成的启动脚本
- `runtime/` — 运行时引擎
- `.claude/` — Claude Code 配置
- `agent-system/` — submodule

### 已有的项目示例

`project/nn-architecture/` 包含一个完整的 GPT-2 small 模型（12 层、768 维、12 头注意力），
支持以下可开关的架构特性（正是框架会自动探索的方向）：

| 标志 | 功能 | 说明 |
|------|------|------|
| `--use-pre-ln` | Pre-LayerNorm | Pre-LN vs Post-LN |
| `--use-qk-norm` | QK-Norm | 注意力头维度 QK LayerNorm |
| `--use-rope` | RoPE | 旋转位置编码替代 learned 位置编码 |
| `--no-swiglu` | GELU | 关闭 SwiGLU，回退到 GELU |
| `--use-parallel-block` | PaLM 式并行块 | 注意力 & MLP 共享输入，1/sqrt(2) 方差缩放 |
| `--use-output-gate` | 残差输出门控 | 可学习的 FPN-风格残差门控 |
| `--use-embed-norm` | Embedding LayerNorm | 输入 embedding 后的稳定化 LayerNorm |
| `--ln-init-random` | LN 随机初始化 | LayerNorm weight 用 N(1,0.02) 替代全 1 |
| `--log-activations` | 激活值诊断 | 记录 MLP 激活/注意力熵诊断信息 |
| `--log-grad-norms` | 梯度诊断 | 记录梯度 L2 范数 |

## 训练入口要求

被优化的项目**必须提供一个命令行训练脚本**（通常是 `train.py`），框架通过
`generate_launch.sh` → `start_training.sh` 驱动它。脚本需要满足以下要求：

### 1. CLI 参数

脚本**必须**通过 `argparse`（或等效方式）接受以下参数，框架启动时会自动注入：

| 参数 | 类型 | 是否必需 | 说明 |
|------|------|----------|------|
| `--num_training_steps` | int | 否 | 总训练步数，对应 `objective.json` 的 `num_training_steps` |
| `--eval_n_steps` | int | 否 | 每 N 步做一次验证评估，对应 `objective.json` 的 `eval_n_steps` |
| `--exp-name` | str | 否 | 当前实验名，如 `exp_5`（自动传入） |

这两个参数的命名**必须严格匹配** `--num_training_steps` 和 `--eval_n_steps`（带下划线），
因为 `generate_launch.sh` 会直接按此名称注入到 launcher 中。

在 `train.py` 中的典型用法：

```python
parser.add_argument("--num_training_steps", type=int, default=None,
    help="Number of training steps (alias for --train-steps, used by launch script)")
parser.add_argument("--eval_n_steps", type=int, default=None,
    help="Evaluate every N steps")
parser.add_argument("--exp-name", default="exp_0000_baseline")

args = parser.parse_args()
# 如果有 --num_training_steps 则覆盖自身步数参数
if args.num_training_steps is not None:
    args.train_steps = args.num_training_steps
```

### 2. 输出行为

- **日志输出到 stdout**：`start_training.sh` 使用 `nohup ... > runtime/logs/train-of-<exp_name>.log 2>&1` 重定向。脚本的所有 print 输出（训练进度、loss、val loss 等）都会被捕获到日志文件
- **输出格式**：日志文本可以是自由格式，但**关键指标必须满足特定模式**（见下方日志格式要求）以便 `monitor_training.py` 能够解析

### 3. 通过 launch script 启动时的路径

`generate_launch.sh` 生成的 `launch_exp_*.sh` 在被 `start_training.sh` 调用时，会：
1. 设置 `CUDA_VISIBLE_DEVICES` 或 `PYTORCH_ENABLE_MPS_FALLBACK`
2. `cd` 到项目根目录
3. 从宿主仓库的 `.venv/` 找 Python 解释器（如果存在），否则用系统 `python3`
4. 执行 `python3 <train.py> --num_training_steps N --eval_n_steps N`

所以你的训练脚本应该**相对于 `project/<your-project>/` 解析路径**（`data/`、`output/` 等）。

### 4. 指标文件（可选）

训练脚本还可以通过 `--metrics-file` 参数输出一份结构化 JSON 指标文件，框架会在
Phase 8 的解析中提取其中的 `final_val_loss` 和 `best_val_loss` 用于经验回收决策。
推荐的输出结构：

```python
metrics = {
    "exp_name": args.exp_name,
    "model": ...,
    "final_val_loss": final_val_loss,
    "best_val_loss": best_val_loss,
    "total_steps": args.train_steps,
    "total_params": total_params,
    "training_time_sec": elapsed_time,
}
```

### 5. 已有的训练脚本（参考实现）

`project/nn-architecture/train.py` 实现了一个完整的 GPT-2 small 训练脚本，满足以上所有
要求，可以作为新项目的参考模板。

## 日志格式要求

`monitor_training.py` 和 `parse_train_log.py` 通过正则表达式从训练日志中提取进度。
日志文本**不限制格式**——只要是文本即可。但有两类信息需要被解析器识别：

### 1. 训练进度行（任意格式，只要含 step 和 loss 关键词）

训练脚本在每步训练时打印的进度行，只要同时包含 `step` + 数字 和 `loss` + 数字，
解析器就能提取 `train_step` 和 `train_loss`：

```
step   10/200 | loss 5.8000 | lr 3.00e-04 | 2.1s     → train_step=10, train_loss=5.8000
train_step=20 train_loss=5.6000                        → train_step=20, train_loss=5.6000
```

无 `step`/`loss` 关键词的行完全被忽略，不影响解析结果。

### 2. 验证评估行（**唯一硬性格式要求**）

验证评估结果**必须**在同一行内同时输出步号和指标值，且格式必须为：

```
Eval at step {step}: {primary_metrics.name}={value}
```

其中 `{primary_metrics.name}` 来自 `objective.json` 的 `primary_metrics.name` 字段。

例如 `objective.json` 中：
```json
{"primary_metrics": {"name": "val_loss", "mode": "minimization"}}
```

则训练日志验证行必须为：
```
  Eval at step 50: val_loss=5.8021       → val_step=50, val_metric=5.8021
  Eval at step 100: val_loss=5.5056      → val_step=100, val_metric=5.5056
  Eval at step 150: val_loss=5.3701      → val_step=150, val_metric=5.3701
  Eval at step 200: val_loss=5.3146      → val_step=200, val_metric=5.3146
```

**只匹配这一种格式**——步号和指标值必须出现在同一行，且必须严格包含 `Eval at step` 和 `{primary_metrics.name}=`。如果验证行不符合此格式，解析器不会提取该次评估结果，对应的指标不会被写入 `experiments` 表。

#### 为什么这么设计

- parser 不再用通用 `key=value` 正则全量扫描每行再按 key 名配对
- 改用 `_build_eval_re(primary_metric)` 构建单一正则，**一步捕获**步号和指标值
- 消除两个正则独立匹配的配对歧义
- 训练脚本改动极低：只需要在打印验证行时使用 `Eval at step {step}: {primary_metrics.name}={value}` 格式

### 示例：完整的日志文件

```
step    0/200 | loss 9.2156 | lr 3.00e-04 | 1.2s
step   10/200 | loss 6.0123 | lr 3.00e-04 | 1.1s
  Eval at step 10: val_loss=5.8021
step   20/200 | loss 5.8765 | lr 3.00e-04 | 1.1s
...
  Eval at step 200: val_loss=5.3146
```

### `loss_exploded` 检测

`parse_train_log.py` 会自动检测 loss 发散。以下情况将标记 `loss_exploded=true`：
- 最新 loss > 1e6
- 最近 3 个 loss 连续上升且最新值 > 前 3 个的 10 倍

### 完整解析输出

`monitor_training.py` 解析后会输出 JSON：

```json
{
  "train_step": 200,
  "train_loss": 2.3456,
  "val_step": 200,
  "val_metric": 5.3146,
  "loss_exploded": false
}
```

这个 JSON 会被 cron 轮询任务读取，用于判断训练是否结束、是否需要进入 Phase 9 经验回收。

## 实时数据库仪表盘

`runtime/scripts/observe_db.py` 提供一个终端内实时刷新的 SQLite 仪表盘，用于
直观观察 observer 写入的实验数据和探索记录：

```bash
cd runtime          # 进入 runtime 目录
python3 scripts/observe_db.py              # 默认模式
python3 scripts/observe_db.py --details    # 显示完整 JSON（含 description）
```

### 布局

```
┌───────────────────────────────────┐
│  📊 experiments        (高度 30%) │
│  行数据，show_lines=True 横线分隔  │
├───────────────────────────────────┤
│  🔍 exploration        (高度 70%) │
│  orthogonal-direction-scout 列    │
│  默认只显示 name，--details 显示   │
│  完整 JSON（含 description）       │
├───────────────────────────────────┤
│  状态栏（1 行高度）                │
│  最后刷新时间 / 行数 / --details 提示 │
└───────────────────────────────────┘
```

- **experiments**：显示实验名和各 eval 检查点的指标列（列数自动适配 `objective.json`
  的 `num_training_steps` / `eval_n_steps`）
- **exploration**：显示 `orthogonal-direction-scout`（候选集）、`decision`（票选结果，
  已自动解析为候选方法名而非 `candidate_N`）、`commit`（提交记录）
- 每 2 秒自动刷新，`Ctrl+C` 退出

## 关键概念

### Subagent 体系

| Agent | 层级 | 角色 | 嵌套 |
|-------|------|------|------|
| `orthogonal-direction-scout` | 一级（串行） | 从多角度找优化候选 | 嵌套 spawn 3 个 reviewer |
| `summarizer` | 一级（串行） | 票选最佳方案 / 经验回收分析 | 嵌套 spawn 3 个 reviewer |
| `coder` | 一级（串行，叶子） | 实施代码修改、冒烟测试、git 提交 | 无嵌套 |
| `flow-arch-reviewer` | 二级（并行） | 架构 / 数据流角度评审 | — |
| `math-theorist` | 二级（并行） | 数学 / 优化理论角度评审 | — |
| `numerical-debugger` | 二级（并行） | 数值稳定性 / 梯度诊断 | — |

### Observer Sidecar

observer 是随 Claude Code session 启动/停止的 Python 守护进程（`observer_daemon.py`）。
它是**完全自治的独立观察者**，**不是 subagent**——team-lead 不能调用 observer 的任何
生命周期脚本或内部函数，只能通过 `emit_event.py` 发射事件来间接驱动它（fire-and-forget）。

#### 事件流

```
emit_event.py → events.jsonl → offset-based consume → dispatch → writer → 持久化
                                                         失败 → deadletter.jsonl
                                  state=9 → 触发 LLM observation 生成 → observations/ + knowledges
                                  control=reset → 自清 events/offsets/run
```

#### 5 种事件类型

| event_type | Writer | 写入目标 | 说明 |
|-----------|--------|---------|------|
| `state` | `write_state.py` | `states.json` | 推进状态机检查点，**唯一必须由 payload 给定全部字段的事件** |
| `log` | `write_log.py` | `observations/*.log` | 记录运行日志 |
| `experiments` | `write_experiments.py` | SQLite `experiments` 表 | 训练实验指标（建行 / 更新指标 / 标记完成） |
| `exploration` | `write_exploration.py` | SQLite `exploration` 表 | 正交候选集 / 决策 / 提交记录 |
| `knowledge` | `write_knowledge.py` | `knowledges/baseline.json` / `learned.json` / `rejected.json` | 经验知识库写入 |
| `control` | 自治处理（不进 writer） | 自清 | `action=reset` 清空 events/offsets/run |

#### 关键设计

- **文件优先**（`file-first`）：所有 writer 优先从权威文件读取上下文参数（如 `exp_name`
  从 `states.json` 获取，指标列名从 `objective.json` 推导），payload 只作为数据本体
  （log 文本、指标值、候选集内容等）。**唯一例外是 `state` 事件**——它自身就是
  `states.json` 的写入者，payload 是状态转移信号。

- **决策名称自动解析**：`write_exploration.py` 写入 `decision` 列时，自动将
  `candidate_N` 解析为对应的候选方法名（从同实验的 `orthogonal-direction-scout` JSON
  中提取 `name` 字段）。

- **自动指标发射**：`monitor_training.py` 在每次 cron 轮询时，自动检测未写入的 eval
  检查点，主动发射 `experiments update_metric` 事件。team-lead 无需手动发射指标事件。

- **一轮收尾自治观察**：`state` 事件 `current_step=9` 触发时，observer daemon 自动
  调用 `generate_observation.py`（使用**独立 LLM 配置** `llm.config.json`），汇总
  本轮数据生成自然语言 observation，存到 `observations/`（SQLite + JSONL），并将
  INSIGHT 回灌到 `knowledges/learned.json`（带 `[observer]` 标记）。整个过程
  best-effort，任何失败被吞掉，不阻塞 offset 推进。

- **健康状态**：observer daemon 每轮写入 `observer/run/observer.status`（含 PID、
  offset、LLM 启用状态、最后轮询时间），供 `/loop-status` 只读查看。

**team-lead 没有直接写权限**，所有持久化通过 `emit_event.py` 走 observer 完成。

### Git Submodule：框架源码

```bash
git submodule update --init --recursive
```

`agent-system/oh-my-autoresearch/` 是**框架源码仓库**（[GitHub](https://github.com/Liu-Xiaoyan97/oh-my-autoresearch)），
为 Git submodule。它包含：

- `runtime.template/` — `runtime/` 运行时引擎的模板文件
- `.claude.template/` — `.claude/` 配置的模板文件
- `install.sh` — 将上述模板复制到宿主仓库的安装脚本
- `doctor.sh` — 环境诊断脚本
- `tests/` — 框架测试

**`runtime/` 和 `.claude/` 由 `install.sh` 从子模块安装**，不是宿主仓库自身维护的源码。
当你拉取子模块更新后，需要重新运行 `install.sh` 来同步最新更改（不会覆盖已存在的文件）。

### Subagent 模型切换

安装后，框架默认使用 `claude-deepseek-4-flash` 驱动各 subagent。
你可以为每个 subagent 单独指定不同的模型，只需修改 `.claude/agents/` 下对应 agent 文件的
`model` 字段为 `claude code` CLI 中可使用的任意模型标识。例如：

```yaml
---
name: "orthogonal-direction-scout"
model: claude-sonnet-4-6        # ← 修改此行
```

目前注册的 6 个 subagent 文件及其默认模型：

| Agent 文件 | 默认模型 | 适用范围 |
|-----------|---------|---------|
| `.claude/agents/coder.md` | `claude-deepseek-4-flash` | 代码修改（叶子，无嵌套） |
| `.claude/agents/orthogonal-direction-scout.md` | `claude-deepseek-4-flash` | 方向探索（嵌套 3 个 reviewer） |
| `.claude/agents/summarizer.md` | `claude-deepseek-4-flash` | 票选汇总（嵌套 3 个 reviewer） |
| `.claude/agents/flow-arch-reviewer.md` | `claude-deepseek-4-flash` | 架构评审（二级 reviewer） |
| `.claude/agents/math-theorist.md` | `claude-deepseek-4-flash` | 数学理论评审（二级 reviewer） |
| `.claude/agents/numerical-debugger.md` | `claude-deepseek-4-flash` | 数值诊断评审（二级 reviewer） |

可用模型标识示例：

- `claude-sonnet-4-6` — 最新 Sonnet，平衡速度与质量
- `claude-haiku-4-5-20251001` — 最快、最经济的选项
- `claude-opus-4-8` — 最强的推理能力，适合 reviewer 角色
- `claude-deepseek-4-flash` — 默认值，快速且性能优秀

**注意：**
- 模型切换只影响 **`mcp__Task__spawn` 调用的子 agent**，不影响 Claude Code 主对话（team-lead）使用的模型——主对话模型由 `claude` CLI 的 `--model` 参数或 settings.json 中的 `"model"` 设定确定
- 如果切换后模型不可用，`Task` 调用会报错，这时改回已知可用的模型即可
- `agent-system/oh-my-autoresearch/` 是 Git submodule，**不要直接在宿主的 `.claude/agents/` 上改完后又提交到 submodule 里修改**。但宿主仓库中 `.claude/agents/*.md` 已经是 install.sh 复制出来的独立副本，在宿主的 `.claude/agents/` 中修改 `model` 字段不会被子模块覆盖（install.sh 使用 no-clobber 策略，不会覆盖已存在的文件）

## 开发

```bash
# 安装开发依赖
uv sync --group dev

# 运行测试
pytest

# 代码检查
ruff check .
```

## 注意事项

- **写权限约束**：team-lead 不能直接 Write/Edit 文件，所有持久化通过 observer event 完成。
  参数采用文件优先原则——writer 从 states.json/objective.json 读取上下文，payload 只作数据本体。
- **observer 独立自治**：observer 是独立守护进程，不是 subagent。team-lead 不得调用 observer 的
  生命周期脚本或内部函数，只能通过 `emit_event.py` 发射 5 种事件类型（state/log/experiments/exploration/knowledge）驱动。
- **训练监控**：使用 Claude Code 内部 `CronCreate` 轮询训练进度，禁止前台 sleep 阻塞
- **脚本约束**：训练必须通过 `generate_launch.sh` → `start_training.sh` → `monitor_training.py` 驱动
- **subagent 约束**：只能使用 `.claude/agents/` 注册的 6 种 subagent，严禁降级到通用 agent
- **远程训练**：通过 `runtime/scripts/utils/ssh_chain.py` 支持 SSH 链式跳板机连接
