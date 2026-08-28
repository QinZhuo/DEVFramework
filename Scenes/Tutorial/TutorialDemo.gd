extends Node3D

## 教程模块演示 — 顺序两步(纯 Task 流程 + TutorialStepDef 表现):
##   1. 点击 UI 按钮(TutorialStepDef + NodeSignalDef 订阅 Button.pressed)
##   2. 点击 3D 球体(TutorialStepDef + NodeSignalDef 订阅 Ball.clicked, 交互语义在 ClickableBall.gd)
## 一行启动: 挂载 Guide 后调 guide.start(flow, host) 即可, 内部完成桥接(等价手动路径)。

const TUTORIAL := preload("res://Assets/Def/Tutorial/Tutorial_Start.tres")

@onready var _hint: Label = $UI/Hint

var _task: GroupTask


func _ready() -> void:
	TranslationTool.initialize()  # 加载 Assets/Translation 翻译(task.csv.zh.translation)
	var layer := CanvasLayer.new()
	layer.name = "TutorialLayer"
	layer.layer = 100
	add_child(layer)
	var guide := TutorialGuide.new()
	guide.name = "TutorialGuide"
	guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	guide.theme = _make_theme()
	guide.hole_clicked.connect(_on_hole_clicked)  # click_to_complete 步骤的点击兜底
	layer.add_child(guide)

	_task = guide.start(TUTORIAL, self)  # 一行启动(桥接在 Guide 内部)
	_task.completed.connect(_on_completed)


## 主题定制(TutorialGuide 命名空间: 暗色/箭头/气泡/边框)
func _make_theme() -> Theme:
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
	return theme


func _on_hole_clicked() -> void:
	var step := _task.active_child_entity
	if step == null:
		return
	var step_def := step.def as TutorialStepDef
	if step_def and step_def.click_to_complete:
		step.complete()


func _on_completed() -> void:
	_hint.text = "教程完成! 可再次运行场景重新体验。"
	print("[TutorialDemo] 教程完成")