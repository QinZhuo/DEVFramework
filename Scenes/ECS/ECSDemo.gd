extends Control

## ECS 对比演示 —— 同一逻辑, 两种实现, 同屏实时对比
##
## 左右两个世界各 N 个实体, 挂完全相同的组件, 跑完全相同的逻辑:
##   - 移动: pos += vel * delta
##   - 治疗: hp = min(max_hp, hp + 5*delta*60)
##
##   ◀ 左侧(绿色): Tier0 原生批量 —— 纯 C++ 循环, GDScript 仅发起几次调用
##   ▶ 右侧(橙色): Tier2 脚本系统 —— GDScript 逐实体循环访问列数组
##
## 顶部实时显示两边每帧耗时与加速比, 肉眼可见差距。
## 运行: F5 运行 Scenes/ECS/ECSDemo.tscn

@export var entity_count: int = 10000
@export var sync_interval: int = 3  # 每 N 帧同步一次可视化

@onready var stats_label: Label = %StatsLabel
@onready var world_left: ECSPointCloud = %WorldLeft
@onready var world_right: ECSPointCloud = %WorldRight

var world_tier0: ECSWorld   # 原生
var world_tier2: ECSWorld   # 脚本

var _native_ms := 0.0
var _script_ms := 0.0
var _frame := 0


func _ready() -> void:
	_setup_worlds()
	_spawn_entities()
	_world_left_ready()
	_update_stats()


func _setup_worlds() -> void:
	# 两个隔离世界(各自独立 ECSCore), 保证对比互不干扰
	world_tier0 = ECSWorld.new(false)
	world_tier0.register_component(HealthComponent)
	world_tier0.register_component(ECSDemoMoveComponent)
	world_tier0.register_system(ECSNativeHealSystem.new(), 10)   # Tier0 治疗
	world_tier0.register_system(ECSMoveSystem.new(), 20)         # Tier0 移动

	world_tier2 = ECSWorld.new(false)
	world_tier2.register_component(HealthComponent)
	world_tier2.register_component(ECSDemoMoveComponent)
	world_tier2.register_system(HealSystem.new(), 10)            # Tier2 治疗
	world_tier2.register_system(ECSScriptMoveSystem.new(), 20)   # Tier2 移动


func _spawn_entities() -> void:
	var n := entity_count
	for i in n:
		var e0 := world_tier0.create_entity()
		world_tier0.add_component(e0, HealthComponent)
		world_tier0.add_component(e0, ECSDemoMoveComponent)
		var e2 := world_tier2.create_entity()
		world_tier2.add_component(e2, HealthComponent)
		world_tier2.add_component(e2, ECSDemoMoveComponent)
		var angle := randf() * TAU
		var speed := 40.0 + randf() * 80.0
		var px := randf_range(20.0, 555.0)   # 左半边
		var qx := randf_range(595.0, 1130.0) # 右半边
		var py := randf_range(20.0, 700.0)
		world_tier0.set_field(e0, ECSDemoMoveComponent, &"pos", Vector2(px, py))
		world_tier0.set_field(e0, ECSDemoMoveComponent, &"vel", Vector2(cos(angle), sin(angle)) * speed)
		world_tier2.set_field(e2, ECSDemoMoveComponent, &"pos", Vector2(qx, py))
		world_tier2.set_field(e2, ECSDemoMoveComponent, &"vel", Vector2(cos(angle), sin(angle)) * speed)
		# 血量对称
		var max_hp := 100 + (i % 50)
		var hp := max_hp - (i % 40)
		world_tier0.set_field(e0, HealthComponent, &"hp", hp)
		world_tier0.set_field(e0, HealthComponent, &"max_hp", max_hp)
		world_tier2.set_field(e2, HealthComponent, &"hp", hp)
		world_tier2.set_field(e2, HealthComponent, &"max_hp", max_hp)


func _world_left_ready() -> void:
	world_left.set_color(Color(0.3, 1.0, 0.5))
	world_right.set_color(Color(1.0, 0.6, 0.2))


func _process(delta: float) -> void:
	if world_tier0 == null:
		return
	# Tier0 计时
	var t0 := Time.get_ticks_usec()
	world_tier0.tick(delta)
	_native_ms = (Time.get_ticks_usec() - t0) / 1000.0
	# Tier2 计时
	var t1 := Time.get_ticks_usec()
	world_tier2.tick(delta)
	_script_ms = (Time.get_ticks_usec() - t1) / 1000.0
	# 隔帧同步可视化
	_frame += 1
	if _frame % sync_interval == 0:
		_sync_visual()
		_update_stats()

func _sync_visual() -> void:
	var pos0: PackedVector2Array = world_tier0.get_column(ECSDemoMoveComponent, &"pos")
	var pos2: PackedVector2Array = world_tier2.get_column(ECSDemoMoveComponent, &"pos")
	world_left.set_points(pos0)
	world_right.set_points(pos2)


func _update_stats() -> void:
	var speedup := _script_ms / maxf(_native_ms, 0.0001)
	stats_label.text = "ECS 对比 ｜ 实体: %d x2\n◀ Tier0 原生批量: %.3f ms\n▶ Tier2 脚本系统: %.3f ms\n⚡ 加速比: %.1f x" % [
		entity_count, _native_ms, _script_ms, speedup]
