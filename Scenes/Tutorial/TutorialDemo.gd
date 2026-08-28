extends Node3D

## 教程模块演示 — 顺序两步(纯 Task 流程 + TutorialStepDef 表现):
##   1. 点击 UI 按钮(TutorialStepDef + NodeSignalDef 订阅 Button.pressed)
##   2. 点击 3D 球体(TutorialStepDef + NodeSignalDef 订阅 Ball.clicked, 交互语义在 ClickableBall.gd)
## 播放完全外部驱动(对齐 Task 系统): TutorialTool.play 返回任务实体,
## task.completed / entity_changed 由外部连接; 视觉由 TutorialGuide 绘制(可主题定制)。

const TUTORIAL := preload("res://Assets/Def/Tutorial/Tutorial_Start.tres")

@onready var _hint: Label = $UI/Hint

var _task: GroupTask


func _ready() -> void:
	var theme := Theme.new()
	theme.set_color("dim_color", "TutorialGuide", Color(0, 0, 0.08, 0.62))
	theme.set_color("arrow_color", "TutorialGuide", Color(0.35, 1.0, 0.6, 1.0))
	theme.set_color("tip_font_color", "TutorialGuide", Color(0.85, 1.0, 0.92, 1.0))
	var tip_box := StyleBoxFlat.new()
	tip_box.bg_color = Color(0.03, 0.12, 0.08, 0.94)
	tip_box.set_border_width_all(1)
	tip_box.border_color = Color(0.35, 1.0, 0.6, 0.7)
	tip_box.set_corner_radius_all(8)
	theme.set_stylebox("tip_stylebox", "TutorialGuide", tip_box)
	var frame_box := StyleBoxFlat.new()
	frame_box.draw_center = false
	frame_box.set_border_width_all(2)
	frame_box.border_color = Color(0.35, 1.0, 0.6, 1.0)
	frame_box.set_corner_radius_all(4)
	theme.set_stylebox("frame_stylebox", "TutorialGuide", frame_box)

	_task = TutorialTool.play(TUTORIAL, self, {"theme": theme})
	_task.entity_changed.connect(_on_step_changed)
	_task.completed.connect(_on_completed)


func _on_step_changed() -> void:
	if _task.is_completed:
		return  # 完成时 GroupTask 也会发 entity_changed, 无活跃步骤
	var step := TutorialTool.current_step(_task)
	var step_name := step.def.name if step and step.def else "?"
	print("[TutorialDemo] 进入步骤: ", step_name)


func _on_completed() -> void:
	_hint.text = "教程完成! 可再次运行场景重新体验。"
	print("[TutorialDemo] 教程完成")