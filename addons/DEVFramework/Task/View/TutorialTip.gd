@tool
## 教程提示气泡 — 显示当前步骤描述(RichText, 支持 EntityDef 的图标/颜色 BBCode)。
## 位置由 TutorialTool 每帧根据挖孔矩形摆放(目标下方, 放不下移上方/底部)。
class_name TutorialTip extends PanelContainer

@onready var _text: RichTextLabel = $Text


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


## 显示提示(空文本 = 隐藏)
func show_tip(bb: String) -> void:
	_text.text = bb
	reset_size()
	visible = not bb.is_empty()


## 依据目标挖孔矩形摆放(每帧调用, 容器尺寸稳定后自动收敛)
func place(hole: Rect2, vp_size: Vector2) -> void:
	if not visible:
		return
	var margin := 12.0
	var pos: Vector2
	if hole.size == Vector2.ZERO:
		# 无目标 → 底部居中
		pos = Vector2((vp_size.x - size.x) * 0.5, vp_size.y - size.y - margin * 2.0)
	else:
		pos = Vector2(hole.get_center().x - size.x * 0.5, hole.end.y + margin)
		if pos.y + size.y > vp_size.y - margin:  # 下方放不下 → 上方
			pos.y = hole.position.y - size.y - margin
		if pos.y < margin:  # 都放不下 → 底部
			pos.y = vp_size.y - size.y - margin * 2.0
	pos.x = clampf(pos.x, margin, maxf(margin, vp_size.x - size.x - margin))
	position = pos