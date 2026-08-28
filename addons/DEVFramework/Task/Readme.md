# Task 任务系统 + 新手教程（Tutorial）

DEV Framework 的**任务系统**：`Def（静态配置 .tres）→ Entity（运行时推进）`，完全外部驱动 —— 无运行器、无隐式生命周期，调用方创建并持有任务实体，靠信号推进。
**新手教程**是任务系统的能力子集，不新增流程引擎，只增加「步骤表现」与「引导视图"两个组件。

---

## 一、任务系统核心（教程的地基）

| 类 | 角色 |
|---|---|
| `TaskDef` | 任务定义基类（抽象） |
| `SignalTaskDef` / `SignalTask` | 任一信号触发即完成 |
| `GroupTaskDef` / `GroupTask` | 子任务编排：`SEQUENTIAL`(顺序) / `ANY_ORDER`(任意全完) / `COMPLETE_ANY`(任一即完) |

```gdscript
var task := Task.create(task_def)   # 或 task_def.create_entity()
task.completed.connect(_on_done)
task.activate(data)                # data 携带信号解析上下文（root 等）
var save := task.save_data()       # 存档（组任务含子进度）
task.load_data(save)               # 断点续玩
```

> 信号源（`SignalDef` 家族）：`NodeSignalDef` 订阅任意节点具名信号（如 `Button.pressed`）；`ConditionSignalDef` 带条件过滤。

## 二、教程 = 任务 + 表现

| 文件 | 角色 |
|---|---|
| `Def/TutorialStepDef.gd` | **步骤定义**：继承 `SignalTaskDef`，额外携带表现字段（target/tip/拦截） |
| `Def/TutorialTargetDef.gd` | 目标换算：把 Control / Node2D / Node3D → 统一屏幕矩形 |
| `View/TutorialGuide.gd` | **引导控件**：遮罩/挖孔/边框/箭头/提示气泡一体化，主题可定制 |
| `Scenes/Tutorial/` | 演示场景（含 `ClickableBall.gd` 自发光点击信号范式） |

**设计要点**：教程流程就是一个普通 `GroupTaskDef`（步骤为 `TutorialStepDef`）。何时完成完全由 Task 系统信号驱动；`TutorialGuide` 只负责"展示什么"。二者通过访问器 `guide.show_step(task.active_child_entity, host)` 在调用方桥接。

### 快速上手（三步）

1. **配步骤**：每个步骤一个 `.tres`（`TutorialStepDef`，含完成信号 + 表现）

```gdscript
# res://Assets/Def/Tutorial/Step_Welcome.tres （节选）
[resource]
script = ExtResource("1_step")                       # TutorialStepDef
signals = Array[SignalDef]([SubResource("sig")])     # NodeSignalDef → Button.pressed
target = SubResource("target")                       # TutorialTargetDef → node_path = UI/StartButton
tip_text = "欢迎！请点击[color=#ffd140]开始游戏[/color]按钮。"
```

2. **配流程**：一个 `.tres`（`GroupTaskDef`，步骤按序引用）

```gdscript
[resource]
script = ExtResource("1_flow")                       # GroupTaskDef
tasks = Array[TaskDef]([步骤1, 步骤2, ...])
mode = 0                                             # SEQUENTIAL
```

3. **代码桥接**（挂 Guide + 激活任务 + 两个信号，无任何运行器）：

```gdscript
var layer := CanvasLayer.new(); layer.layer = 100; add_child(layer)
var guide := TutorialGuide.new()
guide.set_anchors_preset(Control.PRESET_FULL_RECT)
guide.theme = my_theme                                # 可选：主题定制
layer.add_child(guide)

var task := TutorialStart.create_entity() as GroupTask
task.entity_changed.connect(_on_task_changed)
task.completed.connect(_on_completed)
task.activate({"root": self})
_on_task_changed()                                    # activate 不触发 entity_changed，需手动首次渲染

func _on_task_changed() -> void:
	if task.is_completed:
		guide.blur()                                  # 完成时也会触发一次 entity_changed
		return
	var step := task.active_child_entity
	if step and not step.is_completed:
		guide.show_step(step, self)                   # 渲染当前步骤（挖孔/箭头/提示）
```

## 三、配置详解

### TutorialStepDef（继承 SignalTaskDef）

| 字段 | 说明 |
|---|---|
| `signals` | （继承）完成信号，任一触发即完成本步骤 |
| `target: TutorialTargetDef` | 高亮目标；空 = 纯提示步骤（只显示气泡不挖孔） |
| `block_input: bool = true` | 阻断目标外输入（遮罩暗区拦截） |
| `click_to_complete: bool` | 无交互目标时的兜底：点击目标区域即完成 |
| `tip_text: String` | 提示文字（BBCode）；空则回退翻译描述 `tr(名称_desc)` |

### TutorialTargetDef（2D/3D 通用）

| 字段 | 说明 |
|---|---|
| `node_path: NodePath` | 目标节点（相对教程宿主 root） |
| `padding: float = 8` | 挖孔外扩像素 |
| `min_size: Vector2(96,96)` | **2D/3D 统一**最小挖孔尺寸；无体量的 Node2D 直接以它定尺寸 |
| `arrow: bool = true` | 显示指示箭头 |

屏幕矩形换算规则：
- **Control**：`get_global_rect()`
- **Node3D**：全局 AABB 8 角投影（相机背后隐藏；极小/极远目标退化为投影点 + `min_size` 兜底）
- **Node2D**：无固有体量 → 投影原点 + `min_size` 定尺寸

### TutorialGuide 主题（命名空间 `"TutorialGuide"`）

| 主题项 | 类型 | 控制 |
|---|---|---|
| `dim_color` | Color | 遮罩暗色 |
| `frame_stylebox` | StyleBox | 挖孔边框 |
| `arrow_color` | Color | 指示箭头 |
| `arrow_size` | int | 箭头长度 |
| `tip_stylebox` | StyleBox | 提示气泡面板 |
| `tip_font_color` / `tip_font_size` | Color/int | 气泡文字 |

```gdscript
var theme := Theme.new()
theme.set_color("dim_color", "TutorialGuide", Color(0, 0, 0.08, 0.62))
theme.set_stylebox("frame_stylebox", "TutorialGuide", my_frame_box)
guide.theme = theme   # 或 ThemeTypeVariation / 项目全局主题
```

## 四、常见用法

**点击目标区域完成（目标无碰撞体/无逻辑）**：
```gdscript
var step_def := ... as TutorialStepDef
step_def.click_to_complete = true
# 项目里连接 Guide 点击：
guide.hole_clicked.connect(func():
	var s := task.active_child_entity
	if s and (s.def as TutorialStepDef).click_to_complete:
		s.complete())
```

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
task.active_child_entity.complete()      # 跳过当前步骤
var data := task.save_data()             # 进度存档（含子步骤）
task.load_data(data)                     # 断点续玩
```

**自定义外观**：继承 `TutorialGuide` 重写 `_draw`（`_draw_dim/_draw_arrow`），或改造 `focus()/show_step()` 触发的表现；流程/完成逻辑无需改动。

## 五、最佳实践

1. **完成信号由目标节点自己发**（`pressed`/`clicked` 等），`NodeSignalDef` 只做订阅 —— 不替节点过滤输入流。
2. **教程即任务**：`TutorialStepDef` 是 `SignalTaskDef` 子类，可独立复用为普通任务；同一条流程去掉表现字段就是通用任务树。
3. **首次渲染手动调用**：`GroupTask.activate()` 不发射 `entity_changed`，激活后需手动 `guide.show_step(...)`，否则 Guide 停在模糊态遮挡全部点击。
4. 演示场景：`res://Scenes/Tutorial/TutorialDemo.tscn`（UI 按钮 + 3D 球体两步流程，含主题定制示例）。