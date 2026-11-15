@tool
## 一段对话(数据): 若干行 + 播放策略。
##
## 与"表现"完全解耦: 同一个脚本可以播成气泡、对话框、字幕、3D 头顶文本。
class_name DialogueScriptDef extends Resource

@export var lines: Array[DialogueLineDef] = []
## 播完是否从头再来
@export var loop := false
## 玩家能否点击/按键推进
@export var advance_on_click := true
## 能否跳过整段(ESC/跳过键)
@export var skippable := true
## 播放时是否允许玩家操作其它 UI(由 presenter/调用方决定, 这里只是意图)
@export var block_input := false


func is_empty() -> bool:
	return lines.is_empty()


func size() -> int:
	return lines.size()
