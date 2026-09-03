extends Node3D

## 教程模块演示 — 顺序两步(纯 Task 流程 + TutorialStepDef 表现):
##   1. 点击 UI 按钮(TutorialStepDef + NodeSignalDef 订阅 Button.pressed)
##   2. 点击 3D 球体(TutorialStepDef + NodeSignalDef 订阅 Ball.clicked, 交互语义在 ClickableBall.gd)
## 一行启动: 挂载 Guide 后调 guide.start(flow, host) 即可, 内部完成桥接(等价手动路径)。
## 表现定制: 通过 guide.theme 传主题(见 Task/Readme.md "TutorialOverlay 主题");
## 拖拽类步骤: 在 TutorialTargetDef 勾 allow_outside_drag, 或运行时设 guide.allow_hand_drag。

const TUTORIAL := preload("res://Assets/Def/Tutorial/Tutorial_Start.tres")

@onready var _hint: Label = $UI/Hint

var _task: GroupTask


func _ready() -> void:
	TranslationTool.initialize()  # 加载 Assets/Translation 翻译(task.csv.zh.translation)
	var layer := CanvasLayer.new()
	layer.name = "TutorialLayer"
	layer.layer = 100
	add_child(layer)
	var guide := TutorialOverlay.new()
	guide.name = "TutorialGuide"
	guide.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(guide)

	_task = guide.start(TUTORIAL, self)  # 一行启动(桥接在 Guide 内部)
	_task.completed.connect(_on_completed)
	_task.progress_changed.connect(_on_progress_changed)


## 进度变化 → 刷新步骤计数(纯提示步骤由 Guide 内部自推进, 无需宿主转发点击)
func _on_progress_changed() -> void:
	var p := _task.get_progress()
	_hint.text = "教程进度: %d/%d" % [p.x, p.y]


func _on_completed() -> void:
	_hint.text = "教程完成! 可再次运行场景重新体验。"
	print("[TutorialDemo] 教程完成")
