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
│           │ observer event (唯一持久化出口)            │
│           ▼                                          │
│  ┌───────────────────────────────────────────────┐  │
│  │            Observer Sidecar (Python)            │  │
│  │  events.jsonl → dispatch → writers             │  │
│  │  ├─ write_state.py     → states.json           │  │
│  │  ├─ write_log.py       → observations/*.log    │  │
│  │  ├─ write_exploration.py → SQLite / JSON       │  │
│  │  ├─ write_experiments.py  → SQLite             │  │
│  │  └─ write_knowledge.py    → knowledges/*.json  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**核心设计原则：**

- **team-lead 无写权**：所有持久化通过 observer event 完成，team-lead 只发事件，由 observer sidecar 落盘
- **两级 subagent 架构**：一级（scout/summarizer/coder）串行、二级（reviewer）并行
- **N 选 1 决策管线**：scout 找多个正交候选 → 三个 reviewer 各自评分 → summarizer 票选最高 → coder 实施

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
日志文本可以是自由格式的，但**需要解析的指标行**必须满足以下模式。

### 正则规则

```
step N / total     ← 匹配 "step" + 数字，更新 train_step
train_loss = X     ← 匹配 "loss" + 浮点数（loss=, loss: 均可），更新 train_loss
val_X = Y          ← 匹配 "val_" 开头的任何指标 + 浮点数，如 val_loss=3.45
val_step N         ← 可选，匹配 "val_step" + 数字，更新 val_step
```

### 实际例子

以下日志行都能被正确解析（来自 `train.py` 的输出）：

```
step    0/200 | loss 9.2156 | lr 3.00e-04 | 1.2s        → train_step=0, train_loss=9.2156
  Eval at step 10: val_loss=4.0123                       → val_loss=4.0123
  Attn entropy | mean=6.3812 min=0.0015 max=10.2345      → 无（不匹配上述 regex，仅人类可读）
Gradient norm (pre-clip): 12.3456                         → 无（同上）
```

### `loss_exploded` 检测

`parse_train_log.py` 会自动检测 loss 发散。以下情况将标记 `loss_exploded=true`：
- 最新 loss > 1e6
- 最近 3 个 loss 连续上升且最新值 > 前 3 个的 10 倍

### 命名建议

为了被 `monitor_training.py` 正确处理，推荐：

- 训练 loss 用 `loss` 或 `train_loss`
- 验证指标用 `val_<metric_name>`，如 `val_loss`、`val_accuracy`、`val_ppl`
- `objective.json` 中的 `primary_metrics.name` 应去掉 `val_` 前缀（框架会自动拼接）：
  ```json
  { "name": "loss", "mode": "minimization" }
  ```
  这样日志中 `val_loss=3.45` 会被识别为主要指标。

### 完整解析输出

`monitor_training.py` 解析后会输出 JSON：

```json
{
  "train_step": 200,
  "train_loss": 2.3456,
  "val_loss": 3.1234,
  "val_metric": 3.1234,
  "loss_exploded": false
}
```

这个 JSON 会被 cron 轮询任务读取，用于判断训练是否结束、是否需要进入 Phase 9 经验回收。

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

observer 是随 Claude Code session 启动/停止的 Python 守护进程。它：

- 轮询 `runtime/observer/events/events.jsonl`
- 根据事件类型调用对应的 writer（写 states.json / SQLite / knowledge JSON / observation log）
- 处理失败时写入 deadletter，不阻塞主流程

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

- **写权限约束**：team-lead 不能直接 Write/Edit 文件，所有持久化走 observer event
- **训练监控**：使用 Claude Code 内部 `CronCreate` 轮询训练进度，禁止前台 sleep 阻塞
- **脚本约束**：训练必须通过 `generate_launch.sh` → `start_training.sh` → `monitor_training.py` 驱动
- **subagent 约束**：只能使用 `.claude/agents/` 注册的 6 种 subagent，严禁降级到通用 agent
- **远程训练**：通过 `runtime/scripts/utils/ssh_chain.py` 支持 SSH 链式跳板机连接
