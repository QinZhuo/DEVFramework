extends Node3D

## 教程模块演示 — 顺序两步(纯 Task 流程 + TutorialStepDef 表现):
##   1. 点击 UI 按钮(TutorialStepDef + NodeSignalDef 订阅 Button.pressed)
##   2. 点击 3D 球体(TutorialStepDef + NodeSignalDef 订阅 Ball.clicked, 交互语义在 ClickableBall.gd)
## 一行启动: 挂载 Guide 后调 guide.start(flow, host) 即可, 内部完成桥接(等价手动路径)。
## 默认主题: 自动加载 res://Assets/Def/Tutorial/DefaultTutorialTheme.tres (可在 Guide.default_theme_path 修改)

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
	guide.hole_clicked.connect(_on_hole_clicked)  # click_to_complete 步骤的点击兜底
	layer.add_child(guide)

	_task = guide.start(TUTORIAL, self)  # 一行启动(桥接在 Guide 内部)
	_task.completed.connect(_on_completed)


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