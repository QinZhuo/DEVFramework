class_name BodyVisual extends Node2D
## 生态箱：通用圆形身体视觉。
## GoapAgent 基类为 Node（纯大脑），视觉/位置由挂在 agent 下的本节点承载。

@export var radius: float = 11.0
@export var body_color := Color.WHITE
@export var eye_color := Color(0.15, 0.15, 0.22)
@export var show_eyes := true


func _draw() -> void:
	draw_circle(Vector2.ZERO, radius, body_color)
	if show_eyes and radius >= 8.0:
		draw_circle(Vector2(-radius * 0.32, -radius * 0.36), radius * 0.22, eye_color)
		draw_circle(Vector2(radius * 0.32, -radius * 0.36), radius * 0.22, eye_color)
