@tool
## 游戏动作：一次玩家/AI 决策或操作的记录单元（动作即数据）。
## 序列化后可用于回放、战绩审计与 headless 自动化测试。
class_name GameCommand extends RefCounted

## 动作类型，如 &"use_equip"、&"levelup_pick"
var action: StringName = &""
## 通用上下文序号（回合制游戏下为回合号；其他场景可自定义含义）
var index: int = -1
## 决策参数（按操作顺序：点选的列号/目标格/选项序号...；首个参数惯例为动作主体标识）
var params: Array = []

func _init(p_action: StringName = &"", p_index: int = -1, p_params: Array = []) -> void:
	action = p_action
	index = p_index
	params.assign(p_params)

func save_data() -> Dictionary:
	return {action = action, index = index, params = params.duplicate(true)}

## 从存档字典还原；非字典输入返回空动作（调用方决定如何兜底）
static func load_data(data) -> GameCommand:
	var cmd := GameCommand.new()
	if data is Dictionary:
		cmd.action = StringName(str(data.get("action", "")))
		cmd.index = int(data.get("index", -1))
		var p = data.get("params", [])
		if p is Array:
			cmd.params.assign(p)
	return cmd