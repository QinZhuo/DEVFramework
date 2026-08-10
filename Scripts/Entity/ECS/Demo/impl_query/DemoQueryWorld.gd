class_name DemoQueryWorld
extends World

## ECS 查询链实现的**场景化世界** —— 场景根挂本脚本(继承 World 桥接层)。
## 世界本身是 ECSWorld(Def): 要注册的系统(systems)在 ecsworld 的 Inspector 里配置,
## 同步规则在 ECSSyncSystem.field_rules 里配置; 本脚本只负责生成球实体数据与显示节点。
## 切换实现时 = 实例化/删除本场景(由 ECSDemo 调度)。

@export var ball_count := 10000
@export var init_seed := 20260808
@export var max_ball_size := 8.0

## 表格中显示的实现名(兼容 ECSDemo 调度)
var impl_name := "ECS查询链实现"

var visuals: Array[DemoQueryBallNode] = []


func _ready() -> void:
	super()          # World: 按 ecsworld(Def) 初始化世界 + 注册场景配置的系统
	_spawn_balls()


## 渲染开关: 控制场景内 ECSSyncSystem 的 render_enabled(渲染开/关对比用)。
func set_render_enabled(on: bool) -> void:
	if ecs == null:
		return
	for s in ecs._systems:
		if s is ECSSyncSystem:
			s.render_enabled = on


## 生成球实体(ECS 数据) + 显示节点(NodeLink 关联)。
func _spawn_balls() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = init_seed
	for i in ball_count:
		# 随机小球初始数据(与另三种实现同种子同布局)
		var pos := Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var vel := Vector2(cos(ang) * spd, sin(ang) * spd)
		var hp := rng.randf_range(0.0, 100.0)
		# 实体数据入 ECS
		var e := ecs.create_entity()
		ecs.add_component(e, DemoQueryBall)
		ecs.set_field(e, DemoQueryBall, &"pos", pos)
		ecs.set_field(e, DemoQueryBall, &"vel", vel)
		ecs.set_field(e, DemoQueryBall, &"hp", hp)
		# 显示节点: 位置/尺寸由 ECSSyncSystem 批量同步
		var v := DemoQueryBallNode.new()
		v.position = pos
		v.max_ball_size = max_ball_size
		add_child(v)
		v.set_process(false)
		visuals.append(v)
		# NodeLink 关联实体↔显示节点(只存 node_path, 同步字段由规则决定)
		ecs.add_component(e, NodeLink, {"node_path": str(v.get_path())})
