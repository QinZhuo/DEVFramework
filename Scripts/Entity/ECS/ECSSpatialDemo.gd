extends Node2D

## 空间索引样例(RTS/弹幕原型): 每帧问"英雄周围 200 像素内有多少单位"。
##
## 演示的是**同一件事的两种做法**:
##   · 空间索引: spatial_query_radius (格子哈希, 只碰邻近格子)
##   · 全表扫  : 取整列 pos + 逐个 distance 比较(没有索引时只能这样)
## HUD 直接给出两者耗时与倍数 —— 单位越多、查询越频繁, 差距越大。
##
## 操作: 鼠标移动 = 英雄位置  滚轮 = 查询半径  1/2 = 切 1000/5000 单位

const Unit := preload("res://Scripts/Entity/ECS/ECSDemoMoveComponent.gd")
const COLORS := [Color(0.35, 0.65, 1.0, 0.75), Color(1.0, 0.45, 0.45, 0.95)]

@export var unit_count := 2000
@export var query_radius := 200.0
@export var queries_per_frame := 16
@export var world_size := Vector2(1600, 900)

var _world: ECSWorld = null
var _hud: Label = null
var _pos: PackedVector2Array = PackedVector2Array()
var _vel: PackedVector2Array = PackedVector2Array()
var _hits: PackedInt32Array = PackedInt32Array()
var _hero := Vector2(800, 450)
var _spatial_ms := -1.0
var _brute_ms := -1.0


func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 15)
	layer.add_child(_hud)
	randomize()
	_rebuild(unit_count)


func _rebuild(n: int) -> void:
	unit_count = n
	var w := ECSWorld.new(false)
	w.register_component(Unit)
	var pf := w.create_prefab()
	w.prefab_add(pf, Unit, {})
	w.instantiate(pf, n)
	var c := w.columns_of(Unit, [&"pos", &"vel"])
	_pos = c[&"pos"]
	_vel = c[&"vel"]
	for i in _pos.size():
		_pos[i] = Vector2(randf() * world_size.x, randf() * world_size.y)
		_vel[i] = Vector2(randf_range(-60.0, 60.0), randf_range(-60.0, 60.0))
	w.set_columns_of(Unit, {&"pos": _pos, &"vel": _vel})
	# 格子边长取查询半径: 一次查询最多扫 3×3 ~ 4×4 个格子
	w.spatial_enable(Unit, &"pos", maxf(query_radius, 16.0))
	_world = w
	_spatial_ms = -1.0
	_brute_ms = -1.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hero = (event as InputEventMouseMotion).position
	elif event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			query_radius = minf(query_radius + 40.0, 600.0)
			if _world != null:
				_world.spatial_enable(Unit, &"pos", maxf(query_radius, 16.0))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			query_radius = maxf(query_radius - 40.0, 40.0)
			if _world != null:
				_world.spatial_enable(Unit, &"pos", maxf(query_radius, 16.0))
	elif event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_1:
				_rebuild(1000)
			KEY_2:
				_rebuild(5000)


func _process(dt: float) -> void:
	if _world == null:
		return
	var t0 := Time.get_ticks_usec()
	# 单位持续移动 ⇒ 空间索引每帧都会失效并重建, 这就是真实场景下的代价
	for i in _pos.size():
		_pos[i] += _vel[i] * dt
		if _pos[i].x < 0.0 or _pos[i].x > world_size.x:
			_vel[i].x = -_vel[i].x
		if _pos[i].y < 0.0 or _pos[i].y > world_size.y:
			_vel[i].y = -_vel[i].y
	_world.set_columns_of(Unit, {&"pos": _pos})
	var move_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	# 一帧查 N 次(RTS/弹幕的真实形态: 每个单位问"附近有谁")。
	# 只查 1 次时, "全体移动 + 整表重建" 的成本会盖过收益 —— 那是 demo 的假象, 不是索引的问题。
	var n_q := maxi(queries_per_frame, 1)
	var points := PackedVector2Array()
	points.resize(n_q)
	for q in n_q:
		points[q] = Vector2(
			fposmod(float(q) * 137.5, world_size.x),
			fposmod(float(q) * 73.3, world_size.y))

	var t1 := Time.get_ticks_usec()
	for q in n_q:
		if q == 0:
			_hits = _world.spatial_query_radius(points[q], query_radius)
		else:
			_world.spatial_query_radius(points[q], query_radius)
	var s_ms := float(Time.get_ticks_usec() - t1) / 1000.0

	var t2 := Time.get_ticks_usec()
	var r2 := query_radius * query_radius
	var brute := 0
	for q in n_q:
		var c0 := points[q]
		for i in _pos.size():
			if _pos[i].distance_squared_to(c0) <= r2:
				if q == 0:
					brute += 1
	var b_ms := float(Time.get_ticks_usec() - t2) / 1000.0

	_spatial_ms = s_ms if _spatial_ms < 0.0 else lerpf(_spatial_ms, s_ms, 0.25)
	_brute_ms = b_ms if _brute_ms < 0.0 else lerpf(_brute_ms, b_ms, 0.25)

	var speedup := 0.0 if _spatial_ms <= 0.0 else _brute_ms / _spatial_ms
	var st := _world.spatial_stats()
	_hud.text = "\n".join(PackedStringArray([
		"空间索引样例   (鼠标=英雄  滚轮=半径  1/2=单位数)",
		"单位: %d   半径: %.0f   命中: %d (全表扫 %d)" % [_pos.size(), query_radius, _hits.size(), brute],
		"每帧 %d 次查询:  索引 %.3f ms   全表扫 %.3f ms   快 %.1f×" % [queries_per_frame, _spatial_ms, _brute_ms, speedup],
		"格子: %d 个 / %d 个实体   移动+写列: %.3f ms" % [int(st.get("cells", 0)), int(st.get("entities", 0)), move_ms],
	]))
	queue_redraw()


func _draw() -> void:
	if _world == null:
		return
	# 命中的用亮色、其余暗色。query_entities 与 columns_of 的聚合顺序一致,
	# 所以用 id 集合判断命中即可, 不必按 id 反查行号(O(n) 就够, 也不引入额外语义)。
	var hit_set := {}
	for e in _hits:
		hit_set[e] = true
	var ents := _world.query_entities(Unit)
	for i in mini(ents.size(), _pos.size()):
		var hit := hit_set.has(ents[i])
		draw_circle(_pos[i], 3.0 if hit else 1.6, COLORS[1] if hit else COLORS[0])
	draw_arc(_hero, query_radius, 0.0, TAU, 64, Color(1, 1, 1, 0.5), 1.5)
