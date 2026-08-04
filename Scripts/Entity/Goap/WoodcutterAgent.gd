class_name WoodcutterAgent extends GoapAgent

## GOAP 演示示例：樵夫 AI
## 行动/目标配置全部来自 Assets/Def/Goap/ 下的 .tres 资源（配置驱动），
## 展示目标优先级、A* 规划、同步/异步行动、世界状态驱动的重规划。

signal wood_changed(count: int)


const BRING_WOOD_GOAL := preload("res://Assets/Def/Goap/带回木材.tres")
const OWN_WOOD_GOAL := preload("res://Assets/Def/Goap/获得木材.tres")
const FIND_WOOD_ACTION := preload("res://Assets/Def/Goap/寻找木材.tres")
const MAKE_TOOL_ACTION := preload("res://Assets/Def/Goap/制作工具.tres")
const CHOP_WOOD_ACTION := preload("res://Assets/Def/Goap/砍伐木材.tres")
const CARRY_WOOD_ACTION := preload("res://Assets/Def/Goap/搬运回营.tres")


## 在 GoapAgent._ready() 末尾被调用，用于配置目标/行动与初始世界状态
func _ready_goap() -> void:
	# —— 目标（按优先级从高到低尝试） ——
	goals = [BRING_WOOD_GOAL, OWN_WOOD_GOAL]

	# —— 行动 ——
	actions = [FIND_WOOD_ACTION, MAKE_TOOL_ACTION, CHOP_WOOD_ACTION, CARRY_WOOD_ACTION]

	# —— 初始世界状态 ——
	set_state("wood_near", false)
	set_state("has_tool", false)
	set_state("has_wood", false)
	set_state("wood_delivered", false)
	set_state("wood_count", 0)

	debug_enabled = true


## —— 同步行动 ——

func perform_find_wood(_action: GoapAction) -> bool:
	LogTool.log("GOAP", "%s: 四处寻找木材..." % name)
	return true


func perform_make_tool(_action: GoapAction) -> bool:
	LogTool.log("GOAP", "%s: 打磨制作石斧..." % name)
	return true


func perform_chop_wood(_action: GoapAction) -> bool:
	var count: int = get_state("wood_count", 0) + 1
	set_state("wood_count", count)
	wood_changed.emit(count)
	LogTool.log("GOAP", "%s: 砍得木材 x%d" % [name, count])
	return true


## —— 异步行动（声明为 Variant 返回 null，耗时完成后手动通知） ——

func perform_carry_wood(_action: GoapAction) -> Variant:
	LogTool.log("GOAP", "%s: 开始搬运木材回营（异步 1 秒）..." % name)
	get_tree().create_timer(1.0).timeout.connect(func():
		LogTool.log("GOAP", "%s: 木材已送达营地" % name)
		notify_action_finished(true)
	)
	return null
