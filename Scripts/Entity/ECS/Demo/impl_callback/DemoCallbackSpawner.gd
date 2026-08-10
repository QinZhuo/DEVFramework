class_name DemoCallbackSpawner
extends Node

## ECS 查询链回调实现的球生成脚本(不继承 World): 监听父 World 节点的 world_ready 信号生成球。
## 世界创建/系统注册/同步规则全部在场景的 World 节点里配置, 本脚本只负责生成实体数据与显示节点。
## 与 impl_query 共用 DemoQueryBall 组件 / DemoQueryBallNode 显示节点 / NodeLink 关联。

@export var ball_count := 10000
@export var init_seed := 20260808

var visuals: Array[DemoQueryBallNode] = []


func _ready() -> void:
	var world_node := get_parent() as World
	if world_node != null:
		world_node.world_ready.connect(_on_world_ready)


func _on_world_ready(ecs: ECSWorld) -> void:
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
		add_child(v)
		v.set_process(false)
		visuals.append(v)
		ecs.add_component(e, NodeLink, {"node_path": str(v.get_path())})
