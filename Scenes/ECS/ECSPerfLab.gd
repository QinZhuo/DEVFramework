extends Control

## ECS 性能实验室 —— 两种模式, 四路实现对比
##
## 模式1: 战斗玩法 —— 细胞吞并战(互攻/受伤变小/击杀变大)
## 模式2: 纯数值热点 —— 大规模数值结算(回血/伤害), 展示实现方式差异
##
## 四路实现:
##   A. 手写脚本层 : ECS + GDScript 循环
##   B. 声明规则层 : ECS + 声明规则(ECSRule)
##   C. 原生API层  : ECS + batch 批量运算
##   D. 普通Node实现: 传统 OOP

@export var entity_count: int = 600

## 确定性随机种子: 三路实现用相同种子 + 相同生成逻辑 → 初始布局完全一致
const INIT_SEED := 20260808

@onready var stats_label: Label = %StatsLabel
@onready var cloud_l: ECSPointCloud = %CloudL
@onready var cloud_r: ECSPointCloud = %CloudR
@onready var label_l: Label = %LabelL
@onready var label_r: Label = %LabelR
@onready var switch_l_button: Button = %SwitchLButton
@onready var switch_r_button: Button = %SwitchRButton
@onready var mode_button: Button = %ModeButton

const MODE_BATTLE := "战斗玩法"
const MODE_NUMHOT := "纯数值热点"
var current_mode: String = MODE_BATTLE
var MODES2 := [MODE_BATTLE, MODE_NUMHOT]

var _ecs_worlds: Dictionary = {}   # mode -> ECSWorld
var _visuals: Dictionary = {}      # mode -> BattleVisualizer
var _plain_nodes: Array[PlainNodeUnit] = []

var compare_l: String = "手写脚本层"
var compare_r: String = "声明规则层"

const MODE_COLORS := {
	"手写脚本层": Color(0.3, 1.0, 0.5),
	"声明规则层": Color(0.3, 0.8, 1.0),
	"原生API层": Color(0.9, 0.5, 1.0),
	"普通Node实现": Color(1.0, 0.6, 0.2),
}

const MODES := ["手写脚本层", "声明规则层", "原生API层", "普通Node实现"]

var _ms_l := 0.0
var _ms_r := 0.0
var _frame := 0


func _ready() -> void:
	switch_l_button.pressed.connect(_on_switch_l_pressed)
	switch_r_button.pressed.connect(_on_switch_r_pressed)
	mode_button.pressed.connect(_on_mode_pressed)
	_rebuild_all()
	_apply_comparison()
	_update_stats()


func _on_mode_pressed() -> void:
	var i := MODES2.find(current_mode)
	current_mode = MODES2[(i + 1) % MODES2.size()]
	_rebuild_all()
	_apply_comparison()
	_update_stats()


## 重建所有世界(切模式时)
func _rebuild_all() -> void:
	# 清理旧的(RefCounted 置 null 自动回收)
	_ecs_worlds.clear()
	_visuals.clear()
	for u in _plain_nodes:
		if is_instance_valid(u):
			u.queue_free()
	_plain_nodes.clear()

	if current_mode == MODE_BATTLE:
		_build_battle_worlds()
	else:
		_build_numhot_worlds()

	# 点阵抽样 + 分屏
	var step := ceili(entity_count / 2000.0)
	cloud_l.set_sample_step(step)
	cloud_r.set_sample_step(step)
	cloud_l.set_bounds(Rect2(0, 0, 575, 720))
	cloud_r.set_bounds(Rect2(575, 0, 575, 720))


# ===================== 模式1: 战斗玩法 =====================

## 用确定性种子生成初始布局(位置/速度/队伍), 供所有实现共用 → 布局完全一致
func _gen_battle_layout(count: int, half: int, out_pos: PackedVector2Array,
		out_vel: PackedVector2Array, out_team: PackedInt32Array) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = INIT_SEED
	for i in count:
		var team := 0 if i < half else 1
		var angle := rng.randf() * TAU
		out_pos[i] = Vector2(rng.randf_range(20.0, 1130.0), rng.randf_range(20.0, 700.0))
		out_vel[i] = Vector2(cos(angle), sin(angle)) * rng.randf_range(20.0, 50.0)
		out_team[i] = team


func _build_battle_worlds() -> void:
	var half := entity_count / 2
	# 预生成一份布局, 所有实现共用 → 三路起点完全一致
	var layout_pos := PackedVector2Array(); layout_pos.resize(entity_count)
	var layout_vel := PackedVector2Array(); layout_vel.resize(entity_count)
	var layout_team := PackedInt32Array(); layout_team.resize(entity_count)
	_gen_battle_layout(entity_count, half, layout_pos, layout_vel, layout_team)

	for mode in MODES:
		if mode == "普通Node实现":
			continue
		var w := ECSWorld.new(false)
		w.register_component(BattleCell)
		for i in entity_count:
			var e := w.create_entity()
			w.add_component(e, BattleCell)
			w.set_field(e, BattleCell, &"pos", layout_pos[i])
			w.set_field(e, BattleCell, &"vel", layout_vel[i])
			w.set_field(e, BattleCell, &"hp", 100.0)
			w.set_field(e, BattleCell, &"max_hp", 100.0)
			w.set_field(e, BattleCell, &"team", layout_team[i])
			w.set_field(e, BattleCell, &"dmg", 5.0)
			w.set_field(e, BattleCell, &"size", 10.0)
		match mode:
			"手写脚本层":
				w.register_system(BattleSystem.new(), 20)
				w.register_system(BattleSizeSystem.new(), 10)
				w.register_system(BattleHealSystem.new(), 5)
			"声明规则层":
				w.register_system(BattleSystem.new(), 20)
				w.register_system(BattleSizeSystem.new(), 10)
				w.register_rule(BattleRecoverRule.new(), 5)
			"原生API层":
				w.register_system(BattleSystem.new(), 20)
				w.register_system(BattleSizeSystem.new(), 10)
				w.register_system(BattleNativeHealSystem.new(), 5)
		_ecs_worlds[mode] = w
		var vis := BattleVisualizer.new(w, null)
		_visuals[mode] = vis

	# 普通 Node 实现: 与 ECS 完全相同的布局、相同的数量
	var plain_all: Array[PlainNodeUnit] = []
	for i in entity_count:
		var unit := PlainNodeUnit.new()
		unit.position = layout_pos[i]
		unit.vel = layout_vel[i]
		unit.team = layout_team[i]
		unit.hp = 100.0
		unit.max_hp = 100.0
		unit.logic_enabled = false
		%WorldRoot.add_child(unit)
		plain_all.append(unit)
	for unit in plain_all:
		unit.all_units = plain_all
	_plain_nodes = plain_all


# ===================== 模式2: 纯数值热点 =====================

func _build_numhot_worlds() -> void:
	# 预生成一份布局(hp/pos/team), 所有实现共用
	var layout_pos := PackedVector2Array(); layout_pos.resize(entity_count)
	var layout_hp := PackedFloat32Array(); layout_hp.resize(entity_count)
	var layout_team := PackedInt32Array(); layout_team.resize(entity_count)
	var rng := RandomNumberGenerator.new()
	rng.seed = INIT_SEED
	for i in entity_count:
		layout_hp[i] = 20.0 + rng.randf() * 80.0
		layout_team[i] = i % 2
		layout_pos[i] = Vector2(rng.randf()*1100, rng.randf()*690)

	for mode in MODES:
		if mode == "普通Node实现":
			continue
		var w := ECSWorld.new(false)
		w.register_component(BattleCell)
		for i in entity_count:
			var e := w.create_entity()
			w.add_component(e, BattleCell)
			w.set_field(e, BattleCell, &"hp", layout_hp[i])
			w.set_field(e, BattleCell, &"max_hp", 100.0)
			w.set_field(e, BattleCell, &"dmg", 5.0)
			w.set_field(e, BattleCell, &"team", layout_team[i])
			w.set_field(e, BattleCell, &"size", 10.0)
			w.set_field(e, BattleCell, &"pos", layout_pos[i])
		# 三路用各自数值实现(相同逻辑)
		match mode:
			"手写脚本层":
				w.register_system(NumHotSystem.new(), 10)
			"声明规则层":
				w.register_rule(NumHotRule.new(), 10)
			"原生API层":
				w.register_system(NumHotNativeSystem.new(), 10)
		_ecs_worlds[mode] = w
		var vis := BattleVisualizer.new(w, null)
		_visuals[mode] = vis

	# 普通 Node 实现: 与 ECS 相同的数量与布局
	var plain_all: Array[PlainNodeUnit] = []
	for i in entity_count:
		var unit := PlainNodeUnit.new()
		unit.position = layout_pos[i]
		unit.vel = Vector2.ZERO
		unit.team = layout_team[i]
		unit.hp = layout_hp[i]
		unit.max_hp = 100.0
		unit.numhot_mode = true
		unit.logic_enabled = false
		%WorldRoot.add_child(unit)
		plain_all.append(unit)
	for unit in plain_all:
		unit.all_units = plain_all
	_plain_nodes = plain_all


func _apply_comparison() -> void:
	label_l.text = "◀ %s" % compare_l
	label_l.modulate = MODE_COLORS[compare_l]
	label_r.text = "▶ %s" % compare_r
	label_r.modulate = MODE_COLORS[compare_r]
	var plain_selected := (compare_l == "普通Node实现" or compare_r == "普通Node实现")
	for m in MODES:
		if _ecs_worlds.has(m):
			_ecs_worlds[m].set_paused(m != compare_l and m != compare_r)
	for u in _plain_nodes:
		if not is_instance_valid(u):
			continue
		u.logic_enabled = plain_selected
		u.visible = plain_selected
	if _visuals.has(compare_l):
		_visuals[compare_l].cloud = cloud_l
	if _visuals.has(compare_r):
		_visuals[compare_r].cloud = cloud_r
	_update_stats()


func _process(delta: float) -> void:
	if _ecs_worlds.is_empty():
		return
	_check_battle_round()
	if _ecs_worlds.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	_tick_mode(compare_l, delta)
	var t1 := Time.get_ticks_usec()
	_ms_l = (t1 - t0) / 1000.0
	var t2 := Time.get_ticks_usec()
	_tick_mode(compare_r, delta)
	var t3 := Time.get_ticks_usec()
	_ms_r = (t3 - t2) / 1000.0
	_frame += 1
	if _frame % 3 == 0:
		if _visuals.has(compare_l):
			_visuals[compare_l].refresh()
		if _visuals.has(compare_r):
			_visuals[compare_r].refresh()
		if compare_l == "普通Node实现":
			_sync_plain(cloud_l)
		if compare_r == "普通Node实现":
			_sync_plain(cloud_r)
		_update_stats()


func _tick_mode(mode: String, delta: float) -> void:
	if _ecs_worlds.has(mode):
		_ecs_worlds[mode].tick(delta)
	elif mode == "普通Node实现":
		for u in _plain_nodes:
			if not is_instance_valid(u) or u.dead:
				continue
			u._process(delta)


func _sync_plain(cloud: ECSPointCloud) -> void:
	var pts := PackedVector2Array()
	var sizes := PackedFloat32Array()
	var cols := PackedColorArray()
	for u in _plain_nodes:
		if not is_instance_valid(u) or u.dead:
			continue
		pts.append(u.position)
		# 与 BattleVisualizer 一致的统一样式: 大小/透明度 = f(hp)
		var ratio := clampf(u.hp / maxf(u.max_hp, 1.0), 0.0, 1.0)
		sizes.append(3.0 + ratio * 23.0)
		var alpha := 0.15 + ratio * 0.85
		if ratio > 0.66:
			cols.append(Color(0.3, 0.95, 0.6, alpha))
		elif ratio > 0.33:
			cols.append(Color(0.98, 0.85, 0.25, alpha))
		else:
			cols.append(Color(0.95, 0.3, 0.25, alpha))
	cloud.set_points(pts)
	cloud.set_sizes(sizes)
	cloud.set_colors(cols)


func _update_stats() -> void:
	var speedup := _ms_r / maxf(_ms_l, 0.0001)
	var mode_hint := "🦠 各自为战: 细胞互攻/受伤变小/击杀吞并变大"
	if current_mode == MODE_NUMHOT:
		mode_hint = "🔢 纯数值结算: 回血/伤害(大规模数值, 体现实现差异)"
	stats_label.text = "性能实验室[%s] ｜ 每路实体: %d\n\n◀ %s: %.3f ms\n▶ %s: %.3f ms\n\n⚡ 右/左 = %.2f 倍\n(越小表示右路越快)\n\n%s" % [
		current_mode, entity_count, compare_l, _ms_l, compare_r, _ms_r, speedup, mode_hint]


func _on_switch_l_pressed() -> void:
	var i := MODES.find(compare_l)
	compare_l = MODES[(i + 1) % MODES.size()]
	if current_mode == MODE_BATTLE:
		_rebuild_all()  # 战斗模式切路→重新开局, 保证两路从同一起点公平对比
	_apply_comparison()  # 重建后必须重新绑定 cloud/设置 pause, 否则画面不动


func _on_switch_r_pressed() -> void:
	var i := MODES.find(compare_r)
	compare_r = MODES[(i + 1) % MODES.size()]
	if current_mode == MODE_BATTLE:
		_rebuild_all()
	_apply_comparison()


## 战斗进行中: 对比两路总活细胞过低时自动重开一轮,
## 避免"一路打空、另一路还满"造成的负载不公平
func _check_battle_round() -> void:
	if current_mode != MODE_BATTLE:
		return
	var total := 0
	for m in [compare_l, compare_r]:
		if _ecs_worlds.has(m):
			total += _ecs_worlds[m].count(BattleCell)
	if total < entity_count:
		_rebuild_all()
		_apply_comparison()
