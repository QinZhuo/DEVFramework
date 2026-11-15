# DEVFramework

Godot 4.7 数据驱动框架：`Def`（配置）→ `Entity`（运行时）→ `View`（显示），配一批静态 `Tool` 与内置 MCP 调试服务器。

**框架 = 机制，项目 = 内容。** 换一款游戏仍成立的进框架，玩法语义留项目。判定见 [LAYERS.md](LAYERS.md)。

## 四角色

新代码必属其一，没有第五种：

| 角色 | 是什么 | 判别 |
|---|---|---|
| `Def` | 编辑器可配的静态数据（`Resource`） | 策划要在检查器里改？ |
| `Entity` | 运行时状态载体（`RefCounted` / `Node`） | 跑起来才有、且有状态？ |
| `View` | 投影，只读数据 | 玩家看得见 / 要交互？ |
| `Tool` | 横切机制，全 `static` | 换游戏仍成立、不要实例？ |

数据单向流动：`Def → Entity → View`，不回溯。Tool 被调用，不持有调用者。

## 三条硬规则

1. **数据不下行**：View 不写 Entity，Entity 不写 Def。要反馈就发信号或 `Callable`。
2. **一个角色一个基类**：不为同类问题开第二个基类。
3. **删除测试**：删掉任一模块目录，框架仍能编译运行（唯一例外：`plugin.gd` 里的编辑器接线）。

## 目录

```
addons/DEVFramework/
├─ Core/          Def/ Entity/ Tool/ Async/ Pool/ Editor/   ← 跨能力复用
├─ <能力>/         Dialogue Task AI Camera ECS Tween UI Focus Render
│                 ArrayView Value Effect Signal Audio Translation
│                 Screenshot Changelog GameCommand Test
├─ MCP/           扁平（preload 硬编码网，分层无收益）
└─ Native/        原生库 + dev.gdextension（禁止移动）
```

规则：**目录名 = 能力名**；模块内按 `Def / Entity / View / Tool / Editor` 分层，少于 3 个文件就扁平。

命名、归属、搬迁纪律全在 [LAYERS.md](LAYERS.md)。

## 安装

1. 复制 `addons/DEVFramework/` 到项目 `addons/`，插件面板启用。
2. 菜单 **项目 → 工具 → 创建 DEV 项目结构** 生成 `Assets/Def/`、`Scenes/`、`Scripts/` 骨架。

C++ 原生能力（ECS）需编译，见 [gdextension/README](../../gdextension/README.md)。

## 模块文档

| 模块 | 文档 | 可运行示例 |
|---|---|---|
| ECS（列存储 + 系统 + 查询链） | [ECS/Readme.md](ECS/Readme.md) | `Scenes/ECS/ECSDemo.tscn` |
| 对话 / 气泡 | [Dialogue/Readme.md](Dialogue/Readme.md) | `Scenes/Dialogue/DialogueDemo.tscn` |
| 任务 / 教程 | [Task/Readme.md](Task/Readme.md) | `Scenes/Tutorial/TutorialDemo.tscn` |
| GOAP AI | [AI/Readme.md](AI/Readme.md) | `Scenes/AI/GoapDemo.tscn` |
| 相机（机位竞争 + 混合） | [Camera/Readme.md](Camera/Readme.md) | — |
| 命令回放 | [GameCommand/Readme.md](GameCommand/Readme.md) | `Scenes/GameCommand/GameCommandDemo.tscn` |

其余场景见 [Scenes/README.md](../../Scenes/README.md)。

## MCP 调试服务器

插件启用即监听 `http://127.0.0.1:9988/mcp`（多项目共用一个端口）。

- 多项目并存：`list_instances` → `use_instance` 选默认，或单次调用带 `instance`
- 常用：`validate` / `get_logs` / `eval_code` / `run_tests` / `perf` / `game_control` / `restart_editor`
- 导出包默认不带入口（`dev_framework/mcp/runtime_enabled = false`）

## 引擎陷阱

1. **改框架代码后必须重启编辑器**：已注册的全局类不会真正 reload，行为与源码不符且无提示。
2. `await` 已完成的协程句柄会永久挂起 → 用 `AsyncTool.await_coroutine`。
3. 脚本 reload 后，跨编译代次的类型化赋值可能静默得到 null → 跨边界传对象用无类型变量。
4. **别把已释放的节点赋给类型化变量**：`var n: Node = arr.pop_back()` 在实例已 `queue_free` 时会抛
   "Trying to assign invalid previously freed instance"（赋值先于 `is_instance_valid` 检查）。
   先用 `Variant` 接住再判空。
5. **注释/提示文本里的 `res://` 不算路径引用**：批量替换路径时若正则太宽，会把提示文案也改坏。

## 改完必跑

```
run_tests  process=editor action=run script=test_framework_compile   # 全量编译 + 路径存在性
run_tests  process=editor action=run script=test_tutorial            # 遮罩/气泡回归
run_tests  process=editor action=run script=test_dialogue            # 对话链路
```

**`run_tests` 是 job 模型**（长任务标准做法）：

| action | 作用 |
|---|---|
| `run` | 启动任务，立即返回 `job_id`；带 `wait_sec`（默认 8）时窗口内跑完就直接给结果 |
| `status` | 查进度（`progress` 已完成的用例数 / `total` 本轮总数 / `current` 当前用例 / `elapsed_ms` / `rate` / `eta_ms`），**幂等，不重跑** |
| `result` | 取最终汇总（`text` / `cases` / `failures` / `elapsed_ms`） |
| `cancel` | 请求取消（当前用例结束后生效） |

慢测试（回放类常 100s+）不要反复调 `run` —— 那会重跑。用 `status` 轮询到 `running: false`。
`job` 状态存在**跑测试的进程**里，所以 `status`/`result` 的 `process` 必须与启动时一致。

**进度与 ETA 是内建的**：`total` 在开跑前就按"确认会执行的方法数"算好，`eta_ms` 由最近 3 秒的进度速率外推；
进度不可用（总数未知/还没推进）时退化到**同类任务的历史用时**（`user://.dev_framework/perf_history.json`）。
测试轮次还会在正文里给出"用时 X（预估 Y，偏差 Z%）"，预估来自各用例方法的历史 EMA。

## 性能测量

两件事分开做，不要混：

| 目标 | 手段 |
|---|---|
| 测一段逻辑多快 | `PerfTool.measure(callable)` / `PerfTool.bench(callable, iters, warmup)` |
| 测环境帧率/稳定性 | `PerfTool.sample_frames(帧数, 预热帧)` 或 MCP `perf action=fps process=game` |

- `bench` 先跑 `warmup` 次丢弃（首次 load / 着色器编译会高出一个量级），再给 `avg / p50 / p95 / p99 / min / max`。
  **看分位不看平均**：卡顿来自长尾，平均会把偶发尖峰稀释掉。
- 用例里直接断言，把阈值写进 CI：

```gdscript
extends TestCase

func test_query_cost() -> void:
    assert_under_ms(5.0, func(): world.query(...).count())     # 硬上限
    measure_ms("ecs/query", func(): world.query(...).count()) # 只记基线, 不判失败

func test_frame_rate() -> void:
    await assert_fps_at_least(55.0, 120, 30)                  # 需游戏进程
```

- `PerfTool.Rolling` 是通用定长窗口（O(1) 写入、分位数/峰值/超阈值计数），
  替代各处手写 `Array + pop_front`（ECS 演示与调试面板已统一到它）。
- 历史基线进程级共享、跨轮次复用；`perf action=reset` 清空重来，不要写完就删文件。
