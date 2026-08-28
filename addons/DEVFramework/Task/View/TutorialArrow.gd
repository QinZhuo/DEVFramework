@tool
## 教程指示箭头 — 旋转指向目标(多边形默认朝 +X, 由 TutorialOverlay 每帧摆放)。
class_name TutorialArrow extends Control


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false