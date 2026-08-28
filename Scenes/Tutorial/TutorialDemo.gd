extends Node3D

## 教程模块演示 — 顺序两步(纯 Task 流程 + TutorialStepDef 表现):
##   1. 点击 UI 按钮(TutorialStepDef + NodeSignalDef 订阅 Button.pressed)
##   2. 点击 3D 球体(TutorialStepDef + NodeSignalDef 订阅 Ball.clicked, 交互语义在 ClickableBall.gd)
## 每步遮罩挖孔 + 箭头 + 提示气泡, 步骤表现配置见各 Step_*.tres(TutorialStepDef)。

const TUTORIAL := preload("res://Assets/Def/Tutorial/Tutorial_Start.tres")

@onready var _hint: Label = $UI/Hint


func _ready() -> void:
	var runner := TutorialTool.start(TUTORIAL, self)
	runner.step_changed.connect(_on_step_changed)
	runner.tutorial_completed.connect(_on_completed)


func _on_step_changed(step: Task) -> void:
	var step_name := step.def.name if step.def else "?"
	print("[TutorialDemo] 进入步骤: ", step_name)


func _on_completed() -> void:
	_hint.text = "教程完成! 可再次运行场景重新体验。"
	print("[TutorialDemo] 教程完成")
