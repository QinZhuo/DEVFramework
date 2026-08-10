class_name DemoQueryWorld
extends World

## ECS 查询链实现的场景化世界 —— 场景根挂本脚本(继承 World)。
## World 基类负责创建 ECSWorld + 注册场景配置的 systems; 本脚本只负责生成球实体与显示节点。
## 系统/同步规则在场景 Inspector 配置(根节点 systems + ECSSyncSystem.field_rules)。
## 场景放在 impl_query 脚本文件夹下, 由 ECSDemo 实例化/删除来切换实现。

@export var ball_count := 10000
@export var init_seed := 20260808
@export var max_ball_size := 8.0

var visuals: Array[DemoQueryBallNode] = []


func _ready() -> void:
	super()          # World: 创建 ECSWorld + 注册场景配置的系统
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
	for _i in ball_count:
		var pos := Vector2(rng.randf_range(20.0, 1140.0), rng.randf_range(20.0, 700.0))
		var ang := rng.randf() * TAU
		var spd := rng.randf_range(20.0, 60.0)
		var vel := Vector2(cos(ang) * spd, sin(ang) * spd)
		var hp := rng.randf_range(0.0, 100.0)
		var e := ecs.create_entity()
		ecs.add_component(e, DemoQueryBall)
		ecs.set_field(e, DemoQueryBall, &"pos", pos)
		ecs.set_field(e, DemoQueryBall, &"vel", vel)
		ecs.set_field(e, DemoQueryBall, &"hp", hp)
		var v := DemoQueryBallNode.new()
		v.position = pos
		v.max_ball_size = max_ball_size
		add_child(v)
		v.set_process(false)
		visuals.append(v)
		ecs.add_component(e, NodeLink, {"node_path": str(v.get_path())})
