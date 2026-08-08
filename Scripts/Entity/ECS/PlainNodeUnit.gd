class_name PlainNodeUnit
extends Node2D

## 普通 Node 实现 —— 传统 OOP 方式对照。
##
## 每个实体 = 一个 Node2D 对象, 数据存对象属性, 逻辑写在 _process 里。
## 与 ECS 方式做同样的事: 移动(pos += vel*delta) + 治疗(hp 回复)。
## 作为"普通实现"基准, 与 ECS 各种用法对比性能。

## 数据(类似 ECS 组件字段)
var hp: int = 100
var max_hp: int = 120
var vel: Vector2 = Vector2.ZERO

## 颜色(表现)
var dot_color: Color = Color.WHITE

## 统计: 每帧耗时(由 ECSPerfLab 读取)
var last_process_us: int = 0

## 是否暂停逻辑(对比时暂停未选中的实现)
var logic_enabled: bool = true


func _process(delta: float) -> void:
	if not logic_enabled:
		return
	var t0 := Time.get_ticks_usec()
	# 移动
	position += vel * delta
	# 治疗: 每秒 +5, 封顶 max_hp
	if hp < max_hp:
		hp = mini(hp + int(5.0 * delta * 60.0), max_hp)
	last_process_us = Time.get_ticks_usec() - t0


## 边界回弹(与 ECS demo 一致)
func bounce() -> void:
	if position.x < 10.0 or position.x > 1140.0:
		vel.x = -vel.x
		position.x = clampf(position.x, 10.0, 1140.0)
	if position.y < 10.0 or position.y > 710.0:
		vel.y = -vel.y
		position.y = clampf(position.y, 10.0, 710.0)
