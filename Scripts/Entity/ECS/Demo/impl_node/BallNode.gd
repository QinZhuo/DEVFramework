class_name DemoNodeBall
extends Node2D

## 普通 Node 实现的小球节点 —— 纯 OOP 对照: 每个小球 = 一个 Node2D,
## 数据存对象属性, 逻辑写在 _process, 节点本身即显示(_draw 画色块, 位置 = position)。
## 与另外两种 ECS 实现做完全相同的逻辑。

const HP_RATE := 2.0
var max_ball_size: float = 8.0   # 100 hp 时的边长(0 hp 消失)
var color: Color = Color(0.3, 0.7, 1.0)

var vx: float = 0.0
var vy: float = 0.0
var hp: float = 50.0
var dir: int = 1
var size: float = 5.0

var logic_enabled: bool = true


func _process(delta: float) -> void:
	if not logic_enabled:
		return
	# 移动
	position.x += vx * delta
	position.y += vy * delta
	# 边界回弹
	if position.x < 10.0 or position.x > 1150.0:
		vx = -vx
		position.x = clampf(position.x, 10.0, 1150.0)
	if position.y < 10.0 or position.y > 710.0:
		vy = -vy
		position.y = clampf(position.y, 10.0, 710.0)
	# 生命值周期增减: 0 → 100 → 0
	hp += dir * HP_RATE * delta * 60.0
	if hp >= 100.0:
		hp = 100.0
		dir = -1
	elif hp <= 0.0:
		hp = 0.0
		dir = 1
	# 大小 = hp(0 消失, 100 最大)
	size = hp
	queue_redraw()


func _draw() -> void:
	var s := max_ball_size * size / 100.0
	if s < 0.5:
		return
	draw_rect(Rect2(-s * 0.5, -s * 0.5, s, s), color)
