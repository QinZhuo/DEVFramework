# Task 任务系统 + 新手教程

`Def（.tres 静态配置）→ Entity（运行时推进）`，完全外部驱动：调用方创建并持有任务实体，靠信号推进，无运行器。教程只是任务的特化子类（`TutorialStepDef` 继承 `SignalTaskDef`），流程就是一个普通 `GroupTaskDef`。

## 怎么用

```gdscript
var task := Task.create(task_def)        # 或 task_def.create_entity()
task.completed.connect(_on_done)
task.progress_changed.connect(_on_progress)
task.blocked.connect(_on_blocked)
task.activate(data)                      # data 携带上下文（root 等）
task.get_progress()                      # Vector2i(已完成数, 总数)
var save := task.save_data()
var restored := Task.restore(save, data)
```

| 类 | 用途 |
|---|---|
| `SignalTaskDef` / `SignalTask` | 任一信号触发即完成 |
| `CountTaskDef` / `CountTask` | 计数达到 `required` 即完成（`required=1` 退化为信号任务） |
| `GroupTaskDef` / `GroupTask` | `SEQUENTIAL` / `ANY_ORDER` / `COMPLETE_ANY`，内建 `step_entered` |
| `TaskDef` 字段 | `prerequisite`（未满足则 `activate()` 拒绝并保持 INACTIVE、发 `blocked`）/ `skip_if`（激活时已满足 → 直接完成）/ `next: EffectDef`（完成时 `apply`，即奖励） |
| `TaskTool` | `track` / `untrack` / `get_active` / `find` / `save_all` / `load_all` |

教程三件套：步骤 `.tres`（`TutorialStepDef`：`signals` + `target: TutorialTargetDef`）→ 流程 `.tres`（`GroupTaskDef`，`mode = 0`）→ 启动：

```gdscript
var layer := CanvasLayer.new(); layer.layer = 100; add_child(layer)
var guide := TutorialOverlay.new()
guide.set_anchors_preset(Control.PRESET_FULL_RECT)
layer.add_child(guide)
var task := guide.start(TutorialStart, self)   # 内部完成 创建 → activate → 首次渲染，返回 GroupTask
```

`guide.stop()` 跳过（不触发 `completed`，发 `stopped`）；`step_started` / `step_completed` 供埋点。

## 坑

1. 需要存档/还原的任务必须用 `.tres`：运行时 `new()` 的 Def 没有 `resource_path`，存档告警且无法还原。
2. `GroupTask.activate()` **不发** `entity_changed`：手动路径下激活后必须自己调 `guide.show_step(step, host)`，否则 Guide 停在模糊态挡住全部点击（走 `guide.start()` / `bind_task()` 无此问题）。
3. 纯提示步骤（无 `target` 无 `signals`）的"点任意处继续"由 `TutorialOverlay` 按 `TutorialStepDef.click_to_complete` 统一判定，别处不要再 `complete()`；`skip_if` 跳过的步骤视为已达成但不发 `step_completed`。
