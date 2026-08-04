extends Control

## GOAP 演示场景控制脚本 — 展示世界状态、当前目标/计划、行动日志。
## UI 全部由场景（GoapDemo.tscn）定义，本脚本只负责数据绑定。

@onready var woodcutter: WoodcutterAgent = %Woodcutter
@onready var world_label: RichTextLabel = %WorldLabel
@onready var goal_label: Label = %GoalLabel
@onready var plan_label: Label = %PlanLabel
@onready var log_box: RichTextLabel = %LogBox
@onready var pause_button: Button = %PauseButton


func _ready() -> void:
	_update_world()
	woodcutter.world_state.changed.connect(func(_key, _old, _new): _update_world())
	woodcutter.plan_found.connect(_on_plan_found)
	woodcutter.plan_failed.connect(func(goal: GoapGoal): _log("✗ 规划失败：%s" % goal.def.name))
	woodcutter.action_started.connect(_on_action_started)
	woodcutter.action_finished.connect(_on_action_finished)
	woodcutter.plan_completed.connect(func(ok: bool): _log("—— 计划结束（%s） ——" % ("成功" if ok else "中断")))
	_log("AI 就绪，开始规划...")


func _update_world() -> void:
	var lines: Array[String] = []
	lines.append("木头在附近: %s" % str(woodcutter.get_state("wood_near", false)))
	lines.append("拥有工具: %s" % str(woodcutter.get_state("has_tool", false)))
	lines.append("持有木材: %s" % str(woodcutter.get_state("has_wood", false)))
	lines.append("木材已送达: %s" % str(woodcutter.get_state("wood_delivered", false)))
	lines.append("累计砍伐: %d" % int(woodcutter.get_state("wood_count", 0)))
	world_label.text = "[color=#9adc8a]世界状态[/color]\n" + "\n".join(lines)


func _on_plan_found(goal: GoapGoal, plan: Array) -> void:
	goal_label.text = "当前目标: [color=#7fd0ff]%s[/color]" % goal.def.name
	var parts: Array[String] = []
	for action in plan:
		parts.append("[color=#ffd77f]%s[/color]" % action.def.name)
	plan_label.text = "当前计划: " + " → ".join(parts)
	_log("◎ 规划成功（目标：%s）" % goal.def.name)


func _on_action_started(action: GoapAction) -> void:
	_log("▶ %s" % action.def.name)


func _on_action_finished(action: GoapAction, success: bool) -> void:
	if success:
		_log("✓ %s 完成" % action.def.name)


## —— 按钮 ——

func _on_near_pressed() -> void:
	_log("玩家操作：把木头放到附近")
	woodcutter.set_state("wood_near", true)


func _on_tool_pressed() -> void:
	_log("玩家操作：给樵夫工具")
	woodcutter.set_state("has_tool", true)


func _on_reset_pressed() -> void:
	_log("玩家操作：重置世界")
	woodcutter.world_state.reset({
		"wood_near": false,
		"has_tool": false,
		"has_wood": false,
		"wood_delivered": false,
		"wood_count": 0,
	})
	woodcutter.mark_dirty()
	_update_world()


func _on_pause_pressed() -> void:
	woodcutter.paused = not woodcutter.paused
	pause_button.text = "继续 AI" if woodcutter.paused else "暂停 AI"
	_log("AI %s" % ("已暂停" if woodcutter.paused else "已恢复"))


## —— 日志 ——

func _log(msg: String) -> void:
	log_box.append_text("%s\n" % msg)
	log_box.scroll_to_line(log_box.get_line_count())
