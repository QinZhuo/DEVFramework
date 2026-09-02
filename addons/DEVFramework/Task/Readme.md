# Task 任务系统 + 新手教程（Tutorial）

DEV Framework 的**任务系统**：`Def（静态配置 .tres）→ Entity（运行时推进）`，完全外部驱动 —— 无运行器、无隐式生命周期，调用方创建并持有任务实体，靠信号推进。
**新手教程**是任务系统的能力子集，不新增流程引擎，只增加「步骤表现」与「引导视图"两个组件。

***

## 一、任务系统核心（教程的地基）

| 类                              | 角色                                                                |
| ------------------------------ | ----------------------------------------------------------------- |
| `TaskDef`                      | 任务定义基类（抽象）                                                        |
| `SignalTaskDef` / `SignalTask` | 任一信号触发即完成                                                         |
| `GroupTaskDef` / `GroupTask`   | 子任务编排：`SEQUENTIAL`(顺序) / `ANY_ORDER`(任意全完) / `COMPLETE_ANY`(任一即完) |

```gdscript
var task := Task.create(task_def)   # 或 task_def.create_entity()
task.completed.connect(_on_done)
task.progress_changed.connect(_on_progress)   # 进度变化（步骤推进）
task.activate(data)                # data 携带信号解析上下文（root 等）
task.get_progress()                # Vector2i(已完成数, 总数)

var save := task.save_data()                   # 存档（Def 相对路径 + 各步完成状态）
var restored := Task.restore(save, data)       # 断点续玩：一步重建并激活到存档进度
```

> **存档前提**：`Def` 必须有 `resource_path`（即存成 `.tres` 文件）。运行时 `XxxDef.new()` 出来的内置 Def 没有路径，存档时会告警且无法还原 —— 需要持久化的任务请一律用 `.tres` 配置。
>
> `Task.restore(dict, data)` 的 `data` 可省略：省略时只恢复数据不激活，之后调 `task.activate(data)` 会从存档进度继续（不重跑已完成步骤）。
>
> 信号源（`SignalDef` 家族）：`NodeSignalDef` 订阅任意节点具名信号（如 `Button.pressed`）；`ConditionSignalDef` 带条件过滤。

## 二、教程 = 任务 + 表现

| 文件                         | 角色                                                  |
| -------------------------- | --------------------------------------------------- |
| `Def/TutorialStepDef.gd`   | **步骤定义**：继承 `SignalTaskDef`，额外携带表现字段（target/tip/拦截） |
| `Def/TutorialTargetDef.gd` | 目标换算：把 Control / Node2D / Node3D → 统一屏幕矩形           |
| `View/TutorialGuide.gd`    | **引导控件**：遮罩/挖孔/边框/箭头/提示气泡一体化，主题可定制                  |
| `Scenes/Tutorial/`         | 演示场景（含 `ClickableBall.gd` 自发光点击信号范式）                |

**设计要点**：教程流程就是一个普通 `GroupTaskDef`（步骤为 `TutorialStepDef`）。何时完成完全由 Task 系统信号驱动；`TutorialGuide` 只负责"展示什么"。二者通过访问器 `guide.show_step(task.active_child_entity, host)` 在调用方桥接。

### 快速上手（三步）

1. **配步骤**：每个步骤一个 `.tres`（`TutorialStepDef`，含完成信号 + 表现）

```gdscript
# res://Assets/Def/Tutorial/Step_Welcome.tres （节选）
[resource]
script = ExtResource("1_step")                       # TutorialStepDef
signals = Array[SignalDef]([SubResource("sig")])     # NodeSignalDef → Button.pressed
target = SubResource("target")                       # TutorialTargetDef → node_path = UI/StartButton
# 提示文字走统一 desc 翻译: Assets/Translation/task.csv 中 步骤名_desc(如 Step_Welcome_desc)
```

> 翻译表格式（`Assets/Translation/task.csv` 供编辑器写入；运行时由 Godot CSV 导入器自动生成 `task.zh.translation` 并调 `TranslationTool.initialize()` 加载，内容支持 BBCode）：
>
> ```
> keys,zh
> Step_Welcome_desc,欢迎！请点击[color=#ffd140]开始游戏[/color]按钮。
> Step_ClickBall_desc,现在点击[color=#ffd140]蓝色球体[/color]！
> ```
>
> `.translation` 由 CSV 导入器自动生成（`task.zh.translation`），**不要手写同名翻译文件**——否则同键会被重复注册，且手写那份不会随 CSV 更新而漂移失效。

1. **配流程**：一个 `.tres`（`GroupTaskDef`，步骤按序引用）

```gdscript
[resource]
script = ExtResource("1_flow")                       # GroupTaskDef
tasks = Array[TaskDef]([步骤1, 步骤2, ...])
mode = 0                                             # SEQUENTIAL
```

1. **代码启动**（两选一）：

**便捷路径**（一行）：

```gdscript
var layer := CanvasLayer.new(); layer.layer = 100; add_child(layer)
var guide := TutorialGuide.new()
guide.set_anchors_preset(Control.PRESET_FULL_RECT)
guide.theme = my_theme                    # 可选：主题定制
layer.add_child(guide)
var task := guide.start(TutorialStart, self)   # ← 一行启动，内部完成桥接 + 首次渲染
task.completed.connect(_on_completed)
```

> `guide.start(flow, host, {pause_tree: bool})` 内部完成「创建任务→连 entity\_changed/completed→activate→首次渲染」，完成后自动 `blur`；返回 `GroupTask` 供外部连接/存档。
> 配套：`guide.stop()` 提前结束/跳过（停用任务 + blur + 恢复暂停，不触发 completed）；`guide.step_started` 信号每进入一步发一次，可绑步骤 UI/进度条/播音频。

**手动路径**（完全外部驱动，等价）：

```gdscript
var task := TutorialStart.create_entity() as GroupTask
task.entity_changed.connect(_on_task_changed)
task.completed.connect(_on_completed)
task.activate({"root": self})
_on_task_changed()                      # activate 不触发 entity_changed，需手动首次渲染

func _on_task_changed() -> void:
	if task.is_completed:
		guide.blur()                    # 完成时也会触发一次 entity_changed
		return
	var step := task.active_child_entity
	if step and not step.is_completed:
		guide.show_step(step, self)     # 渲染当前步骤（挖孔/箭头/提示）
```

## 三、配置详解

### TutorialStepDef（继承 SignalTaskDef）

| 字段                          | 说明                                                                        |
| --------------------------- | ------------------------------------------------------------------------- |
| `signals`                   | （继承）完成信号，任一触发即完成本步骤                                                       |
| `target: TutorialTargetDef` | 高亮目标；**有 target 即自动遮挡目标外输入**（遮罩挖孔，完成靠目标自身交互/信号）；空 = 纯提示步骤（不挖孔，自动"点任意处继续"） |
| `tip_position: Vector2`     | 提示框屏幕位置（视口归一化 0..1，气泡中心）；仅纯提示生效，有 target 时随挖孔/箭头自动摆放；(-1,-1)=自动（纯提示居中偏上）  |
| （无输入控制字段）                   | 是否遮挡 / 是否可点推进全部由 target 存在性**自动推导**，无需手动配置                                |
| （无提示字段）                     | 提示文字复用 TaskDef 统一 desc 翻译 `tr(名称_desc)`（见上方翻译表）                           |

### TutorialTargetDef（2D/3D 通用）

| 字段                    | 说明                            |
| --------------------- | ----------------------------- |
| `node_path: NodePath` | 目标节点（相对教程宿主 root）             |
| `padding: float = 8`  | 挖孔外扩像素（挖孔 = 目标视觉体量 + padding） |
| `arrow: bool = true`  | 显示指示箭头                        |
| `allow_outside_drag: bool = false` | 放行孔外按下（拖拽类步骤：目标可能超出挖孔，需放行按下才能起拖）。每步进入时自动带入 `TutorialGuide.allow_hand_drag`，运行期也可手动改 |

屏幕矩形换算规则：

- **Control**：`get_global_rect()`

- **Node3D**：全局 AABB 8 角投影（相机背后隐藏；极小/极远目标退化为投影点，尺寸由 `padding` 兜底外扩）

- **Node2D**：汇总自身及子级 `Sprite2D`/`Control` 的视觉体量换算屏幕矩形（2D 精灵挖孔准确）；无任何体量时才退化为投影原点，尺寸由 `padding` 兜底外扩

- 箭头**默认置于挖孔上方**指向目标，顶部放不下才翻到下方兜底；提示气泡始终在箭头尾端外侧（默认上方），固定不随目标左右偏移/浮动；`arrow=false` 时不画箭头，气泡置于孔下方（纯提示无孔默认居中偏上，也可用 `tip_position` 指定位置）

### TutorialGuide 主题（命名空间 `"TutorialGuide"`）

| 主题项                                | 类型        | 控制     |
| ---------------------------------- | --------- | ------ |
| `dim_color`                        | Color     | 遮罩暗色   |
| `frame_stylebox`                   | StyleBox  | 挖孔边框   |
| `arrow_color`                      | Color     | 指示箭头   |
| `arrow_size`                       | int       | 箭头长度   |
| `tip_stylebox`                     | StyleBox  | 提示气泡面板 |
| `tip_font_color` / `tip_font_size` | Color/int | 气泡文字   |

```gdscript
var theme := Theme.new()
theme.set_color("dim_color", "TutorialGuide", Color(0, 0, 0.08, 0.62))
theme.set_stylebox("frame_stylebox", "TutorialGuide", my_frame_box)
guide.theme = theme   # 或 ThemeTypeVariation / 项目全局主题
```

## 四、常见用法

**纯提示步骤"点任意处继续"（自动）**：无 `target` 且无 `signals` 的步骤由 `TutorialGuide` 内部自推进（点任意处 → `hole_clicked` → 完成当前步骤），**宿主无需转发**。

> 有 `target` 的步骤完成靠目标自身交互/信号；无 `target` 但配了 `signals` 的"等待信号"步骤不遮罩、也不点击完成。
> `hole_clicked` 仍可外部连接，仅用于额外钩子（播音效、埋点等），不要再用它推进步骤，否则会重复完成。

**拖拽类步骤**（目标/可拖物可能超出挖孔）：

```gdscript
# 配置式：该步骤的 TutorialTargetDef 勾 allow_outside_drag 即可
# 运行式：或由代码注入"当前是否正在拖拽"的判定，拖拽期间 Guide 放行全部指针事件
guide.drag_checker = func(): return MyDragManager.is_dragging
```

> 框架不认识任何具体拖拽实现：命中判定走鸭子类型（射线命中节点或其祖先带 `is_dragging` 属性即视为可拖），"是否正在拖拽"由 `drag_checker` 注入。

**3D 可点击物体（语义归节点自己，信号 Def 只订阅）** —— 参照 `Scenes/Tutorial/ClickableBall.gd`：

```gdscript
class_name ClickableBall extends Area3D
signal clicked
func _ready() -> void:
	input_event.connect(func(_c, e, _p, _n, _s):
		var press := e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT \
				or e is InputEventScreenTouch and e.pressed
		if press: clicked.emit())
```

**暂停世界播放**（遮罩/箭头仍每帧刷新）：

```gdscript
task.activate({"root": self})
get_tree().paused = true
guide.process_mode = Node.PROCESS_MODE_ALWAYS
task.completed.connect(func(): get_tree().paused = false)
```

**跳过/存档**：

```gdscript
guide.stop()                             # 一键跳过整个教程（Guide 自动停用任务+blur）
# 或仅跳过当前步骤：
task.active_child_entity.complete()
var data := task.save_data()                    # 进度存档（含子步骤）
var same_task := Task.restore(data, {"root": host})  # 断点续玩：重建并激活到存档进度
```

**自定义外观**：继承 `TutorialGuide` 重写 `_draw`（`_draw_dim/_draw_arrow`），或改造 `focus()/show_step()` 触发的表现；流程/完成逻辑无需改动。

## 五、最佳实践

1. **完成信号由目标节点自己发**（`pressed`/`clicked` 等），`NodeSignalDef` 只做订阅 —— 不替节点过滤输入流。
2. **教程即任务**：`TutorialStepDef` 是 `SignalTaskDef` 子类，可独立复用为普通任务；同一条流程去掉表现字段就是通用任务树。
3. **首次渲染手动调用**：`GroupTask.activate()` 不发射 `entity_changed`，激活后需手动 `guide.show_step(...)`，否则 Guide 停在模糊态遮挡全部点击（走 `guide.start()/bind_task()` 无此问题）。
4. **要存档就用 `.tres`**：运行时 `new()` 出来的 Def 没有 `resource_path`，存不下也还原不了。
5. **不要在 `hole_clicked` 里推进步骤**：纯提示步骤已由 Guide 内部自推进，外部再 `complete()` 会重复触发。
6. 演示场景：`res://Scenes/Tutorial/TutorialDemo.tscn`（UI 按钮 + 3D 球体两步流程，含 `progress_changed` 进度显示）。

