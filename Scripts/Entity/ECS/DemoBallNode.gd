class_name DemoBallNode
extends Node2D

## 普通 Node 实现 —— 传统 OOP 方式对照: 每个小球 = 一个 Node2D, 数据存对象属性,
## 逻辑写在 _process 里。与三路 ECS 实现做完全相同的逻辑(移动/边界/生命值周期/大小)。

const HP_RATE := 2.0

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
