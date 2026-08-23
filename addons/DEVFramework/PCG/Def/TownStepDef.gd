@tool
@abstract
class_name TownStepDef extends Resource
## 城镇生成步骤基类 — 可插拔的阶段定义（参考 Minecraft Feature / RimWorld GenStep 模式）
##
## TownDef.steps 按序执行每个启用的步骤；每个子类自带本阶段全部参数，
## 不同 steps 组合 + 参数 = 不同风格城镇（平原农耕镇/山地矿镇/渔村…）。
## 新增内容类型：新建一个 TownStepDef 子类资源即可，核心编排零改动。
##
## 注意：调整步骤顺序会改变后续步骤的随机流（与 Minecraft Feature 顺序语义一致）。

## 是否启用本步骤
@export var enabled := true
## 设计师备注（不影响生成）
@export_multiline var note := ""

## 执行本阶段：读写 ctx（选址/道路/地块/建筑/动态层）
func apply(_ctx: TownGenContext) -> void:
	pass


func short_name() -> String:
	var n := String(get_script().resource_path).get_file().get_basename()
	return n
