class_name PlainNodeUnit
extends Node2D

## 普通 Node 实现 —— 传统 OOP 方式对照。
##
## 每个实体 = 一个 Node2D 对象, 数据存对象属性, 逻辑写在 _process 里。
## 与 ECS 战斗模式(BattleSystem)做完全一样的事:
##   移动(pos += vel*delta, 边界回弹) + 找敌 + 攻击扣血 + 回血 + 大小更新 + 击杀吞并。
## 各自为战: 无阵营, 找最近的任何活细胞攻击。
## 作为"普通实现"基准, 与 ECS 各种用法对比性能。

## 数据(类似 ECS 组件字段)
var hp: float = 100.0
var max_hp: float = 100.0
var vel: Vector2 = Vector2.ZERO
var team: int = 0
var dmg: float = 5.0
var size: float = 10.0

## 共享实体列表(由 ECSDemo 注入, 用于找敌)
var all_units: Array[PlainNodeUnit] = []

## 颜色(表现)
var dot_color: Color = Color.WHITE

## 是否暂停逻辑(对比时暂停未选中的实现)
var logic_enabled: bool = true

## 是否已死亡(吞并被移除)
var dead: bool = false

## 模式: true=战斗玩法(找敌/攻击/吞并), false=纯数值热点(仅回血+伤害结算)
var numhot_mode: bool = false

## 统计: 每帧耗时(由 ECSDemo 读取)
var last_process_us: int = 0


func _process(delta: float) -> void:
	if not logic_enabled or dead:
		return
	var t0 := Time.get_ticks_usec()

	if numhot_mode:
		# ---- 纯数值热点: 与 NumHotSystem 完全一致 ----
		# 回血: hp = min(max_hp, hp + 2.5)
		if hp < max_hp:
			hp = minf(hp + 2.5, max_hp)
		# 3 次伤害结算: h -= 1.0, -1.0, -0.5 (下限 0)
		var h: float = hp
		h -= 1.0
		h -= 1.0
		h -= 0.5
		hp = maxf(h, 0.0)
		last_process_us = Time.get_ticks_usec() - t0
		return

	# ---- 战斗玩法: 移动 + 找敌 + 攻击 + 回血 + 大小 ----
	# 1) 移动 + 边界回弹
	position += vel * delta
	if position.x < 15 or position.x > 1135:
		vel.x = -vel.x
		position.x = clampf(position.x, 15.0, 1135.0)
	if position.y < 15 or position.y > 705:
		vel.y = -vel.y
		position.y = clampf(position.y, 15.0, 705.0)

	# 2) 找最近的活细胞(各自为战, 无阵营 —— 线性遍历共享列表, 传统方式)
	var nearest_enemy: PlainNodeUnit = null
	var nearest_dist := 1e18
	for u in all_units:
		if u == self or not is_instance_valid(u) or u.dead:
			continue
		var d := position.distance_squared_to(u.position)
		if d < nearest_dist:
			nearest_dist = d
			nearest_enemy = u

	if nearest_enemy != null:
		# 3) 攻击: 追击 + 近身扣血
		var dist := sqrt(nearest_dist)
		var dir := (nearest_enemy.position - position).normalized()
		vel = dir * (40.0 + (max_hp - hp) * 0.5)
		if dist < (size + nearest_enemy.size) * 1.4:
			nearest_enemy.hp -= dmg * (60.0 * delta) * 0.3
			if nearest_enemy.hp <= 0:
				nearest_enemy.dead = true
				# 4) 击杀吞并: 最近的活细胞吸收(各自为战)
				var absorb: PlainNodeUnit = null
				var ad := 1e18
				for u in all_units:
					if u == self or not is_instance_valid(u) or u.dead:
						continue
					var dd := position.distance_squared_to(u.position)
					if dd < ad:
						ad = dd
						absorb = u
				if absorb != null:
					absorb.hp = minf(absorb.hp + nearest_enemy.max_hp * 0.5, absorb.max_hp * 1.5)
				nearest_enemy.queue_free()
	else:
		vel = vel.lerp(Vector2.ZERO, 0.02)

	# 5) 回血(hp < 100 每秒 +2, 与 ECS 三路一致)
	if hp < 100.0:
		hp += 2.0 * (60.0 * delta) / 60.0

	# 6) 大小更新: size = 8 + hp * 0.08 (与 BattleSizeSystem 一致)
	size = 8.0 + hp * 0.08

	# 受伤闪红
	if hp < 40.0:
		dot_color = Color(1.0, 0.3, 0.3)
	elif hp < 70.0:
		dot_color = Color(1.0, 0.7, 0.3)

	last_process_us = Time.get_ticks_usec() - t0


## 边界回弹(保留)
func bounce() -> void:
	if position.x < 10.0 or position.x > 1140.0:
		vel.x = -vel.x
		position.x = clampf(position.x, 10.0, 1140.0)
	if position.y < 10.0 or position.y > 710.0:
		vel.y = -vel.y
		position.y = clampf(position.y, 10.0, 710.0)
