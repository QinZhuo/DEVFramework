class_name ECSPointCloud
extends Node2D

## ECS 实体可视化点阵 —— 从世界批量拉取 pos 列绘制。
## 用于同屏对比 Tier0/Tier2 两种实现(不同颜色)。

var points: PackedVector2Array = []
var point_color: Color = Color.WHITE
var point_size: float = 2.0
var _dirty := true


func set_points(new_points: PackedVector2Array) -> void:
	points = new_points
	_dirty = true


func set_color(c: Color) -> void:
	point_color = c
	_dirty = true


func _process(_delta: float) -> void:
	if _dirty:
		queue_redraw()
		_dirty = false


func _draw() -> void:
	if points.is_empty():
		return
	var r := Rect2(Vector2.ZERO, Vector2(point_size, point_size))
	for p in points:
		r.position = p
		draw_rect(r, point_color)
