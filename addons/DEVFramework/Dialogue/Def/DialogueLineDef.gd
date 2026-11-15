@tool
## 对话的一行(数据)。只管"说什么", 不管"怎么显示"。
##
## 显示形态由 View/DialoguePresenter 的实现决定(气泡 / 对话框 / 字幕 / 3D 气泡都可以)。
class_name DialogueLineDef extends Resource

## 说话人标识(项目自定义: "narrator" / "merchant" / 角色 id ...)
@export var speaker: StringName = &""
## 翻译 key(非空时优先翻译; 空则直接用 text)
@export var text_key: StringName = &""
## 直接文案(不翻译/调试用)。支持 bbcode
@export_multiline var text := ""
## 头像/立绘(可选, 由 presenter 决定怎么用)
@export var portrait: Texture2D
## 小图标(可选)
@export var icon: Texture2D
## >0 = 到点自动推进(秒); 0 = 等玩家推进
@export var hold_time := 0.0
## 项目自定义标签(表情/音效/事件名), presenter 自行解释
@export var tags: Array[StringName] = []


## 实际要显示的文本(翻译优先)
func get_display_text() -> String:
	if text_key != &"":
		return tr(String(text_key))
	return text
