extends Control

## ECS 对比演示 —— 同一逻辑, 两种实现, 同屏实时对比
##
## 左右两个世界各 N 个实体, 挂完全相同的组件, 跑完全相同的逻辑:
##   - 移动: pos += vel * delta
##   - 治疗: hp = min(max_hp, hp + 5*delta*60)
##
##   ◀ 左侧(绿色): 「C++ 引擎直接算」 —— 逻辑全在 C++ 里跑, 脚本只喊一声"开始"
##   ▶ 右侧(橙色): 「GDScript 脚本算」 —— 逻辑在 GDScript 里逐实体循环
##
## 两者干的活一模一样, 唯一区别是"谁在干活"。
## 顶部实时显示: 每帧两边各花多少毫秒, 以及"快了多少倍"。
## 运行: F5 运行 Scenes/ECS/ECSDemo.tscn

@export var entity_count: int = 200000   # 每边 20 万实体
@export var sync_interval: int = 3       # 每 N 帧同步一次可视化
@export var visualize_samples: int = 10000  # 抽样绘制点数(数据大时只画部分)

@onready var stats_label: Label = %StatsLabel
@onready var world_left: ECSPointCloud = %WorldLeft
@onready var world_right: ECSPointCloud = %WorldRight

var world_cpp: ECSWorld     # C++ 引擎直接算
var world_script: ECSWorld  # GDScript 脚本算

var _cpp_ms := 0.0
var _script_ms := 0.0
var _frame := 0


func _ready() -> void:
	_setup_worlds()
	_spawn_entities()
	_setup_visual()
	_update_stats()


func _setup_worlds() -> void:
	# 两个隔离世界(各自独立 ECSCore), 保证对比互不干扰
	world_cpp = ECSWorld.new(false)
	world_cpp.register_component(HealthComponent)
	world_cpp.register_component(ECSDemoMoveComponent)
	world_cpp.register_system(ECSNativeHealSystem.new(), 10)  # C++ 治疗
	world_cpp.register_system(ECSMoveSystem.new(), 20)        # C++ 移动

	world_script = ECSWorld.new(false)
	world_script.register_component(HealthComponent)
	world_script.register_component(ECSDemoMoveComponent)
	world_script.register_system(HealSystem.new(), 10)            # 脚本治疗
	world_script.register_system(ECSScriptMoveSystem.new(), 20)   # 脚本移动


func _spawn_entities() -> void:
	var n := entity_count
	for i in n:
		var e0 := world_cpp.create_entity()
		world_cpp.add_component(e0, HealthComponent)
		world_cpp.add_component(e0, ECSDemoMoveComponent)
		var e2 := world_script.create_entity()
		world_script.add_component(e2, HealthComponent)
		world_script.add_component(e2, ECSDemoMoveComponent)
		var angle := randf() * TAU
		var speed := 40.0 + randf() * 80.0
		var px := randf_range(20.0, 555.0)   # 左半边
		var qx := randf_range(595.0, 1130.0) # 右半边
		var py := randf_range(20.0, 700.0)
		world_cpp.set_field(e0, ECSDemoMoveComponent, &"pos", Vector2(px, py))
		world_cpp.set_field(e0, ECSDemoMoveComponent, &"vel", Vector2(cos(angle), sin(angle)) * speed)
		world_script.set_field(e2, ECSDemoMoveComponent, &"pos", Vector2(qx, py))
		world_script.set_field(e2, ECSDemoMoveComponent, &"vel", Vector2(cos(angle), sin(angle)) * speed)
		# 血量对称
		var max_hp := 100 + (i % 50)
		var hp := max_hp - (i % 40)
		world_cpp.set_field(e0, HealthComponent, &"hp", hp)
		world_cpp.set_field(e0, HealthComponent, &"max_hp", max_hp)
		world_script.set_field(e2, HealthComponent, &"hp", hp)
		world_script.set_field(e2, HealthComponent, &"max_hp", max_hp)


func _setup_visual() -> void:
	world_left.set_color(Color(0.3, 1.0, 0.5))
	world_right.set_color(Color(1.0, 0.6, 0.2))
	# 20 万点全画会拖慢渲染, 抽样只画一部分(统计仍按全量)
	var step := ceili(entity_count / float(visualize_samples))
	world_left.set_sample_step(step)
	world_right.set_sample_step(step)


func _process(delta: float) -> void:
	if world_cpp == null:
		return
	# C++ 世界计时
	var t0 := Time.get_ticks_usec()
	world_cpp.tick(delta)
	_cpp_ms = (Time.get_ticks_usec() - t0) / 1000.0
	# 脚本世界计时
	var t1 := Time.get_ticks_usec()
	world_script.tick(delta)
	_script_ms = (Time.get_ticks_usec() - t1) / 1000.0
	# 隔帧同步可视化 + 边界回弹(计时之外, 不污染对比)
	_frame += 1
	if _frame % sync_interval == 0:
		_bounce_positions(world_cpp)
		_bounce_positions(world_script)
		_sync_visual()
		_update_stats()


## 让实体在屏幕边界内回弹(位置超出则翻转速度)。
## 统一在计时外执行, 保证左右对比只反映"移动+治疗"本身的差异。
func _bounce_positions(w: ECSWorld) -> void:
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


func _sync_visual() -> void:
	var pos0: PackedVector2Array = world_cpp.get_column(ECSDemoMoveComponent, &"pos")
	var pos2: PackedVector2Array = world_script.get_column(ECSDemoMoveComponent, &"pos")
	world_left.set_points(pos0)
	world_right.set_points(pos2)


func _update_stats() -> void:
	var speedup := _script_ms / maxf(_cpp_ms, 0.0001)
	var saved := _script_ms - _cpp_ms  # 每帧省下的毫秒
	stats_label.text = "同一件事, 两种做法 ｜ 实体: %d 个 x2\n\n◀ 左边(绿): C++ 引擎直接算\n   每帧只花: %.3f ms\n\n▶ 右边(橙): GDScript 脚本算\n   每帧要花: %.3f ms\n\n⚡ 用 C++ 快 %.1f 倍\n   每帧省下 %.2f ms" % [
		entity_count, _cpp_ms, _script_ms, speedup, saved]
