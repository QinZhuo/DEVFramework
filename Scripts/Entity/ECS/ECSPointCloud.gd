class_name ECSPointCloud
extends Node2D

## ECS 实体可视化点阵 —— 从世界批量拉取 pos 列绘制。
## 支持抽样显示: 数据量大时只画部分点, 保持流畅。

var points: PackedVector2Array = []
var point_color: Color = Color.WHITE
var point_size: float = 2.0
var sizes: PackedFloat32Array = []   # 每点大小(可选, 空则用 point_size)
var colors: PackedColorArray = []    # 每点颜色(可选, 空则用 point_color)
var sample_step: int = 1  # 每 N 个点取 1 个(抽样, 1=全画)
var _dirty := true

## 显示区域(像素矩形)。非空时只在该区域内绘制, 区域外点忽略。
## 用于左右分屏对比: 左路 [0,575] 右路 [575,1150], 互不重叠。
var bounds: Rect2 = Rect2()


func set_points(new_points: PackedVector2Array) -> void:
	points = new_points
	_dirty = true


## 设置每点大小(与 points 等长, 空数组则用固定 point_size)
func set_sizes(new_sizes: PackedFloat32Array) -> void:
	sizes = new_sizes
	_dirty = true


## 设置每点颜色(与 points 等长, 空数组则用固定 point_color)
func set_colors(new_colors: PackedColorArray) -> void:
	colors = new_colors
	_dirty = true


func set_color(c: Color) -> void:
	point_color = c
	_dirty = true


## 设置显示区域(左/右半屏分区)。
## 传空 Rect2 表示不限制(全屏)。
func set_bounds(b: Rect2) -> void:
	bounds = b
	_dirty = true


## 设置抽样步长: 数据量大时加大步长只画部分点(统计仍按全量算)
func set_sample_step(step: int) -> void:
	sample_step = maxi(step, 1)
	_dirty = true


func _process(_delta: float) -> void:
	if _dirty:
		queue_redraw()
		_dirty = false


func _draw() -> void:
	if points.is_empty():
		return
	var use_sizes := sizes.size() == points.size()
	var use_colors := colors.size() == points.size()
	var i := 0
	var r := Rect2(Vector2.ZERO, Vector2(point_size, point_size))
	while i < points.size():
		var p := points[i]
		if bounds.size != Vector2.ZERO and not bounds.has_point(p):
			i += sample_step
			continue
		if use_sizes:
			r.size = Vector2(sizes[i], sizes[i])
		else:
			r.size = Vector2(point_size, point_size)
		if use_colors:
			r.position = p - r.size * 0.5
			draw_rect(r, colors[i])
		else:
			r.position = p - r.size * 0.5
			draw_rect(r, point_color)
		i += sample_step
