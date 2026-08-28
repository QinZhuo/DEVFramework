class_name ClickableBall extends Area3D
## 演示: 3D 可点击物体 — 左键/触摸点击时发出 clicked 信号。
##
## 交互语义归节点自己(过滤输入流、定义"什么算点击"), 信号 Def(NodeSignalDef) 只负责订阅。
## 演示/项目里任意 3D 可交互物体都应自带这类"点击信号", 而非由信号 Def 替它过滤输入。

signal clicked


func _ready() -> void:
	input_event.connect(_on_input_event)


func _on_input_event(_cam: Node, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape: int) -> void:
	var press := false
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		press = true
	elif event is InputEventScreenTouch and event.pressed:
		press = true
	if press:
		clicked.emit()
