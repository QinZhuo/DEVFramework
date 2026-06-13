@tool
@abstract class_name EntityDef extends Def

## 中文名
@export var zh_name: String:
	get(): return _get_zh(name)
	set(value): _set_zh(name, value)

@export_multiline var tr_desc: String:
	get():
		return get_desc(null)
## 图标
@export var icon: Texture2D
## 场景
@export var scene: Resource
## 主题色
@export var color: Color = Color.WHITE
## 效果
@export var effect: EffectDef
## 强度值 用于数值平衡
@export var power: float

func get_desc(_data) -> String:
	var desc := str("[color=#", color.to_html(false), "]", super._to_string(), "[/color]")
	if icon:
		return str("[img=center,center,48x48]", icon.resource_path, "[/img]", desc)
	return desc
