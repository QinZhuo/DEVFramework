extends Control

## ECS 性能实验室 —— 四路实现任意两两对比(同一逻辑: 治疗)
##
## 四路"使用方式"做完全相同的治疗逻辑(hp 每秒 +5, 封顶 max_hp):
##   A. 手写脚本层   : ECS + GDScript 循环(HealSystem)
##   B. 声明规则层   : ECS + 声明式规则(HealRule, C++ 批量)
##   C. 原生API层   : ECS + 直接 batch 调用(C++ 批量)
##   D. 普通 Node 实现: 传统 OOP, 每实体一个 Node2D + _process
##
## 可任意选两路并排对比, 每帧显示各自耗时与加速比。
## 运行: F5 运行 Scenes/ECS/ECSPerfLab.tscn

@export var entity_count: int = 50000     # 每路实体数(普通Node路会明显卡)
@export var compare_l: String = "声明规则层"   # 左路
@export var compare_r: String = "原生API层"    # 右路

@onready var stats_label: Label = %StatsLabel
@onready var cloud_l: ECSPointCloud = %CloudL
@onready var cloud_r: ECSPointCloud = %CloudR
@onready var label_l: Label = %LabelL
@onready var label_r: Label = %LabelR
@onready var switch_l_button: Button = %SwitchLButton
@onready var switch_r_button: Button = %SwitchRButton

## 四路实现的实体 ID 数组(ECS 用) / Node 数组(普通实现用)
var _ecs_worlds: Dictionary = {}   # name -> ECSWorld
var _ecs_ids: Dictionary = {}      # name -> Array[实体ID]
var _plain_nodes: Array[PlainNodeUnit] = []
var _plain_enabled := false

var _ms_l := 0.0
var _ms_r := 0.0
var _frame := 0

const MODES := ["手写脚本层", "声明规则层", "原生API层", "普通Node实现"]


func _ready() -> void:
	switch_l_button.pressed.connect(_on_switch_l_pressed)
	switch_r_button.pressed.connect(_on_switch_r_pressed)
	_setup_all()
	_apply_comparison()
	_update_stats()


func _setup_all() -> void:
	# ---- ECS 三路 ----
	for mode in MODES:
		if mode == "普通Node实现":
			continue
		var w := ECSWorld.new(false)
		w.register_component(HealthComponent)
		w.register_component(ECSDemoMoveComponent)
		var ids := []
		for i in entity_count:
			var e := w.create_entity()
			w.add_component(e, HealthComponent)
			w.set_field(e, HealthComponent, &"hp", i % 100)
			w.set_field(e, HealthComponent, &"max_hp", 120)
			ids.append(e)
		# 按模式注册治疗逻辑(四路统一: 移动+治疗)
		match mode:
			"手写脚本层":
				w.register_system(ECSScriptMoveSystem.new(), 20)
				w.register_system(HealSystem.new(), 10)
			"声明规则层":
				w.register_system(ECSMoveSystem.new(), 20)  # 移动走原生(声明规则暂不支持向量)
				w.register_rule(HealRule.new(), 10)
			"原生API层":
				w.register_system(ECSMoveSystem.new(), 20)
				w.register_system(ECSNativeHealSystem.new(), 10)
		_ecs_worlds[mode] = w
		_ecs_ids[mode] = ids

	# ---- 普通 Node 实现 ----
	for i in entity_count:
		var unit := PlainNodeUnit.new()
		unit.position = Vector2(randf_range(20.0, 1130.0), randf_range(20.0, 700.0))
		unit.vel = Vector2(randf() * 2.0 - 1.0, randf() * 2.0 - 1.0).normalized() * 30.0
		unit.hp = i % 100
		unit.logic_enabled = false
		%WorldRoot.add_child(unit)
		_plain_nodes.append(unit)

	# 可视化
	var step := ceili(entity_count / 3000.0)
	cloud_l.set_sample_step(step)
	cloud_r.set_sample_step(step)
	cloud_l.set_color(Color(0.3, 1.0, 0.5))
	cloud_r.set_color(Color(1.0, 0.6, 0.2))


func _apply_comparison() -> void:
	# 左路
	var l_enabled := false
	match compare_l:
		"普通Node实现":
			l_enabled = true
		_:
			pass
	# 暂停所有, 只开选中的两路
	for m in MODES:
		if _ecs_worlds.has(m):
			_ecs_worlds[m]._systems[0].enabled = (m == compare_l or m == compare_r) if not _ecs_worlds[m]._systems.is_empty() else false
	for u in _plain_nodes:
		u.logic_enabled = (compare_l == "普通Node实现" or compare_r == "普通Node实现")
	_plain_enabled = (compare_l == "普通Node实现" or compare_r == "普通Node实现")
	# 标题
	label_l.text = "◀ %s" % compare_l
	label_r.text = "▶ %s" % compare_r


func _process(delta: float) -> void:
	if _ecs_worlds.is_empty():
		return
	# 左路计时
	var t0 := Time.get_ticks_usec()
	_tick_mode(compare_l, delta)
	var t1 := Time.get_ticks_usec()
	_ms_l = (t1 - t0) / 1000.0
	# 右路计时
	var t2 := Time.get_ticks_usec()
	_tick_mode(compare_r, delta)
	var t3 := Time.get_ticks_usec()
	_ms_r = (t3 - t2) / 1000.0
	# 可视化 + 回弹
	_frame += 1
	if _frame % 3 == 0:
		_sync_visual(compare_l, cloud_l)
		_sync_visual(compare_r, cloud_r)
		_bounce_all()
		_update_stats()


func _tick_mode(mode: String, delta: float) -> void:
	if _ecs_worlds.has(mode):
		_ecs_worlds[mode].tick(delta)
	elif mode == "普通Node实现":
		for u in _plain_nodes:
			u._process(delta)


func _sync_visual(mode: String, cloud: ECSPointCloud) -> void:
	if _ecs_worlds.has(mode):
		var pos: PackedVector2Array = _ecs_worlds[mode].get_column(ECSDemoMoveComponent, &"pos")
		cloud.set_points(pos)
	else:
		var pts := PackedVector2Array()
		for u in _plain_nodes:
			pts.append(u.position)
		cloud.set_points(pts)


func _bounce_all() -> void:
	for m in MODES:
		if _ecs_worlds.has(m) and (m == compare_l or m == compare_r):
			_bounce_ecs(_ecs_worlds[m])
	for u in _plain_nodes:
		if _plain_enabled:
			u.bounce()


func _bounce_ecs(w: ECSWorld) -> void:
	var pos: PackedVector2Array = w.get_column(ECSDemoMoveComponent, &"pos")
	var vel: PackedVector2Array = w.get_column(ECSDemoMoveComponent, &"vel")
	var n := mini(pos.size(), vel.size())
	var changed := false
	for i in n:
		if pos[i].x < 10.0 or pos[i].x > 1140.0:
			vel[i].x = -vel[i].x
			pos[i].x = clampf(pos[i].x, 10.0, 1140.0)
			changed = true
		if pos[i].y < 10.0 or pos[i].y > 710.0:
			vel[i].y = -vel[i].y
			pos[i].y = clampf(pos[i].y, 10.0, 710.0)
			changed = true
	if changed:
		w.set_column(ECSDemoMoveComponent, &"pos", pos)
		w.set_column(ECSDemoMoveComponent, &"vel", vel)


func _update_stats() -> void:
	var speedup := _ms_r / maxf(_ms_l, 0.0001)
	stats_label.text = "ECS 性能实验室 ｜ 每路实体: %d\n\n◀ %s: %.3f ms\n▶ %s: %.3f ms\n\n⚡ 右/左 = %.2f 倍\n(越小表示右路越快)" % [
		entity_count, compare_l, _ms_l, compare_r, _ms_r, speedup]


## 切换对比(按钮)
func _on_switch_l_pressed() -> void:
	var i := MODES.find(compare_l)
	compare_l = MODES[(i + 1) % MODES.size()]
	_apply_comparison()
	_update_stats()


func _on_switch_r_pressed() -> void:
	var i := MODES.find(compare_r)
	compare_r = MODES[(i + 1) % MODES.size()]
	_apply_comparison()
	_update_stats()
