class_name DemoQueryBallNode
extends Node2D

## ECS 查询链实现的显示节点 —— 实体数据在 ECS 列, 本节点是"纯表现"的独立节点:
## 每帧由 DemoQueryImpl 从 ECS 列批量同步 position / 显示尺寸。
## 对应框架"实体是数据、表现用节点"的方案(类似 NodeLink 关联 + 系统同步)。

var color: Color = Color(0.4, 0.9, 0.5)
var max_ball_size: float = 8.0
var _visual_size: float = 5.0
var visual_size: float:
	get:
		return _visual_size
	set(v):
		_visual_size = v
		queue_redraw()   # 显示边长变化自动重绘(可被 ECSSyncSystem 规则同步)


func set_visual_size(v: float) -> void:
	visual_size = v


func _draw() -> void:
	var s := max_ball_size * visual_size / 100.0
	if s < 0.5:
		return
	draw_rect(Rect2(-s * 0.5, -s * 0.5, s, s), color)
